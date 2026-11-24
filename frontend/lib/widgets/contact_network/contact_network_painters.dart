part of '../contact_network_view.dart';

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
