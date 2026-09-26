import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/box/box_media_url.dart';
import '../../utils/e2e_persistent_diag.dart';
import 'box_media_source.dart';
import 'inline_video_arbiter.dart';
import 'media_preview_frame.dart';
import 'video_fullscreen_view.dart';
import 'video_playback_session.dart';

/// Creates the playback session behind an inline player. Injectable so tests
/// can substitute a controller-free fake — a real [VideoPlayerController]
/// needs the platform channel the test binding does not have.
typedef VideoSessionFactory =
    VideoPlaybackSession Function(MessageModel message, String token);

/// Fraction of the bubble's height that must be inside the viewport before
/// inline playback starts, and the release floor it must fall below before it
/// stops. Hysteresis: between the two, the current state is kept, so a bubble
/// hovering at an edge does not thrash a decrypt-and-load cycle per pixel.
const _kPlayVisibleFraction = 0.6;
const _kReleaseVisibleFraction = 0.3;

/// Video message bubble: Telegram-style inline playback.
///
/// The resting state is unchanged — poster (ThumbHash via [MediaPreviewFrame])
/// with a play badge and a duration chip. When the "Autoplay videos" setting
/// is ON, the message's blob is uploaded, and at least 60% of the bubble is on
/// screen, the bubble asks [InlineVideoArbiter] for the SINGLE app-wide inline
/// slot and plays muted in place, looping. The one-session cap is mandatory:
/// media is whole-file AES-GCM with no streaming, so every live session holds
/// a decrypted blob of up to 20 MB in RAM — a scrolling list must never hold N
/// of those.
///
/// A tap anywhere on the video area (playing or not) opens
/// [showVideoFullscreen] — playback CONTROLS still live only there; the inline
/// surface offers exactly one control, the mute toggle. The fullscreen hand-
/// off is positional both ways: the dialog starts where the bubble was, and
/// the bubble resumes where the dialog closed.
///
/// Load failures fall back silently to the poster: the fullscreen view is the
/// surface with honest error copy, and an inline "failed" state would shout
/// about a background nicety the user never asked for.
///
/// The frame's aspect ratio comes from `mediaWidth`/`mediaHeight` in the E2E
/// envelope, written at send time by the composer's `probeVideoPreview` pass.
/// Messages sent before that existed carry neither and fall back to
/// [MediaPreviewFrame.legacyHeight] — upgrade-only, never a regression.
///
/// Message content is a motion-banned zone: no entrance animation.
class VideoMessageContent extends StatefulWidget {
  final MessageModel message;

  /// Test seams. Production callers pass neither: the shared
  /// [InlineVideoArbiter.instance] and the real [VideoPlaybackSession].
  final InlineVideoArbiter? arbiter;
  final VideoSessionFactory? sessionFactory;

  const VideoMessageContent({
    super.key,
    required this.message,
    this.arbiter,
    this.sessionFactory,
  });

  @override
  State<VideoMessageContent> createState() => _VideoMessageContentState();
}

class _VideoMessageContentState extends State<VideoMessageContent>
    with WidgetsBindingObserver {
  InlineVideoArbiter get _arbiter =>
      widget.arbiter ?? InlineVideoArbiter.instance;

  VideoPlaybackSession? _session;
  bool _sessionReady = false;

  /// Per-bubble, RAM-only. Inline playback defaults muted like Telegram's.
  bool _muted = true;

  /// Whole seconds LEFT in the clip, driven at 1 Hz by the controller
  /// listener. A [ValueNotifier] so only the chip rebuilds every second, not
  /// the whole bubble tree.
  final ValueNotifier<int?> _remainingSeconds = ValueNotifier(null);

  bool _autoplay = false;
  double _viewportHeight = 0;
  ScrollPosition? _scrollPosition;

  /// False while another route covers the chat; the slot is released then.
  bool _routeCurrent = true;

  /// Position to seek to when the next inline session starts — set when the
  /// fullscreen dialog returns after the route cover released the session.
  Duration? _resumeAt;

  /// True while the fullscreen dialog is up; blocks an inline restart until
  /// its final position is known.
  bool _fullscreenOpen = false;

  /// Uploaded AND decrypted. A history row arrives with its plaintext
  /// `mediaUrl` column but no `mediaKey` until the Signal pass reaches it;
  /// loading then would fetch the blob only to fail the decrypt. A box
  /// attachment (`box:<id>`, item 3 / media wiring) is uploaded too.
  bool get _hasUploadedBlob {
    final url = widget.message.mediaUrl;
    return url != null &&
        (url.startsWith('http') || isBoxMediaUrl(url)) &&
        widget.message.mediaKey != null &&
        widget.message.mediaIv != null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A denied request (a newer clip held the slot) must retry the moment
    // the slot frees, without waiting for the user to scroll.
    _arbiter.addListener(_onArbiterChanged);
    // First layout has to happen before the bubble can know where it sits.
    WidgetsBinding.instance.addPostFrameCallback((_) => _evaluateVisibility());
  }

  /// True after the arbiter denied this bubble because a newer clip held the
  /// slot; the next release re-evaluates. Nothing else reacts to arbiter
  /// traffic — a bubble whose own load failed must NOT re-request on its own
  /// release, or it retries every frame (and hammers the server).
  bool _deniedByNewer = false;

  void _onArbiterChanged() {
    if (!_deniedByNewer || _session != null || _arbiter.holds(this)) return;
    _deniedByNewer = false;
    // Outside the notifier's dispatch: a request from here would notify
    // re-entrantly while another bubble is still being told.
    WidgetsBinding.instance.addPostFrameCallback((_) => _evaluateVisibility());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Recompute on scroll only — no per-frame work while the list is idle.
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _scrollPosition)) {
      _scrollPosition?.removeListener(_evaluateVisibility);
      _scrollPosition = position;
      position?.addListener(_evaluateVisibility);
    }
  }

  @override
  void didUpdateWidget(VideoMessageContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The row is rebuilt in place when the decrypt pass fills in the media
    // keys (same key, same State), and nothing scrolls — so without this the
    // receiver's bubble never autoplays until the user moves the list.
    final old = oldWidget.message;
    final now = widget.message;
    if (old.mediaKey != now.mediaKey ||
        old.mediaIv != now.mediaIv ||
        old.mediaUrl != now.mediaUrl) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _evaluateVisibility(),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _arbiter.removeListener(_onArbiterChanged);
    _scrollPosition?.removeListener(_evaluateVisibility);
    _releaseSession();
    _remainingSeconds.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _session?.controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.paused) {
      controller.pause();
    } else if (state == AppLifecycleState.resumed && _arbiter.holds(this)) {
      controller.play();
    }
  }

  /// Fraction of the bubble's height currently inside the viewport, or null
  /// before layout. Screen-relative rather than viewport-relative: the chat
  /// list fills the screen minus fixed chrome, so the difference is a few
  /// pixels of app bar — irrelevant against a 60/30 hysteresis band.
  double? _visibleFraction() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return null;
    }
    final height = renderObject.size.height;
    if (height <= 0 || _viewportHeight <= 0) return null;
    final top = renderObject.localToGlobal(Offset.zero).dy;
    final visible =
        math.min(top + height, _viewportHeight) - math.max(top, 0.0);
    return (visible / height).clamp(0.0, 1.0);
  }

  /// Diag step+reason pairs already recorded by THIS bubble — one per pair,
  /// so a scroll pass over a long chat cannot flood the 80-record durable
  /// log, while a bubble that is first below threshold and later ineligible
  /// still reports both.
  final Set<String> _diagOnce = {};

  void _diag(String step, String reason, [Map<String, dynamic> data = const {}]) {
    if (!_diagOnce.add('$step:$reason')) return;
    E2ePersistentDiag.record(step, {
      'msgId': widget.message.id,
      'reason': reason,
      ...data,
    });
  }

  void _evaluateVisibility() {
    if (!mounted) return;
    if (!_autoplay || !_hasUploadedBlob || !_routeCurrent) {
      if (_session != null) _teardownInline('ineligible');
      // Only worth a record once the row COULD play: an undecrypted history
      // row skipping is the normal state, not a finding.
      if (_hasUploadedBlob) {
        _diag(
          'VIDEO_INLINE_SKIPPED',
          !_autoplay ? 'autoplay_off' : 'route_covered',
        );
      }
      return;
    }
    // The dialog's future settles only after its exit transition, while
    // isCurrent flips back at pop START — a restart here would run before
    // _openFullscreen learns the position. It re-evaluates itself on return.
    if (_fullscreenOpen) return;
    final fraction = _visibleFraction();
    if (fraction == null) {
      _diag('VIDEO_INLINE_SKIPPED', 'no_layout');
      return;
    }
    if (_session == null && fraction >= _kPlayVisibleFraction) {
      _startInline();
    } else if (_session != null && fraction < _kReleaseVisibleFraction) {
      _teardownInline('scrolled_out');
    } else if (_session == null) {
      _diag('VIDEO_INLINE_SKIPPED', 'below_threshold', {
        'fraction': (fraction * 100).round(),
        'viewportH': _viewportHeight.round(),
      });
    }
  }

  Future<void> _startInline() async {
    // Every inline session is a fresh playthrough and starts muted — an
    // earlier unmute (or sound in fullscreen) does not carry over.
    _muted = true;
    _lastPosition = Duration.zero;
    // Newest message wins the slot: two visible clips on chat open must
    // resolve to the LAST one, not whichever mounted later.
    final granted = _arbiter.request(
      this,
      _onSlotRevoked,
      priority: widget.message.createdAt.millisecondsSinceEpoch,
    );
    if (!granted) {
      _deniedByNewer = true;
      _diag('VIDEO_INLINE_SKIPPED', 'newer_clip_holds_slot');
      return;
    }
    String token;
    try {
      token = Provider.of<AuthProvider>(context, listen: false).token ?? '';
    } on ProviderNotFoundException {
      token = '';
    }
    final factory =
        widget.sessionFactory ??
        (message, token) => VideoPlaybackSession(
          message: message,
          token: token,
          box: boxMediaSourceFor(context, message.mediaUrl),
        );
    final session = factory(widget.message, token);
    _session = session;
    final failure = await session.load();
    // Torn down (revoked, scrolled out, disposed) while loading: the session
    // was already disposed by that path; this continuation owns nothing.
    if (!identical(session, _session)) return;
    if (!mounted) {
      _releaseSession();
      return;
    }
    if (failure != null) {
      // Silent poster fallback — the fullscreen view owns honest error copy.
      _teardownInline('load_failed');
      return;
    }
    final controller = session.controller!;
    controller.addListener(_onControllerTick);
    await controller.setVolume(_muted ? 0 : 1);
    await controller.setLooping(true);
    final resumeAt = _resumeAt;
    _resumeAt = null;
    if (resumeAt != null) await controller.seekTo(resumeAt);
    await controller.play();
    if (!mounted || !identical(session, _session)) return;
    _diag('VIDEO_INLINE_OK', 'started', {
      'w': controller.value.size.width.round(),
      'h': controller.value.size.height.round(),
      'playing': controller.value.isPlaying,
    });
    setState(() => _sessionReady = session.isReady);
  }

  /// The arbiter granted the slot to a newer requester; this bubble must free
  /// its decrypted buffer NOW. Releasing back is a no-op by arbiter contract.
  void _onSlotRevoked() => _teardownInline('revoked');

  void _teardownInline(String reason) {
    if (_session != null) {
      _diag('VIDEO_INLINE_RELEASED', reason, {'ready': _sessionReady});
    }
    _releaseSession();
    if (mounted) setState(() {});
  }

  /// Disposes the session exactly once and gives the slot back. Safe from
  /// dispose(), revocation, scroll-out and the settings flip alike.
  void _releaseSession() {
    final session = _session;
    _session = null;
    _sessionReady = false;
    _remainingSeconds.value = null;
    if (session != null) {
      session.controller?.removeListener(_onControllerTick);
      session.dispose();
    }
    _arbiter.release(this);
  }

  /// Last observed position, to spot the loop wrapping. Inline has no seek
  /// bar, so a backward jump can only be the clip starting over.
  Duration _lastPosition = Duration.zero;

  void _onControllerTick() {
    final controller = _session?.controller;
    if (controller == null) return;
    final value = controller.value;
    if (!value.isInitialized) return;
    final position = value.position;
    // Owner rule (2026-09-06): an inline unmute lasts ONE playthrough — the
    // auto-replay comes back muted, like the clip first appeared. Fullscreen
    // is different: sound there stays on.
    if (!_muted && position < _lastPosition - const Duration(milliseconds: 500)) {
      _muted = true;
      controller.setVolume(0);
      if (mounted) setState(() {});
    }
    _lastPosition = position;
    final remaining = value.duration - position;
    final seconds = remaining.inSeconds < 0 ? 0 : remaining.inSeconds;
    // Whole-second gate: the notifier only fires ~1 Hz during playback.
    if (_remainingSeconds.value != seconds) _remainingSeconds.value = seconds;
  }

  void _toggleMute() {
    final controller = _session?.controller;
    if (controller == null) return;
    setState(() => _muted = !_muted);
    controller.setVolume(_muted ? 0 : 1);
  }

  Future<void> _openFullscreen() async {
    final controller = _session?.controller;
    Duration? handoff;
    if (controller != null && controller.value.isInitialized) {
      handoff = controller.value.position;
      await controller.pause();
    }
    if (!mounted) return;
    _fullscreenOpen = true;
    Duration? returned;
    try {
      returned = await showVideoFullscreen(
        context,
        widget.message,
        startAt: handoff,
      );
    } finally {
      _fullscreenOpen = false;
    }
    if (!mounted) return;
    // The dialog is a route, so the chat route stopped being current and the
    // slot was released underneath it (nothing holds a decrypted blob behind
    // a covering route). Hand the next session its resume point and let the
    // normal visibility rule decide whether one starts.
    _resumeAt = returned ?? handoff;
    _evaluateVisibility();
  }

  /// `m:ss` from the envelope's `mediaDuration`. Null when the sending
  /// platform could not read the container's duration.
  String? _durationLabel() {
    final seconds = widget.message.mediaDuration;
    if (seconds == null || seconds <= 0) return null;
    return _formatSeconds(seconds);
  }

  @override
  Widget build(BuildContext context) {
    _viewportHeight = MediaQuery.sizeOf(context).height;
    bool autoplay;
    try {
      // watch: a settings flip while the bubble is on screen must reach it.
      autoplay = context.watch<SettingsProvider>().autoplayVideos;
    } on ProviderNotFoundException {
      // Widget tests mount the bubble without providers; no provider means
      // no autoplay, never a crash.
      autoplay = false;
    }
    // ModalRoute.of subscribes this element to route changes, so a push over
    // the chat (Settings, another chat, the fullscreen dialog itself) rebuilds
    // here with isCurrent false. localToGlobal alone would still report the
    // bubble on screen under an opaque route and keep a decrypted blob alive.
    final routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (autoplay != _autoplay || routeCurrent != _routeCurrent) {
      _autoplay = autoplay;
      _routeCurrent = routeCurrent;
      // Side effects (session teardown/start) cannot run inside build.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _evaluateVisibility(),
      );
    }

    final playing = _sessionReady && _session != null;
    final controller = _session?.controller;
    return Semantics(
      label: AppLocalizations.of(context).videoMessage,
      button: true,
      child: MediaPreviewFrame(
        mediaWidth: widget.message.mediaWidth,
        mediaHeight: widget.message.mediaHeight,
        mediaThumbHash: widget.message.mediaThumbHash,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _openFullscreen,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // MediaPreviewFrame paints the ThumbHash behind this stack, so
              // the poster stays visible until the first video frame covers
              // it. Fit is COVER inside the poster-shaped frame: the frame's
              // geometry came from the same clip, so overflow is crop-level,
              // never a squash.
              if (playing && controller != null)
                _InlineVideoStage(controller: controller),
              // On the web the <video> is a platform view, and the engine
              // drops pointer events whose DOM target sits inside one — a
              // finger on the playing clip never reached the GestureDetector
              // above (reproduced on the emulator: the touch targets
              // `VIDEO[flt-platform-view]`, the paused bubble's targets
              // `FLUTTER-VIEW`). The interceptor is a transparent DOM layer
              // above the video that hands the events back to Flutter. The
              // tap target MUST be its child: the interceptor's own render
              // box is a platform view too, whose recognizer wins the arena
              // sweep over any ancestor detector (second emulator round:
              // the touch hit `DIV[flt-platform-view]` and nothing opened).
              // Native: plain passthrough.
              if (playing)
                PointerInterceptor(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _openFullscreen,
                    child: const SizedBox.expand(),
                  ),
                ),
              if (!playing) const Center(child: _PlayBadge()),
              // Telegram layout: the clip's own chrome sits top-left, so the
              // bubble's time/ticks keep the bottom-right corner to
              // themselves.
              if (!playing) _DurationChip(label: _durationLabel()),
              if (playing)
                _RemainingMutePill(
                  remainingSeconds: _remainingSeconds,
                  muted: _muted,
                  onToggleMute: _toggleMute,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The live video, cover-fit into the poster-shaped frame.
class _InlineVideoStage extends StatelessWidget {
  final VideoPlayerController controller;

  const _InlineVideoStage({required this.controller});

  @override
  Widget build(BuildContext context) {
    final aspectRatio = rotationAwareAspectRatio(controller.value);
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          // Arbitrary scale — FittedBox only needs the RATIO. Same
          // rotation-aware ratio as the fullscreen stage: trusting
          // value.aspectRatio squashes rotated phone recordings.
          width: aspectRatio * 100,
          height: 100,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}

String _formatSeconds(int seconds) {
  final clamped = seconds < 0 ? 0 : seconds;
  final minutes = clamped ~/ 60;
  final remainder = clamped % 60;
  return '$minutes:${remainder.toString().padLeft(2, '0')}';
}

/// Static play affordance over the media frame — scrim + glyph, the same
/// theme-independent overlay treatment as the bubble's media time chip.
class _PlayBadge extends StatelessWidget {
  const _PlayBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.play_arrow_rounded,
        size: 36,
        color: Colors.white.withValues(alpha: 0.9),
      ),
    );
  }
}

/// Duration pill, top-left (Telegram): the bubble's own time/ticks overlay
/// owns the bottom-right corner and the bottom-left stays clear too.
class _DurationChip extends StatelessWidget {
  final String? label;

  const _DurationChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final value = label;
    if (value == null) return const SizedBox.shrink();
    return Positioned(left: 8, top: 8, child: _OverlayPill(text: value));
  }
}

/// `0:12 🔇` while playing, top-left, as one tappable pill (Telegram): time
/// REMAINING stepping at 1 Hz off the controller listener, plus the speaker
/// state. The whole pill toggles mute — a 12 px glyph alone is not a target.
/// Subscribes to its own notifier so the once-a-second tick repaints the
/// pill alone.
class _RemainingMutePill extends StatelessWidget {
  final ValueListenable<int?> remainingSeconds;
  final bool muted;
  final VoidCallback onToggleMute;

  const _RemainingMutePill({
    required this.remainingSeconds,
    required this.muted,
    required this.onToggleMute,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Positioned(
      left: 8,
      top: 8,
      child: Semantics(
        button: true,
        label: muted ? l10n.videoUnmute : l10n.videoMute,
        child: GestureDetector(
          key: const ValueKey('video_inline_mute_toggle'),
          behavior: HitTestBehavior.opaque,
          onTap: onToggleMute,
          child: ValueListenableBuilder<int?>(
            valueListenable: remainingSeconds,
            builder: (context, seconds, _) {
              return _OverlayPill(
                text: seconds == null ? null : _formatSeconds(seconds),
                trailing: Icon(
                  muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  size: 14,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Shared scrim pill for the duration chip and the remaining+mute pill.
class _OverlayPill extends StatelessWidget {
  final String? text;
  final Widget? trailing;

  const _OverlayPill({required this.text, this.trailing});

  @override
  Widget build(BuildContext context) {
    final label = text;
    final icon = trailing;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label != null)
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.9),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          if (label != null && icon != null) const SizedBox(width: 4),
          ?icon,
        ],
      ),
    );
  }
}
