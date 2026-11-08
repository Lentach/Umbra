import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../constants/app_constants.dart';
import '../l10n/app_localizations.dart';
import '../models/user_model.dart';
import '../providers/conversations_provider.dart';
import '../providers/friends_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/rpg_theme.dart';
import '../widgets/hex_avatar.dart';
import '../widgets/contact_network_view.dart';
import '../widgets/glass/glass_surface.dart';
import '../widgets/main_tab_screen_header.dart';
import '../utils/instant_opaque_route.dart';
import 'invitations_screen.dart';
import 'chat_detail_screen.dart';
import 'user_card_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  /// One query filters BOTH presentations. The field lives IN the header
  /// capsule row (owner: no dedicated band under it) and only exists when
  /// the account has contacts at all.
  final _searchController = TextEditingController();
  bool _searchOpen = false;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _openSearch() => setState(() => _searchOpen = true);

  void _closeSearch() {
    _searchController.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _query = '';
      _searchOpen = false;
    });
  }

  List<UserModel> _applyQuery(List<UserModel> friends) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return friends;
    return [
      for (final friend in friends)
        if (friend.username.toLowerCase().contains(query)) friend,
    ];
  }

  void _openChatWithContact(BuildContext context, int userId) {
    final convs = context.read<ConversationsProvider>();

    // Check if conversation exists for this user
    final existingConv = convs.conversations.where((conv) {
      final otherUser = convs.getOtherUser(conv);
      return otherUser?.id == userId;
    }).firstOrNull;

    if (existingConv != null) {
      // Conversation exists, open it
      convs.openConversation(existingConv.id);

      final width = MediaQuery.of(context).size.width;
      if (width < AppConstants.layoutBreakpointDesktop) {
        Navigator.of(context).push(
          instantOpaqueRoute(
            builder: (_) => ChatDetailScreen(conversationId: existingConv.id),
          ),
        );
      }
    } else {
      // No conversation, start new one (backend will create)
      convs.startConversation(userId);
      // consumePendingOpen will handle navigation when backend responds
    }
  }

  void _openContactCard(BuildContext context, UserModel user) {
    final convs = context.read<ConversationsProvider>();
    final existingConversation = convs.conversations
        .where(
          (conversation) => convs.getOtherUser(conversation)?.id == user.id,
        )
        .firstOrNull;
    final hasConversation = existingConversation != null;

    Navigator.of(context).push(
      instantOpaqueRoute(
        builder: (cardContext) => UserCardScreen(
          data: UserCardVisualData.fromUser(
            user,
            isSelf: false,
            hasConversation: hasConversation,
            conversationId: existingConversation?.id,
            mute: UserCardMute.fromConversation(
              muted: existingConversation?.muted ?? false,
              mutedUntil: existingConversation?.mutedUntil,
            ),
          ),
          onMessage: () {
            Navigator.of(cardContext).pop();
            _openChatWithContact(context, user.id);
          },
          onMuteChanged: existingConversation == null
              ? null
              : (mute) {
                  convs.setConversationMute(
                    existingConversation.id,
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

  @override
  Widget build(BuildContext context) {
    final convs = context.watch<ConversationsProvider>();
    // When user tapped a contact and we had no conversation, we called startConversation.
    // Backend emits openConversation; consume it here. This is now the tab's ONLY
    // pending-open consumer — Invitations never consumes it, because acceptance no
    // longer emits openConversation at all (it is reserved for explicit
    // startConversation), and Invitations only ever pops a peer id.
    if (convs.pendingOpenConversationId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final id = context.read<ConversationsProvider>().consumePendingOpen();
        if (id != null && context.mounted) {
          Navigator.of(context).push(
            instantOpaqueRoute(
              builder: (_) => ChatDetailScreen(conversationId: id),
            ),
          );
        }
      });
    }
    // Same floating-chrome treatment as the Chats tab (owner, round 4b):
    // the list runs full-bleed behind the transparent header capsule area
    // and the bottom nav; clearance is padding, not a layout slot.
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child:
                context.select<SettingsProvider, bool>(
                  (settings) => settings.contactsListView,
                )
                ? _buildContactsList(context)
                : _buildNetwork(context),
          ),
          Positioned(top: 0, left: 0, right: 0, child: _buildHeader(context)),
        ],
      ),
    );
  }

  /// The header row while searching: the search capsule takes the title's
  /// place, the list/map toggle keeps its slot so the query survives a view
  /// switch (one query drives both presentations).
  Widget _buildHeaderSearchField(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = FireplaceColors.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
      },
      child: Row(
        children: [
          Expanded(
            child: GlassPill(
              height: MainTabScreenHeader.capsuleHeight,
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  Icon(Icons.search, size: 18, color: colors.mutedText),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onChanged: (value) => setState(() => _query = value),
                      style: RpgTheme.bodyFont(
                        fontSize: 14,
                        color: colorScheme.onSurface,
                      ),
                      // `InputDecoration.collapsed` only nulls `border`;
                      // the theme's 2px focusedBorder would draw a second
                      // box inside the glass capsule on focus.
                      decoration: InputDecoration(
                        isCollapsed: true,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        hintText: l10n.contactsSearchHint,
                        hintStyle: RpgTheme.bodyFont(
                          fontSize: 14,
                          color: colors.mutedText,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _closeSearch,
                    tooltip: l10n.cancel,
                    icon: Icon(Icons.close, size: 20, color: colors.mutedText),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          _buildListToggle(context),
        ],
      ),
    );
  }

  /// The network map is the primary presentation; the classic list stays one
  /// tap away as the accessibility / fast-lookup fallback. The choice is
  /// persisted device-side so the tab reopens in whichever view it was left.
  Widget _buildListToggle(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final showList = context.select<SettingsProvider, bool>(
      (settings) => settings.contactsListView,
    );
    return IconButton(
      onPressed: () =>
          context.read<SettingsProvider>().setContactsListView(!showList),
      tooltip: showList
          ? l10n.contactNetworkShowMap
          : l10n.contactNetworkShowList,
      icon: Icon(
        showList ? Icons.hub_outlined : Icons.format_list_bulleted,
        size: 20,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hasContacts = context.watch<FriendsProvider>().friends.isNotEmpty;
    if (!hasContacts) return MainTabScreenHeader(title: l10n.contacts);
    if (_searchOpen) {
      return MainTabScreenHeader.custom(
        child: _buildHeaderSearchField(context),
      );
    }
    return MainTabScreenHeader(
      title: l10n.contacts,
      leadingGlass: false,
      leading: IconButton(
        onPressed: _openSearch,
        tooltip: l10n.contactsSearchHint,
        icon: Icon(
          Icons.search,
          size: 20,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
      trailing: _buildListToggle(context),
    );
  }

  /// The relationship layer lives on this tab now: adding people and the inbound
  /// request queue both open the Invitations screen. It pops the peer's user id
  /// when the user explicitly taps `Open chat`, and null otherwise.
  void _openInvitations(BuildContext context) {
    Navigator.of(context)
        .push<int>(
          MaterialPageRoute(builder: (_) => const InvitationsScreen()),
        )
        .then((userId) {
          if (userId != null && context.mounted) {
            _openChatWithContact(context, userId);
          }
        });
  }

  Widget _buildNetwork(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final friendsProvider = context.watch<FriendsProvider>();
    final allFriends = List<UserModel>.from(friendsProvider.friends)
      ..sort(_compareByDisplayName);
    final friends = _applyQuery(allFriends);
    final filtering = _query.trim().isNotEmpty && allFriends.isNotEmpty;
    final sentInvitees = _applyQuery([
      for (final request in friendsProvider.sentRequests) request.receiver,
    ]);
    final convs = context.watch<ConversationsProvider>();
    final conversationContactIds = <int>{};
    for (final conversation in convs.conversations) {
      final other = convs.getOtherUser(conversation);
      if (other != null) conversationContactIds.add(other.id);
    }
    final pendingRequests = friendsProvider.pendingRequestsCount;
    final currentUser = context.watch<AuthProvider>().currentUser;
    final media = MediaQuery.paddingOf(context);

    return ContactNetworkView(
      contacts: friends,
      sentInvitees: sentInvitees,
      pendingInviteLabel: l10n.invitationStatusPending,
      pendingInviteSemanticLabel: l10n.invitationSemanticOutgoing,
      localNodeLabel: currentUser?.username ?? '',
      localNodeAvatarUrl: currentUser?.profilePictureUrl,
      localNodeAvatar: currentUser?.avatar,
      localNodeCaption: l10n.contactNetworkLocalNode,
      emptyTitle: filtering ? l10n.contactsSearchNoResults : l10n.noContactsYet,
      emptyMessage: filtering ? '' : l10n.addFriendsToStart,
      onContactTap: (user) => _openContactCard(context, user),
      onContactOpenChat: (user) => _openChatWithContact(context, user.id),
      openChatSemanticHint: l10n.contactNetworkOpenChatHint,
      // The add cell is part of the board, but a filtered result set must
      // not grow one — search shows matches, nothing else.
      onAddContact: filtering ? null : () => _openInvitations(context),
      addSlotLabel: l10n.contactNetworkAddSlot,
      addSlotSemanticLabel: l10n.contactNetworkAddSlotSemantic,
      pendingRequestCount: filtering ? 0 : pendingRequests,
      onPendingRequestsTap: () => _openInvitations(context),
      pendingRequestsSemanticLabel: l10n.contactNetworkPendingRequests(
        pendingRequests,
      ),
      networkSemanticLabel: l10n.contactNetworkSemantic(friends.length),
      localNodeSemanticLabel: l10n.contactNetworkYouLocalNode,
      safeInsets: EdgeInsets.fromLTRB(
        12,
        media.top + MainTabScreenHeader.clearance,
        12,
        media.bottom + 8,
      ),
      conversationContactIds: conversationContactIds,
      mapCaption: l10n.contactNetworkNodes(
        friends.length.toString().padLeft(2, '0'),
      ),
    );
  }

  /// Natural sort: same prefix → smaller number first (ziomek3, ziomek6, ziomek50).
  static int _compareByDisplayName(UserModel a, UserModel b) {
    final aMatch = RegExp(r'^(.+?)(\d+)$').firstMatch(a.username);
    final bMatch = RegExp(r'^(.+?)(\d+)$').firstMatch(b.username);
    final aPrefix = (aMatch?.group(1) ?? a.username).toLowerCase();
    final bPrefix = (bMatch?.group(1) ?? b.username).toLowerCase();
    final aNum = aMatch != null ? int.tryParse(aMatch.group(2)!) ?? 0 : 0;
    final bNum = bMatch != null ? int.tryParse(bMatch.group(2)!) ?? 0 : 0;

    final prefixCmp = aPrefix.compareTo(bPrefix);
    if (prefixCmp != 0) return prefixCmp;
    return aNum.compareTo(bNum);
  }

  Widget _buildContactsList(BuildContext context) {
    final friendsProvider = context.watch<FriendsProvider>();
    final allFriends = List<UserModel>.from(friendsProvider.friends)
      ..sort(_compareByDisplayName);
    final friends = _applyQuery(allFriends);
    final filtering = _query.trim().isNotEmpty && allFriends.isNotEmpty;
    final isDark = RpgTheme.isDark(context);
    final mutedColor = FireplaceColors.of(context).mutedText;

    final media = MediaQuery.paddingOf(context);
    final bottomClearance = media.bottom;
    final topClearance = media.top + MainTabScreenHeader.clearance;

    if (friends.isEmpty) {
      if (filtering) {
        return Center(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              32,
              32 + topClearance,
              32,
              32 + bottomClearance,
            ),
            child: Text(
              AppLocalizations.of(context).contactsSearchNoResults,
              textAlign: TextAlign.center,
              style: RpgTheme.bodyFont(fontSize: 14, color: mutedColor),
            ),
          ),
        );
      }
      return Center(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            32,
            32 + topClearance,
            32,
            32 + bottomClearance,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.people_outline, size: 48, color: mutedColor),
              const SizedBox(height: 16),
              Text(
                AppLocalizations.of(context).noContactsYet,
                style: RpgTheme.bodyFont(fontSize: 16, color: mutedColor),
              ),
              const SizedBox(height: 8),
              Text(
                AppLocalizations.of(context).addFriendsToStart,
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
      );
    }

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(8, topClearance, 8, bottomClearance + 8),
      itemCount: friends.length,
      itemBuilder: (context, index) {
        final friend = friends[index];
        return _buildContactTile(context, friend);
      },
    );
  }

  Widget _buildContactTile(BuildContext context, UserModel friend) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = FireplaceColors.of(context);
    final user = friend;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => _openContactCard(context, user),
          borderRadius: BorderRadius.circular(12),
          splashColor: colorScheme.primary.withValues(alpha: 0.2),
          child: Padding(
            // Matches the ConversationTile "normal" row exactly (owner: rows
            // must line up with the Chats tab): v10 + 44px hex = 64px tall,
            // and 4+21 = the 4+6+3+12 left offset of a chat row's hex.
            padding: const EdgeInsets.fromLTRB(21, 10, 12, 10),
            child: Row(
              children: [
                HexAvatar(
                  size: 44,
                  displayName: user.username,
                  imageUrl: user.profilePictureUrl,
                  avatar: user.avatar,
                  surface: colors.convItemBg,
                  borderColor: colors.convItemBorder,
                  initialsStyle: RpgTheme.bodyFont(
                    fontSize: 44 * 0.34,
                    fontWeight: FontWeight.w800,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    user.username,
                    style: RpgTheme.bodyFont(
                      fontSize: 14,
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
