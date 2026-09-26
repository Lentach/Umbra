import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants/app_constants.dart';
import '../config/app_config.dart';
import '../l10n/app_localizations.dart';
import '../models/message_model.dart';
import '../providers/auth_provider.dart';
import '../providers/connection_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/encryption_provider.dart';
import '../providers/friends_provider.dart';
import '../providers/messaging_provider.dart';
import '../providers/passcode_provider.dart';
import '../providers/settings_provider.dart';
import '../services/box/box_client.dart';
import '../services/contacts/contact_store.dart';
import '../theme/rpg_theme.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/chat_honeycomb_picker.dart';
import '../widgets/hex_avatar.dart';
import '../widgets/conversation_tile.dart';
import '../widgets/conversation_list_skeleton.dart';
import '../widgets/main_tab_screen_header.dart';
import '../utils/backup_nudge.dart';
import '../utils/instant_opaque_route.dart';
import '../widgets/backup_nudge_line.dart';
import 'chat_detail_screen.dart';
import 'passcode_lock_screen.dart';
import 'invitations_screen.dart';
import 'recovery_key_screen.dart';

class ConversationsScreen extends StatefulWidget {
  final VoidCallback? onAvatarTap;

  const ConversationsScreen({super.key, this.onAvatarTap});

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  Timer? _listCountdownTimer;

  /// (lxxxiii) clause 1: armed once per fresh registration; fires the offer
  /// when the server has said this account holds no recovery phrase. The provider is
  /// held so dispose() can unsubscribe without touching the context.
  (EncryptionProvider, VoidCallback)? _phraseOffer;

  @override
  void initState() {
    super.initState();
    final messaging = context.read<MessagingProvider>();
    _listCountdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (messaging.isRecordingVoice) return;
      messaging.removeExpiredMessages();
      context.read<ConversationsProvider>().pruneExpiredLastMessages();
      messaging.countdownTickNotifier.value++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final auth = context.read<AuthProvider>();
      final conn = context.read<ConnectionProvider>();
      final enc = context.read<EncryptionProvider>();
      final friends = context.read<FriendsProvider>();
      final convs = context.read<ConversationsProvider>();
      final msg = context.read<MessagingProvider>();
      final settings = context.read<SettingsProvider>();

      // Wire all sub-providers into ConnectionProvider. The contact store
      // borrows the encryption layer's content store (one opener per
      // process; see `EncryptionService.contentKv`).
      conn.setProviders(
        encryption: enc,
        friends: friends,
        conversations: convs,
        messaging: msg,
        contactStore: ContactStore(
          open: () => enc.encryptionService.contentKv,
          selfProfile: () => auth.currentUser,
        ),
        // PR2.4: owned by AuthProvider (the password lives only there);
        // handed here so the connect path can restore before the socket.
        contactBackup: auth.contactBackup,
        // PR3.1: the box — its own socket on the same server, no account.
        boxClient: (baseUrl) => BoxClient(baseUrl: baseUrl),
      );

      // Wire MessagingProvider dependencies
      msg.setEncryptionProvider(enc);
      msg.setConversationsProvider(convs);

      // (lxxix): the encryption layer decides between the manual key-change
      // ceremony and the demoted auto-acknowledge off this live setting.
      enc.keyChangeWarnings = () => settings.keyChangeWarnings;

      // Start connection via ConnectionProvider (owns socket lifecycle)
      await auth.ensureSessionReady();
      if (!mounted) return;
      final userId = auth.currentUser!.id;
      conn.connect(userId, auth.token!, AppConfig.baseUrl);
      settings.loadBackupNudge(userId).ignore();
      if (auth.consumeFreshRegistration()) _armPhraseOffer(enc);
    });
  }

  @override
  void dispose() {
    _listCountdownTimer?.cancel();
    _disarmPhraseOffer();
    super.dispose();
  }

  /// (lxxxiii) clause 1 + clause 4: the offer waits for an EXPLICIT
  /// `hasRecoveryPhrase: false` — never unknown, never true (an existing
  /// account reached through the lost-answer probe keeps whatever phrase it
  /// already holds, blob or not).
  void _armPhraseOffer(EncryptionProvider enc) {
    void check() {
      if (enc.hasRecoveryPhrase != false) return;
      _disarmPhraseOffer();
      if (mounted) _openRecoveryKey(deferrable: true);
    }

    _phraseOffer = (enc, check);
    enc.addListener(check);
    check();
  }

  void _disarmPhraseOffer() {
    final offer = _phraseOffer;
    if (offer == null) return;
    _phraseOffer = null;
    offer.$1.removeListener(offer.$2);
  }

  /// Any exit other than a saved backup is "later": snooze the Czaty line so
  /// it does not reappear under the screen the user just closed.
  Future<void> _openRecoveryKey({required bool deferrable}) async {
    final settings = context.read<SettingsProvider>();
    final userId = context.read<AuthProvider>().currentUser?.id;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RecoveryKeyScreen(deferrable: deferrable),
      ),
    );
    if (saved == true || !deferrable || userId == null) return;
    settings.snoozeBackupNudge(userId).ignore();
  }

  void _snoozeBackupNudge() {
    final userId = context.read<AuthProvider>().currentUser?.id;
    if (userId == null) return;
    context.read<SettingsProvider>().snoozeBackupNudge(userId).ignore();
  }

  /// (lxxxiii) clause 3: the one muted line for an account the server
  /// EXPLICITLY reported as having no recovery phrase, or null.
  Widget? _buildBackupNudge() {
    final show = shouldShowBackupNudge(
      hasRecoveryPhrase: context.watch<EncryptionProvider>().hasRecoveryPhrase,
      dismissedAt: context.watch<SettingsProvider>().backupNudgeDismissedAt,
      now: DateTime.now(),
    );
    if (!show) return null;
    return BackupNudgeLine(
      onTap: () => _openRecoveryKey(deferrable: false),
      onDismiss: _snoozeBackupNudge,
    );
  }

  void _openChat(int conversationId) {
    final convs = context.read<ConversationsProvider>();
    final width = MediaQuery.of(context).size.width;
    if (width >= AppConstants.layoutBreakpointDesktop) {
      // Desktop: only set active so ChatDetailScreen shows; it will call openConversation (avoids double getMessages)
      convs.setActiveConversation(conversationId);
    } else {
      // Mobile: only navigate; ChatDetailScreen initState will call openConversation (avoids double getMessages)
      Navigator.of(context).push(
        instantOpaqueRoute(
          builder: (_) => ChatDetailScreen(conversationId: conversationId),
        ),
      );
    }
  }

  Future<void> _showNewChatPicker() async {
    final friends = context.read<FriendsProvider>();
    final choice = await showChatHoneycombPicker(
      context,
      friends: friends.friends,
      inviters: [for (final request in friends.friendRequests) request.sender],
    );
    if (choice == null || !mounted) return;

    switch (choice) {
      case ChatPickerReviewInvitations() || ChatPickerInviteNew():
        // Reviewing inbound invitations and inviting someone new are the
        // same destination: InvitationsScreen owns both halves of the
        // relationship layer (and the accept/decline retry machinery).
        await _openInvitations();
      case ChatPickerFriend(:final friend):
        _startChatWith(friend.id);
    }
  }

  /// The "+" badge counts inbound invitations, so the sheet behind it has to
  /// reach them. Accepting stays in `InvitationsScreen`, which owns the
  /// failure and retry machinery; this only routes there and back.
  Future<void> _openInvitations() async {
    final peerUserId = await Navigator.of(
      context,
    ).push<int>(MaterialPageRoute(builder: (_) => const InvitationsScreen()));
    if (peerUserId == null || !mounted) return;
    _startChatWith(peerUserId);
  }

  void _startChatWith(int userId) {
    final convs = context.read<ConversationsProvider>();
    final existingConversation = convs.conversations
        .where((conversation) => convs.getOtherUser(conversation)?.id == userId)
        .firstOrNull;
    if (existingConversation != null) {
      _openChat(existingConversation.id);
      return;
    }

    // The backend creates the conversation and emits `openConversation`; the
    // build path below consumes that pending ID through this screen's normal
    // open-chat path.
    convs.startConversation(userId);
  }

  void _deleteConversation(int conversationId) {
    // Dialog is handled by Dismissible widget in ConversationTile
    // This method is called after user confirms in swipe-to-delete dialog
    final msg = context.read<MessagingProvider>();
    final convs = context.read<ConversationsProvider>();
    // Clear message state in sync with optimistic list removal (see deleteConversation).
    msg.onConversationDeleted(conversationId);
    convs.deleteConversation(conversationId);
  }

  @override
  Widget build(BuildContext context) {
    final convs = context.watch<ConversationsProvider>();
    if (convs.pendingOpenConversationId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final conversationId = context
            .read<ConversationsProvider>()
            .consumePendingOpen();
        if (conversationId != null && mounted) {
          _openChat(conversationId);
        }
      });
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop =
            constraints.maxWidth >= AppConstants.layoutBreakpointDesktop;
        if (isDesktop) {
          return _buildDesktopLayout();
        }
        return _buildMobileLayout();
      },
    );
  }

  Widget _buildMobileLayout() {
    // Floating glass chrome: the list runs full-bleed behind the header
    // capsules (and behind the bottom nav via MainShell's extendBody);
    // clearance is applied as list padding, not layout slots. While the
    // backup nudge is up it takes the header clearance itself and the list
    // starts below it — the line has to exist in the skeleton, empty and
    // populated states alike, so it cannot be a list item.
    final nudge = _buildBackupNudge();
    return Stack(
      children: [
        Positioned.fill(
          child: nudge == null
              ? _buildConversationList(floatingChrome: true)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height:
                          MediaQuery.paddingOf(context).top +
                          MainTabScreenHeader.clearance,
                    ),
                    nudge,
                    Expanded(child: _buildConversationList()),
                  ],
                ),
        ),
        Positioned(top: 0, left: 0, right: 0, child: _buildCustomHeader()),
      ],
    );
  }

  Widget _buildCustomHeader() {
    final auth = context.watch<AuthProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    final user = auth.currentUser;
    final l10n = AppLocalizations.of(context);
    return MainTabScreenHeader(
      title: l10n.chat,
      leading: Semantics(
        button: true,
        label: l10n.avatarOpenProfileSemantics,
        child: GestureDetector(
          onTap: widget.onAvatarTap,
          child: AvatarCircle(
            displayName: user?.username ?? '',
            radius: 22,
            profilePictureUrl: user?.profilePictureUrl,
          ),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Zangi parity (owner ask): the padlock sits immediately left of
          // `+`, lower emphasis than it. Enabled → lock the app right now;
          // not configured → open the setup screen, so the Chats screen is a
          // door to the feature and not just a switch for it.
          Consumer<PasscodeProvider>(
            builder: (context, passcode, _) => IconButton(
              key: const Key('conversations-passcode-button'),
              icon: Icon(
                passcode.isEnabled ? Icons.lock_outline : Icons.lock_open,
                color: colorScheme.onSurface,
                size: 22,
              ),
              tooltip: passcode.isEnabled
                  ? l10n.passcodeLockNowTooltip
                  : l10n.passcodeSetUpTooltip,
              onPressed: () {
                if (passcode.isEnabled) {
                  passcode.lockNow();
                  return;
                }
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const PasscodeLockScreen(),
                  ),
                );
              },
            ),
          ),
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                key: const Key('conversations-new-chat-button'),
                icon: Icon(
                  Icons.add_circle_outline,
                  color: colorScheme.primary,
                  size: 28,
                ),
                onPressed: _showNewChatPicker,
                tooltip: l10n.chatPickerOpenTooltip,
              ),
              Consumer<FriendsProvider>(
                builder: (context, friends, _) {
                  if (friends.pendingRequestsCount == 0) {
                    return const SizedBox.shrink();
                  }
                  return Positioned(
                    right: 2,
                    top: 2,
                    // Pointy-top hex like every other badge in the app (owner
                    // ruling 2026-08-03: no circles for counts).
                    child: HexCountBadge(
                      label: '${friends.pendingRequestsCount}',
                      size: 18,
                      background: colorScheme.error,
                      textStyle: RpgTheme.bodyFont(
                        fontSize: 10,
                        color: colorScheme.onError,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopLayout() {
    final convs = context.watch<ConversationsProvider>();
    final borderColor = FireplaceColors.of(context).convItemBorder;

    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 320,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildCustomHeader(),
                ?_buildBackupNudge(),
                Expanded(child: _buildConversationList()),
              ],
            ),
          ),
          Container(width: 1, color: borderColor),
          Expanded(
            child: convs.activeConversationId != null
                ? ChatDetailScreen(
                    conversationId: convs.activeConversationId!,
                    isEmbedded: true,
                  )
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 64,
                          color: FireplaceColors.of(context).mutedText,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          AppLocalizations.of(context).selectAConversation,
                          style: RpgTheme.bodyFont(
                            fontSize: 16,
                            color: FireplaceColors.of(context).mutedText,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationList({bool floatingChrome = false}) {
    final convs = context.watch<ConversationsProvider>();
    final conversations = convs.sortedConversations;
    final isDark = RpgTheme.isDark(context);
    final mutedColor = FireplaceColors.of(context).mutedText;

    final media = MediaQuery.paddingOf(context);
    final listPadding = floatingChrome
        ? EdgeInsets.fromLTRB(
            8,
            media.top + MainTabScreenHeader.clearance,
            8,
            media.bottom + 8,
          )
        : EdgeInsets.fromLTRB(8, 8, 8, media.bottom + 8);

    // Show the loading skeleton only while the first fetch is plausibly in
    // flight AND nothing local can be shown: contact-store hydration fills
    // the list before the socket, and a cold start with no network must
    // paint it, not shimmer through ~31 s of reconnect backoff. On a known
    // connection error fall through to the empty state so it never shimmers
    // forever.
    if (!convs.hasLoadedConversationsOnce &&
        conversations.isEmpty &&
        context.watch<ConnectionProvider>().errorMessage == null) {
      return ConversationListSkeleton(padding: listPadding);
    }

    if (conversations.isEmpty) {
      return Padding(
        padding: listPadding,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.forum_outlined, size: 48, color: mutedColor),
                const SizedBox(height: 16),
                Text(
                  AppLocalizations.of(context).noConversationsYet,
                  style: RpgTheme.bodyFont(fontSize: 16, color: mutedColor),
                ),
                const SizedBox(height: 8),
                Text(
                  AppLocalizations.of(context).startNewChatToBegin,
                  style: RpgTheme.bodyFont(
                    fontSize: 13,
                    color: isDark
                        ? RpgTheme.timeColorDark
                        : RpgTheme.textSecondaryLight,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Rows carry their own spacing and rounded surface now (live rows are
    // tinted, cold rows shrink); hairline dividers fought that hierarchy.
    // (lxxxviii) A1: a last message's stored plaintext can only be read once
    // the E2E layer is up, so the rows ask again when it comes up.
    return Selector<EncryptionProvider, bool>(
      selector: (_, encryption) => encryption.isE2EReady,
      builder: (context, _, _) => ListView.builder(
        padding: listPadding,
        itemCount: conversations.length,
        itemBuilder: (context, index) {
          final conv = conversations[index];
          final otherUser = convs.getOtherUser(conv);
          final displayName = convs.getOtherUserUsername(conv);
          final lastMsg = convs.lastMessages[conv.id];
          final unreadCount = convs.getUnreadCount(conv.id);
          // (lxxxviii) A1: messaging resolves what the preview line may say —
          // the plaintext this install holds, "New message" for an unread
          // peer row, or nothing — and re-notifies when a stored copy is
          // read, the identity boundary moves, or a decrypt verdict lands.
          return Selector<MessagingProvider, (bool, MessageModel?)>(
            selector: (_, messaging) => (
              messaging.isPartnerTyping(conv.id),
              lastMsg == null
                  ? null
                  : messaging.listPreviewFor(
                      lastMsg,
                      unreadCount: unreadCount,
                    ),
            ),
            builder: (context, state, _) {
              final (isTyping, preview) = state;
              return ConversationTile(
                key: ValueKey<int>(conv.id),
                conversationId: conv.id,
                displayName: displayName,
                lastMessage: lastMsg,
                isActive: conv.id == convs.activeConversationId,
                unreadCount: unreadCount,
                isMuted: conv.isNotificationMuted,
                onTap: () => _openChat(conv.id),
                onDelete: () => _deleteConversation(conv.id),
                otherUser: otherUser,
                isTyping: isTyping,
                previewMessage: preview,
                hidePreview: lastMsg != null && preview == null,
              );
            },
          );
        },
      ),
    );
  }
}
