part of '../contact_network_view.dart';

/// The node builders of [_ContactNetworkViewState] that never call
/// `setState`: the local core, the inbound port, the visual contact hex, the
/// ghost cell with its semantics, and the empty-board copy.
extension _ContactNetworkNodes on _ContactNetworkViewState {
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

  static String _initials(String value) => hexInitials(value);
}
