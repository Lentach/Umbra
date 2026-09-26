import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/auth_provider.dart';
import '../../theme/rpg_theme.dart';
import '../message_date_separator.dart';
import 'box_media_source.dart';
import 'video_playback_session.dart';

/// Opens the fullscreen video player for [message], optionally starting at
/// [startAt] (the inline player hands its position over so the clip resumes
/// where the bubble left off).
///
/// Resolves with the LAST playback position when the dialog closes, or null
/// when the clip never initialised. All three dismissal routes — the back
/// chevron, system back and the swipe-down — pop the same dialog, so the
/// position is captured once, in the view's `PopScope.onPopInvokedWithResult`
/// (NOT `dispose`: `showDialog` resolves at pop, dispose runs after the exit
/// transition and always arrived too late).
///
/// Mirrors the image viewer's presentation (transparent full-bleed [Dialog],
/// tap-to-close chrome) so both media types dismiss identically. A dialog —
/// not a route — because that is the established pattern here and it gives
/// system-back dismissal for free.
Future<Duration?> showVideoFullscreen(
  BuildContext context,
  MessageModel message, {
  Duration? startAt,
}) async {
  Duration? lastPosition;
  await showDialog<void>(
    context: context,
    // The view paints its own black backdrop so a swipe-down can thin it.
    barrierColor: Colors.transparent,
    builder: (_) => _VideoFullscreenView(
      message: message,
      startAt: startAt,
      onLastPosition: (position) => lastPosition = position,
    ),
  );
  return lastPosition;
}

/// `m:ss` (or `h:mm:ss` past the hour) for the seek-bar timestamps.
String _timestamp(Duration d) {
  final seconds = d.inSeconds.clamp(0, 359999);
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// How long the control chrome stays up during playback before fading.
/// Telegram uses ~3 s; matched here so the player feels familiar.
const _kChromeAutoHide = Duration(seconds: 3);

/// Fullscreen player, Telegram-shaped: a center play/pause button, a seek bar
/// with current/total timestamps, and chrome that auto-hides while playing.
/// A tap on the stage toggles the CHROME, never playback — playback state is
/// only ever changed by the button, so it is always visible when it changes.
///
/// Owns its own [VideoPlaybackSession]: the dialog is torn down independently
/// of the bubble, and sharing one decrypted buffer would mean neither side
/// could safely free it.
class _VideoFullscreenView extends StatefulWidget {
  final MessageModel message;
  final Duration? startAt;
  final ValueChanged<Duration> onLastPosition;

  const _VideoFullscreenView({
    required this.message,
    required this.startAt,
    required this.onLastPosition,
  });

  @override
  State<_VideoFullscreenView> createState() => _VideoFullscreenViewState();
}

class _VideoFullscreenViewState extends State<_VideoFullscreenView>
    with SingleTickerProviderStateMixin {
  VideoPlaybackSession? _session;
  bool _loading = true;
  VideoStageError? _error;
  bool _playing = false;
  bool _chromeVisible = true;
  int _positionSeconds = 0;
  Timer? _hideTimer;

  VideoPlayerController? get _controller => _session?.controller;

  bool get _ready => _session?.isReady ?? false;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(vsync: this)
      ..addListener(
        () => setState(() => _dragDy = _slideTween.evaluate(_slide)),
      );
    _load();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _slide.dispose();
    _controller?.removeListener(_onControllerTick);
    _session?.dispose();
    super.dispose();
  }

  /// Runs on EVERY dismissal route (back chevron, system back, swipe-down)
  /// at pop time. NOT in dispose(): `showDialog`'s future resolves on pop,
  /// and the widget is only disposed after the exit transition — reporting
  /// from dispose always arrived too late and the bubble resumed from the
  /// handoff position instead (measured on the emulator: 27.4 s → 21.7 s).
  void _onPopInvoked(bool didPop, Object? _) {
    if (!didPop) return;
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      widget.onLastPosition(controller.value.position);
    }
  }

  void _onControllerTick() {
    final value = _controller?.value;
    if (value == null || !mounted) return;
    final playing = value.isPlaying;
    final seconds = value.position.inSeconds;
    if (playing == _playing && seconds == _positionSeconds) return;
    setState(() {
      _positionSeconds = seconds;
      if (playing != _playing) {
        _playing = playing;
        if (playing) {
          _scheduleHide();
        } else {
          // A pause surfaces the chrome and pins it: a stopped player must
          // never sit behind invisible controls. (End-of-clip loops instead.)
          _hideTimer?.cancel();
          _chromeVisible = true;
        }
      }
    });
  }

  Future<void> _load() async {
    final session = VideoPlaybackSession(
      message: widget.message,
      token: context.read<AuthProvider>().token ?? '',
      box: boxMediaSourceFor(context, widget.message.mediaUrl),
    );
    _session = session;
    final failure = await session.load();
    if (!mounted) {
      session.dispose();
      return;
    }
    if (failure != null) {
      setState(() {
        _loading = false;
        _error = failure;
      });
      return;
    }
    session.controller!.addListener(_onControllerTick);
    setState(() {
      _loading = false;
      _playing = true;
    });
    _scheduleHide();
    final startAt = widget.startAt;
    if (startAt != null && startAt > Duration.zero) {
      await session.controller!.seekTo(startAt);
    }
    // Owner call (2026-09-05): the clip replays from the top when it ends,
    // like Telegram's viewer, instead of parking on the last frame.
    await session.controller!.setLooping(true);
    await session.controller!.play();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_kChromeAutoHide, () {
      if (!mounted) return;
      if (_controller?.value.isPlaying ?? false) {
        setState(() => _chromeVisible = false);
      }
    });
  }

  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
    if (_chromeVisible) _scheduleHide();
  }

  void _togglePlayback() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      controller.pause();
      return;
    }
    controller.play();
    _scheduleHide();
  }

  // --- swipe-down dismiss (Telegram) --------------------------------------

  /// Vertical stage offset while a dismiss drag is in flight; 0 at rest.
  /// Driven by the finger during the drag and by [_slide] afterwards.
  double _dragDy = 0;

  /// Set once the release decided to dismiss: the stage keeps sliding off
  /// the bottom and the dialog pops when it is gone. Further drags ignored.
  bool _dismissing = false;

  late final AnimationController _slide;
  Tween<double> _slideTween = Tween(begin: 0, end: 0);

  /// Fraction of the viewport the finger must travel to dismiss on release
  /// without a fling.
  static const _kDismissFraction = 0.22;
  static const _kDismissFlingVelocity = 700.0;

  void _onDragStart(DragStartDetails _) {
    if (_dismissing) return;
    _slide.stop();
    _hideTimer?.cancel();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_dismissing) return;
    setState(() => _dragDy = math.max(0, _dragDy + details.delta.dy));
  }

  /// Telegram's release: the stage keeps travelling in the finger's
  /// direction — off the bottom to dismiss, or back to rest — instead of
  /// popping from wherever the finger let go (owner: "discards ugly").
  /// Reduce-motion collapses both animations to a snap.
  Future<void> _onDragEnd(DragEndDetails details) async {
    if (_dismissing) return;
    final height = MediaQuery.sizeOf(context).height;
    final velocity = details.primaryVelocity ?? 0;
    final dismiss =
        velocity > _kDismissFlingVelocity || _dragDy > height * _kDismissFraction;
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
    if (dismiss) {
      Navigator.pop(context);
    } else if (_controller?.value.isPlaying ?? false) {
      _scheduleHide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    // The backdrop is painted here, not by the dialog barrier, so it can
    // thin out under the finger the way Telegram's does.
    final progress = (_dragDy / height).clamp(0.0, 1.0);
    final scale = 1 - progress * 0.25;
    return PopScope(
      onPopInvokedWithResult: _onPopInvoked,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: _stageGestures(
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
                child: Transform.scale(scale: scale, child: _buildStage()),
              ),
            ),
            if (_dragDy == 0) _buildChrome(context),
          ],
        ),
      ),
    ),
    );
  }

  /// Tap toggles chrome; a vertical drag is the swipe-down dismiss. Used
  /// twice: around the whole surface (letterbox bars) and as the pointer
  /// interceptor's child over the `<video>` itself — see [_buildStage].
  Widget _stageGestures({required Widget child}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleChrome,
      onVerticalDragStart: _onDragStart,
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      child: child,
    );
  }

  /// Every control lives in one fading layer so it appears and hides as a
  /// unit. `IgnorePointer` while hidden: an invisible close button that still
  /// swallows taps would fight the chrome-revealing tap on the stage.
  ///
  /// Telegram shape: back chevron top-left with a sender/day header pill,
  /// centered play/pause, and an `elapsed — slider — remaining` pill above the
  /// gesture-navigation zone.
  Widget _buildChrome(BuildContext context) {
    final controller = _controller;
    final l10n = AppLocalizations.of(context);
    final myId = context.read<AuthProvider>().currentUser?.id;
    final sender = widget.message.senderId == myId
        ? l10n.videoSenderYou
        : widget.message.senderUsername;
    final when =
        '${MessageDateSeparator.dayLabel(context, widget.message.createdAt)}'
        ' · ${RpgTheme.formatMessageClock(widget.message.createdAt)}';
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !_chromeVisible,
        child: AnimatedOpacity(
          opacity: _chromeVisible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        Material(
                          color: Colors.black54,
                          shape: const CircleBorder(),
                          child: IconButton(
                            key: const ValueKey('video_fullscreen_close'),
                            icon: const Icon(
                              Icons.arrow_back_ios_new_rounded,
                              color: Colors.white,
                            ),
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).closeButtonTooltip,
                            onPressed: () => Navigator.pop(context),
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    sender,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    when,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // Balances the back button so the header pill is
                        // centered on the screen, not on the leftover width.
                        const SizedBox(width: 48),
                      ],
                    ),
                  ),
                ),
              ),
              if (_ready)
                Center(
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: IconButton(
                      key: const ValueKey('video_play_pause'),
                      iconSize: 44,
                      padding: const EdgeInsets.all(14),
                      icon: Icon(
                        _playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                      ),
                      onPressed: _togglePlayback,
                    ),
                  ),
                ),
              if (_ready && controller != null)
                Positioned(
                  left: 12,
                  right: 12,
                  // Uniform 64 px clearance from the physical bottom edge. A
                  // 12 px inset put the thumb inside Android's gesture-
                  // navigation zone, so a scrub drag fired swipe-up-home
                  // instead of seeking (owner report 2026-09-05). The Chrome
                  // PWA reports a 0 bottom inset there, so the clearance is
                  // explicit and the system inset only ever widens it
                  // (iOS home indicator = 34 pt, still 64 total, not 98).
                  // Telegram keeps its scrubber ~64 px up.
                  bottom: math.max(64.0, MediaQuery.viewPaddingOf(context).bottom + 12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: VideoSeekBar(
                      controller: controller,
                      onScrubStart: () => _hideTimer?.cancel(),
                      onScrubEnd: () {
                        if (controller.value.isPlaying) _scheduleHide();
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStage() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
    }
    final error = _error;
    if (error != null || !_ready) {
      // One error surface, not two: the glyph and its explanation belong in
      // the same branch. This used to render `videoMessage` — the bubble's
      // LABEL ("Video") — which told the user nothing.
      final stillSending = error == VideoStageError.stillSending;
      final l10n = AppLocalizations.of(context);
      final detail = stillSending ? null : _session?.failureDetail;
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                stillSending
                    ? Icons.cloud_upload_outlined
                    : Icons.broken_image,
                size: 64,
                color: Colors.white54,
              ),
              const SizedBox(height: 12),
              Text(
                stillSending
                    ? l10n.videoStillSending
                    : l10n.videoFailedToLoad,
                style: const TextStyle(color: Colors.white70),
              ),
              if (detail != null) ...[
                const SizedBox(height: 8),
                // Diagnostic, deliberately untranslated: `stage · bytes ·
                // error` straight from the session, so a phone screenshot
                // of this screen is the bug report.
                SelectableText(
                  detail,
                  key: const ValueKey('video_failure_detail'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final controller = _controller!;
    return Center(
      child: AspectRatio(
        // NOT controller.value.aspectRatio: that getter ignores
        // rotationCorrection, while VideoPlayer compensates internally
        // with a RotatedBox. Trusting it squashes every rotated phone
        // recording into a landscape box.
        aspectRatio: rotationAwareAspectRatio(controller.value),
        child: Stack(
          fit: StackFit.expand,
          children: [
            VideoPlayer(controller),
            // Web: the <video> is a platform view whose DOM events never
            // reach Flutter — without this the chrome-toggling tap and the
            // swipe-down were dead on real phones. The gestures must be the
            // interceptor's CHILD, not an ancestor (see the bubble's note).
            PointerInterceptor(
              child: _stageGestures(child: const SizedBox.expand()),
            ),
          ],
        ),
      ),
    );
  }
}

/// `position — draggable slider — total`. A Material [Slider] instead of
/// [VideoProgressIndicator]: the package scrubber is an 8 px strip with no
/// thumb and a hit target fingers routinely miss on device — the owner
/// could not seek at all. The slider gives a visible thumb, a 48 px-tall
/// gesture surface, and drag semantics that reliably win the arena over
/// the stage's chrome-toggle tap.
///
/// Subscribes to the controller itself via [ValueListenableBuilder] — the
/// same subscription [VideoProgressIndicator] had — so the thumb glides at
/// the controller's native cadence instead of stepping with the fullscreen
/// state's whole-second rebuild gate.
///
/// While dragging: [onScrubStart] lets the owner pin its chrome (the hide
/// timer must not fire under the finger), the thumb and position label
/// follow the finger, the controller is seeked live so the frame scrubs
/// like Telegram, and [onScrubEnd] lets the owner re-arm auto-hide.
class VideoSeekBar extends StatefulWidget {
  const VideoSeekBar({
    super.key,
    required this.controller,
    this.onScrubStart,
    this.onScrubEnd,
  });

  final VideoPlayerController controller;
  final VoidCallback? onScrubStart;
  final VoidCallback? onScrubEnd;

  @override
  State<VideoSeekBar> createState() => _VideoSeekBarState();
}

class _VideoSeekBarState extends State<VideoSeekBar> {
  /// Non-null while the user is dragging, in milliseconds. Drives both the
  /// thumb and the position label so the UI tracks the finger, not the
  /// (lagging) controller position.
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final durationMs = value.duration.inMilliseconds;
        // A not-yet-known duration would make the slider's max 0; render the
        // bar inert until the controller reports one.
        final maxMs = durationMs > 0 ? durationMs.toDouble() : 1.0;
        final positionMs = (_dragMs ??
                value.position.inMilliseconds.toDouble())
            .clamp(0.0, maxMs);
        return Row(
          children: [
            Text(
              _timestamp(Duration(milliseconds: positionMs.round())),
              key: const ValueKey('video_position_label'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 16),
                  activeTrackColor: Theme.of(context).colorScheme.primary,
                  // Same media-scrim precedent as the bubble's time chip: a
                  // scrim over arbitrary frames is theme-independent.
                  inactiveTrackColor: Colors.white.withValues(alpha: 0.25),
                  thumbColor: Colors.white,
                  overlayColor: Colors.white.withValues(alpha: 0.15),
                ),
                child: Slider(
                  key: const ValueKey('video_seek_slider'),
                  max: maxMs,
                  value: positionMs,
                  onChangeStart: durationMs <= 0
                      ? null
                      : (v) {
                          widget.onScrubStart?.call();
                          setState(() => _dragMs = v);
                        },
                  onChanged: durationMs <= 0
                      ? null
                      : (v) {
                          setState(() => _dragMs = v);
                          widget.controller
                              .seekTo(Duration(milliseconds: v.round()));
                        },
                  onChangeEnd: durationMs <= 0
                      ? null
                      : (v) {
                          widget.controller
                              .seekTo(Duration(milliseconds: v.round()));
                          setState(() => _dragMs = null);
                          widget.onScrubEnd?.call();
                        },
                ),
              ),
            ),
            Text(
              // Telegram: the right label counts DOWN.
              _timestamp(
                Duration(milliseconds: (maxMs - positionMs).round()),
              ),
              key: const ValueKey('video_remaining_label'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        );
      },
    );
  }

}
