import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../theme/rpg_theme.dart';
import 'hex_avatar.dart';

/// The session-restore frame (`AuthGate`, `isRestoringSession`): the Flutter
/// twin of the DOM boot loader `#fp-boot` in `web/index.html`.
///
/// The DOM loader is removed on Flutter's first rendered frame and this is
/// the screen `AuthGate` shows next, so a different spinner here is a visible
/// jump from honeycomb to Material. Geometry, timings, delays, colour and
/// vertical position match the DOM copy (seven [hexPath] cells, a breathing
/// core with a ring chasing around it, a thin bar under them); change one
/// side, change both.
///
/// The bar is indeterminate on purpose: the DOM bar is a fake-asymptotic
/// percentage of a download, and there is nothing to measure here.
class BootHoneycomb extends StatefulWidget {
  const BootHoneycomb({super.key});

  @override
  State<BootHoneycomb> createState() => _BootHoneycombState();
}

class _BootHoneycombState extends State<BootHoneycomb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-checked on EVERY dependency change: reduce-motion can flip while the
    // screen is up.
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat().ignore();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = RpgTheme.ephemeralAccent(
      context,
      themePreference: context.select<SettingsProvider, String>(
        (s) => s.themePreference,
      ),
    );
    final track = Theme.of(context).colorScheme.onSurface.withValues(
      alpha: 0.12,
    );
    final still = MediaQuery.disableAnimationsOf(context);
    return ExcludeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CustomPaint(
            size: const Size.square(_size),
            painter: _HoneycombPainter(
              progress: _controller,
              color: accent,
              still: still,
            ),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: _barWidth,
            height: 3,
            child: CustomPaint(
              painter: _BarPainter(
                progress: _controller,
                color: accent,
                track: track,
                still: still,
              ),
            ),
          ),
          // The DOM loader's label + hint sit below the bar; reserve that
          // height so the honeycomb does not move at the handoff.
          const SizedBox(height: _belowBar),
        ],
      ),
    );
  }
}

const _period = Duration(milliseconds: 1600);
const double _size = 84;
const double _barWidth = 132;
// 16 label margin + 13px * 1.3 label line + 8 hint margin + 34 reserved hint
// height (web/index.html: .fp-boot-label, .fp-boot-hint).
const double _belowBar = 74.9;

// Honeycomb geometry in the DOM loader's 64 x 64 viewBox.
const double _viewBox = 64;
const double _cellRadius = 9;
const double _cellStroke = 1.6;
const double _cellGap = 3.2;
// Seconds between one ring cell and the next in the chase.
const double _chaseStep = 0.13;

final double _cellPitch = math.sqrt(3) * _cellRadius + _cellGap;

class _HoneycombPainter extends CustomPainter {
  _HoneycombPainter({
    required this.progress,
    required this.color,
    required this.still,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / _viewBox);
    const centre = Offset(_viewBox / 2, _viewBox / 2);
    final seconds = progress.value * _period.inMilliseconds / 1000;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _cellStroke
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..style = PaintingStyle.fill;

    // Core: steady outline, breathing fill.
    final core = hexPath(centre, _cellRadius);
    fill.color = color.withValues(alpha: still ? 0.6 : _core(_phase(seconds, 0)));
    canvas.drawPath(core, fill);
    stroke.color = color;
    canvas.drawPath(core, stroke);

    for (var i = 0; i < 6; i++) {
      final a = math.pi / 3 * i;
      final c = centre + Offset(math.cos(a), math.sin(a)) * _cellPitch;
      final phase = _phase(seconds, (i + 1) * _chaseStep);
      stroke.color = color.withValues(alpha: still ? 1 : _wave(phase));
      canvas.drawPath(hexPath(c, _cellRadius), stroke);
    }
  }

  /// Position in the cell's cycle, 0..1. Before its delay a cell sits at the
  /// first keyframe (CSS `backwards` fill), which the modulo reproduces.
  static double _phase(double seconds, double delay) {
    final p = (seconds - delay) / (_period.inMilliseconds / 1000);
    return p - p.floorToDouble();
  }

  /// 0% .25 → 40% 1 → 100% .25, ease-in-out per segment (`fpBootWave`).
  static double _wave(double p) => p < 0.4
      ? _lerp(0.25, 1, Curves.easeInOut.transform(p / 0.4))
      : _lerp(1, 0.25, Curves.easeInOut.transform((p - 0.4) / 0.6));

  /// 0% .35 → 50% 1 → 100% .35 (`fpBootCore`).
  static double _core(double p) => p < 0.5
      ? _lerp(0.35, 1, Curves.easeInOut.transform(p / 0.5))
      : _lerp(1, 0.35, Curves.easeInOut.transform((p - 0.5) / 0.5));

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  bool shouldRepaint(_HoneycombPainter old) =>
      old.color != color || old.still != still;
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.progress,
    required this.color,
    required this.track,
    required this.still,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;
  final Color track;
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height);
    canvas
      ..clipRRect(RRect.fromRectAndRadius(Offset.zero & size, radius))
      ..drawRect(Offset.zero & size, Paint()..color = track);
    // Reduce-motion: the track alone. A parked segment would read as progress
    // frozen at some percentage.
    if (still) return;
    final segment = size.width * 0.35;
    final t = Curves.easeInOut.transform(progress.value);
    final left = -segment + (size.width + segment) * t;
    canvas.drawRect(
      Rect.fromLTWH(left, 0, segment, size.height),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.color != color || old.track != track || old.still != still;
}
