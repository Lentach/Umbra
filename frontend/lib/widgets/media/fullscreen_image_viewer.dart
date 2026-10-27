import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import 'swipe_down_to_dismiss.dart';

/// The fullscreen stage for stills and GIFs: swipe left/right between pages,
/// pinch-zoom, tap to close, and swipe-down-to-dismiss with the same physics
/// as the video viewer (`frontend/docs/composer-media.md`, "Fullscreen
/// swipe-down is animated").
///
/// Owner requests: the swipe-down (2026-09-14 — it dismissed a video and did
/// nothing on a photo) and the paging (2026-10-27 — the next photo took a
/// close and a reopen).
///
/// Gesture ownership is the load-bearing part, one owner at a time:
/// - At rest scale the vertical drag belongs to the dismiss and the horizontal
///   one to the pager. `InteractiveViewer` claims BOTH drags whenever panning
///   is enabled, so panning is enabled ONLY while zoomed in — and then the
///   dismiss is disarmed and the pager frozen, so a drag moves the photo.
/// - Two fingers are a pinch, never a page turn. `InteractiveViewer`'s scale
///   recognizer needs the spread to change 18 px; a pinch where one finger
///   leads travels the 18 px a page drag needs first (test-proven), so the
///   pager is frozen from the frame a second finger lands — that rebuild
///   drops its drag recognizer out of the arena.
class FullscreenImageViewer extends StatefulWidget {
  const FullscreenImageViewer({
    required this.pageKeys,
    required this.pageBuilder,
    super.key,
    this.initialIndex = 0,
    this.overlayBuilder,
    this.onPageChanged,
  });

  /// Identity of each page, in display order. When the list changes under an
  /// open viewer (a new message, a deleted or expired one), the viewer stays
  /// on the page it was showing; if that page is gone, the viewer closes.
  final List<Object> pageKeys;

  /// The decoded image widget for a page (`Image.memory` / `Image.network`).
  final IndexedWidgetBuilder pageBuilder;

  final int initialIndex;

  /// Controls for the CURRENT page (copy/save/close), mounted above the stage
  /// so a tap on them is claimed by their own recognizers, never by
  /// tap-to-close. They do not zoom or slide with the page.
  final IndexedWidgetBuilder? overlayBuilder;

  /// The page now on screen, after a swipe or after the list shifted under
  /// it.
  final ValueChanged<int>? onPageChanged;

  @override
  State<FullscreenImageViewer> createState() => _FullscreenImageViewerState();
}

class _FullscreenImageViewerState extends State<FullscreenImageViewer> {
  late final PageController _pages;
  late int _index;
  bool _zoomed = false;

  /// Set when the page on screen left [FullscreenImageViewer.pageKeys]; the
  /// pop is a frame away and [_index] no longer names a page.
  bool _closing = false;

  /// Fingers on the stage; two or more freeze the pager (class doc).
  int _pointers = 0;
  final FocusNode _keys = FocusNode(debugLabel: 'fullscreen-image-viewer');

  static const _kPageTurn = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.pageKeys.length - 1);
    _pages = PageController(initialPage: _index);
  }

  @override
  void didUpdateWidget(FullscreenImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_index >= oldWidget.pageKeys.length) return;
    final next = _nearestIndexOf(oldWidget.pageKeys[_index], _index);
    if (next == null) {
      // The page on screen was deleted or expired: never keep showing it.
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return;
    }
    if (next == _index) return;
    _index = next;
    widget.onPageChanged?.call(next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pages.hasClients) _pages.jumpToPage(_index);
    });
  }

  /// Index of [key] in the new [FullscreenImageViewer.pageKeys] closest to
  /// [from] — the same GIF url can appear twice in a chat.
  int? _nearestIndexOf(Object key, int from) {
    int? best;
    for (var i = 0; i < widget.pageKeys.length; i++) {
      if (widget.pageKeys[i] != key) continue;
      if (best == null || (i - from).abs() < (best - from).abs()) best = i;
    }
    return best;
  }

  @override
  void dispose() {
    _pages.dispose();
    _keys.dispose();
    super.dispose();
  }

  void _setPointers(int count) {
    final froze = _pointers > 1;
    _pointers = count;
    if (froze != count > 1) setState(() {});
  }

  void _turnTo(int index) {
    if (_zoomed || index < 0 || index >= widget.pageKeys.length) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(index);
    } else {
      _pages
          .animateToPage(
            index,
            duration: _kPageTurn,
            curve: Curves.easeOutCubic,
          )
          .ignore();
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _turnTo(_index - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _turnTo(_index + 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Touch platforms page with a swipe; elsewhere a mouse cannot drag a
  /// [PageView], so side arrows (and the arrow keys) do it.
  static bool get _touchPlatform =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    final count = widget.pageKeys.length;
    if (_closing || count == 0) return const ColoredBox(color: Colors.black);
    return Focus(
      focusNode: _keys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: SwipeDownToDismiss(
        onTap: () => Navigator.pop(context),
        canDrag: () => !_zoomed,
        child: Stack(
          children: [
            Positioned.fill(
              child: Listener(
                onPointerDown: (_) => _setPointers(_pointers + 1),
                onPointerUp: (_) => _setPointers(_pointers - 1),
                onPointerCancel: (_) => _setPointers(_pointers - 1),
                child: PageView.builder(
                  controller: _pages,
                  itemCount: count,
                  // Builds the neighbours too, so the next photo is already
                  // decrypted when the swipe reveals it.
                  allowImplicitScrolling: true,
                  physics: _zoomed || _pointers > 1
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  onPageChanged: (index) {
                    setState(() {
                      _index = index;
                      _zoomed = false;
                    });
                    widget.onPageChanged?.call(index);
                  },
                  itemBuilder: (context, index) => _ZoomablePage(
                    onZoomChanged: (zoomed) {
                      if (index == _index && zoomed != _zoomed) {
                        setState(() => _zoomed = zoomed);
                      }
                    },
                    child: widget.pageBuilder(context, index),
                  ),
                ),
              ),
            ),
            if (!_touchPlatform && count > 1) ...[
              if (_index > 0)
                Align(
                  alignment: Alignment.centerLeft,
                  child: _StageButton(
                    key: const ValueKey('media-viewer-previous'),
                    icon: Icons.chevron_left,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).previousPageTooltip,
                    onTap: () => _turnTo(_index - 1),
                  ),
                ),
              if (_index < count - 1)
                Align(
                  alignment: Alignment.centerRight,
                  child: _StageButton(
                    key: const ValueKey('media-viewer-next'),
                    icon: Icons.chevron_right,
                    tooltip: MaterialLocalizations.of(context).nextPageTooltip,
                    onTap: () => _turnTo(_index + 1),
                  ),
                ),
            ],
            if (count > 1)
              Positioned(
                top: 0,
                left: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text(
                          '${_index + 1} / $count',
                          key: const ValueKey('media-viewer-counter'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (widget.overlayBuilder != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: widget.overlayBuilder!(context, _index),
              ),
          ],
        ),
      ),
    );
  }
}

/// One page: pinch-zoom with panning enabled ONLY while zoomed in (see the
/// class doc of [FullscreenImageViewer]).
class _ZoomablePage extends StatefulWidget {
  const _ZoomablePage({required this.child, required this.onZoomChanged});

  final Widget child;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomablePage> createState() => _ZoomablePageState();
}

class _ZoomablePageState extends State<_ZoomablePage> {
  final TransformationController _transform = TransformationController();

  /// Rest scale within float noise: `InteractiveViewer` can settle a hair off
  /// 1.0 after a pinch-out that snaps back.
  static const _kRestScaleEpsilon = 0.01;

  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
  }

  @override
  void dispose() {
    _transform
      ..removeListener(_onTransform)
      ..dispose();
    super.dispose();
  }

  void _onTransform() {
    final zoomed =
        _transform.value.getMaxScaleOnAxis() > 1 + _kRestScaleEpsilon;
    if (zoomed == _zoomed || !mounted) return;
    setState(() => _zoomed = zoomed);
    widget.onZoomChanged(zoomed);
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _transform,
      minScale: 0.5,
      maxScale: 4,
      panEnabled: _zoomed,
      child: widget.child,
    );
  }
}

class _StageButton extends StatelessWidget {
  const _StageButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: IconButton(
          icon: Icon(icon, color: Colors.white),
          tooltip: tooltip,
          onPressed: onTap,
        ),
      ),
    );
  }
}
