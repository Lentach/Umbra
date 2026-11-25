part of '../chat_input_bar.dart';

/// The emoji panel: its visibility, the paint-only slide and the emoji
/// insert and delete callbacks. The controller and its offset animation are
/// created in [ChatInputBarState.initState].
mixin _ComposerEmojiPanel on _ComposerCore {
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
}
