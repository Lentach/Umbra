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

@immutable
class _VisibleRowRange {
  const _VisibleRowRange(this.first, this.last);

  const _VisibleRowRange.empty() : first = 0, last = -1;

  final int first;
  final int last;

  bool contains(int row) => row >= first && row <= last;

  bool get isEmpty => last < first;

  @override
  bool operator ==(Object other) =>
      other is _VisibleRowRange && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(first, last);
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

  /// Last row whose avatars are allowed to fetch: everything on screen plus
  /// one row of lookahead, so a face decodes just before it scrolls in.
  int _visibleThroughRow(ContactHexLayoutResult layout, double fallbackHeight) {
    if (layout.slots.isEmpty) return 0;
    final attached = _scrollController.hasClients;
    final offset = attached ? _scrollController.position.pixels : 0.0;
    final viewport = attached
        ? _scrollController.position.viewportDimension
        : fallbackHeight;
    final bottom = offset + viewport + layout.rowPitch;
    final rows = ((bottom - layout.slots.first.dy) / layout.rowPitch).ceil();
    return rows.clamp(0, math.max(0, layout.rowCount - 1));
  }

  void _armVisibleRows() {
    final layout = _lastLayout;
    if (layout == null) return;
    final next = _visibleThroughRow(layout, 0);
    if (next > _armedThroughRow.value) _armedThroughRow.value = next;
  }

  /// Scrolling is intentionally a notifier-only path: viewport changes mount
  /// and unmount just the nearby visual rows, while the full focus/semantics
  /// control layer stays stable for traversal and assistive technology.
  void _onScroll() {
    _armVisibleRows();
    _syncVisibleRows();
  }

  _VisibleRowRange _visibleRowRange(
    ContactHexLayoutResult layout,
    double fallbackHeight,
  ) {
    if (layout.slots.isEmpty) return const _VisibleRowRange.empty();
    final attached = _scrollController.hasClients;
    final offset = attached ? _scrollController.position.pixels : 0.0;
    final viewport = attached
        ? _scrollController.position.viewportDimension
        : fallbackHeight;
    final firstRow =
        (((offset - layout.slots.first.dy) / layout.rowPitch).floor() - 1)
            .clamp(0, layout.rowCount - 1)
            .toInt();
    // Two rows of visual overscan prevent a blank edge during a fast fling.
    // Avatar arming keeps its tighter one-row lookahead, so the outermost
    // mounted row still proves that images remain lazy.
    final lastRow =
        (((offset + viewport - layout.slots.first.dy) / layout.rowPitch)
                    .ceil() +
                2)
            .clamp(firstRow, layout.rowCount - 1)
            .toInt();
    return _VisibleRowRange(firstRow, lastRow);
  }

  void _syncVisibleRows() {
    final layout = _lastLayout;
    if (layout == null) return;
    final next = _visibleRowRange(layout, _lastViewportHeight);
    if (next != _visibleRows.value) _visibleRows.value = next;
  }

  void _scheduleVisibleRowsSync() {
    if (_visibleRowsSyncScheduled) return;
    _visibleRowsSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibleRowsSyncScheduled = false;
      if (mounted) _syncVisibleRows();
    });
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

  Widget _buildCore(
    BuildContext context,
    ContactHexLayoutResult layout,
    double entrance,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    const radius = ContactHexLayout.coreRadius;
    final captionStyle = RpgTheme.bodyFont(
      fontSize: 10,
      fontWeight: FontWeight.w700,
      color: colorScheme.onSurface,
    ).copyWith(letterSpacing: 1.5);

    // Full-width band, NOT a box hugging the avatar: the caption is wider
    // than the reticle, and a shrink-wrapped Positioned let the Column's
    // intrinsic width (= caption width) shove the avatar right by
    // (captionWidth - 2*radius)/2. That desynced the drawn core from
    // `layout.coreCenter`, which every feed line and route is aimed at, so
    // the leftmost first-row wires visibly stopped short of the rim.
    return Positioned(
      left: 0,
      width: layout.coreCenter.dx * 2,
      top: layout.coreCenter.dy - radius,
      child: Semantics(
        container: true,
        label: widget.localNodeSemanticLabel,
        sortKey: const OrdinalSortKey(0),
        excludeSemantics: true,
        child: Opacity(
          opacity: entrance,
          child: Column(
            children: [
              LocalNodeCore(
                radius: radius,
                displayName: widget.localNodeLabel,
                avatarUrl: widget.localNodeAvatarUrl,
                avatar: widget.localNodeAvatar,
              ),
              const SizedBox(height: 6),
              Text(
                widget.localNodeCaption,
                textAlign: TextAlign.center,
                style: captionStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Inbound port: pending friend requests docking into the top of the core.
  /// Rendered only when someone is actually waiting — the count is real.
  Widget _buildInboundPort(
    BuildContext context,
    ContactHexLayoutResult layout,
    double entrance,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = FireplaceColors.of(context);
    final count = widget.pendingRequestCount;
    final label = count > 99 ? '99+' : '$count';

    return Positioned(
      left: layout.coreCenter.dx - 46,
      top: math.max(0, layout.coreCenter.dy - ContactHexLayout.coreRadius - 34),
      width: 92,
      child: Semantics(
        container: true,
        button: true,
        label: widget.pendingRequestsSemanticLabel ?? label,
        sortKey: const OrdinalSortKey(-1),
        excludeSemantics: true,
        child: Opacity(
          opacity: entrance,
          child: Center(
            child: GestureDetector(
              excludeFromSemantics: true,
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onPendingRequestsTap?.call(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colors.convItemBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colorScheme.primary),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.south, size: 12, color: colorScheme.primary),
                        const SizedBox(width: 4),
                        Text(
                          label,
                          style: RpgTheme.bodyFont(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Stub docking into the reticle rim.
                  Container(
                    width: 1.5,
                    height: 12,
                    color: colorScheme.primary.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

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

  /// The viewport-only visual plane. Its avatar leaf keeps the original
  /// high-water arming gate; scrolling it never rebuilds the control plane.
  Widget _buildContactNode(
    BuildContext context,
    UserModel contact,
    ContactHexLayoutResult layout,
    TextStyle labelStyle,
    double entrance,
    bool disableAnimations,
  ) {
    final colors = FireplaceColors.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final slotIndex = layout.slotIndexForContactId(contact.id)!;
    final slot = layout.slots[slotIndex];
    final focused = _focusedContactId == contact.id;
    final routing = _routeContactId == contact.id;
    // Row-staggered entrance: rows materialize top-down within the single
    // 280ms envelope (motion budget), never per-item unbounded.
    final rowCount = math.max(1, layout.rowCount);
    final row = layout.rowOf[slotIndex];
    final rowT = ((entrance * (rowCount + 1)) - row).clamp(0.0, 1.0);

    return Positioned(
      left: slot.dx - layout.pitch / 2,
      top: slot.dy - ContactHexLayout.hexRadius,
      width: layout.pitch,
      child: ExcludeSemantics(
        child: Opacity(
          opacity: rowT,
          child: Transform.scale(
            scale: 0.94 + rowT * 0.06,
            child: GestureDetector(
              key: ValueKey('contact-node-${contact.id}'),
              excludeFromSemantics: true,
              behavior: HitTestBehavior.opaque,
              onTap: () => _activateContact(contact, disableAnimations),
              onLongPress: _canOpenChat(contact)
                  ? () => _openChat(contact)
                  : null,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: ContactHexLayout.hexWidth,
                    height: ContactHexLayout.hexRadius * 2,
                    child: CustomPaint(
                      foregroundPainter: _HexChromePainter(
                        outline: colorScheme.onSurface,
                        accent: colorScheme.primary,
                        focused: focused || routing,
                      ),
                      // Only rows that have been on screen are allowed to
                      // fetch. The listener is HERE, around the avatar leaf,
                      // so crossing a row rebuilds faces and not the resident
                      // Focus/Semantics control plane.
                      child: ClipPath(
                        clipper: const HexClipper(),
                        child: ValueListenableBuilder<int>(
                          valueListenable: _armedThroughRow,
                          builder: (context, armed, _) {
                            final shown = row <= math.max(armed, _armedFloor);
                            return HexAvatarSurface(
                              imageUrl: shown ? contact.profilePictureUrl : null,
                              avatar: shown ? contact.avatar : null,
                              initials: _initials(contact.username),
                              surface: colors.convItemBg,
                              initialsStyle: RpgTheme.bodyFont(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: colorScheme.onSurface,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: ContactHexLayout.labelGap),
                  Text(
                    contact.username,
                    softWrap: false,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: labelStyle,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A sent invitation reserves a terminal without pretending its recipient
  /// is already a contact: no avatar, no wire, no focus target, and no chat.
  Widget _buildGhostNode(
    BuildContext context,
    UserModel invitee,
    ContactHexLayoutResult layout,
    int slotIndex,
    TextStyle labelStyle,
    double entrance,
  ) {
    final colors = FireplaceColors.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final slot = layout.slots[slotIndex];
    final rowCount = math.max(1, layout.rowCount);
    final row = layout.rowOf[slotIndex];
    final rowT = ((entrance * (rowCount + 1)) - row).clamp(0.0, 1.0);

    return Positioned(
      left: slot.dx - layout.pitch / 2,
      top: slot.dy - ContactHexLayout.hexRadius,
      width: layout.pitch,
      child: ExcludeSemantics(
        child: Opacity(
          opacity: rowT,
          child: Transform.scale(
            scale: 0.94 + rowT * 0.06,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: ContactHexLayout.hexWidth,
                  height: ContactHexLayout.hexRadius * 2,
                  child: CustomPaint(
                    painter: DashedHexPainter(
                      // Longer 8px runs distinguish a pending ghost from the
                      // 5px "+" socket.
                      outline: colorScheme.onSurface.withValues(alpha: 0.32),
                      strokeWidth: 1.2,
                      dashOn: 8,
                      fill: colors.convItemBg,
                    ),
                    child: Center(
                      child: Icon(
                        Icons.send_outlined,
                        size: 18,
                        color: colors.mutedText.withValues(alpha: 0.72),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: ContactHexLayout.labelGap),
                Text(
                  invitee.username,
                  softWrap: false,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: labelStyle.copyWith(
                    color: colors.mutedText.withValues(alpha: 0.78),
                  ),
                ),
                // The outbound glyph alone reads as decoration; the state has
                // to be a word. Accent, because it is the one thing in this
                // cell the user is waiting on (>=4.7:1 on every theme field).
                if (widget.pendingInviteLabel != null)
                  Text(
                    widget.pendingInviteLabel!,
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
          ),
        ),
      ),
    );
  }

  /// Ghosts remain discoverable to assistive technology but deliberately
  /// expose no activation action: a pending invite cannot open a chat.
  Widget _buildGhostSemantics(
    UserModel invitee,
    ContactHexLayoutResult layout,
    int slotIndex,
  ) {
    final rect = layout.visualRectAt(slotIndex);
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: Semantics.fromProperties(
        container: true,
        excludeSemantics: true,
        properties: SemanticsProperties(
          label:
              widget.pendingInviteSemanticLabel?.call(invitee.username) ??
              invitee.username,
          sortKey: OrdinalSortKey((slotIndex + 1).toDouble()),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }

  /// Scrolls a keyboard-focused slot's full visual rect into the viewport.
  void _revealSlot(ContactHexLayoutResult layout, Offset slot) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final top = slot.dy - ContactHexLayout.hexRadius - 16;
    final bottom =
        slot.dy + ContactHexLayout.hexRadius + layout.labelHeight + 24;
    final viewTop = position.pixels;
    final viewBottom = viewTop + position.viewportDimension;
    double? target;
    if (top < viewTop) {
      target = top;
    } else if (bottom > viewBottom) {
      target = bottom - position.viewportDimension;
    }
    if (target != null) {
      position.moveTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    }
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

  Widget _buildEmptyCopy(BuildContext context, ContactHexLayoutResult layout) {
    final colors = FireplaceColors.of(context);
    // With an add cell on the board the copy sits under it, not on top.
    final top = layout.slots.isEmpty
        ? layout.coreCenter.dy + ContactHexLayout.coreRadius + 52
        : layout.slots.last.dy +
              ContactHexLayout.hexRadius +
              ContactHexLayout.labelGap +
              layout.labelHeight +
              24;
    return Positioned(
      left: 24,
      right: 24,
      top: top,
      child: Column(
        children: [
          Text(
            widget.emptyTitle,
            textAlign: TextAlign.center,
            style: RpgTheme.bodyFont(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.emptyMessage,
            textAlign: TextAlign.center,
            style: RpgTheme.bodyFont(fontSize: 13, color: colors.mutedText),
          ),
        ],
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

  static String _initials(String value) => hexInitials(value);
}

/// Sorting input to the pure hex-field algorithm.
@immutable
class ContactHexLayoutInput {
  const ContactHexLayoutInput({required this.id, required this.displayName});

  final int id;
  final String displayName;
}

/// Geometry is immutable; [traces] is a memo of it, built on first read.
class ContactHexLayoutResult {
  ContactHexLayoutResult({
    required this.inputs,
    required this.fieldInputs,
    required this.ghostIds,
    required Map<int, int> contactSlotById,
    required this.slots,
    required this.rowOf,
    required this.rowCount,
    this.leadingSlots = 0,
    required this.columnsWide,
    required this.pitch,
    required this.labelHeight,
    required this.coreCenter,
    required this.fieldHeight,
  }) : _contactSlotById = contactSlotById;

  /// Real contacts in natural-sort order. They deliberately exclude ghost
  /// invitees, so callers' node counts and contact semantics stay honest.
  final List<ContactHexLayoutInput> inputs;

  /// Every occupied person terminal in spatial order: real contacts plus
  /// pending outbound invitees. [slots] follows this list after any leading
  /// field-owned cells.
  final List<ContactHexLayoutInput> fieldInputs;

  /// Ids in [fieldInputs] that are ghost invitees, never relationships.
  final Set<int> ghostIds;

  /// Hex centers: [leadingSlots] field-owned cells, then one per
  /// [fieldInputs] entry.
  final List<Offset> slots;

  /// Row index per slot, parallel to [slots].
  final List<int> rowOf;

  final int rowCount;

  /// Slots at the head of the field that belong to the field, not to a
  /// person (the "+" add cell).
  final int leadingSlots;

  /// Column count of a full wide row (4 on phones, up to 8 on desktop).
  final int columnsWide;
  final double pitch;
  final double labelHeight;
  final Offset coreCenter;
  final double fieldHeight;

  final Map<int, int> _contactSlotById;

  Path? _traces;

  /// Every contact's dormant trace as ONE path, built on first read and
  /// reused for the life of this layout.
  ///
  /// One path, one stroke, on purpose. Drawing 27 separate paths meant
  /// overlapping segments composited 27 times, so the bundle under the core
  /// darkened to near-opaque while the same stroke stayed faint lower down.
  /// A single draw unions the coverage: uniform weight everywhere. It also
  /// keeps `routePath` off the paint path — it sorts peers to fan the rim,
  /// and the 480ms tap fill repaints every frame.
  Path get traces {
    final cached = _traces;
    if (cached != null) return cached;
    final combined = Path();
    for (var i = leadingSlots; i < slots.length; i++) {
      if (!isContactSlot(i)) continue;
      combined.addPath(ContactHexLayout.routePath(this, i), Offset.zero);
    }
    return _traces = combined;
  }

  bool isGhostSlot(int slotIndex) {
    final fieldIndex = slotIndex - leadingSlots;
    return fieldIndex >= 0 &&
        fieldIndex < fieldInputs.length &&
        ghostIds.contains(fieldInputs[fieldIndex].id);
  }

  bool isContactSlot(int slotIndex) {
    final fieldIndex = slotIndex - leadingSlots;
    return fieldIndex >= 0 &&
        fieldIndex < fieldInputs.length &&
        !ghostIds.contains(fieldInputs[fieldIndex].id);
  }

  int? slotIndexForContactId(int contactId) => _contactSlotById[contactId];

  /// Vertical distance between row centres — the same value `resolve` laid
  /// the rows out on.
  double get rowPitch =>
      ContactHexLayout.hexRadius * 2 +
      ContactHexLayout.labelGap +
      labelHeight +
      9;

  /// Full visual rect (hex + label) of one slot, for tests and reveal math.
  Rect visualRectAt(int index) {
    final slot = slots[index];
    return Rect.fromLTWH(
      slot.dx - pitch / 2,
      slot.dy - ContactHexLayout.hexRadius,
      pitch,
      ContactHexLayout.hexRadius * 2 + ContactHexLayout.labelGap + labelHeight,
    );
  }
}

/// Pure, deterministic geometry for the honeycomb field. Same contacts +
/// width + label height always produce identical slots.
class ContactHexLayout {
  static const double hexRadius = 30; // point-to-point 60
  static const double labelGap = 5;
  static const double coreRadius = 34;
  static const double maxPitch = 92;

  /// Flat-to-flat hex width for a pointy-top hexagon.
  static double get hexWidth => hexRadius * math.sqrt(3);

  static ContactHexLayoutResult resolve({
    required List<ContactHexLayoutInput> contacts,
    List<ContactHexLayoutInput> ghosts = const <ContactHexLayoutInput>[],
    required double width,
    required double labelHeight,
    // Cells at the HEAD of the field that the field owns rather than a
    // contact (the "+" add slot). Reserved here so it lands on the same
    // lattice, never faked as a contact — [inputs] and the announced node
    // count stay honest.
    int leadingSlots = 0,
  }) {
    final orderedContacts = sortContacts(contacts);
    final contactIds = <int>{for (final contact in orderedContacts) contact.id};
    final ghostIds = <int>{};
    final uniqueGhosts = <ContactHexLayoutInput>[];
    for (final ghost in ghosts) {
      if (contactIds.contains(ghost.id)) continue;
      if (ghostIds.add(ghost.id)) uniqueGhosts.add(ghost);
    }
    final fieldInputs = sortContacts([...orderedContacts, ...uniqueGhosts]);
    final contactSlotById = <int, int>{
      for (var index = 0; index < fieldInputs.length; index++)
        if (!ghostIds.contains(fieldInputs[index].id))
          fieldInputs[index].id: index + leadingSlots,
    };
    final halfUsable = math.max(hexWidth, width / 2 - hexWidth);
    // Adaptive width: phones run 4-3 rows; wider viewports earn more
    // columns (up to 8-7) at the ideal pitch instead of a skinny strip.
    final halfSteps = (halfUsable / maxPitch + 0.5).floor().clamp(2, 4);
    final pitch = math
        .min(maxPitch, halfUsable / (halfSteps - 0.5))
        .clamp(hexWidth + 6, maxPitch)
        .toDouble();
    final wideCapacity = halfSteps * 2;
    // 48, not 64: the safe rect already begins below the header capsule, so
    // a 64px centre left ~30px of dead air above the reticle. 48 leaves
    // ~14px under the header and lifts the whole field with it, which buys
    // roughly one more visible row before scrolling.
    final coreCenter = Offset(width / 2, 48);
    final rowPitch = hexRadius * 2 + labelGap + labelHeight + 9;

    final slots = <Offset>[];
    final rowOf = <int>[];
    // Core radius + caption band + first-row clearance.
    var y = coreCenter.dy + coreRadius + 28 + hexRadius;
    var remaining = fieldInputs.length + leadingSlots;
    var wideRow = true;
    var rowIndex = 0;
    while (remaining > 0) {
      final capacity = wideRow ? wideCapacity : wideCapacity - 1;
      final take = math.min(remaining, capacity);
      final offsets = <double>[];
      // A full row spans symmetric lattice offsets; the partial last row
      // centers itself on the same 1-pitch grid: balanced at any count.
      final start = -(take - 1) / 2;
      for (var i = 0; i < take; i++) {
        offsets.add(start + i);
      }
      for (final f in offsets) {
        slots.add(Offset(coreCenter.dx + f * pitch, y));
        rowOf.add(rowIndex);
      }
      remaining -= take;
      y += rowPitch;
      wideRow = !wideRow;
      rowIndex++;
    }
    final fieldHeight = slots.isEmpty
        ? coreCenter.dy + coreRadius + 120
        : slots.last.dy + hexRadius + labelGap + labelHeight + 40;

    return ContactHexLayoutResult(
      inputs: orderedContacts,
      fieldInputs: fieldInputs,
      ghostIds: Set<int>.unmodifiable(ghostIds),
      contactSlotById: Map<int, int>.unmodifiable(contactSlotById),
      slots: slots,
      rowOf: rowOf,
      rowCount: rowIndex,
      leadingSlots: leadingSlots,
      columnsWide: wideCapacity,
      pitch: pitch,
      labelHeight: labelHeight,
      coreCenter: coreCenter,
      fieldHeight: fieldHeight,
    );
  }

  /// Route from the core rim to slot [index]'s socket pad, weaving through
  /// the lattice gap nearest the straight path in every intermediate row.
  static Path routePath(ContactHexLayoutResult layout, int index) {
    final slot = layout.slots[index];
    final pad = Offset(slot.dx, slot.dy - hexRadius - 9);
    final core = layout.coreCenter;
    final targetRow = layout.rowOf[index];

    // First-row nodes fill along their existing feed line: rim -> bend -> pad.
    if (targetRow == 0) {
      final dir = Offset(pad.dx - core.dx, 52);
      final rim = core + dir / dir.distance * coreRadius;
      return Path()
        ..moveTo(rim.dx, rim.dy)
        ..lineTo(pad.dx, pad.dy - 16)
        ..lineTo(pad.dx, pad.dy);
    }

    // A pointy-top honeycomb has NO straight vertical channel and no clean
    // long diagonal either: the gaps of a wide row sit exactly over the
    // CENTRES of the narrow row below it, so any monotone diagonal is inside
    // a hex every other row. That is what sliced the corners off the
    // first-row terminals — the feed did its sideways travel across the row
    // plane, where there is nothing but hex.
    //
    // So the route steps: it descends INSIDE a gap corridor (pitch/2 from
    // either neighbouring centre, ~17px of clearance past the hex's widest
    // point) and does all of its sideways travel in the empty band BETWEEN
    // rows. No horizontal rails — each band leg is a short slant of one
    // half-pitch, the same diagonal language the field always had.
    //
    // The fan off the rim is per CORRIDOR, not per contact. Row 0 has at
    // most `columnsWide + 1` gaps, so the bundle is bounded no matter how
    // many contacts feed through it — which is what made the old
    // per-contact fan smear into a wedge at 100 nodes.
    final sideSign = slot.dx >= core.dx ? 1.0 : -1.0;
    final route = Path();
    var started = false;

    for (var row = 0; row < targetRow; row++) {
      final rowXs = <double>[];
      double? rowY;
      for (var j = 0; j < layout.slots.length; j++) {
        if (layout.rowOf[j] == row) {
          rowXs.add(layout.slots[j].dx);
          rowY = layout.slots[j].dy;
        }
      }
      if (rowY == null || rowXs.isEmpty) continue;
      rowXs.sort();
      final t = (rowY - core.dy) / math.max(1, slot.dy - core.dy);
      final idealX = core.dx + (slot.dx - core.dx) * t;
      final gaps = <double>[
        rowXs.first - layout.pitch / 2,
        for (var g = 0; g < rowXs.length - 1; g++)
          (rowXs[g] + rowXs[g + 1]) / 2,
        rowXs.last + layout.pitch / 2,
      ];
      final gapX = _nearestGap(gaps, idealX, core.dx, sideSign);
      final top = rowY - hexRadius;
      if (!started) {
        final dir = Offset(gapX - core.dx, top - core.dy);
        final rim = core + dir / dir.distance * coreRadius;
        route.moveTo(rim.dx, rim.dy);
        started = true;
      }
      route
        ..lineTo(gapX, top)
        ..lineTo(gapX, rowY + hexRadius);
    }
    // Last leg: out of the final corridor and into the pad, entirely inside
    // the band above the target row. The guard is not decorative — a path
    // whose first verb is `lineTo` implicitly starts at (0,0) and would draw
    // a stray wire out of the board's top-left corner.
    if (!started) {
      final dir = Offset(pad.dx - core.dx, pad.dy - core.dy);
      final rim = core + dir / dir.distance * coreRadius;
      route.moveTo(rim.dx, rim.dy);
    }
    route.lineTo(pad.dx, pad.dy);
    return route;
  }

  /// Gap nearest [idealX], with ties broken OUTWARD from [coreX] on the
  /// contact's own side. Without the tie-break both members of a mirrored
  /// pair pick the same gap and the field stops being symmetric.
  static double _nearestGap(
    List<double> gaps,
    double idealX,
    double coreX,
    double sideSign,
  ) {
    var best = double.infinity;
    for (final gap in gaps) {
      final d = (gap - idealX).abs();
      if (d < best) best = d;
    }
    var chosen = gaps.first;
    var bestOutward = double.negativeInfinity;
    for (final gap in gaps) {
      if ((gap - idealX).abs() > best + 0.01) continue;
      final outward = (gap - coreX) * sideSign;
      if (outward > bestOutward) {
        bestOutward = outward;
        chosen = gap;
      }
    }
    return chosen;
  }

  /// Natural sort: same prefix -> smaller number first (ziomek3, ziomek50).
  static int compareByDisplayName(
    ContactHexLayoutInput a,
    ContactHexLayoutInput b,
  ) {
    final aMatch = RegExp(r'^(.+?)(\d+)$').firstMatch(a.displayName);
    final bMatch = RegExp(r'^(.+?)(\d+)$').firstMatch(b.displayName);
    final aPrefix = (aMatch?.group(1) ?? a.displayName).toLowerCase();
    final bPrefix = (bMatch?.group(1) ?? b.displayName).toLowerCase();
    final aNumber = aMatch == null ? 0 : int.tryParse(aMatch.group(2)!) ?? 0;
    final bNumber = bMatch == null ? 0 : int.tryParse(bMatch.group(2)!) ?? 0;
    final prefixCompare = aPrefix.compareTo(bPrefix);
    if (prefixCompare != 0) return prefixCompare;
    return aNumber.compareTo(bNumber);
  }

  static List<ContactHexLayoutInput> sortContacts(
    List<ContactHexLayoutInput> contacts,
  ) {
    final sorted = List<ContactHexLayoutInput>.of(contacts)
      ..sort(compareByDisplayName);
    return sorted;
  }
}

/// Hex terminal chrome: ONE outline plus the focus halo. Drawn in the
/// field's ink (`onSurface`), not `convItemBorder` — that token is a
/// near-invisible hairline on the light themes (#E8E3DC on #FAF8F5) and
/// left every empty cell ghosted while the wires beside it read fine.
class _HexChromePainter extends CustomPainter {
  const _HexChromePainter({
    required this.outline,
    required this.accent,
    required this.focused,
  });

  final Color outline;
  final Color accent;
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.height / 2 - 0.75;
    // Single border by owner call: the old inner hairline at r-3 read as a
    // double edge drawn on top of the avatar.
    canvas.drawPath(
      hexPath(c, r),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = outline.withValues(alpha: 0.42),
    );
    if (focused) {
      canvas.drawPath(
        hexPath(c, r + 3),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = accent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HexChromePainter oldDelegate) =>
      oldDelegate.outline != outline ||
      oldDelegate.accent != accent ||
      oldDelegate.focused != focused;
}

/// Screen-fixed corner brackets framing the field viewport.
class _NetworkFramePainter extends CustomPainter {
  const _NetworkFramePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 10.0;
    const arm = 14.0;
    final p = Paint()
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.35);
    for (final c in <(Offset, Offset, Offset)>[
      (Offset(inset, inset), const Offset(1, 0), const Offset(0, 1)),
      (
        Offset(size.width - inset, inset),
        const Offset(-1, 0),
        const Offset(0, 1),
      ),
      (
        Offset(inset, size.height - inset),
        const Offset(1, 0),
        const Offset(0, -1),
      ),
      (
        Offset(size.width - inset, size.height - inset),
        const Offset(-1, 0),
        const Offset(0, -1),
      ),
    ]) {
      canvas.drawLine(c.$1, c.$1 + c.$2 * arm, p);
      canvas.drawLine(c.$1, c.$1 + c.$3 * arm, p);
    }
  }

  @override
  bool shouldRepaint(covariant _NetworkFramePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// The field's ambient and wiring layer: faint unoccupied lattice points,
/// per-node socket stubs (doubled = conversation), the core's visible feed
/// to the first row, and the tap/focus route fill.
class _HexFieldPainter extends CustomPainter {
  const _HexFieldPainter({
    required this.layout,
    required this.conversationIds,
    required this.baseColor,
    required this.accent,
    required this.entranceProgress,
    required this.routeProgress,
    required this.routeIndex,
  });

  final ContactHexLayoutResult layout;
  final Set<int> conversationIds;
  final Color baseColor;
  final Color accent;
  final double entranceProgress;
  final double routeProgress;
  final int? routeIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final core = layout.coreCenter;

    // Faint lattice points continuing past the populated rows: the machine
    // frame has free sockets (chrome, not fake contacts).
    final dotPaint = Paint()..color = baseColor.withValues(alpha: 0.16);
    if (layout.slots.isNotEmpty) {
      final rowPitch = layout.rowPitch;
      var wideRow = layout.rowCount.isEven;
      for (
        var y = layout.slots.last.dy + rowPitch;
        y < size.height - 24;
        y += rowPitch
      ) {
        final count = wideRow ? layout.columnsWide : layout.columnsWide - 1;
        final offsets = [for (var i = 0; i < count; i++) -(count - 1) / 2 + i];
        for (final f in offsets) {
          canvas.drawCircle(
            Offset(core.dx + f * layout.pitch, y),
            1.2,
            dotPaint,
          );
        }
        wideRow = !wideRow;
      }
    }

    // Per-node sockets; the pads brighten with the entrance sweep row by row.
    final stubPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.square;
    final padPaint = Paint();
    final rowCount = math.max(1, layout.rowCount);
    for (var i = 0; i < layout.slots.length; i++) {
      final slot = layout.slots[i];
      final row = layout.rowOf[i];
      final rowT = ((entranceProgress * (rowCount + 1)) - row).clamp(0.0, 1.0);
      if (rowT <= 0) continue;
      // Add and ghost cells occupy a socket but never own a conversation.
      final fieldIndex = i - layout.leadingSlots;
      final hasConv =
          layout.isContactSlot(i) &&
          conversationIds.contains(layout.fieldInputs[fieldIndex].id);
      stubPaint.color = baseColor.withValues(alpha: 0.38 * rowT);
      padPaint.color = baseColor.withValues(alpha: 0.60 * rowT);
      final top = Offset(slot.dx, slot.dy - ContactHexLayout.hexRadius);
      void stub(double dx) {
        final base = Offset(top.dx + dx, top.dy - 1);
        final tip = Offset(top.dx + dx, top.dy - 9);
        canvas.drawLine(base, tip, stubPaint);
        canvas.drawRect(
          Rect.fromCenter(center: tip, width: 3, height: 3),
          padPaint,
        );
      }

      if (hasConv) {
        stub(-2.2);
        stub(2.2);
      } else {
        stub(0);
      }
    }

    // Every relationship is drawn, dormant, all the time: the board is a
    // wired board, not four wired nodes and the rest floating. One trace per
    // real contact - no bus, no shared rail - so the picture still cannot
    // lie about who you know. Tapping does not conjure a wire, it energises
    // the one already there.
    //
    // ONE path, ONE stroke. That is what keeps it thin: shared runs near the
    // core overlap heavily, and drawing each trace separately composited
    // them 13-deep into a fat bundle while the same stroke stayed faint
    // further down. A single draw unions the coverage, so the picture has
    // uniform weight at 3 contacts and at 300.
    if (entranceProgress > 0) {
      canvas.drawPath(
        layout.traces,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9
          ..color = baseColor.withValues(alpha: 0.17 * entranceProgress),
      );
    }

    // Tap/focus route: the connection fills with the accent color from the
    // contact's socket up to the local core.
    final index = routeIndex;
    if (index != null && index < layout.slots.length && routeProgress > 0) {
      final route = ContactHexLayout.routePath(layout, index);
      final metrics = route.computeMetrics().toList(growable: false);
      if (metrics.isNotEmpty) {
        var total = 0.0;
        for (final m in metrics) {
          total += m.length;
        }
        // The visible strip grows from the node's pad toward the core: the
        // path runs core->pad, so we reveal its tail first.
        var remainingStart = total * (1 - routeProgress);
        final routePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.square
          ..color = accent.withValues(alpha: 0.9);
        for (final m in metrics) {
          if (remainingStart >= m.length) {
            remainingStart -= m.length;
            continue;
          }
          canvas.drawPath(m.extractPath(remainingStart, m.length), routePaint);
          remainingStart = 0;
        }
        // Bright head where the strip currently is: makes the travel
        // direction (node -> core) readable at a glance.
        if (routeProgress < 1) {
          var headOffset = total * (1 - routeProgress);
          for (final m in metrics) {
            if (headOffset > m.length) {
              headOffset -= m.length;
              continue;
            }
            final head = m.getTangentForOffset(headOffset)?.position;
            if (head != null) {
              canvas.drawCircle(head, 2.6, Paint()..color = accent);
            }
            break;
          }
        }
        final slot = layout.slots[index];
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset(slot.dx, slot.dy - ContactHexLayout.hexRadius - 9),
            width: 3.5,
            height: 3.5,
          ),
          Paint()..color = accent,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HexFieldPainter oldDelegate) =>
      oldDelegate.layout != layout ||
      oldDelegate.baseColor != baseColor ||
      oldDelegate.accent != accent ||
      oldDelegate.entranceProgress != entranceProgress ||
      oldDelegate.routeProgress != routeProgress ||
      oldDelegate.routeIndex != routeIndex;
}
