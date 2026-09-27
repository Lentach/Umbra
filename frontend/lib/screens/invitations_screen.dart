import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../l10n/app_localizations.dart';
import '../models/friend_request_model.dart';
import '../models/invitation_state.dart';
import '../models/user_model.dart';
import '../providers/friends_provider.dart';
import '../utils/caption_metrics.dart';
import '../theme/rpg_theme.dart';
import '../widgets/glass/glass_surface.dart';
import '../widgets/hex_avatar.dart';
import '../widgets/invitations/invitation_row.dart';
import '../widgets/top_snackbar.dart';

class InvitationsScreen extends StatefulWidget {
  const InvitationsScreen({super.key});

  @override
  State<InvitationsScreen> createState() => _InvitationsScreenState();
}

class _InvitationsScreenState extends State<InvitationsScreen> {
  /// Sentinel for "the user collapsed the comb's card"; distinct from null,
  /// which means "no manual choice yet" and lets a lone request auto-expand.
  static const int _combCollapsed = -1;

  final _handleController = TextEditingController();
  final Map<int, InvitationAction> _actingRequestActions = {};
  int? _expandedRequestId;

  FriendsProvider? _friends;
  bool _searching = false;
  bool _handlingProviderChange = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<FriendsProvider>().loadFriendRequests();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final friends = context.read<FriendsProvider>();
    if (friends == _friends) return;

    _friends?.removeListener(_onFriendsChanged);
    _friends = friends;
    _friends!.addListener(_onFriendsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onFriendsChanged());
  }

  @override
  void dispose() {
    _friends?.removeListener(_onFriendsChanged);
    _handleController.dispose();
    super.dispose();
  }

  /// Socket results change provider state. Consume failures here, rather than
  /// during build, so rendering stays side-effect free.
  void _onFriendsChanged() {
    if (!mounted || _handlingProviderChange) return;
    _handlingProviderChange = true;
    try {
      final friends = _friends!;
      final resolvedActions = _actingRequestActions.keys
          .where(
            (requestId) =>
                friends.invitationActionFor(requestId) !=
                InvitationActionStatus.inFlight,
          )
          .toList(growable: false);
      final searchFinished = _searching && friends.searchResults != null;
      if (resolvedActions.isNotEmpty || searchFinished) {
        setState(() {
          for (final requestId in resolvedActions) {
            _actingRequestActions.remove(requestId);
          }
          if (searchFinished) _searching = false;
        });
      }

      final failure = friends.consumeInvitationFailure();
      if (failure != null) {
        final message = _failureMessage(AppLocalizations.of(context), failure);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showTopSnackBar(context, message);
        });
      }
    } finally {
      _handlingProviderChange = false;
    }
  }

  String _failureMessage(AppLocalizations l10n, InvitationFailure failure) {
    return switch (failure.reason) {
      'user_not_found' => l10n.invitationFailedUserNotFound,
      'self_request' => l10n.invitationFailedSelf,
      'blocked' => l10n.invitationFailedBlocked,
      'already_friends' => l10n.invitationFailedAlreadyFriends,
      'duplicate_request' => l10n.invitationFailedDuplicate,
      'invalid_payload' => l10n.invitationFailedInvalidPayload,
      'not_friends' => l10n.invitationFailedNotFriends,
      'accept_failed' => l10n.invitationAcceptFailed,
      'reject_failed' => l10n.invitationDeclineFailed,
      _ => switch (failure.action) {
        InvitationAction.send => l10n.invitationSendFailed,
        InvitationAction.accept => l10n.invitationAcceptFailed,
        InvitationAction.decline => l10n.invitationDeclineFailed,
        InvitationAction.ensureChat => l10n.invitationChatSetupFailed,
      },
    };
  }

  void _search() {
    final handle = _handleController.text.trim();
    if (handle.isEmpty) return;

    setState(() => _searching = true);
    final friends = context.read<FriendsProvider>();
    friends.clearSearchResults();
    friends.searchUsers(handle);
  }

  void _actOnIncoming(FriendRequestModel request, InvitationAction action) {
    setState(() => _actingRequestActions[request.id] = action);
    final friends = context.read<FriendsProvider>();
    switch (action) {
      case InvitationAction.accept:
        friends.acceptFriendRequest(request.id);
        break;
      case InvitationAction.decline:
        friends.rejectFriendRequest(request.id);
        break;
      case InvitationAction.send:
      case InvitationAction.ensureChat:
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    const headerHeight = 52.0;
    final headerClearance = topInset + 8 + headerHeight + 8;
    final friends = context.watch<FriendsProvider>();

    // Which inbound request's accept/decline card is open under the comb.
    // A lone request auto-expands (the common case pays zero extra taps);
    // an explicit collapse sticks until the user picks a hex again.
    final requests = friends.friendRequests;
    int? expandedRequestId;
    if (_expandedRequestId != _combCollapsed) {
      final manual = _expandedRequestId;
      if (manual != null && requests.any((r) => r.id == manual)) {
        expandedRequestId = manual;
      } else if (requests.length == 1) {
        expandedRequestId = requests.first.id;
      }
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                12,
                headerClearance,
                12,
                MediaQuery.paddingOf(context).bottom + 24,
              ),
              // Desktop uses the same module in a centered, max-width column
              // (approved design). Full-bleed at 1440 px stretched every action
              // button to ~900 px, which read as unfinished rather than roomy.
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: friends.hasLoadedInvitationsOnce
                      ? _InvitationEntrance(
                          child: _InvitationContent(
                            handleController: _handleController,
                            searching: _searching,
                            actingRequestActions: _actingRequestActions,
                            friends: friends,
                            expandedRequestId: expandedRequestId,
                            onToggleRequest: _toggleRequest,
                            onSearch: _search,
                            onActOnIncoming: _actOnIncoming,
                          ),
                        )
                      : const _InvitationSkeleton(),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Padding(
              padding: EdgeInsets.fromLTRB(14, topInset + 8, 14, 0),
              // Chrome shares the content column's width so the header capsule and
              // the rows stay aligned on desktop; unconstrained, GlassPill expands
              // to the full 1440 px and becomes an enormous lozenge.
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SizedBox(
                    height: headerHeight,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 60),
                            child: Center(
                              child: GlassPill(
                                height: headerHeight,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                ),
                                child: Center(
                                  child: Text(
                                    AppLocalizations.of(context).invitations,
                                    style: RpgTheme.bodyFont(
                                      fontSize: 16,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: GlassCircle(
                            size: headerHeight,
                            child: Center(
                              child: IconButton(
                                icon: const Icon(Icons.arrow_back),
                                tooltip: MaterialLocalizations.of(
                                  context,
                                ).backButtonTooltip,
                                onPressed: () => Navigator.of(context).pop(),
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
          ),
        ],
      ),
    );
  }

  void _toggleRequest(int requestId, bool wasExpanded) {
    setState(() {
      _expandedRequestId = wasExpanded ? _combCollapsed : requestId;
    });
  }
}

class _InvitationContent extends StatelessWidget {
  final TextEditingController handleController;
  final bool searching;
  final FriendsProvider friends;
  final Map<int, InvitationAction> actingRequestActions;

  /// The inbound request whose accept/decline card is open under the comb.
  final int? expandedRequestId;
  final void Function(int requestId, bool wasExpanded) onToggleRequest;
  final VoidCallback onSearch;
  final void Function(FriendRequestModel request, InvitationAction action)
  onActOnIncoming;

  const _InvitationContent({
    required this.handleController,
    required this.searching,
    required this.friends,
    required this.actingRequestActions,
    required this.expandedRequestId,
    required this.onToggleRequest,
    required this.onSearch,
    required this.onActOnIncoming,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final incomingOutcomes = friends.acceptedOutcomesFor(
      InvitationDirection.incoming,
    );
    final outgoingOutcomes = friends.acceptedOutcomesFor(
      InvitationDirection.outgoing,
    );
    // The server answers a known contact like anyone (owner decision 4; a
    // box friendship has no server row), so "add" is offered here to
    // strangers only. "Not found" stays tied to an EMPTY raw answer.
    final knownIds = {
      for (final user in friends.friends) user.id,
      for (final request in friends.friendRequests) request.sender.id,
      for (final request in friends.sentRequests) request.receiver.id,
      for (final user in friends.blockedUsers) user.id,
    };
    final visibleSearchResults = (friends.searchResults ?? const <UserModel>[])
        .where(
          (user) =>
              !knownIds.contains(user.id) &&
              friends.acceptedOutcomeForPeer(user.id) == null,
        )
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InviteByHandleControl(
          controller: handleController,
          searching: searching,
          onSearch: onSearch,
        ),
        if (friends.searchResults != null &&
            friends.searchResults!.isEmpty) ...[
          const SizedBox(height: 12),
          Text(
            l10n.userNotFound,
            textAlign: TextAlign.center,
            style: RpgTheme.bodyFont(
              fontSize: 14,
              color: FireplaceColors.of(context).mutedText,
            ),
          ),
        ],
        for (final user in visibleSearchResults) ...[
          const SizedBox(height: 12),
          _SearchIdentityRow(
            key: ValueKey(user.id),
            user: user,
            sending:
                friends.sendActionFor(user.id) ==
                InvitationActionStatus.inFlight,
            onSend: () => friends.sendFriendRequest(user.id),
          ),
        ],
        const SizedBox(height: 28),
        _InvitationSection(
          title: l10n.invitationsWaitingForYou,
          count: incomingOutcomes.length + friends.friendRequests.length,
          // Inbound requests are the one thing on this screen that wants an
          // answer; the badge flips to the accent while any are waiting.
          accented: friends.friendRequests.isNotEmpty,
          emptyMessage: l10n.invitationsNothingWaiting,
          rows: [
            for (final outcome in incomingOutcomes)
              _outcomeRow(context, friends, outcome),
            // Inbound requests are a mini honeycomb of accent terminals, not
            // a wall of cards; tapping a hex opens that sender's accept /
            // decline card in place. The expanded card is a DIRECT sibling of
            // the outcome rows ON PURPOSE: it shares its peer-id key with the
            // outcome row that replaces it on accept, so the element is
            // reused and the avatar's forge animation sees the transition.
            if (friends.friendRequests.isNotEmpty)
              _WaitingComb(
                key: const Key('invitation-waiting-comb'),
                requests: friends.friendRequests,
                expandedRequestId: expandedRequestId,
                onToggle: onToggleRequest,
              ),
            for (final request in friends.friendRequests)
              if (request.id == expandedRequestId)
                _incomingRow(context, friends, request),
          ],
        ),
        const SizedBox(height: 28),
        _InvitationSection(
          title: l10n.invitationsSent,
          count: outgoingOutcomes.length + friends.sentRequests.length,
          emptyMessage: l10n.invitationsNoneSent,
          rows: [
            for (final outcome in outgoingOutcomes)
              _outcomeRow(context, friends, outcome),
            for (final request in friends.sentRequests)
              InvitationRow(
                key: ValueKey(request.receiver.id),
                peer: request.receiver,
                state: InvitationRowState.outbound,
              ),
          ],
        ),
      ],
    );
  }

  InvitationRow _incomingRow(
    BuildContext context,
    FriendsProvider friends,
    FriendRequestModel request,
  ) {
    final acting =
        friends.invitationActionFor(request.id) ==
        InvitationActionStatus.inFlight;
    final state = acting
        ? InvitationRowState.acting
        : InvitationRowState.inbound;

    return InvitationRow(
      key: ValueKey(request.sender.id),
      peer: request.sender,
      state: state,
      actingAction: actingRequestActions[request.id],
      onAccept: () => onActOnIncoming(request, InvitationAction.accept),
      onDecline: () => onActOnIncoming(request, InvitationAction.decline),
    );
  }

  InvitationRow _outcomeRow(
    BuildContext context,
    FriendsProvider friends,
    InvitationOutcome outcome,
  ) {
    return InvitationRow(
      key: ValueKey(outcome.peerUserId),
      peer: outcome.peer,
      state: outcome.chatReady
          ? InvitationRowState.acceptedReady
          : InvitationRowState.acceptedNeedsChat,
      retrying: outcome.retrying,
      onOpenChat: () => Navigator.of(context).pop(outcome.peerUserId),
      onDone: () => friends.clearAcceptedOutcome(outcome.peerUserId),
      onCreateChat: () => friends.ensureInvitationChat(outcome.peerUserId),
    );
  }
}

class _InviteByHandleControl extends StatelessWidget {
  final TextEditingController controller;
  final bool searching;
  final VoidCallback onSearch;

  const _InviteByHandleControl({
    required this.controller,
    required this.searching,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GlassSurface(
      borderRadius: BorderRadius.circular(16),
      // Content surface, so it must be OPAQUE (SPEC §1: no translucency on a text
      // surface). `blur: false` is NOT enough — it still paints the translucent
      // `GlassTheme.fill`; only `forceOpaque` selects the solid `opaqueFill`.
      forceOpaque: true,
      shadow: false,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.inviteByHandleHint,
            style: RpgTheme.bodyFont(
              fontSize: 12,
              color: FireplaceColors.of(context).mutedText,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('invitation-handle-field'),
            controller: controller,
            style: RpgTheme.bodyFont(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            decoration: RpgTheme.rpgInputDecoration(
              hintText: l10n.usernameTagPlaceholder,
              prefixIcon: Icons.person_outlined,
              context: context,
            ),
            onSubmitted: (_) => onSearch(),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            key: const Key('invitation-handle-submit'),
            onPressed: searching ? null : onSearch,
            child: searching
                ? const SizedBox(
                    key: Key('invitation-search-progress'),
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.invitationFindUser),
          ),
        ],
      ),
    );
  }
}

class _SearchIdentityRow extends StatelessWidget {
  final UserModel user;
  final bool sending;
  final VoidCallback onSend;

  const _SearchIdentityRow({
    super.key,
    required this.user,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = FireplaceColors.of(context);
    return GlassSurface(
      borderRadius: BorderRadius.circular(16),
      forceOpaque: true,
      shadow: false,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          HexAvatar(
            size: 44,
            displayName: user.username,
            imageUrl: user.profilePictureUrl,
            surface: colors.convItemBg,
            // mutedText, not convItemBorder — same 3:1 ring-boundary reason
            // as InvitationRow (design review 2026-08-03).
            borderColor: colors.mutedText,
            initialsStyle: RpgTheme.bodyFont(
              fontSize: 44 * 0.34,
              fontWeight: FontWeight.w800,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              user.displayHandle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RpgTheme.bodyFont(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            key: Key('invitation-send-${user.id}'),
            onPressed: sending ? null : onSend,
            child: sending
                ? const SizedBox(
                    key: Key('invitation-send-progress'),
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(AppLocalizations.of(context).sendInvitation),
          ),
        ],
      ),
    );
  }
}

/// A section of the relationship inbox, headed by a title and a hex-shaped
/// count badge — the same shape language as the avatars below it.
class _InvitationSection extends StatelessWidget {
  final String title;
  final int count;
  final bool accented;
  final String emptyMessage;
  final List<Widget> rows;

  const _InvitationSection({
    required this.title,
    required this.count,
    this.accented = false,
    required this.emptyMessage,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = FireplaceColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: RpgTheme.bodyFont(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            // `convItemBg` sits within a hair of the scaffold in light and teal,
            // so the fill alone left the count reading as a bare floating
            // number. The muted outline is what makes it a badge in every
            // theme; the accented badge sits on the accent and needs none.
            // Pointy-top like every other hex in the app — owner ruling
            // 2026-08-03: no flat-top variants.
            HexCountBadge(
              label: '$count',
              background: accented ? colorScheme.primary : colors.convItemBg,
              borderColor: accented ? null : colors.mutedText,
              textStyle: RpgTheme.bodyFont(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: accented
                    ? colorScheme.onPrimary
                    : colorScheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          Text(
            emptyMessage,
            style: RpgTheme.bodyFont(fontSize: 13, color: colors.mutedText),
          )
        else
          for (final row in rows) ...[row, const SizedBox(height: 8)],
      ],
    );
  }
}

class _InvitationSkeleton extends StatelessWidget {
  const _InvitationSkeleton();

  @override
  Widget build(BuildContext context) {
    final isDark = RpgTheme.isDark(context);
    final boneColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: isDark ? 0.08 : 0.06);
    final effect = MediaQuery.disableAnimationsOf(context)
        ? SolidColorEffect(color: boneColor)
        : ShimmerEffect(
            baseColor: boneColor,
            highlightColor: boneColor.withValues(alpha: boneColor.a + 0.04),
            duration: const Duration(milliseconds: 1100),
          );

    return Skeletonizer(
      enabled: true,
      effect: effect,
      child: Column(
        children: [
          const _InvitationSkeletonTile(tall: true),
          const SizedBox(height: 28),
          const _InvitationSkeletonTile(),
          const SizedBox(height: 8),
          const _InvitationSkeletonTile(),
          const SizedBox(height: 28),
          const _InvitationSkeletonTile(),
          const SizedBox(height: 8),
          const _InvitationSkeletonTile(),
        ],
      ),
    );
  }
}

class _InvitationSkeletonTile extends StatelessWidget {
  final bool tall;

  const _InvitationSkeletonTile({this.tall = false});

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(16),
      forceOpaque: true,
      shadow: false,
      padding: const EdgeInsets.all(12),
      child: SizedBox(
        height: tall ? 132 : 52,
        child: Row(
          children: [
            const Bone.circle(size: 44),
            const SizedBox(width: 12),
            const Expanded(child: Bone.text(width: 160, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

/// One-shot entrance for the loaded inbox: a 240 ms fade + 12 px rise,
/// played once when the skeleton hands over, never on provider rebuilds
/// (the tween's end value is stable, so rebuilds don't replay it).
class _InvitationEntrance extends StatelessWidget {
  final Widget child;

  const _InvitationEntrance({required this.child});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        // The rise is decorative; assistive tech must see the inbox from the
        // first frame, not after 240 ms.
        alwaysIncludeSemantics: true,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - t)),
          child: child,
        ),
      ),
    );
  }
}

/// The "Waiting for you" honeycomb: one accent hex terminal per inbound
/// request, same lattice math and caption rhythm as the Chats picker comb.
/// Tapping a hex toggles that sender's accept/decline card below the comb.
class _WaitingComb extends StatelessWidget {
  const _WaitingComb({
    super.key,
    required this.requests,
    required this.expandedRequestId,
    required this.onToggle,
  });

  static const double _labelGap = 5;
  static const double _rowGap = 6;

  final List<FriendRequestModel> requests;
  final int? expandedRequestId;
  final void Function(int requestId, bool wasExpanded) onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final colors = FireplaceColors.of(context);
    final labelStyle = RpgTheme.bodyFont(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: colorScheme.onSurface,
    );
    final labelHeight = measureCaptionHeight(context, labelStyle, lines: 1);

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 82).floor().clamp(3, 6);
        // Half-cell in the divisor = the odd-row stagger staying inside the
        // column, exactly as in the Chats picker.
        final hexHeight =
            (constraints.maxWidth / ((columns + 0.5) * kHexWidthRatio))
                .clamp(56.0, 72.0)
                .toDouble();
        final cellWidth = hexHeight * kHexWidthRatio;
        final rowHeight = hexHeight + _labelGap + labelHeight + _rowGap;
        final rowCount = (requests.length / columns).ceil();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var row = 0; row < rowCount; row++)
              SizedBox(
                height: rowHeight,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: row.isOdd ? cellWidth / 2 : 0,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final request in requests.sublist(
                        row * columns,
                        ((row + 1) * columns).clamp(0, requests.length),
                      ))
                        _buildCell(
                          context,
                          l10n,
                          colorScheme,
                          colors,
                          labelStyle,
                          request,
                          cellWidth,
                          hexHeight,
                          rowHeight,
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildCell(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme colorScheme,
    FireplaceColors colors,
    TextStyle labelStyle,
    FriendRequestModel request,
    double cellWidth,
    double hexHeight,
    double rowHeight,
  ) {
    final expanded = request.id == expandedRequestId;
    return SizedBox(
      width: cellWidth,
      height: rowHeight,
      child: Semantics(
        button: true,
        selected: expanded,
        label: l10n.invitationSemanticIncoming(request.sender.username),
        excludeSemantics: true,
        child: InkResponse(
          key: Key('invitation-comb-${request.id}'),
          onTap: () => onToggle(request.id, expanded),
          radius: hexHeight / 2,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HexAvatar(
                size: hexHeight,
                displayName: request.sender.username,
                imageUrl: request.sender.profilePictureUrl,
                surface: colors.convItemBg,
                borderColor: expanded ? colorScheme.primary : colors.mutedText,
                // Every terminal here wants an answer; the open one burns
                // brightest.
                ember: expanded ? 1 : 0.45,
                initialsStyle: RpgTheme.bodyFont(
                  fontSize: hexHeight * 0.25,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: _labelGap),
              Text(
                request.sender.username,
                softWrap: false,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: expanded
                    ? labelStyle.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.primary,
                      )
                    : labelStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
