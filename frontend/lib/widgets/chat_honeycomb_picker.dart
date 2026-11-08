import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/user_model.dart';
import '../theme/glass_theme.dart';
import '../theme/rpg_theme.dart';
import '../utils/caption_metrics.dart';
import 'glass/glass_sheet.dart';
import 'hex_avatar.dart';

/// What the Chats picker came back with.
sealed class ChatPickerChoice {
  const ChatPickerChoice();
}

/// Start, or reopen, a conversation with this friend.
class ChatPickerFriend extends ChatPickerChoice {
  const ChatPickerFriend(this.friend);

  final UserModel friend;
}

/// Open the invitation queue.
///
/// The picker deliberately never accepts an invitation itself: accept and
/// decline carry a scoped-failure and retry state machine that already lives
/// in `InvitationsScreen`, and a second copy of it would drift from the first.
class ChatPickerReviewInvitations extends ChatPickerChoice {
  const ChatPickerReviewInvitations();
}

/// Open the invitation screen to add someone new — the picker's trailing
/// dashed "+" socket, the same door the Contacts board's add cell opens.
class ChatPickerInviteNew extends ChatPickerChoice {
  const ChatPickerInviteNew();
}

/// Opens the Chats friend picker as floating glass chrome.
Future<ChatPickerChoice?> showChatHoneycombPicker(
  BuildContext context, {
  required List<UserModel> friends,
  List<UserModel> inviters = const <UserModel>[],
}) {
  return showGlassSheet<ChatPickerChoice>(
    context,
    isScrollControlled: true,
    builder: (_) => ChatHoneycombPicker(friends: friends, inviters: inviters),
  );
}

/// A one-shot, reduce-motion-aware honeycomb of friends to start a chat with.
///
/// People who have invited *you* lead the comb as accent terminals. The Chats
/// tab badges its "+" with the inbound request count, so the sheet behind that
/// badge has to be able to answer it — otherwise the badge points at a door
/// that does not open.
class ChatHoneycombPicker extends StatefulWidget {
  const ChatHoneycombPicker({
    super.key,
    required this.friends,
    this.inviters = const <UserModel>[],
  });

  final List<UserModel> friends;

  /// Senders of inbound invitations still awaiting an answer.
  final List<UserModel> inviters;

  @override
  State<ChatHoneycombPicker> createState() => _ChatHoneycombPickerState();
}

class _ChatHoneycombPickerState extends State<ChatHoneycombPicker>
    with SingleTickerProviderStateMixin {
  static const _entranceDuration = Duration(milliseconds: 220);

  late final AnimationController _entranceController = AnimationController(
    vsync: this,
    duration: _entranceDuration,
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _entranceController,
    curve: Curves.easeOutCubic,
  );
  late final Animation<Offset> _offset =
      Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _entranceController,
          curve: Curves.easeOutCubic,
        ),
      );

  bool _entranceStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce-motion is re-checked on EVERY dependency change, not latched on
    // the first: switching it on mid-entrance must snap the sheet to its end
    // state. Only the forward() is one-shot.
    if (MediaQuery.disableAnimationsOf(context)) {
      _entranceController.value = 1;
      return;
    }
    if (!_entranceStarted) {
      _entranceStarted = true;
      _entranceController.forward();
    }
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final glass = GlassTheme.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.68;

    final cells = <_PickerCell>[
      // The comb LEADS with the empty socket, exactly like the Contacts
      // board's leading add cell (owner ruling 2026-08-04: with many friends
      // a trailing socket ends up below the fold and the door disappears).
      // Only the fully empty picker drops it — a lone socket looks broken,
      // so the empty state carries the same door as a button instead.
      if (widget.inviters.isNotEmpty || widget.friends.isNotEmpty)
        const _PickerCell.addSlot(),
      for (final inviter in widget.inviters) _PickerCell.invitation(inviter),
      for (final friend in widget.friends) _PickerCell.friend(friend),
    ];

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: FadeTransition(
          opacity: _opacity,
          child: SlideTransition(
            position: _offset,
            child: Padding(
              key: const Key('chat-honeycomb-picker'),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: glass.onGlassMuted.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    l10n.chatPickerTitle,
                    style: RpgTheme.bodyFont(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.chatPickerSubtitle,
                    style: RpgTheme.bodyFont(
                      fontSize: 13,
                      color: glass.onGlassMuted,
                    ),
                  ),
                  if (widget.inviters.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      key: const Key('chat-picker-invitations-hint'),
                      l10n.contactNetworkPendingRequests(
                        widget.inviters.length,
                      ),
                      style: RpgTheme.bodyFont(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.primary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Flexible(
                    child: cells.length <= 1
                        ? _EmptyPickerState(
                            title: l10n.chatPickerEmptyTitle,
                            description: l10n.chatPickerEmptyDescription,
                            inviteLabel: l10n.chatPickerInviteButton,
                            onInvite: () => Navigator.of(
                              context,
                            ).pop(const ChatPickerInviteNew()),
                          )
                        : _HoneycombGrid(
                            cells: cells,
                            onSelected: (cell) => Navigator.of(context).pop(
                              switch (cell) {
                                _PickerCell(isAddSlot: true) =>
                                  const ChatPickerInviteNew(),
                                _PickerCell(isInvitation: true) =>
                                  const ChatPickerReviewInvitations(),
                                _PickerCell(:final user) =>
                                  ChatPickerFriend(user!),
                              },
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
}

/// One terminal of the comb: a friend to chat with, someone waiting on an
/// answer from you, or the empty "+" socket that invites someone new.
@immutable
class _PickerCell {
  const _PickerCell.friend(UserModel this.user)
    : isInvitation = false,
      isAddSlot = false;

  const _PickerCell.invitation(UserModel this.user)
    : isInvitation = true,
      isAddSlot = false;

  const _PickerCell.addSlot()
    : user = null,
      isInvitation = false,
      isAddSlot = true;

  /// Null only for the add socket.
  final UserModel? user;
  final bool isInvitation;
  final bool isAddSlot;
}

class _HoneycombGrid extends StatelessWidget {
  const _HoneycombGrid({required this.cells, required this.onSelected});

  /// Gap between a hex and its caption, and between a caption and the next
  /// row — the same rhythm the Contacts board uses, so both combs read as one
  /// shape language instead of two.
  static const double _labelGap = 5;
  static const double _rowGap = 6;

  final List<_PickerCell> cells;
  final ValueChanged<_PickerCell> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final colors = FireplaceColors.of(context);
    final glass = GlassTheme.of(context);

    // An avatar-only comb is unusable the moment a friend has no picture: every
    // such terminal collapses to a single initial. The name is the identifier.
    final labelStyle = RpgTheme.bodyFont(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: colorScheme.onSurface,
    );
    final hasInvitations = cells.any((cell) => cell.isInvitation);
    final labelHeight = measureCaptionHeight(
      context,
      labelStyle,
      lines: hasInvitations ? 2 : 1,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 82).floor().clamp(3, 6);
        // The half-cell in the divisor is the odd-row stagger: it keeps the
        // widest row inside the sheet instead of overflowing it.
        final hexHeight =
            (constraints.maxWidth / ((columns + 0.5) * kHexWidthRatio))
                .clamp(64.0, 86.0)
                .toDouble();
        final cellWidth = hexHeight * kHexWidthRatio;
        final rowHeight = hexHeight + _labelGap + labelHeight + _rowGap;
        final rows = (cells.length / columns).ceil();

        return ListView.builder(
          key: const Key('chat-honeycomb-grid'),
          itemCount: rows,
          padding: EdgeInsets.zero,
          itemBuilder: (context, row) {
            final start = row * columns;
            final end = (start + columns).clamp(0, cells.length);
            return SizedBox(
              height: rowHeight,
              child: Padding(
                padding: EdgeInsets.only(left: row.isOdd ? cellWidth / 2 : 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final cell in cells.sublist(start, end))
                      SizedBox(
                        width: cellWidth,
                        height: rowHeight,
                        child: cell.isAddSlot
                            ? _buildAddCell(
                                context,
                                l10n,
                                colors,
                                colorScheme,
                                labelStyle,
                                hexHeight,
                              )
                            : Semantics(
                                button: true,
                                label: cell.isInvitation
                                    ? l10n.invitationSemanticIncoming(
                                        cell.user!.username,
                                      )
                                    : cell.user!.displayHandle,
                                excludeSemantics: true,
                                child: InkResponse(
                                  key: Key(
                                    cell.isInvitation
                                        ? 'chat-picker-invite-${cell.user!.id}'
                                        : 'chat-picker-friend-${cell.user!.id}',
                                  ),
                                  onTap: () => onSelected(cell),
                                  radius: hexHeight / 2,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      HexAvatar(
                                        size: hexHeight,
                                        displayName: cell.user!.username,
                                        imageUrl: cell.user!.profilePictureUrl,
                                        avatar: cell.user!.avatar,
                                        surface: colorScheme.surface,
                                        borderColor: cell.isInvitation
                                            ? colorScheme.primary
                                            : glass.border,
                                        // An inbound invitation is the one
                                        // terminal in the comb that wants
                                        // something from you.
                                        ember: cell.isInvitation ? 1 : 0,
                                        initialsStyle: RpgTheme.bodyFont(
                                          fontSize: hexHeight * 0.25,
                                          fontWeight: FontWeight.w700,
                                          color: colorScheme.onSurface,
                                        ),
                                      ),
                                      const SizedBox(height: _labelGap),
                                      Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            cell.user!.username,
                                            softWrap: false,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: labelStyle,
                                          ),
                                          if (cell.isInvitation)
                                            Text(
                                              l10n.invitationStatusPending,
                                              softWrap: false,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              textAlign: TextAlign.center,
                                              style: labelStyle.copyWith(
                                                fontWeight: FontWeight.w700,
                                                color: colorScheme.primary,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ],
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
      },
    );
  }

  /// The trailing empty socket: a dashed hex with a "+", same vocabulary as
  /// the Contacts board's add cell, so both combs offer the same door.
  Widget _buildAddCell(
    BuildContext context,
    AppLocalizations l10n,
    FireplaceColors colors,
    ColorScheme colorScheme,
    TextStyle labelStyle,
    double hexHeight,
  ) {
    return Semantics(
      button: true,
      label: l10n.contactNetworkAddSlotSemantic,
      excludeSemantics: true,
      child: InkResponse(
        key: const Key('chat-picker-invite-new'),
        onTap: () => onSelected(const _PickerCell.addSlot()),
        radius: hexHeight / 2,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: hexHeight * kHexWidthRatio,
              height: hexHeight,
              child: CustomPaint(
                painter: DashedHexPainter(
                  outline: colorScheme.onSurface.withValues(alpha: 0.45),
                ),
                child: Center(
                  child: Icon(Icons.add, size: 22, color: colors.mutedText),
                ),
              ),
            ),
            const SizedBox(height: _labelGap),
            Text(
              l10n.contactNetworkAddSlot,
              softWrap: false,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: labelStyle.copyWith(color: colors.mutedText),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPickerState extends StatelessWidget {
  const _EmptyPickerState({
    required this.title,
    required this.description,
    required this.inviteLabel,
    required this.onInvite,
  });

  final String title;
  final String description;
  final String inviteLabel;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final glass = GlassTheme.of(context);
    return Center(
      child: Semantics(
        key: const Key('chat-honeycomb-empty-state'),
        container: true,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hub_outlined, size: 48, color: glass.onGlassMuted),
              const SizedBox(height: 14),
              Text(
                title,
                style: RpgTheme.bodyFont(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                description,
                textAlign: TextAlign.center,
                style: RpgTheme.bodyFont(
                  fontSize: 13,
                  color: glass.onGlassMuted,
                ),
              ),
              const SizedBox(height: 16),
              // The empty picker used to describe the fix ("add a friend")
              // without offering it. The button IS the add socket's door.
              ElevatedButton.icon(
                key: const Key('chat-picker-invite-empty'),
                onPressed: onInvite,
                icon: const Icon(Icons.add, size: 18),
                label: Text(inviteLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
