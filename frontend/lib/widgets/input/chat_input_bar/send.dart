part of '../chat_input_bar.dart';

/// Everything that sends: pasted and picked attachments, text, the staged
/// image with its caption, voice, and the reply and edit targets that feed the
/// text field.
mixin _ComposerSend on _ComposerFocus {
  MessageModel? _lastReplyingTo;
  MessageModel? _lastEditingMessage;

  /// Completes when the last queued [sendPickedFiles] batch has finished.
  Future<void> _pickedBatchTail = Future<void>.value();

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

  /// Paperclip pick → IMMEDIATE send of every picked file, one message each,
  /// in pick order (owner ruling 2026-10-27: the gallery tap is the
  /// confirmation; other messengers do not make you press send again).
  /// Pasted images still stage — a paste can happen by accident.
  ///
  /// At most [kMaxFilesPerPick] go out; the rest are dropped with a toast.
  /// Files go one after another, each awaited to its socket emit, so the
  /// peer sees them in pick order. A web file_picker pick arrives with every
  /// file already read; the other doors read each file on its turn.
  /// A typed draft stays in the field: there is no staging step to attach it
  /// to as a caption.
  ///
  /// The provider sends into the ACTIVE conversation, so a file goes out only
  /// while [pickedIn] — the chat the paperclip was tapped in — is still the
  /// active one: the batch stops the moment the user leaves it (or this
  /// composer unmounts), never landing a file in whichever chat is open by
  /// then. That covers the wait before the files arrive (a web pick reads
  /// every file first) and the waits inside a video (transcode, probe): the
  /// desktop split view keeps this composer mounted across a chat switch, so
  /// `mounted` alone is no guard. The toast goes on the root overlay, which
  /// outlives this composer.
  ///
  /// A pick made while an earlier batch is still going waits for it
  /// ([_pickedBatchTail]): two loops running at once would interleave their
  /// files and break the pick order the peer sees. Nothing is dropped.
  Future<void> sendPickedFiles(
    List<PickedAttachment> files, {
    required int pickedIn,
  }) async {
    if (files.isEmpty || !mounted) return;
    // A recording replaces the composer row, and the picks have nowhere to
    // go until it is resolved: say so instead of dropping them (A3-CMP-07).
    if (_isRecording) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context).attachmentBlockedWhileRecording,
      );
      return;
    }
    if (!_canAcceptPaste()) return;
    final l10n = AppLocalizations.of(context);
    final rootOverlay = Overlay.of(context, rootOverlay: true);
    var batch = files;
    if (files.length > kMaxFilesPerPick) {
      showTopSnackBar(context, l10n.attachmentPickLimit(kMaxFilesPerPick));
      batch = files.sublist(0, kMaxFilesPerPick);
    }
    final previous = _pickedBatchTail;
    final turn = Completer<void>();
    _pickedBatchTail = turn.future;
    void interrupted() {
      if (!rootOverlay.mounted) return;
      showTopSnackBar(
        rootOverlay.context,
        l10n.attachmentBatchInterrupted,
        overlay: rootOverlay,
      );
    }

    try {
      await previous;
      // Left the chat while queued: read nothing (a web pick's files are
      // already in RAM, a native one reads each file on its turn).
      if (!mounted || _chatSwitchedFrom(pickedIn)) {
        interrupted();
        return;
      }
      for (final file in batch) {
        final bytes = await file.readBytes();
        if (!mounted ||
            _chatSwitchedFrom(pickedIn) ||
            !await _sendPickedFile(file, bytes)) {
          interrupted();
          return;
        }
      }
    } finally {
      turn.complete();
    }
  }

  /// False only when the user left the chat before the file could go out
  /// (the caller stops the batch); refusals and failures return true.
  Future<bool> _sendPickedFile(PickedAttachment file, Uint8List? bytes) async {
    final l10n = AppLocalizations.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    if (bytes == null) {
      showTopSnackBar(
        context,
        l10n.snackbarCouldNotReadFile,
        backgroundColor: errorColor,
      );
      return true;
    }
    switch (file.kind) {
      case PickedAttachmentKind.image:
        if (bytes.length > MediaCryptoService.maxBytes) {
          showTopSnackBar(context, l10n.snackbarPastedImageTooLarge);
          return true;
        }
        // A send, like the staged path: the keyboard must not collapse
        // underneath it.
        _armComposerCollapseGuard();
        await AttachmentHandler.sendImage(
          context,
          imageBytes: bytes,
          filename: file.name,
          mimeType: file.imageMimeType,
        );
      case PickedAttachmentKind.video:
        return sendPickedVideo(bytes: bytes, filename: file.name);
      case PickedAttachmentKind.document:
        await AttachmentHandler.sendDocument(
          context,
          bytes: bytes,
          fileName: file.name,
          mimeType: file.documentMimeType,
        );
      case PickedAttachmentKind.unsupported:
        showTopSnackBar(
          context,
          l10n.attachmentUnsupportedFileType,
          backgroundColor: errorColor,
        );
    }
    return true;
  }

  /// One picked video → IMMEDIATE send (owner ruling 2026-08-31). iOS's own
  /// `Retake / Use Video` review screen is already the confirmation step.
  ///
  /// Gate order is deliberate: the cheap extension and size checks run first,
  /// because `probeVideoPreview` loads the whole clip into a decoder and costs
  /// seconds on a phone. That single probe pass supplies the duration for the
  /// cap AND the geometry + ThumbHash the receiving bubble needs — the
  /// provider never re-probes.
  ///
  /// Returns false, sending nothing, when the user left the chat it was
  /// picked in during the transcode or probe; true otherwise.
  Future<bool> sendPickedVideo({
    required Uint8List bytes,
    required String filename,
  }) async {
    final conversationId =
        context.read<ConversationsProvider>().activeConversationId;
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
      return true;
    }
    if (bytes.length > MediaCryptoService.maxBytes) {
      final transcoded = await _transcodeOversizeVideo(bytes);
      if (!mounted || _chatSwitchedFrom(conversationId)) return false;
      if (transcoded == null) {
        // Named actuals, not just the limit: "34 MB, max 20 MB" tells the user
        // WHY this clip failed and roughly how much to trim.
        final sizeMb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
        showTopSnackBar(
          context,
          l10n.videoTooLarge(sizeMb),
          backgroundColor: Colors.red,
        );
        return true;
      }
      bytes = transcoded;
    }

    final preview = await (ChatInputBarState.debugProbeOverride?.call(bytes) ??
        video_probe.probeVideoPreview(
          bytes,
          mimeType: videoMimeForFilename(filename),
        ));
    if (!mounted || _chatSwitchedFrom(conversationId)) return false;
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
      return true;
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
    return true;
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
    final override = ChatInputBarState.debugTranscodeOverride;
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
  /// the caption is restored to the field (the failed bubble owns retry). The
  /// provider sends into the ACTIVE chat, so the caption is also kept back
  /// (restored) when the user switched chats during the image's send — the
  /// desktop split view keeps this composer mounted across that switch.
  ///
  /// While an edit is active the field holds the EDIT, not a caption (A3-CMP-06):
  /// it is applied to the original message (or the edit is dropped when the
  /// field is empty, like [_send]) and the picture goes out on its own, with
  /// no caption — the same as a paperclip pick made during an edit.
  Future<void> _sendStaged() async {
    if (_isSendingStagedMedia) return;
    final staged = _attachment.staged;
    if (staged == null) return;
    final keepEmojiPanel = _showEmojiPicker;
    _armComposerCollapseGuard();

    final messaging = context.read<MessagingProvider>();
    final editing = messaging.editingMessage;
    final fieldText = _controller.text.trim();
    if (editing != null) {
      if (fieldText.isEmpty) {
        messaging.cancelEditMessage();
      } else {
        messaging.editMessage(editing.id, fieldText);
      }
    }
    final caption = editing != null ? '' : fieldText;
    final convs = context.read<ConversationsProvider>();
    final expiresIn = convs.conversationDisappearingTimer;
    final conversationId = convs.activeConversationId;
    // The composer may unmount during the send (mobile: the chat is popped);
    // what the caption needs afterwards is captured while it is mounted.
    final l10n = AppLocalizations.of(context);
    final rootOverlay = Overlay.of(context, rootOverlay: true);

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
      if (!mounted) {
        if (sent && caption.isNotEmpty) {
          if (convs.activeConversationId == conversationId) {
            messaging.sendMessage(caption, expiresIn: expiresIn);
          } else if (rootOverlay.mounted) {
            showTopSnackBar(
              rootOverlay.context,
              l10n.attachmentBatchInterrupted,
              overlay: rootOverlay,
            );
          }
        }
        return;
      }
      if (caption.isNotEmpty) {
        if (sent && !_chatSwitchedFrom(conversationId)) {
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

  /// Called by [RecordingController] when recording state changes.
  /// Recording replaces the composer row — close the emoji panel with it
  /// (Telegram parity: mic tap dismisses the panel) and the action panel too:
  /// its paperclip would hand picks to a composer that cannot send them
  /// mid-recording (A3-CMP-07).
  void _onRecordingStateChanged(bool isRecording) {
    if (!mounted) {
      _isRecording = isRecording;
      return;
    }
    setState(() {
      _isRecording = isRecording;
      if (isRecording) {
        _setEmojiPickerVisible(false);
        _showActionPanel = false;
      }
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
}
