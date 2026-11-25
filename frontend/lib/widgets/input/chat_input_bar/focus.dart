part of '../chat_input_bar.dart';

/// Focus and keyboard handling: taps outside the composer, the chat-surface
/// dismiss, the shared keyboard inset, the action panel toggle and the
/// keyboard-neutral ping refocus.
mixin _ComposerFocus on _ComposerEmojiPanel {
  bool _ignoreComposerTapOutsideForChatSurfaceTap = false;
  // Captured on pointer-down inside the action panel, BEFORE the tap's DOM
  // blur can reach the framework: tells ping's keyboard-neutral refocus
  // whether the keyboard was up when the user tapped.
  bool _actionPanelPointerDownHadFocus = false;

  // Cached so dispose removes the listener from the SAME instance initState
  // added it to, even when a test overrides the shared source between mounts.
  late final KeyboardInsetSource _sharedInsetSource;
  // H2: iOS fires visualViewport resize/scroll repeatedly during the keyboard
  // pan; this state only consumes the BOOLEAN (inset > 0), so rebuilds are
  // gated on the flip, not per pixel event.
  bool _lastSharedInsetVisible = false;

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

  /// Ping is keyboard-neutral: tapping the tile must not dismiss a raised
  /// keyboard (user ruling 2026-07-09). On iOS WebKit the [FocusGuardArea]
  /// around the tile prevents the DOM blur outright; this is the non-iOS
  /// fallback — the same post-frame refocus pattern as `_send`. Gated on
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
}
