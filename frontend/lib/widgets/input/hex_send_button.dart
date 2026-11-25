import 'package:flutter/material.dart';

import '../../theme/rpg_theme.dart';
import '../hex_avatar.dart';

/// The composer's text-send affordance: the app's own pointy-top hexagon
/// (the same [hexPath] the Chats avatars and the Contacts honeycomb use)
/// filled with an ember gradient derived from the theme accent.
///
/// PAINT ONLY — it carries no gesture recognizer and no semantics. The 48x48
/// `_ComposerTapSendOverlay` stacked above it owns the hit region, tooltip and
/// semantics; its doc comment says why it is a raw `Listener` (the mic beneath
/// is tap-to-toggle, not hold-to-record).
///
/// The glyph color comes from [RpgTheme.readableOn], never a hardcoded white:
/// three of the five themes have a pale accent (`cosmic` #8FD8FF, `blue`
/// #2AABEE, `dark` #5C9EAD) where a white glyph lands at 1.56:1 / 2.57:1 /
/// 3.02:1 and fails the 3:1 non-text contrast gate.
class HexSendButton extends StatelessWidget {
  const HexSendButton({super.key, this.height = 40});

  /// Hexagon height; width follows [kHexWidthRatio].
  final double height;

  @override
  Widget build(BuildContext context) {
    final accent = RpgTheme.primaryColor(context);
    return SizedBox(
      width: height * kHexWidthRatio,
      height: height,
      child: CustomPaint(
        painter: _HexEmberPainter(accent: accent),
        child: Center(
          child: Icon(
            Icons.send_rounded,
            size: height * 0.425,
            color: RpgTheme.readableOn(accent),
          ),
        ),
      ),
    );
  }
}

/// Coal fill: hotter at the top, banked at the bottom, with a lit rim.
class _HexEmberPainter extends CustomPainter {
  const _HexEmberPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.height / 2;

    canvas.drawPath(
      hexPath(center, radius),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(accent, Colors.white, 0.14)!,
            Color.lerp(accent, Colors.black, 0.18)!,
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      hexPath(center, radius - 0.75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Color.lerp(
          accent,
          Colors.white,
          0.45,
        )!.withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(covariant _HexEmberPainter oldDelegate) =>
      oldDelegate.accent != accent;
}
