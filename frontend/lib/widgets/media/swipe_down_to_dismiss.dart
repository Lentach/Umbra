import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Telegram-style swipe-down dismissal for a fullscreen media viewer: the
/// stage follows the finger, shrinks slightly, and the backdrop thins out;
/// on release it keeps travelling in the finger's direction — off the bottom
/// to dismiss, or back to rest — rather than popping from wherever the finger
/// let go (owner: "discards ugly").
///
/// Physics match `video_fullscreen_view.dart`, which shipped this interaction
/// first and still owns its own copy: its drag is entangled with chrome
/// hiding, playback state and a pointer interceptor over the platform
/// `<video>`, so migrating it is a separate change with real regression risk
/// on an owner-approved surface. The constants here are the ones it tuned —
/// if either side changes them, change both.
///
/// [canDrag] exists for zoomable content: pass `false` while an
/// `InteractiveViewer` is zoomed in, or panning a magnified image would close
/// the viewer instead of moving it.
class SwipeDownToDismiss extends StatefulWidget {
  const SwipeDownToDismiss({
    required this.child,
    super.key,
    this.canDrag,
    this.onTap,
  });

  final Widget child;

  /// Consulted at drag start. `null` means "always draggable".
  final bool Function()? canDrag;

  /// Tap-to-close and friends; kept here so callers do not stack a second
  /// [GestureDetector] that would compete for the vertical drag.
  final VoidCallback? onTap;

  @override
  State<SwipeDownToDismiss> createState() => _SwipeDownToDismissState();
}

class _SwipeDownToDismissState extends State<SwipeDownToDismiss>
    with SingleTickerProviderStateMixin {
  /// Vertical stage offset while a drag is in flight; 0 at rest.
  double _dragDy = 0;

  /// Set once the release decided to dismiss: the stage keeps sliding off the
  /// bottom and the route pops when it is gone. Further drags ignored.
  bool _dismissing = false;

  /// False when [SwipeDownToDismiss.canDrag] refused at drag start, so the
  /// rest of that gesture is ignored too.
  bool _dragArmed = false;

  /// Built in [initState], NEVER as a lazy `late final`: a viewer that is
  /// opened, zoomed and closed without ever dragging would otherwise touch
  /// this field for the FIRST time in [dispose], and `createTicker` then looks
  /// up `TickerMode` on a deactivated element ("Looking up a deactivated
  /// widget's ancestor is unsafe"). Caught by the zoom case in
  /// `test/widgets/fullscreen_image_viewer_test.dart`.
  late final AnimationController _slide;
  Tween<double> _slideTween = Tween(begin: 0, end: 0);

  /// Fraction of the viewport the finger must travel to dismiss on release
  /// without a fling.
  static const _kDismissFraction = 0.22;
  static const _kDismissFlingVelocity = 700.0;

  @override
  void initState() {
    super.initState();
    _slide =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addListener(() {
          if (!mounted) return;
          setState(() => _dragDy = _slideTween.transform(_slide.value));
        });
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails _) {
    if (_dismissing) return;
    _dragArmed = widget.canDrag?.call() ?? true;
    if (!_dragArmed) return;
    _slide.stop();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_dismissing || !_dragArmed) return;
    setState(() => _dragDy = math.max(0, _dragDy + details.delta.dy));
  }

  Future<void> _onDragEnd(DragEndDetails details) async {
    if (_dismissing || !_dragArmed) return;
    final height = MediaQuery.sizeOf(context).height;
    final velocity = details.primaryVelocity ?? 0;
    final dismiss =
        velocity > _kDismissFlingVelocity ||
        _dragDy > height * _kDismissFraction;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final target = dismiss ? height : 0.0;
    final distance = (target - _dragDy).abs();
    // A fling finishes at the finger's speed (bounded); a slow release glides.
    final ms = reduceMotion
        ? 0
        : dismiss
        ? (distance / math.max(velocity, 1400) * 1000).clamp(80, 220).round()
        : 220;
    _dismissing = dismiss;
    _slideTween = Tween(begin: _dragDy, end: target);
    _slide.duration = Duration(milliseconds: ms);
    _slide.value = 0;
    await _slide.animateTo(
      1,
      curve: dismiss ? Curves.easeIn : Curves.easeOutCubic,
    );
    if (!mounted) return;
    if (dismiss) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    // The backdrop is painted here, not by the dialog barrier, so it can thin
    // out under the finger the way Telegram's does.
    final progress = (_dragDy / height).clamp(0.0, 1.0);
    return GestureDetector(
      onTap: widget.onTap,
      onVerticalDragStart: _onDragStart,
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 1 - progress),
            ),
          ),
          Positioned.fill(
            child: Transform.translate(
              offset: Offset(0, _dragDy),
              child: Transform.scale(
                scale: 1 - progress * 0.25,
                child: widget.child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
