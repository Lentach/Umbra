import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'hex_avatar.dart' show kHexWidthRatio;
import '../models/message_model.dart';
import '../utils/message_expiry.dart';

/// Fireplace hex ember for read-based disappearing messages.
///
/// A pointy-top hexagon (the avatar/honeycomb silhouette): a dim continuous
/// frame keeps the shape readable at 12px, six edge bars burn out clockwise
/// from the top vertex, and a coal core dims with the time left.
///
/// [preRead] = TTL frozen, countdown not started: bright frame,
/// full core, no bars. Otherwise [progress] is the time left, 1 → 0.
class HearthFadeHexPainter extends CustomPainter {
  final Color color;
  final double progress;
  final bool preRead;

  /// Stroke width of the frame AND the lit bars (equal, so a lit bar exactly
  /// recolours its edge instead of overshooting it). Corner gaps and the core
  /// scale with it, so one painter serves 12px and the 72px hero.
  final double strokeWidth;

  const HearthFadeHexPainter({
    required this.color,
    this.progress = 0,
    this.preRead = false,
    this.strokeWidth = 1.5,
  });

  /// Pointy-top hexagon vertices, clockwise from the top.
  static List<Offset> _hexVertices(Offset center, double radius) => [
    for (var i = 0; i < 6; i++)
      center +
          Offset(
            math.cos(-math.pi / 2 + i * math.pi / 3),
            math.sin(-math.pi / 2 + i * math.pi / 3),
          ) *
              radius,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Largest pointy-top hexagon the box holds, centred. The inset covers the
    // miter tip at a 120° corner (0.58 × stroke) so nothing clips.
    final height = math.min(size.height, size.width / kHexWidthRatio);
    final center = Offset(size.width / 2, size.height / 2);
    final radius = height / 2 - strokeWidth * 0.6;
    final vertices = _hexVertices(center, radius);
    final clamped = progress.clamp(0.0, 1.0);

    canvas.drawPath(
      Path()..addPolygon(vertices, true),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = color.withValues(alpha: preRead ? 0.55 : 0.24),
    );

    if (!preRead) {
      final bar = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt
        ..color = color;
      // A regular hexagon's edge equals its circumradius; the gap sits at
      // each corner so the frame shows through and the corners stay sharp.
      final gap = strokeWidth * 0.3 / radius;
      for (var k = 0; k < 6; k++) {
        final lit = math.min(1 - gap, (clamped * 6 - k).clamp(0.0, 1.0));
        if (lit <= gap) continue;
        final from = vertices[k];
        final to = vertices[(k + 1) % 6];
        canvas.drawLine(
          Offset.lerp(from, to, gap)!,
          Offset.lerp(from, to, lit)!,
          bar,
        );
      }
    }

    canvas.drawPath(
      Path()..addPolygon(_hexVertices(center, radius * 0.42), true),
      Paint()
        ..color = color.withValues(
          alpha: preRead ? 0.9 : 0.22 + 0.78 * clamped,
        ),
    );
  }

  @override
  bool shouldRepaint(HearthFadeHexPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.progress != progress ||
        oldDelegate.preRead != preRead ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

/// Small hex indicator for bubble metadata rows and the chats list.
class HearthFadeHexIndicator extends StatelessWidget {
  final MessageModel message;
  final Color color;
  final double size;

  const HearthFadeHexIndicator({
    super.key,
    required this.message,
    required this.color,
    this.size = 12,
  });

  static bool showsEphemeralState(MessageModel message) {
    if (isMessageExpired(message)) return false;
    if (message.disappearAfterSeconds != null && message.expiresAt == null) {
      return true;
    }
    if (message.expiresAt != null) {
      final remaining = message.expiresAt!.difference(DateTime.now());
      return !remaining.isNegative;
    }
    return false;
  }

  static bool isPreRead(MessageModel message) =>
      message.disappearAfterSeconds != null && message.expiresAt == null;

  static double? countdownProgress(MessageModel message, [DateTime? now]) {
    final expiresAt = message.expiresAt;
    if (expiresAt == null) return null;
    final n = now ?? DateTime.now();
    final remaining = expiresAt.difference(n);
    if (remaining.isNegative) return null;
    final totalSeconds = message.disappearAfterSeconds;
    if (totalSeconds != null && totalSeconds > 0) {
      return remaining.inSeconds / totalSeconds;
    }
    final span = expiresAt.difference(message.createdAt);
    if (span.inSeconds <= 0) return 1.0;
    return remaining.inSeconds / span.inSeconds;
  }

  static String? countdownLabel(MessageModel message, [DateTime? now]) {
    final expiresAt = message.expiresAt;
    if (expiresAt == null) return null;
    final remaining = expiresAt.difference(now ?? DateTime.now());
    if (remaining.isNegative) return null;
    if (remaining.inHours > 0) {
      return '${remaining.inHours}h';
    }
    if (remaining.inMinutes > 0) {
      return '${remaining.inMinutes}m';
    }
    return '${remaining.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final preRead = isPreRead(message);
    final progress = preRead ? 0.0 : (countdownProgress(message) ?? 0.0);

    return CustomPaint(
      size: Size(size * kHexWidthRatio, size),
      painter: HearthFadeHexPainter(
        color: color,
        progress: progress,
        preRead: preRead,
        strokeWidth: size < 16 ? 1.5 : 2.5,
      ),
    );
  }
}

/// Hero-scale decorative hex for the timer sheet.
class HearthFadeHexHero extends StatelessWidget {
  final Color color;
  final double size;
  final double progress;

  const HearthFadeHexHero({
    super.key,
    required this.color,
    this.size = 72,
    this.progress = 0.85,
  });

  @override
  Widget build(BuildContext context) {
    final disableMotion = MediaQuery.disableAnimationsOf(context);
    final child = CustomPaint(
      size: Size(size * kHexWidthRatio, size),
      painter: HearthFadeHexPainter(
        color: color,
        progress: progress,
        strokeWidth: 4,
      ),
    );
    if (disableMotion) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.65, end: progress),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => CustomPaint(
        size: Size(size * kHexWidthRatio, size),
        painter: HearthFadeHexPainter(
          color: color,
          progress: value,
          strokeWidth: 4,
        ),
      ),
    );
  }
}

/// Compact duration label for composer banner and list hints.
String formatCompactDisappearingSeconds(int seconds) {
  if (seconds >= 86400) {
    final d = seconds ~/ 86400;
    return '${d}d';
  }
  if (seconds >= 3600) {
    final h = seconds ~/ 3600;
    return '${h}h';
  }
  if (seconds >= 60) {
    final m = seconds ~/ 60;
    return '${m}m';
  }
  return '${seconds}s';
}
