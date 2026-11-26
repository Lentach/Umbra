part of '../chat_detail_screen.dart';

// These members belong to the State class and only live in a part file for
// size; the analyzer honours `@protected` only inside a State subclass's own
// members, so the `setState` calls below warn although they run on this State.
// ignore_for_file: invalid_use_of_protected_member

/// List, scroll and message-area members of [_ChatDetailScreenState]: revealing a
/// pinned message, the new-message badge and autoscroll, the keyboard-open
/// autoscroll, the scroll-to-bottom button and the message list itself.
///
/// `_onScroll` and `_onWebKeyboardInsetChanged` stay in the class: both are added
/// and removed as tear-offs, and an extension tear-off is a new closure every
/// time, so the removal would never match.
extension _ChatDetailScroll on _ChatDetailScreenState {
  Future<void> _scrollToMessageId(int messageId) async {
    final messaging = context.read<MessagingProvider>();
    final l10n = AppLocalizations.of(context);

    final listIndex = listIndexForMessageId(
      messageId: messageId,
      messages: messaging.messages,
    );

    if (listIndex == null) {
      if (mounted) {
        showTopSnackBar(context, l10n.snackbarPinnedMessageUnavailable);
      }
      return;
    }

    final generation = ++_scrollGeneration;
    setState(() {
      _scrollTargetListIndex = listIndex;
      _scrollTargetKey = GlobalKey();
    });

    var revealed = false;
    const maxRevealAttempts = 12;
    final itemCount = messaging.messages.length;
    for (var attempt = 0; attempt < maxRevealAttempts; attempt++) {
      if (attempt > 0 && _scrollController.hasClients && itemCount > 1) {
        final maxExtent = _scrollController.position.maxScrollExtent;
        final fraction = listIndex / (itemCount - 1);
        _scrollController.jumpTo((maxExtent * fraction).clamp(0.0, maxExtent));
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || generation != _scrollGeneration) return;
      final targetContext = _scrollTargetKey?.currentContext;
      if (targetContext != null) {
        await Scrollable.ensureVisible(
          targetContext, // ignore: use_build_context_synchronously
          alignment: 0.5,
          duration: const Duration(milliseconds: 300),
        );
        revealed = true;
        break;
      }
    }

    if (!mounted || generation != _scrollGeneration) return;
    if (!revealed) {
      showTopSnackBar(context, l10n.snackbarPinnedMessageUnavailable);
    }

    setState(() {
      _scrollTargetListIndex = null;
      _scrollTargetKey = null;
    });
  }

  Widget _buildMessageListItem({
    required int listIndex,
    required MessageModel msg,
    required bool showDate,
    required bool isMine,
    // Computed once in `_ChatDetailScreenState.build` with a `context.select`:
    // the bubble must not re-derive it, which would mean walking
    // ConversationsProvider for the peer and silently skipping the
    // subscription before that list has loaded.
    required bool peerRefused,
  }) {
    final scrollKey = listIndex == _scrollTargetListIndex
        ? (_scrollTargetKey ??= GlobalKey())
        : null;
    final bubble = Column(
      key: ValueKey(msg.id),
      children: [
        if (showDate) MessageDateSeparator(date: msg.createdAt),
        if (showDate) const SizedBox(height: 8),
        ChatMessageBubble(
          message: msg,
          isMine: isMine,
          peerRefusedIdentity: peerRefused,
        ),
      ],
    );
    if (scrollKey == null) return bubble;
    return KeyedSubtree(key: scrollKey, child: bubble);
  }

  Widget? _buildPinnedMessageBanner(
    BuildContext context,
    ConversationModel conv,
    MessagingProvider messaging,
    ConversationsProvider convs,
  ) {
    if (!shouldShowPinnedMessageBanner(conv)) return null;
    final l10n = AppLocalizations.of(context);
    final preview = conv.pinnedMessagePreview;
    if (preview == null) return null;
    final encryption = context.read<EncryptionProvider>();
    final pinnedId = conv.pinnedMessageId!;
    final localRow = messaging.messageById(pinnedId);
    final previewModel = resolvePinnedPreviewMessage(
      serverPreview: preview,
      localMessage: localRow,
    );
    final previewText = replyPreviewForMessage(
      l10n,
      previewModel,
      encryption: encryption,
    );
    return PinnedMessageBanner(
      previewText: previewText,
      // An own row carries no username: without the id check the fallback
      // put the PEER's name on the reader's own pinned message.
      senderLabel: previewModel.senderId == convs.currentUserId
          ? l10n.senderYou
          : previewModel.senderUsername.isNotEmpty
          ? previewModel.senderUsername
          : convs.getOtherUserUsername(conv),
      onTap: () => _scrollToMessageId(conv.pinnedMessageId!),
      onUnpin: () => messaging.unpinMessage(conv.id),
    );
  }

  void _onNewMessages(int currentCount, int added) {
    final messaging = context.read<MessagingProvider>();
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    final currentMessages = messaging.messages;
    final currentMessageIds = currentMessages.map((m) => m.id).toSet();

    if (added <= 0) {
      _lastMessageCount = currentCount;
      _knownMessageIds
        ..clear()
        ..addAll(currentMessageIds);
      _lastLinkPreviewCount = currentMessages
          .where((m) => m.linkPreviewUrl != null)
          .length;
      return;
    }

    final newPeerMessages = currentMessages.where((m) {
      final known = _knownMessageIds.contains(m.id);
      return !known && m.senderId != currentUserId;
    }).length;
    final newOwnMessages = currentMessages.where((m) {
      final known = _knownMessageIds.contains(m.id);
      return !known && m.senderId == currentUserId;
    }).length;

    _knownMessageIds.addAll(currentMessageIds);

    // Initial full snapshot: opening the chat. _lastMessageCount was 0 so added == currentCount.
    // Do NOT badge — this is the open render, not an incoming message.
    // pixels=0 already shows newest with reverse:true; no explicit scroll needed.
    if (_lastMessageCount == 0 && added == currentCount) {
      _lastMessageCount = currentCount;
      _lastLinkPreviewCount = currentMessages
          .where((m) => m.linkPreviewUrl != null)
          .length;
      return;
    }

    // Subsequent incoming message.
    _lastMessageCount = currentCount;
    _lastLinkPreviewCount = currentMessages
        .where((m) => m.linkPreviewUrl != null)
        .length;
    // Own sends always scroll (emote-panel sends have no keyboard-open scroll
    // to piggyback on); peer messages scroll only near-bottom, else badge.
    if (shouldAutoScrollOnNewMessages(
      newOwnMessages: newOwnMessages,
      wasNearBottom: _wasNearBottom,
      userHasScrolledChat: _userHasScrolledChat,
    )) {
      _scrollToBottom();
    } else if (newPeerMessages > 0) {
      setState(() => _newMessagesCount += newPeerMessages);
    }
  }

  // Keyboard just opened: keep the newest messages visible above it. Both
  // keyboard signals (Flutter viewInsets via didChangeMetrics; the shared
  // visualViewport inset on iOS WebKit) funnel here, and the height is always
  // the MAX of the two — so a zero-write from the idle signal (e.g. a
  // didChangeMetrics toolbar resize while the iOS keyboard is up) can never
  // reset the edge detector and re-trigger the scroll on the next inset
  // change.
  void _handleKeyboardHeightChanged() {
    final flutterInset = View.of(context).viewInsets.bottom;
    final webInset = _sharedInset.inset.value;
    final bottom = flutterInset > webInset ? flutterInset : webInset;
    if (bottom > 0 &&
        _lastKeyboardHeight == 0 &&
        _messaging.messages.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (!mounted || !_scrollController.hasClients) return;
          _scrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        });
      });
    }
    _lastKeyboardHeight = bottom;
  }

  void _scrollToBottom() {
    if (mounted) setState(() => _newMessagesCount = 0);
    if (!mounted || !_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _onScrollToBottomButtonTap() {
    _scrollToBottom();
  }

  Widget _buildScrollToBottomButton() {
    return Positioned(
      bottom: 140,
      right: 16,
      child: Semantics(
        button: true,
        label: AppLocalizations.of(context).chatScrollToBottomSemantics,
        child: Material(
          elevation: 2,
          borderRadius: BorderRadius.circular(24),
          color: Theme.of(context).colorScheme.surface,
          child: InkWell(
            onTap: _onScrollToBottomButtonTap,
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.keyboard_arrow_down, size: 28),
                  if (_newMessagesCount > 0)
                    Positioned(
                      top: -4,
                      right: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        // Theme tokens, not Colors.blue/Colors.white: the raw
                        // pair is off-brand on the ember/teal/cosmic themes, and
                        // white on #2196F3 is ~3.3:1 — under the 4.5:1 gate for
                        // 11px text. primary/onPrimary is the pairing every other
                        // count badge in the app already uses.
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: const BorderRadius.all(
                            Radius.circular(10),
                          ),
                        ),
                        constraints: const BoxConstraints(minWidth: 18),
                        child: Text(
                          _newMessagesCount > 99 ? '99+' : '$_newMessagesCount',
                          style: RpgTheme.bodyFont(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _isDifferentDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year != lb.year || la.month != lb.month || la.day != lb.day;
  }

  Widget _buildMessagesArea({
    required double listBottomPadding,
    required bool topInsetHandled,
    required List<MessageModel> messages,
    required Color mutedColor,
    required Color messagesAreaBg,
    required UserModel? peer,
    required bool peerIdentityChanged,
    required bool peerHeld,
    required bool peerRefused,
    required bool peerKeyChangeNoted,
    required List<int> keyChangeLogMs,
    required int currentUserId,
  }) {
    // Wallpaper runs full-bleed behind the floating top chrome
    // (extendBodyBehindAppBar); the list clears it via top padding unless a
    // pinned banner already consumed the top inset.
    final topClearance = topInsetHandled
        ? 8.0
        : MediaQuery.paddingOf(context).top + 8.0;
    // The EMPTY-state column is static: its first child sits at `top`
    // forever, unlike the reverse list whose content is anchored at the
    // bottom and only reaches the chrome while scrolling. Status-bar inset
    // alone put the identity-change row exactly under the GlassTopBar
    // capsule (capsule spans [top + 8, top + 60]) — the avatar and the title
    // pill painted over it and the warning was unreadable (owner report,
    // 2026-09-14). Same clearance formula the other GlassTopBar screens use.
    final emptyTopClearance = topInsetHandled
        ? 8.0
        : MediaQuery.paddingOf(context).top + GlassTopBar.capsuleHeight + 16;
    final settings = context.watch<SettingsProvider>();
    // Phase 0a: unacknowledged peer identity change renders a system row at
    // the newest end of the timeline (reverse list => index 0). Clears the
    // moment the user confirms fingerprints in the verify dialog. With
    // key-change warnings demoted (amendment (lxxix)) the slot instead holds
    // the muted one-shot note. The flags are computed (and subscribed) in
    // build() — this helper also runs inside ChatComposerViewport's build,
    // where context.select is illegal.
    final identityRowOffset = (peerIdentityChanged || peerKeyChangeNoted)
        ? 1
        : 0;
    // Decision 152: each key change this device accepted by itself is a
    // permanent system line at its own time, between the messages around it.
    final entries = _timelineEntries(messages, keyChangeLogMs);
    return ChatBackgroundPattern(
      backgroundColor: messagesAreaBg,
      layer: settings.resolvedChatBackground,
      child: messages.isEmpty
          // The alarm must survive an EMPTY conversation. This row used to be
          // rendered ONLY inside the ListView below, so a peer whose identity
          // changed was announced NOWHERE in exactly the chats most likely to
          // be empty: cleared history, fully expired history, or a peer who
          // reset before the first message — and the server
          // `peerIdentityChanged` event raises the warning with no local
          // message required, so an empty chat is not a corner case.
          ? Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 20,
                top: emptyTopClearance,
                bottom: 8 + listBottomPadding,
              ),
              child: Column(
                children: [
                  if (peerIdentityChanged)
                    PeerIdentityChangedRow(
                      // Only ever true when the peer is known; see build().
                      peerId: peer!.id,
                      peerName: _getContactName(),
                      held: peerHeld,
                    )
                  else if (peerKeyChangeNoted)
                    PeerIdentityChangedNote(
                      peerId: peer!.id,
                      peerName: _getContactName(),
                    ),
                  for (final ms in keyChangeLogMs) _keyChangeLogLine(ms, peer!),
                  Expanded(
                    child: Center(
                      child: Text(
                        AppLocalizations.of(context).noMessagesYet,
                        style: RpgTheme.bodyFont(
                          fontSize: 14,
                          color: mutedColor,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                _composerKey.currentState?.dismissForChatSurfaceTap();
              },
              child: NotificationListener<ScrollStartNotification>(
                onNotification: (notification) {
                  dismissMessageContextMenu();
                  return false;
                },
                child: NotificationListener<UserScrollNotification>(
                  onNotification: (notification) {
                    _userHasScrolledChat = true;
                    return false;
                  },
                  child: ListView.builder(
                    reverse: true,
                    controller: _scrollController,
                    findChildIndexCallback: (Key key) {
                      if (key is ValueKey<int>) {
                        final idx = messages.indexWhere(
                          (m) => m.id == key.value,
                        );
                        if (idx == -1) return null;
                        final at = entries.indexWhere((e) => e.msgIndex == idx);
                        return entries.length - 1 - at + identityRowOffset;
                      }
                      return null;
                    },
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 20,
                      top: topClearance,
                      bottom: 8 + listBottomPadding,
                    ),
                    itemCount: entries.length + identityRowOffset,
                    itemBuilder: (context, index) {
                      if (peerIdentityChanged && index == 0) {
                        return PeerIdentityChangedRow(
                          // peerIdentityChanged is only computed true in
                          // build() when otherUser (this `peer`) is non-null.
                          peerId: peer!.id,
                          peerName: _getContactName(),
                          held: peerHeld,
                        );
                      }
                      if (peerKeyChangeNoted && index == 0) {
                        return PeerIdentityChangedNote(
                          peerId: peer!.id,
                          peerName: _getContactName(),
                        );
                      }
                      final entry =
                          entries[entries.length - 1 - (index - identityRowOffset)];
                      final noteMs = entry.noteMs;
                      if (noteMs != null) return _keyChangeLogLine(noteMs, peer!);
                      final msgIndex = entry.msgIndex!;
                      final msg = messages[msgIndex];
                      final showDate =
                          msgIndex == 0 ||
                          _isDifferentDay(
                            messages[msgIndex - 1].createdAt,
                            msg.createdAt,
                          );
                      return _buildMessageListItem(
                        listIndex: messages.length - 1 - msgIndex,
                        msg: msg,
                        showDate: showDate,
                        isMine: msg.senderId == currentUserId,
                        peerRefused: peerRefused,
                      );
                    },
                  ),
                ),
              ),
            ),
    );
  }

  /// The ascending timeline: every message, with each accepted-key-change
  /// instant ([notesMs], ascending) slotted before the first message stamped
  /// after it.
  static List<({int? msgIndex, int? noteMs})> _timelineEntries(
    List<MessageModel> messages,
    List<int> notesMs,
  ) {
    final out = <({int? msgIndex, int? noteMs})>[];
    var n = 0;
    for (var i = 0; i < messages.length; i++) {
      final at = messages[i].createdAt.millisecondsSinceEpoch;
      while (n < notesMs.length && notesMs[n] < at) {
        out.add((msgIndex: null, noteMs: notesMs[n++]));
      }
      out.add((msgIndex: i, noteMs: null));
    }
    while (n < notesMs.length) {
      out.add((msgIndex: null, noteMs: notesMs[n++]));
    }
    return out;
  }

  Widget _keyChangeLogLine(int atMs, UserModel peer) => KeyedSubtree(
    key: ValueKey('peer-key-change-log-$atMs'),
    child: PeerIdentityChangedNote(
      peerId: peer.id,
      peerName: _getContactName(),
    ),
  );
}
