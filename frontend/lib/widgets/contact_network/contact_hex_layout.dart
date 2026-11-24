part of '../contact_network_view.dart';

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
