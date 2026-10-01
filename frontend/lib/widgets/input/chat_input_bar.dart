import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show kIsWeb, visibleForTesting, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../constants/app_constants.dart';
import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/conversations_provider.dart';
import '../../providers/messaging_provider.dart';
import '../../providers/settings_provider.dart';
import '../../theme/glass_theme.dart';
import '../../theme/rpg_theme.dart';
import '../glass/glass_surface.dart';
import '../../utils/composer_paste.dart';
import '../../utils/message_expiry.dart';
import '../../utils/message_length.dart';
import '../../utils/reply_preview_helper.dart';
import '../../utils/soft_keyboard.dart';
import '../../utils/web_keyboard_inset.dart';
import '../../utils/web_focus_guard.dart';
import '../../utils/web_ios_webkit.dart';
import '../../utils/web_viewport_scroll.dart';
import '../../utils/web_ios_viewport_pin.dart';
import '../../services/media_crypto_service.dart';
import '../../utils/video_preview.dart';
import '../../utils/video_probe_stub.dart'
    if (dart.library.html) '../../utils/video_probe_web.dart'
    if (dart.library.io) '../../utils/video_probe_io.dart'
    as video_probe;
import '../../utils/video_transcode_stub.dart'
    if (dart.library.io) '../../utils/video_transcode_io.dart'
    as video_transcode;
import '../chat_action_tiles.dart';
import '../hearth_fade_hex.dart';
import '../top_snackbar.dart' show showTopSnackBar;
import '../emoji/fireplace_emoji_picker.dart';
import 'attachment_handler.dart';
import 'composer_attachment_bar.dart';
import 'composer_attachment_controller.dart';
import 'focus_guard_area.dart';
import 'hex_send_button.dart';
import 'recording_controller.dart';
import 'reply_preview_bar.dart';
import 'edit_preview_bar.dart';
import 'composer_keyboard_signals.dart';
import 'composer_emoji_text_editing.dart';

class ChatInputBar extends StatefulWidget {
  const ChatInputBar({super.key});

  @override
  State<ChatInputBar> createState() => ChatInputBarState();
}

class ChatInputBarState extends State<ChatInputBar>
    with SingleTickerProviderStateMixin {
  static const Duration _kTrailingSendFadeDuration = Duration(
    milliseconds: 175,
  );
  static const Object _composerTapRegionGroup = Object();
  /// Test seam for the oversize-video transcode: unit tests cannot reach the
  /// native codec channel, and the real thing is pinned on-device instead.
  /// Non-null only under test.
  @visibleForTesting
  static Future<Uint8List?> Function(Uint8List bytes)? debugTranscodeOverride;

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  MessageModel? _lastReplyingTo;
  MessageModel? _lastEditingMessage;
  bool _showActionPanel = false;
  bool _showEmojiPicker = false;
  // Emoji panel slide (owner-approved motion in the composer zone because it
  // is PAINT-ONLY): the panel occupies its full 320px layout from the first
  // frame (composerBottomPanelPinned semantics unchanged — the viewport
  // anchors bottom:0 instantly); only the CONTENT slides via SlideTransition
  // under a ClipRect. Never a SizeTransition / height tween — a ~300px block
  // relayouting per frame through the keyboard window is the deleted H3 trap
  // (.cursor/session-summaries/2026-07-09-session-action-panel-transitions.md).
  late final AnimationController _emojiPanelController;
  late final Animation<Offset> _emojiPanelOffset;
  // True while the panel is still mounted playing its exit slide after
  // _showEmojiPicker flipped false: it keeps occupying layout (pin held)
  // until the reverse completes, then unmounts in one relayout.
  bool _emojiPanelExiting = false;

  bool get _emojiPanelOccupiesLayout => _showEmojiPicker || _emojiPanelExiting;
  bool _ignoreComposerTapOutsideForChatSurfaceTap = false;
  // Captured on pointer-down inside the action panel, BEFORE the tap's DOM
  // blur can reach the framework: tells ping's keyboard-neutral refocus
  // whether the keyboard was up when the user tapped.
  bool _actionPanelPointerDownHadFocus = false;

  @visibleForTesting
  bool get isActionPanelOpenForTest => _showActionPanel;

  @visibleForTesting
  bool get isEmojiPickerOpenForTest => _showEmojiPicker;

  /// Mobile = Android/iOS regardless of native-vs-web: [defaultTargetPlatform]
  /// reflects the underlying OS on web, so a phone PWA counts as mobile while
  /// desktop web does not (kIsWeb would misclassify both).
  static bool get _isMobilePlatform =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  Timer? _typingDebounceTimer;
  MessagingProvider? _messagingProvider;
  // Cached for _handleVoiceSent, which can run after this State is unmounted
  // (RecordingController.stopAndSend deliberately outlives a mid-stop teardown).
  ConversationsProvider? _conversationsProvider;

  // Cached so dispose removes the listener from the SAME instance initState
  // added it to, even when a test overrides the shared source between mounts.
  late final KeyboardInsetSource _sharedInsetSource;
  // H2: iOS fires visualViewport resize/scroll repeatedly during the keyboard
  // pan; this state only consumes the BOOLEAN (inset > 0), so rebuilds are
  // gated on the flip, not per pixel event.
  bool _lastSharedInsetVisible = false;
  // Set true (with a 600ms auto-clear) whenever the composer initiates a send /
  // deliberate refocus that may briefly blur+restore the IME. Gates the viewport
  // keyboard-collapse debounce — see composer_keyboard_signals.dart.
  Timer? _collapseGuardTimer;

  // Recording state mirrored from RecordingController via callback
  bool _isRecording = false;
  bool _isSendingVoice = false;

  // GlobalKey to access RecordingControllerState.buildRecordingBar() + methods.
  final _recordingKey = GlobalKey<RecordingControllerState>();

  // Staged media (Clipboard Phase 2 image; a picked video sends immediately
  // and never stages). Chip renders above the input row; _sendStaged() drains
  // it honoring the media-then-caption ordering contract (spec §3).
  final _attachment = ComposerAttachmentController();
  bool _isSendingStagedMedia = false;

  @override
  void initState() {
    super.initState();
    _emojiPanelController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _emojiPanelOffset =
        Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _emojiPanelController,
            curve: Curves.easeOutCubic,
          ),
        );
    _controller.addListener(() {
      if (_controller.text.trim().isEmpty) return;
      _typingDebounceTimer?.cancel();
      _typingDebounceTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) context.read<MessagingProvider>().emitTyping();
      });
    });

    _attachment.addListener(_onAttachmentChanged);

    // Telegram/Signal contract: keyboard and emoji panel are mutually
    // exclusive. Any composer focus gain (field tap, reply/edit refocus)
    // closes the panel so they never stack.
    _focusNode.addListener(_closeEmojiPickerOnFocusGain);
    _sharedInsetSource = sharedKeyboardInsetSource();
    if (kIsWeb) {
      _focusNode.addListener(_onComposerFocusForWebViewport);
      // Single source of truth for keyboard visibility (iOS WebKit's
      // viewInsets read 0): drives bottomInteractivePadding. The inactive
      // source never fires off iOS web.
      _lastSharedInsetVisible = _sharedInsetSource.inset.value > 0;
      _sharedInsetSource.inset.addListener(_onSharedKeyboardInsetChanged);
      ensureFocusGuardListenerInstalled();
      installComposerPasteListener(
        shouldHandle: _canAcceptPaste,
        onImage: _onPastedImage,
        onText: _insertPastedText,
      );
    }
  }

  /// Single mutation point for emoji-panel visibility so the viewport bottom
  /// pin ([composerBottomPanelPinned]) can never drift out of sync with the
  /// panel's LAYOUT presence. Call inside setState.
  ///
  /// Open always slides the content up from below (instant under reduce
  /// motion). On close, keyboard-NEUTRAL callers (chat-surface tap, tap
  /// outside, system back) pass [animateExit] to keep the panel mounted
  /// through the reverse slide — the pin holds bottom:0, and with the
  /// keyboard down that is a no-op for layout. Keyboard-REPLACEMENT closes
  /// (focus gain, toggle back to keyboard) and recording start stay INSTANT:
  /// their unmount must land before the keyboard show/hide window, not
  /// inside it.
  void _setEmojiPickerVisible(bool value, {bool animateExit = false}) {
    _showEmojiPicker = value;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (value) {
      _emojiPanelExiting = false;
      composerBottomPanelPinned.value = true;
      if (reduceMotion) {
        _emojiPanelController.value = 1.0;
      } else {
        final status = _emojiPanelController.status;
        if (status == AnimationStatus.reverse) {
          // Reopened mid-exit: resume the slide from where it is.
          _emojiPanelController.forward();
        } else if (status == AnimationStatus.dismissed) {
          _emojiPanelController.forward(from: 0);
        }
        // forward/completed: already opening/open — idempotent.
      }
    } else if (animateExit &&
        !reduceMotion &&
        _emojiPanelController.value > 0) {
      if (!_emojiPanelExiting) {
        _emojiPanelExiting = true;
        // Pin stays true: the panel still occupies layout until the exit ends.
        _emojiPanelController.reverse().whenComplete(_onEmojiPanelExitDone);
      }
    } else {
      _emojiPanelExiting = false;
      _emojiPanelController.value = 0;
      composerBottomPanelPinned.value = false;
    }
  }

  void _onEmojiPanelExitDone() {
    // A TickerFuture completes only on an uninterrupted reverse; a reopen or
    // an instant close mid-exit leaves it forever pending — no stale unmount.
    if (!mounted || _showEmojiPicker || !_emojiPanelExiting) return;
    setState(() {
      _emojiPanelExiting = false;
      composerBottomPanelPinned.value = false;
    });
  }

  void _closeEmojiPickerOnFocusGain() {
    if (!_focusNode.hasFocus || !_showEmojiPicker) return;
    setState(() => _setEmojiPickerVisible(false));
  }

  void _requestComposerFocus() {
    if (!mounted || !_focusNode.canRequestFocus) return;
    if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
    showSoftKeyboardIfHidden(context: context, hasFocus: true);
  }

  /// Restores the composer after a transient surface such as User Card closes.
  void focusComposer() => _requestComposerFocus();

  void _handleComposerTapOutside(PointerDownEvent _) {
    if (_ignoreComposerTapOutsideForChatSurfaceTap) return;
    if (kIsWeb && isIOSWebKit()) return;
    _focusNode.unfocus();
  }

  void dismissForChatSurfaceTap() {
    if (_showActionPanel) {
      // The message list owns the real chat-surface pointer. TapRegion still
      // receives the same outside tap afterward; suppress only that follow-up
      // so the lower action panel does not collapse (07-03 contract: the
      // panel survives chat-surface taps). The keyboard dismisses on ALL
      // platforms since 0.0.99: the former iOS keep-focus gate made the
      // canvas tap's DOM blur fight the still-focused framework node — the
      // keyboard closed and bounced straight back (user-reported 2026-07-09,
      // iOS + Android). Unfocusing the framework node lets the dismiss stick.
      _ignoreComposerTapOutsideForChatSurfaceTap = true;
      if (_showEmojiPicker) {
        setState(() => _setEmojiPickerVisible(false, animateExit: true));
      }
      _focusNode.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ignoreComposerTapOutsideForChatSurfaceTap = false;
      });
      return;
    }
    _dismissOpenComposerPanels();
    _focusNode.unfocus();
  }

  void _handleComposerRegionTapOutside(PointerDownEvent event) {
    if (_ignoreComposerTapOutsideForChatSurfaceTap) return;
    _dismissOpenComposerPanels();
    _handleComposerTapOutside(event);
  }

  void _dismissOpenComposerPanels() {
    if (!_showEmojiPicker && !_showActionPanel) return;
    setState(() {
      if (_showEmojiPicker) {
        _setEmojiPickerVisible(false, animateExit: true);
      }
      _showActionPanel = false;
    });
  }

  void _onComposerFocusForWebViewport() {
    if (!kIsWeb) return;
    if (!_focusNode.hasFocus) {
      setIOSComposerViewportPin(false);
      return;
    }
    if (!isIOSWebKit()) return;
    setIOSComposerViewportPin(true);
  }

  void _onSharedKeyboardInsetChanged() {
    // H2: this widget consumes only the boolean (inset > 0) for
    // bottomInteractivePadding; rebuild on the flip, not on every
    // visualViewport pixel event — a per-event setState relayouts the open
    // ~300px action panel through the whole keyboard pan.
    final visible = _sharedInsetSource.inset.value > 0;
    if (visible == _lastSharedInsetVisible) return;
    _lastSharedInsetVisible = visible;
    if (mounted) setState(() {});
  }

  void _onAttachmentChanged() {
    if (mounted) setState(() {});
  }

  bool _canAcceptPaste() => mounted && !_isRecording && !_isSendingStagedMedia;

  void _onPastedImage(Uint8List bytes, String mimeType, String filename) {
    if (!mounted) return;
    final result = _attachment.stage(
      bytes: bytes,
      mimeType: mimeType,
      filename: filename,
    );
    if (result == StageResult.ok) return;
    final l10n = AppLocalizations.of(context);
    showTopSnackBar(
      context,
      result == StageResult.tooLarge
          ? l10n.snackbarPastedImageTooLarge
          : l10n.snackbarPastedImageUnsupported,
    );
  }

  /// Android IME image insertion (Gboard clipboard chip / sticker insert) —
  /// Clipboard Phase 4. Some keyboards/OS versions deliver a content URI
  /// with no inline bytes; reading content:// needs a platform channel we
  /// don't have, so surface an honest error instead of failing silently.
  void _onKeyboardContentInserted(KeyboardInsertedContent content) {
    if (!_canAcceptPaste()) return;
    if (!content.hasData) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context).snackbarPastedImageUnavailable,
      );
      return;
    }
    _onPastedImage(
      content.data!,
      content.mimeType,
      pastedFilenameForMime(content.mimeType),
    );
  }

  /// Gallery/camera image pick → the same staged-image flow as paste
  /// (stage, chip, send on the trailing button). Toasts on rejection.
  void stagePickedImage({
    required Uint8List bytes,
    required String mimeType,
    required String filename,
  }) {
    if (!_canAcceptPaste()) return;
    _onPastedImage(bytes, mimeType, filename);
  }

  /// Gallery/camera video pick → IMMEDIATE send (owner ruling 2026-08-31).
  ///
  /// Video does NOT stage. iOS's own `Retake / Use Video` review screen is
  /// already the confirmation step, so a composer chip made the user confirm
  /// the same decision twice. Documents in `ChatActionTiles._routePickedFile`
  /// have always sent immediately; video now matches them. Images still stage
  /// — a gallery tap is their only confirmation, and they carry captions.
  ///
  /// Gate order is deliberate: the cheap extension and size checks run first,
  /// because `probeVideoPreview` loads the whole clip into a decoder and costs
  /// seconds on a phone. That single probe pass supplies the duration for the
  /// cap AND the geometry + ThumbHash the receiving bubble needs — the
  /// provider never re-probes.
  Future<void> sendPickedVideo({
    required Uint8List bytes,
    required String filename,
  }) async {
    if (!_canAcceptPaste()) return;
    final l10n = AppLocalizations.of(context);
    final ext = filename.contains('.')
        ? filename.split('.').last.toLowerCase()
        : '';
    if (!kSendableVideoExtensions.contains(ext)) {
      showTopSnackBar(
        context,
        l10n.videoUnsupportedFormat,
        backgroundColor: Colors.red,
      );
      return;
    }
    if (bytes.length > MediaCryptoService.maxBytes) {
      final transcoded = await _transcodeOversizeVideo(bytes);
      if (!mounted) return;
      if (transcoded == null) {
        // Named actuals, not just the limit: "34 MB, max 20 MB" tells the user
        // WHY this clip failed and roughly how much to trim.
        final sizeMb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
        showTopSnackBar(
          context,
          l10n.videoTooLarge(sizeMb),
          backgroundColor: Colors.red,
        );
        return;
      }
      bytes = transcoded;
    }

    final preview = await video_probe.probeVideoPreview(
      bytes,
      mimeType: videoMimeForFilename(filename),
    );
    if (!mounted) return;
    final duration = preview.durationInSeconds;
    if (duration != null &&
        duration > MediaCryptoService.maxVideoDurationSeconds) {
      final minutes = duration ~/ 60;
      final seconds = duration % 60;
      showTopSnackBar(
        context,
        l10n.videoTooLong('$minutes:${seconds.toString().padLeft(2, '0')}'),
        backgroundColor: Colors.red,
      );
      return;
    }

    // Same collapse guard the staged-send path arms: this is a send, and the
    // keyboard must not collapse underneath it.
    _armComposerCollapseGuard();
    await AttachmentHandler.sendVideo(
      context,
      videoBytes: bytes,
      durationSeconds: duration,
      width: preview.width,
      height: preview.height,
      thumbHash: preview.thumbHash,
    );
  }

  /// Move-4 on-device transcode for an oversize pick (owner decision
  /// 2026-09-01: native first; the PWA keeps the 20 MB wall until chunked
  /// streaming exists).
  ///
  /// Returns bytes that fit [MediaCryptoService.maxBytes], or null when no
  /// transcode path exists (web), it failed, or the output is STILL oversize —
  /// possible by physics: the codec's bitrate floor is 2 Mbps, so a ~3-minute
  /// clip cannot always reach 18 MB. The caller shows the honest "too large"
  /// toast for every null.
  Future<Uint8List?> _transcodeOversizeVideo(Uint8List bytes) async {
    final override = debugTranscodeOverride;
    if (override == null && !video_transcode.isVideoTranscodeSupported) {
      return null;
    }
    // Hardware transcode of a multi-minute clip takes seconds to tens of
    // seconds; without this the composer just sits there silently.
    showTopSnackBar(context, AppLocalizations.of(context).videoCompressing);
    final out = override != null
        ? await override(bytes)
        : await video_transcode.transcodeVideoToFit(bytes);
    if (out == null || out.length > MediaCryptoService.maxBytes) return null;
    return out;
  }

  /// Mixed text+image paste: preventDefault suppressed the native insertion,
  /// so we re-insert the clipboard text at the current cursor/selection
  /// (spec §3 — not append-at-end).
  void _insertPastedText(String text) {
    if (!mounted) return;
    final value = _controller.value;
    final sel = value.selection;
    final start = (sel.isValid ? sel.start : value.text.length).clamp(
      0,
      value.text.length,
    );
    final end = (sel.isValid ? sel.end : value.text.length).clamp(
      0,
      value.text.length,
    );
    _controller.value = value.copyWith(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
    );
  }

  void _onMessagingProviderChanged() {
    _onReplyTargetChanged(_messagingProvider?.replyingToMessage);
    _onEditTargetChanged(_messagingProvider?.editingMessage);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final messaging = context.read<MessagingProvider>();
    if (_messagingProvider != messaging) {
      _messagingProvider?.removeListener(_onMessagingProviderChanged);
      _messagingProvider = messaging;
      messaging.addListener(_onMessagingProviderChanged);
      messaging.setComposerFocusRequest(_requestComposerFocus);
      _onReplyTargetChanged(messaging.replyingToMessage);
      _onEditTargetChanged(messaging.editingMessage);
    }
    _conversationsProvider = context.read<ConversationsProvider>();
  }

  void _onReplyTargetChanged(MessageModel? replyingTo) {
    if (replyingTo != null && _lastReplyingTo != replyingTo) {
      _lastReplyingTo = replyingTo;
      // Fallback when reply was set without a user gesture (e.g. tests).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_focusNode.canRequestFocus) return;
        if (!_focusNode.hasFocus) {
          _focusNode.requestFocus();
        }
        showSoftKeyboardIfHidden(context: context, hasFocus: true);
      });
    } else if (replyingTo == null) {
      _lastReplyingTo = null;
    }
  }

  void _onEditTargetChanged(MessageModel? editing) {
    if (editing != null && _lastEditingMessage?.id != editing.id) {
      _lastEditingMessage = editing;
      _controller.text = editing.content;
      _controller.selection = TextSelection.collapsed(
        offset: editing.content.length,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_focusNode.canRequestFocus) return;
        if (!_focusNode.hasFocus) _focusNode.requestFocus();
        showSoftKeyboardIfHidden(context: context, hasFocus: true);
      });
    } else if (editing == null && _lastEditingMessage != null) {
      _lastEditingMessage = null;
      _controller.clear();
    }
  }

  @override
  void dispose() {
    // Reset the pin so the next chat opens unpinned, but DEFER it: a sync
    // notify here fires the still-mounted ancestor viewport's
    // setState during tree finalization (locked-tree assert when leaving the
    // chat with the panel open). By microtask time the tree is unlocked (or
    // the viewport is unmounted and its listener no-ops on the mounted guard).
    scheduleMicrotask(() => composerBottomPanelPinned.value = false);
    _focusNode.removeListener(_closeEmojiPickerOnFocusGain);
    if (kIsWeb) {
      _focusNode.removeListener(_onComposerFocusForWebViewport);
      _sharedInsetSource.inset.removeListener(_onSharedKeyboardInsetChanged);
      setIOSComposerViewportPin(false);
      uninstallComposerPasteListener();
    }
    _collapseGuardTimer?.cancel();
    composerKeyboardCollapseGuard.value = false;
    _messagingProvider?.setComposerFocusRequest(null);
    _messagingProvider?.removeListener(_onMessagingProviderChanged);
    _attachment.removeListener(_onAttachmentChanged);
    _attachment.dispose();
    _controller.dispose();
    _focusNode.dispose();
    _typingDebounceTimer?.cancel();
    _emojiPanelController.dispose();
    super.dispose();
  }

  // Tells [ChatComposerViewport] a refocus is imminent so it defers collapsing
  // the keyboard inset (preserves the send-bounce flash guard). Auto-clears so a
  // subsequent genuine dismiss collapses immediately (no laggy gap on hide).
  // NOTE 2026-07-07: the iOS `_sendJustFired` fast-refocus that this guard
  // masked was deleted after the device probe proved it unobservable — the
  // DOM focus guard (load-bearing, see composer_keyboard_signals.dart) holds
  // focus through send taps. The guard stays as cheap cover for the edit /
  // staged / action-toggle paths the probe did not isolate.
  void _armComposerCollapseGuard() {
    composerKeyboardCollapseGuard.value = true;
    _collapseGuardTimer?.cancel();
    _collapseGuardTimer = Timer(const Duration(milliseconds: 600), () {
      composerKeyboardCollapseGuard.value = false;
    });
  }

  void _send() {
    if (_attachment.staged != null) {
      _sendStaged().ignore();
      return;
    }
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (!isMessageWithinByteLimit(text)) {
      showTopSnackBar(context, AppLocalizations.of(context).messageTooLong);
      return;
    }
    // Telegram parity: sending from the emoji panel keeps the panel open and
    // the keyboard hidden — skip the post-send refocus in that state.
    final keepEmojiPanel = _showEmojiPicker;
    _armComposerCollapseGuard();

    final messaging = context.read<MessagingProvider>();
    final editing = messaging.editingMessage;
    if (editing != null) {
      messaging.editMessage(editing.id, text);
      _controller.clear();
      if (!keepEmojiPanel) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_focusNode.canRequestFocus) return;
          if (!_focusNode.hasFocus) _focusNode.requestFocus();
          showSoftKeyboardIfHidden(context: context, hasFocus: true);
        });
      }
      return;
    }
    final convs = context.read<ConversationsProvider>();
    final expiresIn = convs.conversationDisappearingTimer;
    messaging.sendMessage(text, expiresIn: expiresIn);

    _controller.clear();
    if (keepEmojiPanel) return;
    // Post-send refocus: keeps the keyboard up after a send-button tap on
    // non-iOS (the DOM focus guard covers iOS WebKit).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focusNode.canRequestFocus) return;
      if (!_focusNode.hasFocus) _focusNode.requestFocus();
      showSoftKeyboardIfHidden(context: context, hasFocus: true);
    });
  }

  /// Media-then-caption send (spec §3 ordering contract): await the staged
  /// item's post-emit completion, only then emit the caption; on media failure
  /// the caption is restored to the field (the failed bubble owns retry).
  Future<void> _sendStaged() async {
    if (_isSendingStagedMedia) return;
    final staged = _attachment.staged;
    if (staged == null) return;
    final keepEmojiPanel = _showEmojiPicker;
    _armComposerCollapseGuard();

    final caption = _controller.text.trim();
    final messaging = context.read<MessagingProvider>();
    final expiresIn = context
        .read<ConversationsProvider>()
        .conversationDisappearingTimer;

    setState(() => _isSendingStagedMedia = true);
    _attachment.clear();
    _controller.clear();
    try {
      final sent = await AttachmentHandler.sendImage(
        context,
        imageBytes: staged.bytes,
        filename: staged.filename,
        mimeType: staged.mimeType,
      );
      if (!mounted) return;
      if (caption.isNotEmpty) {
        if (sent) {
          messaging.sendMessage(caption, expiresIn: expiresIn);
        } else {
          final current = _controller.text;
          _controller.text = current.isEmpty ? caption : '$caption\n$current';
        }
      }
    } finally {
      if (mounted) setState(() => _isSendingStagedMedia = false);
    }
    if (keepEmojiPanel) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focusNode.canRequestFocus) return;
      if (!_focusNode.hasFocus) _focusNode.requestFocus();
      showSoftKeyboardIfHidden(context: context, hasFocus: true);
    });
  }

  void _insertEmoji(String emoji) {
    _controller.value = insertEmojiAtSelection(_controller.value, emoji);
  }

  void _deletePreviousEmoji() {
    _controller.value = deletePreviousEmojiGrapheme(_controller.value);
  }

  void _toggleEmojiPicker() {
    final opening = !_showEmojiPicker;
    setState(() {
      _setEmojiPickerVisible(opening);
    });
    if (opening) {
      _focusNode.unfocus();
      if (kIsWeb && isIOSWebKit()) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_showEmojiPicker) return;
          resetWebDocumentScroll();
        });
      }
    } else {
      _requestComposerFocus();
    }
  }

  void _toggleActionPanel() {
    final hadComposerFocus = _focusNode.hasFocus;
    setState(() {
      _showActionPanel = !_showActionPanel;
    });
    if (kIsWeb && isIOSWebKit()) {
      if (hadComposerFocus) {
        _armComposerCollapseGuard();
        // Keyboard was open: keep it open and reset any iOS document scroll.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_focusNode.canRequestFocus) return;
          if (!_focusNode.hasFocus) {
            _focusNode.requestFocus();
          }
          showSoftKeyboardIfHidden(context: context, hasFocus: true);
          resetWebDocumentScroll();
        });
      } else if (_showActionPanel) {
        // Panel just opened from keyboard-hidden state. iOS may auto-focus the
        // textarea on any canvas tap (no active editable → guard does not fire).
        // Dismiss the auto-focus so the keyboard does not appear unexpectedly,
        // and reset any document scroll iOS may have applied.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_showActionPanel) return;
          if (_focusNode.hasFocus) _focusNode.unfocus();
          resetWebDocumentScroll();
        });
      }
    }
  }

  /// Called by [RecordingController] when recording state changes.
  /// Recording replaces the composer row — close the emoji panel with it
  /// (Telegram parity: mic tap dismisses the panel).
  void _onRecordingStateChanged(bool isRecording) {
    if (!mounted) {
      _isRecording = isRecording;
      return;
    }
    setState(() {
      _isRecording = isRecording;
      if (isRecording) _setEmojiPickerVisible(false);
    });
  }

  /// Idle mic tapped. Start recording, then on iOS WebKit dismiss any keyboard
  /// the canvas tap may have auto-summoned (same pattern as [_toggleActionPanel]
  /// for the keyboard-hidden case). Kept here so RecordingController stays
  /// FocusNode-agnostic.
  void _onMicTap() {
    _recordingKey.currentState?.startRecording();
    if (kIsWeb && isIOSWebKit()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_focusNode.hasFocus) _focusNode.unfocus();
        resetWebDocumentScroll();
      });
    }
  }

  /// Ping is keyboard-neutral: tapping the tile must not dismiss a raised
  /// keyboard (user ruling 2026-07-09). On iOS WebKit the [FocusGuardArea]
  /// around the tile prevents the DOM blur outright; this is the non-iOS
  /// fallback — the same post-frame refocus pattern as [_send]. Gated on
  /// [_actionPanelPointerDownHadFocus] so a ping from the panel-open,
  /// keyboard-hidden state never summons the keyboard.
  void _refocusComposerAfterPing() {
    if (!_actionPanelPointerDownHadFocus) return;
    _actionPanelPointerDownHadFocus = false;
    _armComposerCollapseGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focusNode.canRequestFocus) return;
      if (!_focusNode.hasFocus) _focusNode.requestFocus();
      showSoftKeyboardIfHidden(context: context, hasFocus: true);
    });
  }

  /// Widget tests: mirror recording state without mic hardware.
  @visibleForTesting
  void setRecordingForTest(bool isRecording) {
    _onRecordingStateChanged(isRecording);
  }

  /// Widget tests: stage attachments without a paste source (Phases 3/4 add those).
  @visibleForTesting
  ComposerAttachmentController get attachmentControllerForTest => _attachment;

  /// Widget tests: trigger and await the send path (the tap overlay is private).
  @visibleForTesting
  Future<void> sendForTest() async {
    if (_attachment.staged != null) {
      await _sendStaged();
    } else {
      _send();
    }
  }

  /// Widget tests: drive the paste-image handler without a DOM paste event.
  @visibleForTesting
  void handlePastedImageForTest(
    Uint8List bytes,
    String mimeType,
    String filename,
  ) => _onPastedImage(bytes, mimeType, filename);

  /// Widget tests: drive cursor-aware pasted-text insertion.
  @visibleForTesting
  void insertPastedTextForTest(String text) => _insertPastedText(text);

  /// Widget tests: exercise trailing spinner / send precedence without upload pipeline.
  @visibleForTesting
  void setSendingVoiceForTest(bool isSendingVoice) {
    setState(() => _isSendingVoice = isSendingVoice);
  }

  /// Called by [RecordingController] when a voice message is ready.
  ///
  /// May run after this State is unmounted: `stopAndSend` keeps going through a
  /// mid-stop teardown so the recording is not silently destroyed. Providers are
  /// therefore read from the cached references and every `context` use is
  /// mounted-gated. [conversationId] is the id captured when send was tapped —
  /// ChatDetailScreen.dispose has already cleared the provider's active id by
  /// the time a post-teardown send lands here.
  Future<void> _handleVoiceSent({
    required int duration,
    int? conversationId,
    String? localAudioPath,
    Uint8List? audioBytes,
  }) async {
    final messaging = _messagingProvider ?? context.read<MessagingProvider>();
    final convs =
        _conversationsProvider ?? context.read<ConversationsProvider>();
    final targetConversationId = conversationId ?? convs.activeConversationId;

    if (mounted) setState(() => _isSendingVoice = true);
    try {
      if (targetConversationId == null) {
        if (!mounted) return;
        showTopSnackBar(
          context,
          AppLocalizations.of(context).snackbarNoActiveConversation,
        );
        return;
      }

      final conversation = convs.conversations.firstWhere(
        (c) => c.id == targetConversationId,
      );
      final recipientId = conversation.userOne.id == convs.currentUserId
          ? conversation.userTwo.id
          : conversation.userOne.id;

      await messaging.sendVoiceMessage(
        recipientId: recipientId,
        duration: duration,
        conversationId: targetConversationId,
        localAudioPath: localAudioPath,
        localAudioBytes: audioBytes?.toList(),
      );
    } catch (e) {
      debugPrint('Send voice error: $e');
      if (!mounted) return;
      showTopSnackBar(
        context,
        AppLocalizations.of(context).snackbarFailedToSendVoiceMessage,
      );
    } finally {
      if (mounted) {
        setState(() => _isSendingVoice = false);
      }
    }
  }

  /// Trailing mic + text-send overlay. [ValueListenableBuilder] limits rebuilds to this slot.
  Widget _buildTrailingSlot(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final showTextSend =
            !_isRecording &&
            !_isSendingVoice &&
            !_isSendingStagedMedia &&
            (value.text.trim().isNotEmpty || _attachment.staged != null);
        final showVoiceSend = _isRecording && !_isSendingVoice;

        // ExcludeFocus on the whole trailing slot (mic + send overlay) so long-press
        // never steals focus from the text field. RecordingController does not add a
        // second ExcludeFocus — one ancestor is enough.
        return ExcludeFocus(
          child: SizedBox(
            width: 48,
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ExcludeSemantics(
                  excluding: showTextSend || showVoiceSend,
                  child: IgnorePointer(
                    ignoring: _isRecording || _isSendingVoice,
                    child: AnimatedOpacity(
                      opacity: (showTextSend || showVoiceSend) ? 0.0 : 1.0,
                      duration: _kTrailingSendFadeDuration,
                      curve: Curves.easeInOut,
                      child: RecordingController(
                        key: _recordingKey,
                        onVoiceSent: _handleVoiceSent,
                        onRecordingStateChanged: _onRecordingStateChanged,
                        onMicTap: _onMicTap,
                        isSendingVoice: _isSendingVoice,
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  key: const ValueKey('composer_text_send_layer'),
                  child: ExcludeSemantics(
                    excluding: !showTextSend,
                    child: IgnorePointer(
                      ignoring: !showTextSend,
                      child: AnimatedOpacity(
                        opacity: showTextSend ? 1 : 0,
                        duration: _kTrailingSendFadeDuration,
                        curve: Curves.easeInOut,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Ember hexagon — the app's shape language
                            // (paint only; the overlay below hits).
                            const IgnorePointer(child: HexSendButton()),
                            // Full 48×48 opaque tap target (was a left-nudged 22×22,
                            // easy to miss + leaked outer-ring taps to the mic).
                            Positioned.fill(
                              child: _ComposerTapSendOverlay(
                                enabled: showTextSend,
                                onTap: _send,
                                tooltip: l10n.chatComposerSendTooltip,
                                semanticsLabel: l10n.chatComposerSendSemantics,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  key: const ValueKey('composer_voice_send_layer'),
                  child: ExcludeSemantics(
                    excluding: !showVoiceSend,
                    child: IgnorePointer(
                      ignoring: !showVoiceSend,
                      child: AnimatedOpacity(
                        opacity: showVoiceSend ? 1 : 0,
                        duration: _kTrailingSendFadeDuration,
                        curve: Curves.easeInOut,
                        child: Tooltip(
                          message: l10n.voiceRecordingSendVoiceTooltip,
                          child: Semantics(
                            button: true,
                            label: l10n.voiceRecordingSendVoiceSemantics,
                            excludeSemantics: true,
                            child: IconButton(
                              onPressed: showVoiceSend
                                  ? () => _recordingKey.currentState
                                        ?.stopAndSend()
                                  : null,
                              padding: const EdgeInsets.all(12),
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              icon: Icon(
                                Icons.send_rounded,
                                size: 22,
                                color: RpgTheme.primaryColor(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _bannerDurationLabel(AppLocalizations l10n, int seconds) {
    final parts = splitDisappearingSeconds(seconds);
    final summaryParts = <String>[];
    if (parts.days > 0) {
      summaryParts.add(l10n.disappearingTimerDays(parts.days));
    }
    if (parts.hours > 0) {
      summaryParts.add(l10n.disappearingTimerHours(parts.hours));
    }
    if (parts.minutes > 0) {
      summaryParts.add(l10n.disappearingTimerMinutes(parts.minutes));
    }
    if (parts.seconds > 0) {
      summaryParts.add(l10n.disappearingTimerSeconds(parts.seconds));
    }
    return summaryParts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild only for composer-relevant provider slices so message list / decrypt
    // updates do not dismiss the Android soft keyboard while typing.
    final replyingTo = context.select<MessagingProvider, MessageModel?>(
      (m) => m.replyingToMessage,
    );
    final editing = context.select<MessagingProvider, MessageModel?>(
      (m) => m.editingMessage,
    );

    final activeTimer = context.select<ConversationsProvider, int?>(
      (c) => c.conversationDisappearingTimer,
    );
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final glass = GlassTheme.of(context);
    final themePref = context.select<SettingsProvider, String>(
      (s) => s.themePreference,
    );
    final ephemeral = RpgTheme.ephemeralAccent(
      context,
      themePreference: themePref,
    );
    final mediaQuery = MediaQuery.of(context);
    final pad = mediaQuery.padding;
    final isCompactLayout =
        mediaQuery.size.width < AppConstants.layoutBreakpointDesktop;
    // Phone / narrow PWA: keep trailing mic off the physical right edge so OS back-swipe
    // and browser edge gestures are less likely to steal the long-press.
    const trailingGestureBufferDp = 14.0;
    final trailingGestureBuffer = isCompactLayout
        ? trailingGestureBufferDp
        : 0.0;
    // Insets for notches / home indicator: chat body no longer applies horizontal SafeArea
    // around the composer (see ChatDetailScreen), so we pad here instead.
    final composerHorizontalPadding = EdgeInsets.fromLTRB(
      8.0 + pad.left,
      8.0,
      4.0 + pad.right + trailingGestureBuffer,
      8.0,
    );
    // Single source of truth (D2 fix): MediaQuery.viewInsets reads 0 on iOS
    // WebKit while the keyboard is up — fold in the shared visualViewport
    // inset so the ergonomic bottom buffer never renders underneath a raised
    // keyboard.
    //
    // FOCUS IS DELIBERATELY NOT A TERM HERE (H1 reverted 2026-09-12, owner
    // report + desktop/mobile screenshots). The buffer is the composer's
    // resting clearance over the home indicator and — inside MainShell's
    // `extendBody: true` Scaffold, where the bottom nav height arrives as
    // MediaQuery.padding.bottom — over the bottom nav. Collapsing it on focus
    // moved the composer DOWN by that clearance with nothing lifting it:
    // desktop web (no soft keyboard at all) buried the input row behind the
    // nav bar, and on phones it dropped to the physical bottom edge in the
    // window before the keyboard inset ticks up. Only a real inset — which
    // simultaneously lifts the composer via ChatComposerViewport's
    // `bottom: effectiveInset` — may collapse it.
    final keyboardVisible =
        mediaQuery.viewInsets.bottom > 0 ||
        _sharedInsetSource.inset.value > 0;
    final bottomSystemInset = math.max(
      mediaQuery.viewPadding.bottom,
      mediaQuery.padding.bottom,
    );
    const additionalBottomSpacing = 16.0;
    final needsErgonomicBuffer = bottomSystemInset > 0;
    final webMobileFallbackInset =
        !needsErgonomicBuffer && kIsWeb && isCompactLayout && !keyboardVisible
        ? 16.0
        : 0.0;
    final bottomInteractivePadding = keyboardVisible
        ? 0.0
        : (needsErgonomicBuffer
              ? bottomSystemInset + additionalBottomSpacing
              : webMobileFallbackInset);

    // Cap multiline growth: Row/Expanded can still pass a tall maxHeight; keep the
    // composer Telegram-like even under large text scale or IME quirks.
    final textScaler = MediaQuery.textScalerOf(context);
    final maxComposerHeight = (textScaler.scale(22.0) * 12 + 36).clamp(
      120.0,
      480.0,
    );

    // Telegram/Signal parity: system back with the emoji panel open closes
    // the panel instead of leaving the chat.
    return PopScope(
      canPop: !_showEmojiPicker,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showEmojiPicker) {
          setState(() => _setEmojiPickerVisible(false, animateExit: true));
        }
      },
      child: TapRegion(
        groupId: _composerTapRegionGroup,
        onTapOutside: _handleComposerRegionTapOutside,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Reply preview
            if (replyingTo != null)
              Selector<MessagingProvider, MessageModel>(
                selector: (_, messaging) {
                  return findMessageById(replyingTo.id, messaging.messages) ??
                      replyingTo;
                },
                builder: (context, resolvedReply, _) {
                  return ReplyPreviewBar(
                    message: resolvedReply,
                    onDismiss: () =>
                        context.read<MessagingProvider>().clearReplyingTo(),
                  );
                },
              ),

            // Editing banner
            if (editing != null)
              EditPreviewBar(
                onDismiss: () =>
                    context.read<MessagingProvider>().cancelEditMessage(),
              ),

            if (activeTimer != null)
              Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: ephemeral.withValues(alpha: 0.5)),
                ),
                child: Semantics(
                  label: l10n.disappearingComposerBannerSemantics(
                    _bannerDurationLabel(l10n, activeTimer),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CustomPaint(
                          size: const Size(14, 14),
                          painter: HearthFadeHexPainter(
                            color: ephemeral,
                            preRead: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            l10n.disappearingComposerBanner(
                              _bannerDurationLabel(l10n, activeTimer),
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: RpgTheme.bodyFont(
                              fontSize: 11,
                              color: ephemeral,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Staged pasted image (Clipboard Phase 2)
            if (_attachment.staged != null && !_isRecording)
              ComposerAttachmentBar(
                attachment: _attachment.staged!,
                onRemove: _attachment.clear,
              ),

            // Input row
            TapRegion(
              groupId: _composerTapRegionGroup,
              // Liquid Glass: the input row is a floating glass pill; the
              // surrounding area is transparent so chat content scrolls
              // behind it. Structure (TapRegion/FocusGuardArea/trailing
              // stack) is unchanged — glass is paint, not layout.
              child: Padding(
                padding: composerHorizontalPadding,
                child: GlassSurface(
                  borderRadius: BorderRadius.circular(28),
                  child: Row(
                    children: [
                      // Action panel toggle (hidden during recording)
                      if (!_isRecording)
                        FocusGuardArea(
                          id: 'composer_action_toggle',
                          child: Focus(
                            canRequestFocus: false,
                            child: IconButton(
                              icon: Icon(
                                _showActionPanel
                                    ? Icons.keyboard_arrow_up
                                    : Icons.keyboard_arrow_down,
                              ),
                              iconSize: 24,
                              color: glass.onGlassMuted,
                              onPressed: _toggleActionPanel,
                            ),
                          ),
                        ),
                      if (!_isRecording)
                        FocusGuardArea(
                          id: 'composer_emoji_toggle',
                          child: Focus(
                            canRequestFocus: false,
                            child: Semantics(
                              button: true,
                              label: l10n.chatComposerEmojiSemantics,
                              excludeSemantics: true,
                              child: IconButton(
                                key: const ValueKey('composer-emoji-toggle'),
                                tooltip: l10n.chatComposerEmojiTooltip,
                                icon: Icon(
                                  _showEmojiPicker
                                      ? Icons.keyboard_alt_outlined
                                      : Icons.emoji_emotions_outlined,
                                ),
                                iconSize: 24,
                                color: _showEmojiPicker
                                    ? glass.onGlassAccent
                                    : glass.onGlassMuted,
                                onPressed: _toggleEmojiPicker,
                              ),
                            ),
                          ),
                        ),
                      // Text field or recording bar
                      Expanded(
                        child: _isRecording
                            ? Builder(
                                builder: (context) {
                                  final recordingState =
                                      _recordingKey.currentState;
                                  if (recordingState == null) {
                                    return const SizedBox.shrink();
                                  }
                                  return recordingState.buildRecordingBar(
                                    context,
                                  );
                                },
                              )
                            : CallbackShortcuts(
                                bindings: <ShortcutActivator, VoidCallback>{
                                  // Web/desktop: multiline fields often lack an IME “Send”; keep one send path.
                                  const SingleActivator(
                                    LogicalKeyboardKey.enter,
                                    control: true,
                                  ): _send,
                                  const SingleActivator(
                                    LogicalKeyboardKey.enter,
                                    meta: true,
                                  ): _send,
                                },
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight: maxComposerHeight,
                                  ),
                                  child: TextField(
                                    controller: _controller,
                                    focusNode: _focusNode,
                                    // Incognito keyboard (Signal parity):
                                    // message text must not feed the IME's
                                    // personal dictionary / cloud sync.
                                    // Android-IME hint; no-op on web/iOS.
                                    enableIMEPersonalizedLearning: false,
                                    textCapitalization:
                                        TextCapitalization.sentences,
                                    style: RpgTheme.bodyFont(
                                      fontSize: 14,
                                      color: colorScheme.onSurface,
                                    ),
                                    // Borderless inside the glass pill (spec
                                    // §5): the pill IS the field chrome.
                                    decoration: InputDecoration(
                                      hintText: AppLocalizations.of(
                                        context,
                                      ).chatMessageHint,
                                      hintStyle: RpgTheme.bodyFont(
                                        fontSize: 14,
                                        color: glass.onGlassMuted,
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 10,
                                          ),
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      filled: false,
                                    ),
                                    // Cap height so the composer does not consume the whole screen (matches
                                    // WhatsApp/Telegram-style behavior: grow to a few lines, then scroll inside).
                                    minLines: 1,
                                    maxLines: 12,
                                    // Platform matrix (owner ruling 2026-07-28):
                                    // - Mobile (Android/iOS, native or PWA): the
                                    //   IME action key inserts a NEWLINE; sending
                                    //   is the on-screen send button only.
                                    // - Desktop (web or native): UNCHANGED — IME
                                    //   "Send" action + Ctrl/Cmd+Enter shortcuts;
                                    //   plain Enter inserts '\n' in this
                                    //   multiline field.
                                    textInputAction: _isMobilePlatform
                                        ? TextInputAction.newline
                                        : TextInputAction.send,
                                    // Default [onEditingComplete] unfocuses after "Send", which dismisses
                                    // the keyboard while the node can still report focused in the same sync turn.
                                    onEditingComplete: () {},
                                    onSubmitted: _isMobilePlatform
                                        ? null
                                        : (_) => _send(),
                                    // Android/desktop should hide the keyboard when
                                    // the user taps the chat outside the whole
                                    // composer. Composer controls sit in the same
                                    // [TapRegion] group, so send/emoji/attachment
                                    // taps do not trigger this callback. iOS WebKit
                                    // keeps the old no-op because tap-outside blur
                                    // caused the send-button keyboard bounce.
                                    groupId: _composerTapRegionGroup,
                                    onTapOutside: _handleComposerTapOutside,
                                    // Android IME rich-content insertion (Phase 4);
                                    // other platforms never emit commitContent.
                                    contentInsertionConfiguration:
                                        ContentInsertionConfiguration(
                                          allowedMimeTypes:
                                              kStageableImageMimeTypes.toList(),
                                          onContentInserted:
                                              _onKeyboardContentInserted,
                                        ),
                                  ),
                                ),
                              ),
                      ),

                      const SizedBox(width: 2),

                      // Trailing 48×48 stack: mic always mounted; text send fades on top (Phase 0).
                      // CLAUDE.md: never swap mic/send as Row siblings — unmount dismisses keyboard.
                      FocusGuardArea(
                        id: 'composer_trailing',
                        child: _buildTrailingSlot(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            if (!_showActionPanel &&
                !_emojiPanelOccupiesLayout &&
                bottomInteractivePadding > 0)
              SizedBox(height: bottomInteractivePadding),

            // Action panel: instant mount/unmount, mirroring the emoji panel
            // (H3 — the 0.0.88 treatment). The 250ms SizeTransition kept a
            // ~300px block relayouting through the exact window where iOS
            // counter-pans the viewport and Android Chrome leaves stale
            // composited regions. The Listener captures focus state BEFORE
            // the tap's DOM blur so ping's keyboard-neutral refocus knows
            // whether the keyboard was up.
            if (_showActionPanel)
              Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) =>
                    _actionPanelPointerDownHadFocus = _focusNode.hasFocus,
                child: ChatActionTiles(
                  bottomPadding: bottomInteractivePadding,
                  onPingSent: _refocusComposerAfterPing,
                  onStageImage: stagePickedImage,
                  onPickedVideo: sendPickedVideo,
                ),
              ),

            // Emoji panel: full 320px layout from the first frame (the bottom
            // pin reserves the keyboard's space instantly); only the CONTENT
            // slides, clipped to the panel's box — a pure paint transform,
            // for the same H3 reason the action panel above stays instant.
            if (_emojiPanelOccupiesLayout)
              ClipRect(
                child: SlideTransition(
                  position: _emojiPanelOffset,
                  child: FireplaceEmojiPicker(
                    onEmojiSelected: _insertEmoji,
                    onBackspacePressed: _deletePreviousEmoji,
                    height: 320,
                  ),
                ),
              ),
          ],
        ), // Column
      ), // TapRegion
    ); // PopScope
  }
}

/// Tap-only trailing send so [RecordingController]'s long-press reaches the mic below.
/// [IconButton] would win the gesture arena and block hold-to-record when draft text is visible.
class _ComposerTapSendOverlay extends StatefulWidget {
  const _ComposerTapSendOverlay({
    required this.enabled,
    required this.onTap,
    required this.tooltip,
    required this.semanticsLabel,
  });

  final bool enabled;
  final VoidCallback onTap;
  final String tooltip;
  final String semanticsLabel;

  @override
  State<_ComposerTapSendOverlay> createState() =>
      _ComposerTapSendOverlayState();
}

class _ComposerTapSendOverlayState extends State<_ComposerTapSendOverlay> {
  static const Duration _kTapMaxDuration = Duration(milliseconds: 300);
  static const double _kTapMaxMovement = 18.0;

  DateTime? _downTime;
  Offset? _downPosition;

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled) return;
    _downTime = DateTime.now();
    _downPosition = event.position;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!widget.enabled || _downTime == null || _downPosition == null) return;
    final duration = DateTime.now().difference(_downTime!);
    final moved = (event.position - _downPosition!).distance;
    _downTime = null;
    _downPosition = null;
    if (duration <= _kTapMaxDuration && moved <= _kTapMaxMovement) {
      widget.onTap();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _downTime = null;
    _downPosition = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: Tooltip(
        message: widget.tooltip,
        child: Semantics(
          button: true,
          label: widget.semanticsLabel,
          excludeSemantics: true,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
