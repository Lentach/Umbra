import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';

import '../models/profile_photo.dart';
import '../models/user_model.dart';
import '../theme/rpg_theme.dart';
import '../utils/caption_metrics.dart';
import 'hex_avatar.dart';
import 'local_node_core.dart';

part 'contact_network/contact_hex_layout.dart';
part 'contact_network/contact_network_nodes.dart';
part 'contact_network/contact_network_painters.dart';
part 'contact_network/contact_network_viewport.dart';

/// A provider-free rendering of the existing contact set as a "honeycomb
/// core": the local user's reticle node feeds a fixed-width staggered field
/// of hex terminals that grows straight down and scrolls.
///
/// Composition contract (owner-approved 2026-07-23):
/// - Alphabetical (natural) order = spatial order, rows fill 4-3-4-3, the
///   partial last row centers itself, so the picture never degrades with
///   count - more contacts only means more rows.
/// - Every hex carries its own socket stub + pad (doubled = a real
///   conversation exists). No shared bus wiring: every drawn line is one
///   direct user->contact relationship.
/// - Tapping a contact fills their route with the accent color from the hex
///   up to the local core, then the parent opens the user card.
///
/// The parent owns contact data and navigation.
class ContactNetworkView extends StatefulWidget {
  const ContactNetworkView({
    super.key,
    required this.contacts,
    this.sentInvitees = const <UserModel>[],
    this.pendingInviteLabel,
    this.pendingInviteSemanticLabel,
    required this.localNodeLabel,
    this.localNodeAvatarUrl,
    this.localNodeAvatar,
    required this.localNodeCaption,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.onContactTap,
    this.onContactOpenChat,
    this.openChatSemanticHint,
    this.onAddContact,
    this.addSlotLabel,
    this.addSlotSemanticLabel,
    this.pendingRequestCount = 0,
    this.onPendingRequestsTap,
    this.pendingRequestsSemanticLabel,
    required this.networkSemanticLabel,
    required this.localNodeSemanticLabel,
    this.safeInsets = EdgeInsets.zero,
    this.conversationContactIds = const <int>{},
    this.mapCaption,
  });

  final List<UserModel> contacts;

  /// Recipients of the caller's pending outbound invitations. They occupy
  /// ghost cells but remain outside the real-contact contract.
  final List<UserModel> sentInvitees;

  /// Word rendered under a pending outbound invitation ("Pending"). Null
  /// leaves the ghost cell wordless — the state would then be carried by the
  /// outbound glyph alone, which is exactly what users read as "just an
  /// arrow". Supplying it also widens every row's label band to two lines,
  /// and only for as long as an invitation is actually outstanding.
  final String? pendingInviteLabel;

  /// Screen-reader sentence for a pending outbound invitation, given the
  /// invitee's name. Null falls back to the bare name.
  final String Function(String name)? pendingInviteSemanticLabel;
  final String localNodeLabel;

  /// The local user's avatar, shown inside the core reticle when set.
  final String? localNodeAvatarUrl;
  final ProfilePhotoRef? localNodeAvatar;
  final String localNodeCaption;
  final String emptyTitle;
  final String emptyMessage;
  final ValueChanged<UserModel> onContactTap;

  /// Secondary activation (long press, Shift+Enter): jump straight into the
  /// conversation, no route animation — chat entry is instant by doctrine.
  /// Null for contacts the parent has no conversation for, so a stray press
  /// can never create one; those fall back to [onContactTap].
  final ValueChanged<UserModel>? onContactOpenChat;

  /// Screen-reader hint for the long-press action ("Open chat"), so the
  /// gesture is announced with its meaning instead of a bare "long press".
  final String? openChatSemanticHint;

  /// Tapping the trailing "+" cell. Null hides the cell entirely.
  final VoidCallback? onAddContact;

  /// Caption under the "+" cell (localized by the parent).
  final String? addSlotLabel;

  /// Spoken name of the "+" cell; the visible caption is a bare "add".
  final String? addSlotSemanticLabel;

  /// Inbound friend requests waiting at the core. 0 hides the port.
  final int pendingRequestCount;
  final VoidCallback? onPendingRequestsTap;
  final String? pendingRequestsSemanticLabel;
  final String networkSemanticLabel;
  final String localNodeSemanticLabel;

  /// Parent chrome clearance, such as the floating tab header and navigation.
  final EdgeInsets safeInsets;

  /// Ids of contacts that already share a conversation with the local user.
  /// Their socket renders doubled. Purely visual; the parent supplies real data.
  final Set<int> conversationContactIds;

  /// Factual micro-caption under the bottom-left frame bracket (node count).
  final String? mapCaption;

  @override
  State<ContactNetworkView> createState() => _ContactNetworkViewState();
}

class _ContactNetworkViewState extends State<ContactNetworkView>
    with SingleTickerProviderStateMixin {
  final _scrollController = ScrollController();
  late final AnimationController _routeController;

  int? _routeContactId;
  int? _focusedContactId;
  bool _entranceCompleted = false;
  bool _addSlotFocused = false;

  /// Highest row whose avatars may fetch. A ValueNotifier, not setState:
  /// crossing a row while scrolling rebuilds mounted avatar leaves, never
  /// the resident focus/semantics controls or unrelated visual rows.
  final _armedThroughRow = ValueNotifier<int>(0);

  /// Rows visible right now, recomputed each build. Combined with the
  /// notifier's high-water mark so scrolling back up never drops a face
  /// that already loaded back to initials.
  int _armedFloor = 0;
  ContactHexLayoutResult? _lastLayout;

  /// Rows with a visible hex subtree. Focus and semantics stay resident for
  /// every real contact in a lightweight control layer below.
  final _visibleRows = ValueNotifier<_VisibleRowRange>(
    const _VisibleRowRange.empty(),
  );
  bool _visibleRowsSyncScheduled = false;
  double _lastViewportHeight = 0;

  @override
  void initState() {
    super.initState();
    _routeController =
        AnimationController(
          vsync: this,
          // Slow enough to READ: the strip travelling to the core is the
          // point of the interaction (owner call, overrides the entrance
          // cap - this is user-triggered feedback, not chrome).
          duration: const Duration(milliseconds: 480),
        )..addStatusListener((status) {
          if (status != AnimationStatus.completed) return;
          final id = _routeContactId;
          _routeController.reset();
          if (id == null) return;
          UserModel? target;
          for (final contact in widget.contacts) {
            if (contact.id == id) {
              target = contact;
              break;
            }
          }
          setState(() => _routeContactId = null);
          if (target != null) widget.onContactTap(target);
        });
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(ContactNetworkView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The mark is a ROW INDEX into the field that produced it. A different
    // contact or ghost run re-flows the field, so a carried-over mark means
    // nothing — and because it is a HIGH-WATER mark, a stale high one arms
    // every row at once and silently disables the gate for the rest of the
    // session: scroll a long board to the bottom, filter, clear the filter,
    // and all N faces fetch again while the user is sitting back at row 0.
    // `_armedFloor` needs no reset here — the build right behind us
    // recomputes it from the current viewport unconditionally.
    final contactsChanged = !_sameContactRun(
      oldWidget.contacts,
      widget.contacts,
    );
    final inviteesChanged = !_sameContactRun(
      oldWidget.sentInvitees,
      widget.sentInvitees,
    );
    final leadingSlotChanged =
        (oldWidget.onAddContact == null) != (widget.onAddContact == null);
    if (contactsChanged || inviteesChanged || leadingSlotChanged) {
      _armedThroughRow.value = 0;
      _visibleRows.value = const _VisibleRowRange.empty();
    }
  }

  /// Compares the field's identity, not the models': [UserModel] has no
  /// `==`, so comparing instances would reset the marks on every provider
  /// tick that hands us freshly-built objects for the same people.
  static bool _sameContactRun(List<UserModel> a, List<UserModel> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _routeController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _armedThroughRow.dispose();
    _visibleRows.dispose();
    super.dispose();
  }

  /// Scrolling is intentionally a notifier-only path: viewport changes mount
  /// and unmount just the nearby visual rows, while the full focus/semantics
  /// control layer stays stable for traversal and assistive technology.
  void _onScroll() {
    _armVisibleRows();
    _syncVisibleRows();
  }

  void _activateContact(UserModel contact, bool disableAnimations) {
    if (disableAnimations) {
      widget.onContactTap(contact);
      return;
    }
    if (_routeController.isAnimating) return;
    setState(() => _routeContactId = contact.id);
    _routeController.forward(from: 0);
  }

  /// Only a contact whose wire already exists (doubled socket = a real
  /// conversation) can be entered directly; everyone else opens the card,
  /// so a stray long press can never create a conversation.
  bool _canOpenChat(UserModel contact) =>
      widget.onContactOpenChat != null &&
      widget.conversationContactIds.contains(contact.id);

  /// Secondary activation: travel the existing wire straight into the chat.
  /// No route fill — the chat route is deliberately zero-duration, so an
  /// animation here would only add 480ms in front of it.
  void _openChat(UserModel contact) {
    final openChat = widget.onContactOpenChat;
    if (openChat == null) return;
    if (_routeController.isAnimating) return;
    if (!kIsWeb) HapticFeedback.selectionClick();
    openChat(contact);
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final colorScheme = Theme.of(context).colorScheme;
    final colors = FireplaceColors.of(context);
    final nodeTextStyle = RpgTheme.bodyFont(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: colorScheme.onSurface,
    );
    // A pending invitation says so in words under its name, so the whole
    // field reserves a second label line while any invitation is
    // outstanding. Uniform rows are what keeps the lattice a lattice; the
    // cost is paid only until the last invitation resolves.
    final showsInviteStatus =
        widget.pendingInviteLabel != null && widget.sentInvitees.isNotEmpty;
    final labelHeight = measureCaptionHeight(
      context,
      nodeTextStyle,
      lines: showsInviteStatus ? 2 : 1,
    );

    final contactsById = <int, UserModel>{
      for (final contact in widget.contacts) contact.id: contact,
    };
    final ghostUsersById = <int, UserModel>{
      for (final invitee in widget.sentInvitees)
        if (!contactsById.containsKey(invitee.id)) invitee.id: invitee,
    };
    final inputs = ContactHexLayout.sortContacts([
      for (final contact in contactsById.values)
        ContactHexLayoutInput(id: contact.id, displayName: contact.username),
    ]);
    final ghostInputs = [
      for (final invitee in ghostUsersById.values)
        ContactHexLayoutInput(id: invitee.id, displayName: invitee.username),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final fullSize = Size(constraints.maxWidth, constraints.maxHeight);
        final safeRect = _safeRect(fullSize, widget.safeInsets);
        final layout = ContactHexLayout.resolve(
          contacts: inputs,
          ghosts: ghostInputs,
          width: safeRect.width,
          labelHeight: labelHeight,
          leadingSlots: widget.onAddContact == null ? 0 : 1,
        );
        final viewportHeight = safeRect.height;
        final initialVisibleRows = _visibleRowRange(layout, viewportHeight);
        final fieldHeight = math.max(layout.fieldHeight, viewportHeight);
        // Plain assignments, deliberately not setState: we are already
        // inside build, and notifying the arming notifier here would fire
        // listeners mid-build.
        _lastLayout = layout;
        _lastViewportHeight = viewportHeight;
        _armedFloor = _visibleThroughRow(layout, viewportHeight);
        _scheduleVisibleRowsSync();

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fromRect(
              rect: safeRect,
              child: Semantics(
                container: true,
                label: widget.networkSemanticLabel,
                child: FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    physics: layout.fieldHeight > viewportHeight
                        ? const ClampingScrollPhysics()
                        : const NeverScrollableScrollPhysics(),
                    child: SizedBox(
                      width: safeRect.width,
                      height: fieldHeight,
                      child: _buildField(
                        context,
                        layout,
                        initialVisibleRows,
                        contactsById,
                        ghostUsersById,
                        nodeTextStyle,
                        colorScheme,
                        disableAnimations,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fromRect(
              rect: safeRect,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: CustomPaint(
                    painter: _NetworkFramePainter(color: colors.borderColor),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            if (widget.mapCaption != null && widget.contacts.isNotEmpty)
              Positioned(
                left: safeRect.left + 14,
                top: safeRect.bottom - 30,
                child: ExcludeSemantics(
                  child: Text(
                    widget.mapCaption!,
                    style: RpgTheme.bodyFont(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: colors.mutedText,
                    ).copyWith(letterSpacing: 1.5),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildField(
    BuildContext context,
    ContactHexLayoutResult layout,
    _VisibleRowRange initialVisibleRows,
    Map<int, UserModel> contactsById,
    Map<int, UserModel> ghostUsersById,
    TextStyle nodeTextStyle,
    ColorScheme colorScheme,
    bool disableAnimations,
  ) {
    return TweenAnimationBuilder<double>(
      duration: disableAnimations || _entranceCompleted
          ? Duration.zero
          : const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(begin: 0, end: 1),
      onEnd: () {
        if (_entranceCompleted) return;
        // Under reduce-motion the zero-duration tween completes during the
        // first build; setState here would be a during-build rebuild.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_entranceCompleted) {
            setState(() => _entranceCompleted = true);
          }
        });
      },
      builder: (context, entrance, _) {
        return Stack(
          clipBehavior: Clip.none,
          children: [
            // The route controller drives ONLY this painter, so only this
            // subtree may listen to it. It used to wrap the whole Stack:
            // every frame of the 480ms fill rebuilt every contact node -
            // Focus, Semantics, GestureDetector, ClipPath and Image apiece -
            // which is ~6k subtree builds for one tap on a 100-contact
            // board. The nodes only care about `_routeContactId`, which
            // changes twice per tap via setState.
            Positioned.fill(
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _routeController,
                      builder: (context, _) => CustomPaint(
                        painter: _HexFieldPainter(
                          layout: layout,
                          conversationIds: widget.conversationContactIds,
                          baseColor: colorScheme.onSurface,
                          accent: colorScheme.primary,
                          entranceProgress: entrance,
                          routeProgress: _routeContactId == null
                              ? 0
                              : Curves.easeInOut.transform(
                                  _routeController.value,
                                ),
                          routeIndex: _slotIndexOf(layout, _routeContactId),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _buildCore(context, layout, entrance),
            if (widget.pendingRequestCount > 0)
              _buildInboundPort(context, layout, entrance),
            for (final input in layout.inputs)
              _buildContactControl(
                context,
                contactsById[input.id]!,
                layout,
                disableAnimations,
              ),
            for (
              var slotIndex = layout.leadingSlots;
              slotIndex < layout.slots.length;
              slotIndex++
            )
              if (layout.isGhostSlot(slotIndex))
                _buildGhostSemantics(
                  ghostUsersById[layout
                      .fieldInputs[slotIndex - layout.leadingSlots]
                      .id]!,
                  layout,
                  slotIndex,
                ),
            ValueListenableBuilder<_VisibleRowRange>(
              valueListenable: _visibleRows,
              builder: (context, visibleRows, _) {
                final rows = visibleRows.isEmpty
                    ? initialVisibleRows
                    : visibleRows;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (
                      var slotIndex = layout.leadingSlots;
                      slotIndex < layout.slots.length;
                      slotIndex++
                    )
                      if (rows.contains(layout.rowOf[slotIndex]))
                        if (layout.isGhostSlot(slotIndex))
                          _buildGhostNode(
                            context,
                            ghostUsersById[layout
                                .fieldInputs[slotIndex - layout.leadingSlots]
                                .id]!,
                            layout,
                            slotIndex,
                            nodeTextStyle,
                            entrance,
                          )
                        else
                          _buildContactNode(
                            context,
                            contactsById[layout
                                .fieldInputs[slotIndex - layout.leadingSlots]
                                .id]!,
                            layout,
                            nodeTextStyle,
                            entrance,
                            disableAnimations,
                          ),
                  ],
                );
              },
            ),
            if (layout.leadingSlots > 0)
              _buildAddNode(context, layout, nodeTextStyle, entrance),
            if (layout.inputs.isEmpty) _buildEmptyCopy(context, layout),
          ],
        );
      },
    );
  }

  /// Only real contacts own routes; ghost terminals are deliberately absent.
  static int? _slotIndexOf(ContactHexLayoutResult layout, int? contactId) =>
      contactId == null ? null : layout.slotIndexForContactId(contactId);

  /// The resident, cheap control plane. Every real contact stays focusable
  /// and semantic even while its expensive visual hex is outside the viewport.
  Widget _buildContactControl(
    BuildContext context,
    UserModel contact,
    ContactHexLayoutResult layout,
    bool disableAnimations,
  ) {
    final slotIndex = layout.slotIndexForContactId(contact.id)!;
    final slot = layout.slots[slotIndex];
    final rect = layout.visualRectAt(slotIndex);
    final order = (slotIndex + 1).toDouble();

    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: FocusTraversalOrder(
        order: NumericFocusOrder(order),
        child: Focus(
          onFocusChange: (hasFocus) {
            final next = hasFocus ? contact.id : null;
            if (_focusedContactId != next) {
              setState(() => _focusedContactId = next);
            }
            if (hasFocus) _revealSlot(layout, slot);
          },
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final isActivation =
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space;
            if (!isActivation) return KeyEventResult.ignored;
            // Shift+Enter is the keyboard twin of the long press.
            if (HardwareKeyboard.instance.isShiftPressed &&
                _canOpenChat(contact)) {
              _openChat(contact);
              return KeyEventResult.handled;
            }
            _activateContact(contact, disableAnimations);
            return KeyEventResult.handled;
          },
          child: Semantics.fromProperties(
            container: true,
            excludeSemantics: true,
            properties: SemanticsProperties(
              button: true,
              label: contact.username,
              sortKey: OrdinalSortKey(order),
              onTap: () => _activateContact(contact, disableAnimations),
              onLongPress: _canOpenChat(contact)
                  ? () => _openChat(contact)
                  : null,
              hintOverrides: _canOpenChat(contact)
                  ? SemanticsHintOverrides(
                      onLongPressHint: widget.openChatSemanticHint,
                    )
                  : null,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  /// The leading "+" cell: an empty socket waiting for the next person.
  /// Dashed, avatar-less, and never counted as a contact. It heads the field
  /// rather than trailing it — at 27 contacts a trailing cell sat seven rows
  /// down and had to be scrolled to before anyone could be added.
  Widget _buildAddNode(
    BuildContext context,
    ContactHexLayoutResult layout,
    TextStyle labelStyle,
    double entrance,
  ) {
    final colors = FireplaceColors.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final slot = layout.slots.first;
    final rowCount = math.max(1, layout.rowCount);
    final rowT = (entrance * (rowCount + 1)).clamp(0.0, 1.0);
    final focused = _addSlotFocused;

    return Positioned(
      left: slot.dx - layout.pitch / 2,
      top: slot.dy - ContactHexLayout.hexRadius,
      width: layout.pitch,
      child: FocusTraversalOrder(
        order: const NumericFocusOrder(0.5),
        child: Focus(
          onFocusChange: (hasFocus) {
            if (_addSlotFocused != hasFocus) {
              setState(() => _addSlotFocused = hasFocus);
            }
            if (hasFocus) _revealSlot(layout, slot);
          },
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.space)) {
              widget.onAddContact?.call();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Semantics(
            container: true,
            button: true,
            label: widget.addSlotSemanticLabel ?? widget.addSlotLabel ?? '',
            sortKey: const OrdinalSortKey(0.5),
            onTap: () => widget.onAddContact?.call(),
            excludeSemantics: true,
            child: Opacity(
              opacity: rowT,
              child: Transform.scale(
                scale: 0.94 + rowT * 0.06,
                child: GestureDetector(
                  excludeFromSemantics: true,
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onAddContact?.call(),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: ContactHexLayout.hexWidth,
                        height: ContactHexLayout.hexRadius * 2,
                        child: CustomPaint(
                          painter: DashedHexPainter(
                            outline: focused
                                ? colorScheme.primary
                                : colorScheme.onSurface.withValues(
                                    alpha: 0.45,
                                  ),
                          ),
                          child: Center(
                            child: Icon(
                              Icons.add,
                              size: 22,
                              color: focused
                                  ? colorScheme.primary
                                  : colors.mutedText,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: ContactHexLayout.labelGap),
                      Text(
                        widget.addSlotLabel ?? '',
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: labelStyle.copyWith(color: colors.mutedText),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Rect _safeRect(Size size, EdgeInsets insets) {
    final left = insets.left;
    final top = insets.top;
    final right = math.max(left + 1, size.width - insets.right);
    final bottom = math.max(top + 1, size.height - insets.bottom);
    return Rect.fromLTRB(left, top, right, bottom);
  }
}
