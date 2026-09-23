import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/friends_provider.dart';
import '../providers/messaging_provider.dart';
import '../providers/settings_provider.dart';
import '../services/voice_audio_coordinator.dart';
import '../theme/rpg_theme.dart';
import '../widgets/glass/glass_top_bar.dart';
import '../widgets/message/chat_message_bubble.dart';
import '../widgets/input/chat_input_bar.dart';
import '../widgets/input/chat_composer_viewport.dart';
import '../widgets/input/composer_diagnostics_overlay.dart'
    show toggleComposerDiagOverlay;
import '../widgets/message_date_separator.dart';
import '../models/conversation_model.dart';
import '../models/message_model.dart';
import '../models/user_model.dart';
import '../widgets/hex_avatar.dart';
import '../widgets/chat_background_pattern.dart';
import '../widgets/devices_syncing_note.dart';
import '../widgets/ping_effect_overlay.dart';
import '../widgets/top_snackbar.dart';
import '../widgets/message/pinned_message_banner.dart';
import '../widgets/message/message_context_menu_overlay.dart';
import '../utils/scroll_to_message_helper.dart';
import '../utils/chat_auto_scroll.dart';
import '../utils/pinned_banner_visibility.dart';
import '../utils/reply_preview_helper.dart';
import '../utils/chat_resume_reassert.dart';
import '../utils/ping_sound.dart';
import '../utils/web_keyboard_inset.dart';
import '../providers/encryption_provider.dart';
import '../widgets/peer_identity_changed_row.dart';
import '../services/notification_cleaner_stub.dart'
    if (dart.library.html) '../services/notification_cleaner_web.dart'
    if (dart.library.io) '../services/notification_cleaner_io.dart';
import '../utils/instant_opaque_route.dart';
import 'user_card_screen.dart';

class ChatDetailScreen extends StatefulWidget {
  final int conversationId;
  final bool isEmbedded;

  const ChatDetailScreen({
    super.key,
    required this.conversationId,
    this.isEmbedded = false,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen>
    with WidgetsBindingObserver {
  /// Cached in [initState] so [dispose] can sync push state without relying on [context].
  late final ConversationsProvider _conversations;
  late final MessagingProvider _messaging;
  final _notificationCleaner = createNotificationCleaner();

  final _scrollController = ScrollController();
  final _composerKey = GlobalKey<ChatInputBarState>();
  bool _showScrollToBottomButton = false;
  int _newMessagesCount = 0;
  int _lastMessageCount = 0;
  int _lastLinkPreviewCount = 0;
  /// (lxxxiv): the note instant whose durable eviction this screen already
  /// requested; stops repeated builds from re-requesting it.
  String? _dismissedNoteAt;
  final Set<int> _knownMessageIds = <int>{};
  double _lastKeyboardHeight = 0;
  // Cached so dispose removes the listener from the SAME instance initState
  // added it to, even when a test overrides the shared source between mounts.
  late final KeyboardInsetSource _sharedInset;
  bool _isLoadingMoreLocal = false;
  double? _prePaginationScrollOffset;
  double? _prePaginationScrollExtent;
  bool _wasNearBottom = true;

  /// After the user drags the list, do not auto-scroll to bottom until they scroll back
  /// (cleared when near bottom in [_onScroll]).
  bool _userHasScrolledChat = false;
  static const double _scrollToBottomThreshold = 80;
  int? _scrollTargetListIndex;
  GlobalKey? _scrollTargetKey;

  Future<void> _scrollToMessageId(int messageId) async {
    final messaging = context.read<MessagingProvider>();
    final l10n = AppLocalizations.of(context);

    final listIndex = await loadListIndexForMessageId(
      messageId: messageId,
      getMessages: () => messaging.messages,
      hasMoreMessages: () => messaging.hasMoreMessages,
      loadOlderPage: () => messaging.loadOlderMessages(widget.conversationId),
    );

    if (listIndex == null) {
      if (mounted) {
        showTopSnackBar(context, l10n.snackbarPinnedMessageUnavailable);
      }
      return;
    }

    setState(() {
      _scrollTargetListIndex = listIndex;
      _scrollTargetKey = GlobalKey();
    });

    var revealed = false;
    const maxRevealAttempts = 12;
    final itemCount = messaging.messages.length + (_isLoadingMoreLocal ? 1 : 0);
    for (var attempt = 0; attempt < maxRevealAttempts; attempt++) {
      if (attempt > 0 && _scrollController.hasClients && itemCount > 1) {
        final maxExtent = _scrollController.position.maxScrollExtent;
        final fraction = listIndex / (itemCount - 1);
        _scrollController.jumpTo((maxExtent * fraction).clamp(0.0, maxExtent));
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
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

    if (!revealed && mounted) {
      showTopSnackBar(context, l10n.snackbarPinnedMessageUnavailable);
    }

    if (mounted) {
      setState(() {
        _scrollTargetListIndex = null;
        _scrollTargetKey = null;
      });
    }
  }

  Widget _buildMessageListItem({
    required int listIndex,
    required MessageModel msg,
    required bool showDate,
    required bool isMine,
    // Computed once in build() with a `context.select` (`:1000`): the bubble
    // must not re-derive it, which would mean walking ConversationsProvider
    // for the peer and silently skipping the subscription before that list
    // has loaded.
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
      senderLabel: previewModel.senderUsername.isNotEmpty
          ? previewModel.senderUsername
          : convs.getOtherUserUsername(conv),
      onTap: () => _scrollToMessageId(conv.pinnedMessageId!),
      onUnpin: () => messaging.unpinMessage(conv.id),
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // With reverse:true, pixels=0 is the bottom (newest). Near-bottom = pixels <= threshold.
    final atBottom = pos.pixels <= _scrollToBottomThreshold;
    _wasNearBottom = atBottom;
    if (atBottom) {
      _userHasScrolledChat = false;
    }
    if (_showScrollToBottomButton != !atBottom && mounted) {
      setState(() => _showScrollToBottomButton = !atBottom);
    }

    // Near visual top (oldest messages) = pixels near maxScrollExtent → load older.
    // Require maxScrollExtent > 0 so short non-scrollable threads do not satisfy
    // pixels >= maxScrollExtent - 300 while sitting at the bottom.
    final maxExtent = pos.maxScrollExtent;
    if (maxExtent > 0 && pos.pixels >= maxExtent - 300) {
      final messaging = context.read<MessagingProvider>();
      if (!messaging.isLoadingMore && messaging.hasMoreMessages) {
        _prePaginationScrollOffset = _scrollController.offset;
        _prePaginationScrollExtent = _scrollController.position.maxScrollExtent;
        setState(() => _isLoadingMoreLocal = true);
        messaging.loadOlderMessages(widget.conversationId);
      }
    }
  }

  void _onNewMessages(int currentCount, int added) {
    final messaging = context.read<MessagingProvider>();
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    final currentMessages = messaging.messages;
    final currentMessageIds = currentMessages.map((m) => m.id).toSet();

    if (_isLoadingMoreLocal) {
      _knownMessageIds.addAll(currentMessageIds);
      _lastMessageCount = currentCount;
      _lastLinkPreviewCount = currentMessages
          .where((m) => m.linkPreviewUrl != null)
          .length;

      if (!messaging.isLoadingMore) {
        setState(() => _isLoadingMoreLocal = false);
        final preOffset = _prePaginationScrollOffset;
        final preExtent = _prePaginationScrollExtent;
        _prePaginationScrollOffset = null;
        _prePaginationScrollExtent = null;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (preOffset == null || preExtent == null) return;
          if (!_scrollController.hasClients) return;
          final newExtent = _scrollController.position.maxScrollExtent;
          _scrollController.jumpTo(preOffset + (newExtent - preExtent));
        });
        return;
      }
      final preOffset = _prePaginationScrollOffset;
      final preExtent = _prePaginationScrollExtent;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (preOffset == null || preExtent == null) return;
        if (!_scrollController.hasClients) return;
        final newExtent = _scrollController.position.maxScrollExtent;
        final delta = newExtent - preExtent;
        _prePaginationScrollOffset = preOffset + delta;
        _prePaginationScrollExtent = newExtent;
        _scrollController.jumpTo(preOffset + delta);
      });
      return;
    }

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

  /// Clears server push-suppression when this route/widget is torn down without the
  /// AppBar back handler (Android system back, block menu, auto-pop after conv removed).
  /// Skips when another conversation is already active (desktop list switch).
  void _clearActiveConversationIfThisChat() {
    if (_conversations.activeConversationDeletedByOther) {
      _conversations.clearActiveIfDeletedByOther();
      return;
    }
    if (_conversations.activeConversationId == widget.conversationId) {
      _conversations.closeConversation(notify: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _conversations.notifyActiveConversationChanged();
        // Deferred off the pop's teardown frame so the reverse route
        // transition stays light. Guarded: if anything re-opened a
        // conversation before this frame ended (e.g. the iOS PWA resume
        // reassert), clearing now would wipe its freshly asserted state.
        // isDisposed: the whole app tree can go down in this same frame
        // (hot restart, test teardown) — never notify a dead provider.
        if (!_messaging.isDisposed &&
            _conversations.activeConversationId == null) {
          _messaging.clearMessages();
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _conversations = context.read<ConversationsProvider>();
    _messaging = context.read<MessagingProvider>();
    _scrollController.addListener(_onScroll);
    // D3 fix: didChangeMetrics never fires for the iOS WebKit keyboard
    // (Flutter's viewInsets stay 0 there) — the shared visualViewport source
    // is the real keyboard signal, so the keyboard-open autoscroll listens to
    // it too. Inactive (never fires) off iOS web.
    _sharedInset = sharedKeyboardInsetSource();
    _sharedInset.inset.addListener(_onWebKeyboardInsetChanged);
    // Web/iOS: install the Web Audio gesture-unlock now so a ping that lands
    // later (outside any user gesture) can still produce sound. No-op native.
    primePingSound();
    // Active id + push-SW post immediately; listener notify deferred (initState).
    _conversations.openConversation(widget.conversationId, notify: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _conversations.notifyActiveConversationChanged();
      _messaging.loadCachedMessages(widget.conversationId);
      _messaging.getMessages(widget.conversationId);
      final userId = context.read<AuthProvider>().currentUser?.id;
      if (userId != null) {
        context.read<SettingsProvider>().loadChatBackground(userId);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Exclude this conversation — opening it reads it, but the local count
      // may not be zeroed yet when this runs, and the badge must not flash
      // the about-to-be-read messages back in.
      final unreadTotal = _conversations.unreadCounts.entries
          .where((e) => e.key != widget.conversationId)
          .fold<int>(0, (sum, e) => sum + e.value);
      _notificationCleaner.closeNotificationForConversation(
        widget.conversationId,
        newUnreadTotal: unreadTotal,
      );
    });

    // Countdown tick + expiry prune run on [ConversationsScreen] (always mounted in
    // [MainShell] IndexedStack) so we avoid duplicate 1 Hz timers when chat is open.
  }

  @override
  void didUpdateWidget(ChatDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _knownMessageIds.clear();
      _lastMessageCount = 0;
      _lastLinkPreviewCount = 0;
      _newMessagesCount = 0;
      _userHasScrolledChat = false;
      _isLoadingMoreLocal = false;
      _prePaginationScrollOffset = null;
      _prePaginationScrollExtent = null;
      _dismissedNoteAt = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final convs = context.read<ConversationsProvider>();
        final messaging = context.read<MessagingProvider>();
        messaging.loadCachedMessages(widget.conversationId);
        convs.openConversation(widget.conversationId);
        messaging.getMessages(widget.conversationId);
      });
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted) return;
    dismissMessageContextMenu();
    _handleKeyboardHeightChanged();
  }

  void _onWebKeyboardInsetChanged() {
    if (!mounted) return;
    _handleKeyboardHeightChanged();
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // iOS PWA resume can dispose this widget and/or reconnect the socket while
    // the chat is still on screen, which clears the active/pagination conversation
    // ids (dispose → closeConversation + clearMessages) — incoming messages then
    // get dropped by _addMessageToState's active-id gate (confirmed via E2eDiagLog
    // ADD_TO_STATE appendedToOpenChat:false). Re-assert + reload the open chat on
    // resume so live receive recovers deterministically (no manual reopen needed).
    if (state == AppLifecycleState.resumed && mounted) {
      reassertOpenConversationOnResume(
        _conversations,
        _messaging,
        widget.conversationId,
      );
    }
  }

  @override
  void dispose() {
    VoiceAudioCoordinator.instance.pauseActive();
    dismissMessageContextMenu();
    WidgetsBinding.instance.removeObserver(this);
    _sharedInset.inset.removeListener(_onWebKeyboardInsetChanged);
    _clearActiveConversationIfThisChat();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _onAvatarTap() async {
    final otherUser = _getOtherUser();
    if (otherUser == null) return;

    await Navigator.of(context).push(
      instantOpaqueRoute(
        builder: (cardContext) => UserCardScreen(
          data: UserCardVisualData.fromUser(
            otherUser,
            isSelf: false,
            hasConversation: true,
            conversationId: widget.conversationId,
            mute: UserCardMute.fromConversation(
              muted:
                  _conversations.conversations
                      .where(
                        (conversation) =>
                            conversation.id == widget.conversationId,
                      )
                      .firstOrNull
                      ?.muted ??
                  false,
              mutedUntil: _conversations.conversations
                  .where(
                    (conversation) => conversation.id == widget.conversationId,
                  )
                  .firstOrNull
                  ?.mutedUntil,
            ),
          ),
          onMessage: () {
            Navigator.of(cardContext).pop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _composerKey.currentState?.focusComposer();
            });
          },
          onMuteChanged: (mute) {
            _conversations.setConversationMute(
              widget.conversationId,
              switch (mute) {
                UserCardMute.off => 'off',
                UserCardMute.oneHour => '1h',
                UserCardMute.eightHours => '8h',
                UserCardMute.oneWeek => '1w',
                UserCardMute.forever => 'forever',
              },
            );
          },
        ),
      ),
    );
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

  ConversationModel? _getActiveConversation() {
    return context.read<ConversationsProvider>().getConversationById(
      widget.conversationId,
    );
  }

  /// (lxxxi): the ONE pill standing in for every pre-link `none_for_device`
  /// row, rendered at the oldest end of the list and in the all-hidden empty
  /// state — both sites, one builder, one key.
  Widget _preLinkDivider(BuildContext context) => MessageDateSeparator.label(
    AppLocalizations.of(context).historyNotOnThisDevice,
    key: const Key('pre-link-history-divider'),
  );

  String _getContactName() {
    final conv = _getActiveConversation();
    return conv != null
        ? context.read<ConversationsProvider>().getOtherUserUsername(conv)
        : '';
  }

  UserModel? _getOtherUser() {
    final conv = _getActiveConversation();
    return conv != null
        ? context.read<ConversationsProvider>().getOtherUser(conv)
        : null;
  }

  /// statusText: e.g. "typing..." or "Recording voice..."
  Widget _buildHeaderTitle(
    BuildContext context,
    String contactName,
    UserModel? otherUser,
    String? statusText,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final accentColor = Theme.of(context).colorScheme.primary;
    final nameWidget = Text(
      contactName,
      style: RpgTheme.bodyFont(
        fontSize: 16,
        color: colorScheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      overflow: TextOverflow.ellipsis,
    );
    if (statusText == null || statusText.isEmpty) return nameWidget;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        nameWidget,
        Text(
          statusText,
          style: RpgTheme.bodyFont(
            fontSize: 12,
            color: accentColor,
          ).copyWith(fontStyle: FontStyle.italic),
        ),
      ],
    );
  }

  String? _getHeaderStatusText(BuildContext context, MessagingProvider msg) {
    final l10n = AppLocalizations.of(context);
    if (msg.isRecordingVoice) return l10n.recordingVoice;
    if (msg.isPartnerRecordingVoice(widget.conversationId)) {
      return l10n.recordingVoice;
    }
    if (msg.isPartnerTyping(widget.conversationId)) return l10n.typing;
    return null;
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
    required bool peerRefused,
    required bool peerKeyChangeNoted,
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
    // Amendment (lxxxi): rows that predate this device's link are not in
    // `messages`; one pill at the oldest end says why the thread starts here.
    final preLinkDivider = context.read<MessagingProvider>().hiddenPreLinkCount > 0
        ? 1
        : 0;
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
                    )
                  else if (peerKeyChangeNoted)
                    PeerIdentityChangedNote(
                      peerId: peer!.id,
                      peerName: _getContactName(),
                    ),
                  Expanded(
                    child: Center(
                      child: preLinkDivider == 1
                          ? _preLinkDivider(context)
                          : Text(
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
                        return messages.length - 1 - idx + identityRowOffset;
                      }
                      return null;
                    },
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 20,
                      top: topClearance,
                      bottom: 8 + listBottomPadding,
                    ),
                    itemCount:
                        messages.length +
                        (_isLoadingMoreLocal ? 1 : 0) +
                        identityRowOffset +
                        preLinkDivider,
                    itemBuilder: (context, index) {
                      if (peerIdentityChanged && index == 0) {
                        return PeerIdentityChangedRow(
                          // peerIdentityChanged is only computed true in
                          // build() when otherUser (this `peer`) is non-null.
                          peerId: peer!.id,
                          peerName: _getContactName(),
                        );
                      }
                      if (peerKeyChangeNoted && index == 0) {
                        return PeerIdentityChangedNote(
                          peerId: peer!.id,
                          peerName: _getContactName(),
                        );
                      }
                      final effIndex = index - identityRowOffset;
                      final loadingSlot = _isLoadingMoreLocal ? 1 : 0;
                      if (preLinkDivider == 1 &&
                          effIndex == messages.length + loadingSlot) {
                        return _preLinkDivider(context);
                      }
                      if (_isLoadingMoreLocal && effIndex == messages.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final msgIndex = messages.length - 1 - effIndex;
                      final msg = messages[msgIndex];
                      final showDate =
                          msgIndex == 0 ||
                          _isDifferentDay(
                            messages[msgIndex - 1].createdAt,
                            msg.createdAt,
                          );
                      return _buildMessageListItem(
                        listIndex: effIndex,
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

  /// (lxxxiv): whether a key-change note recorded at [occurredAt] (ISO-8601)
  /// is still the newest thing in conversation [conversationId]: nothing in
  /// the ascending [messages] timeline and no [lastMessageAt] known to the
  /// list is after it. Rows of ANOTHER conversation are ignored — right after
  /// an embedded-pane switch the build still holds the previous chat's list
  /// (`didUpdateWidget` reloads post-frame), and its newer rows must not
  /// evict, let alone durably dismiss, this peer's note. A message stamped at
  /// the SAME instant does not evict. The instant always parses: the writer
  /// is `toIso8601String()` and `_loadKeyChangeNotes` drops anything else at
  /// the boundary, so the null branch is "no evidence of newer", not a
  /// second meaning.
  static bool _isNewestInTimeline(
    String occurredAt,
    List<MessageModel> messages,
    DateTime? lastMessageAt,
    int conversationId,
  ) {
    final at = DateTime.tryParse(occurredAt);
    if (at == null) return true;
    if (lastMessageAt != null && lastMessageAt.isAfter(at)) return false;
    if (messages.isEmpty || messages.last.conversationId != conversationId) {
      return true;
    }
    return !messages.last.createdAt.isAfter(at);
  }

  Widget _buildComposerFooter({
    required UserModel? otherUser,
    required Color mutedColor,
    required ColorScheme colorScheme,
  }) {
    if (otherUser != null &&
        context.read<FriendsProvider>().blockedByUserIds.contains(
          otherUser.id,
        )) {
      return SafeArea(
        top: false,
        left: true,
        right: true,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: Center(
            child: Text(
              AppLocalizations.of(context).cantTypeToThisUser,
              style: RpgTheme.bodyFont(
                fontSize: 13,
                color: mutedColor,
              ).copyWith(fontStyle: FontStyle.italic),
            ),
          ),
        ),
      );
    }
    return ChatInputBar(key: _composerKey);
  }

  /// Wraps the message [body] with the ping-effect overlay and the
  /// scroll-to-bottom button, shared by the embedded and non-embedded layouts.
  Widget _buildChatBodyStack(Widget body, MessagingProvider messaging) {
    return Stack(
      children: [
        body,

        // Ping effect overlay
        if (messaging.showPingEffect)
          Positioned.fill(
            child: PingEffectOverlay(
              onComplete: () {
                messaging.clearPingEffect();
              },
            ),
          ),
        if (_showScrollToBottomButton) _buildScrollToBottomButton(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final messaging = context.watch<MessagingProvider>();
    final convs = context.watch<ConversationsProvider>();
    final auth = context.watch<AuthProvider>();
    final messages = messaging.messages;
    final contactName = _getContactName();

    if (messages.isNotEmpty && messages.length != _lastMessageCount) {
      final added = messages.length - _lastMessageCount;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _onNewMessages(messages.length, added);
      });
    }

    // When a link preview arrives, the same message is updated in place (no count change)
    // but the bubble grows; scroll to bottom so the expanded message stays visible.
    final linkPreviewCount = messages
        .where((m) => m.linkPreviewUrl != null)
        .length;
    if (messages.isNotEmpty && linkPreviewCount > _lastLinkPreviewCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _lastLinkPreviewCount = linkPreviewCount);
        _scrollToBottom();
      });
    }

    final isDark = RpgTheme.isDark(context);
    final colorScheme = Theme.of(context).colorScheme;
    final messagesAreaBg = FireplaceColors.of(context).messagesAreaBg;
    final mutedColor = isDark
        ? RpgTheme.mutedDark
        : RpgTheme.textSecondaryLight;
    final otherUser = _getOtherUser();
    // Rebuilds when the peer's identity-change warning appears or clears
    // (Phase 0a timeline row).
    //
    // The pill renders whenever this device's account anchor still holds the
    // peer's OLD key, because that state BLOCKS SENDING: `buildSession` fails
    // closed with `AccountIdentityMismatch` until a human compares the new
    // safety number. A peer leaves `peersWithChangedIdentity` exactly when the
    // anchor advances (`EncryptionService.acknowledgePeerIdentity`), so
    // membership IS "sends to this chat will fail" — and it is knowable the
    // moment the change arrives, long before the user composes anything.
    //
    // It is therefore NO LONGER gated on the (lxxix) warnings setting. That
    // setting chooses how an ABSORBED change is announced (muted note vs
    // manual confirmation); it was never meant to hide a chat that cannot
    // send. With warnings off (the default) a peer reinstall left a calm
    // "klucze zaktualizowane" note and the user discovered the block only by
    // having a message bounce with "Ponów" (field-observed 2026-09-13).
    // `_demoteKeyChangeIfMuted` now leaves the peer in the set precisely when
    // the anchor did NOT advance, so the muted note and this pill stay
    // mutually exclusive.
    final warnOnKeyChange = context.select<SettingsProvider, bool>(
      (s) => s.keyChangeWarnings,
    );
    final peerRefused =
        otherUser != null &&
        context.select<EncryptionProvider, bool>(
          (e) => e.peersRefusedIdentity.contains(otherUser.id),
        );
    final peerIdentityChanged =
        peerRefused ||
        (otherUser != null &&
            context.select<EncryptionProvider, bool>(
              (e) => e.peersWithChangedIdentity.contains(otherUser.id),
            ));
    // (lxxxiv): the muted note lives until the next message — it renders only
    // while nothing in the conversation is newer than the change it
    // announces. The list's `lastMessages` entry covers the window before
    // history has loaded (an empty `messages` cannot out-date anything).
    final peerKeyChangeNoteAt =
        otherUser != null && !peerIdentityChanged && !warnOnKeyChange
        ? context.select<EncryptionProvider, String?>(
            (e) => e.peerKeyChangeNotes[otherUser.id],
          )
        : null;
    final peerKeyChangeNoted =
        peerKeyChangeNoteAt != null &&
        _isNewestInTimeline(
          peerKeyChangeNoteAt,
          messages,
          convs.lastMessages[widget.conversationId]?.createdAt,
          widget.conversationId,
        );
    if (otherUser != null &&
        peerKeyChangeNoteAt != null &&
        !peerKeyChangeNoted &&
        peerKeyChangeNoteAt != _dismissedNoteAt) {
      // Superseded: forget it durably so a later open does not flash the line
      // while history loads. Once per note instant — a later change writes a
      // fresh instant and gets its own eviction; the service compares the
      // instant before removing, so a note written between this build and
      // the callback survives.
      _dismissedNoteAt = peerKeyChangeNoteAt;
      final enc = context.read<EncryptionProvider>();
      final peerId = otherUser.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        enc.dismissPeerKeyChangeNote(peerId, occurredAt: peerKeyChangeNoteAt);
      });
    }
    final activeConv = convs.getConversationById(widget.conversationId);
    final statusText = _getHeaderStatusText(context, messaging);
    // Long-press the title toggles the iOS keyboard-diagnostics overlay (dev
    // tool; only renders on iOS WebKit, off by default).
    final headerTitle = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: toggleComposerDiagOverlay,
      child: _buildHeaderTitle(context, contactName, otherUser, statusText),
    );
    final pinnedBanner = activeConv != null
        ? _buildPinnedMessageBanner(context, activeConv, messaging, convs)
        : null;
    final deletedByOther =
        activeConv == null && convs.activeConversationDeletedByOther;
    // Auto-pop only when conv gone and NOT deleted by other (e.g. unfriend/block)
    if (activeConv == null &&
        convs.conversations.isNotEmpty &&
        !deletedByOther) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (Navigator.canPop(context)) {
          _clearActiveConversationIfThisChat();
          Navigator.pop(context);
          if (mounted) {
            showTopSnackBar(
              context,
              AppLocalizations.of(context).cantMessageThisUser,
              backgroundColor: colorScheme.error,
            );
          }
        }
      });
    }

    final currentUserId = auth.currentUser!.id;
    final composerFooter = _buildComposerFooter(
      otherUser: otherUser,
      mutedColor: mutedColor,
      colorScheme: colorScheme,
    );

    // When other user deleted the conversation, show message instead of auto-close
    final Widget body;
    if (deletedByOther) {
      body = SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.delete_outline, size: 48, color: mutedColor),
                const SizedBox(height: 16),
                Text(
                  AppLocalizations.of(context).conversationDeletedByOther,
                  textAlign: TextAlign.center,
                  style: RpgTheme.bodyFont(fontSize: 14, color: mutedColor),
                ),
              ],
            ),
          ),
        ),
      );
    } else if (widget.isEmbedded) {
      // Pinned banner is rendered by the embedded shell above this [body].
      // Embedded header/banner are in-flow — no floating chrome to clear.
      body = Column(
        children: [
          if (messaging.devicesSyncing) const DevicesSyncingNote(),
          Expanded(
            child: _buildMessagesArea(
              listBottomPadding: 0,
              topInsetHandled: true,
              messages: messages,
              mutedColor: mutedColor,
              messagesAreaBg: messagesAreaBg,
              currentUserId: currentUserId,
              peer: otherUser,
              peerIdentityChanged: peerIdentityChanged,
              peerRefused: peerRefused,
              peerKeyChangeNoted: peerKeyChangeNoted,
            ),
          ),
          composerFooter,
        ],
      );
    } else {
      // Non-embedded: pinned banner clears the floating top chrome via the
      // body's MediaQuery top padding (extendBodyBehindAppBar exposes the
      // GlassTopBar height there); the list then skips its own clearance.
      final hasInFlowTopBanner = pinnedBanner != null;
      body = Column(
        children: [
          if (pinnedBanner != null)
            SafeArea(bottom: false, child: pinnedBanner),
          if (messaging.devicesSyncing)
            SafeArea(
              bottom: false,
              top: pinnedBanner == null,
              child: const DevicesSyncingNote(),
            ),
          Expanded(
            child: ChatComposerViewport(
              messageListBuilder: (listBottomPadding) => _buildMessagesArea(
                listBottomPadding: listBottomPadding,
                topInsetHandled: hasInFlowTopBanner,
                messages: messages,
                mutedColor: mutedColor,
                messagesAreaBg: messagesAreaBg,
                currentUserId: currentUserId,
                peer: otherUser,
                peerIdentityChanged: peerIdentityChanged,
                peerRefused: peerRefused,
                peerKeyChangeNoted: peerKeyChangeNoted,
              ),
              composer: composerFooter,
            ),
          ),
        ],
      );
    }

    if (widget.isEmbedded) {
      final borderColor = FireplaceColors.of(context).convItemBorder;
      return Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(bottom: BorderSide(color: borderColor)),
            ),
            child: Row(
              children: [
                Semantics(
                  button: true,
                  label: AppLocalizations.of(
                    context,
                  ).avatarOpenProfileSemantics,
                  child: GestureDetector(
                    onTap: _onAvatarTap,
                    child: HexAvatar(
                      size: 36,
                      displayName: contactName,
                      imageUrl: otherUser?.profilePictureUrl,
                      surface: FireplaceColors.of(context).convItemBg,
                      // mutedText, not convItemBorder: the blue border token is
                      // 1.92:1 on this fill and the ring paints at 0.6 alpha —
                      // the hex outline vanishes (design review 2026-08-03).
                      borderColor: FireplaceColors.of(context).mutedText,
                      initialsStyle: RpgTheme.bodyFont(
                        fontSize: 36 * 0.34,
                        fontWeight: FontWeight.w800,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
                Expanded(child: Center(child: headerTitle)),
              ],
            ),
          ),
          ?pinnedBanner,
          Expanded(child: _buildChatBodyStack(body, messaging)),
        ],
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      extendBodyBehindAppBar: true,
      appBar: GlassTopBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () {
            _clearActiveConversationIfThisChat();
            Navigator.of(context).pop();
          },
        ),
        title: headerTitle,
        // Hex avatar slot (owner ruling 2026-08-03: the chat header speaks the
        // same hex language as the Chats list and the Contacts board; the old
        // bare 52px circle was the round-4 Telegram reference).
        avatar: Semantics(
          button: true,
          label: AppLocalizations.of(context).avatarOpenProfileSemantics,
          child: GestureDetector(
            onTap: _onAvatarTap,
            child: HexAvatar(
              size: GlassTopBar.capsuleHeight,
              displayName: contactName,
              imageUrl: otherUser?.profilePictureUrl,
              surface: FireplaceColors.of(context).convItemBg,
              // mutedText for the same 3:1 boundary reason as the embedded
              // header's hex above.
              borderColor: FireplaceColors.of(context).mutedText,
              initialsStyle: RpgTheme.bodyFont(
                fontSize: GlassTopBar.capsuleHeight * 0.34,
                fontWeight: FontWeight.w800,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
      body: _buildChatBodyStack(body, messaging),
    );
  }
}
