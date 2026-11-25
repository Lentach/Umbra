part of '../chat_input_bar.dart';

/// State every other composer part reads: the text field, the staged
/// attachment, the recording and sending flags, the cached providers and the
/// keyboard collapse guard.
mixin _ComposerCore on State<ChatInputBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  bool _showActionPanel = false;

  MessagingProvider? _messagingProvider;
  // Cached for _handleVoiceSent, which can run after this State is unmounted
  // (RecordingController.stopAndSend deliberately outlives a mid-stop teardown).
  ConversationsProvider? _conversationsProvider;

  // Set true (with a 600ms auto-clear) whenever the composer initiates a send /
  // deliberate refocus that may briefly blur+restore the IME. Gates the viewport
  // keyboard-collapse debounce — see composer_keyboard_signals.dart.
  Timer? _collapseGuardTimer;

  // Recording state mirrored from RecordingController via callback
  bool _isRecording = false;
  bool _isSendingVoice = false;

  // GlobalKey to access RecordingControllerState.buildRecordingBar() + methods.
  final _recordingKey = GlobalKey<RecordingControllerState>();

  // Staged media: a pasted or keyboard-inserted image only (Clipboard Phase
  // 2); paperclip picks send immediately and never stage. Chip renders above
  // the input row; _sendStaged() drains it honoring the media-then-caption
  // ordering contract (spec §3).
  final _attachment = ComposerAttachmentController();
  bool _isSendingStagedMedia = false;

  void _requestComposerFocus() {
    if (!mounted || !_focusNode.canRequestFocus) return;
    if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
    showSoftKeyboardIfHidden(context: context, hasFocus: true);
  }

  /// Restores the composer after a transient surface such as User Card closes.
  void focusComposer() => _requestComposerFocus();

  /// True when the active chat is no longer [conversationId] — a send now
  /// would go to the wrong chat. Callers check `mounted` first.
  bool _chatSwitchedFrom(int? conversationId) =>
      context.read<ConversationsProvider>().activeConversationId !=
      conversationId;

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
}
