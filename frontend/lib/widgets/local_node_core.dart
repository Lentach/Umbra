import 'package:flutter/material.dart';

import '../models/profile_photo.dart';
import '../theme/rpg_theme.dart';
import 'hex_avatar.dart';

/// The local node: the current user's avatar inside an instrument reticle.
///
/// ONE definition, shared by the Contacts honeycomb core and the Settings
/// console header. Those two are the same entity — you — so they must never
/// drift apart. The node is deliberately a CIRCLE while every contact is a
/// hexagon: that shape difference is what marks it as the local node, and it
/// is an owner call (2026-07-25). Do not hex it.
class LocalNodeCore extends StatelessWidget {
  const LocalNodeCore({
    super.key,
    required this.radius,
    required this.displayName,
    this.avatarUrl,
    this.avatar,
    this.focused = false,
    this.initialsFontSize = 16,
  });

  final double radius;
  final String displayName;
  final String? avatarUrl;
  final ProfilePhotoRef? avatar;

  /// Draws the keyboard-focus ring just outside the rim.
  final bool focused;

  final double initialsFontSize;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = FireplaceColors.of(context);

    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: CustomPaint(
        foregroundPainter: LocalNodeReticlePainter(
          outline: colorScheme.onSurface,
          accent: colorScheme.primary,
          focused: focused,
        ),
        child: ClipOval(
          child: HexAvatarSurface(
            imageUrl: avatarUrl,
            avatar: avatar,
            initials: hexInitials(displayName),
            surface: colors.convItemBg,
            initialsStyle: RpgTheme.bodyFont(
              fontSize: initialsFontSize,
              fontWeight: FontWeight.w800,
              color: colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Instrument reticle for the local node: the accent ring rides the
/// circumference and N/E/S/W ticks sit just inside it. No inner ring —
/// a second circle drawn over the avatar read as a border on the picture
/// (owner nit).
class LocalNodeReticlePainter extends CustomPainter {
  const LocalNodeReticlePainter({
    required this.outline,
    required this.accent,
    required this.focused,
  });

  final Color outline;
  final Color accent;
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final stroke = Paint()..style = PaintingStyle.stroke;

    stroke
      ..strokeWidth = 1.5
      ..color = accent;
    canvas.drawCircle(c, r - 0.75, stroke);

    // Tick LENGTH scales with the rim so the bigger Settings core does not
    // wear the same 4px nicks the 34px board core has. At r=34 this returns
    // 4.08px, i.e. the board's existing geometry to within a tenth of a pixel.
    final tickOuter = r - 1.5;
    final tickInner = tickOuter - (r * 0.12).clamp(4.0, 9.0);
    stroke
      ..strokeWidth = 1
      ..color = outline.withValues(alpha: 0.45);
    for (final d in const [
      Offset(0, -1),
      Offset(1, 0),
      Offset(0, 1),
      Offset(-1, 0),
    ]) {
      canvas.drawLine(c + d * tickInner, c + d * tickOuter, stroke);
    }

    if (focused) {
      stroke
        ..strokeWidth = 1
        ..color = accent;
      canvas.drawCircle(c, r + 3, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant LocalNodeReticlePainter oldDelegate) =>
      oldDelegate.outline != outline ||
      oldDelegate.accent != accent ||
      oldDelegate.focused != focused;
}
