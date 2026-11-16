import 'package:fireplace/utils/keyboard_inset_math.dart';
import 'package:flutter_test/flutter_test.dart';

/// One row of the [computeKeyboardInset] truth table: the seven inputs and the
/// three outputs the pure step must produce. Each row pins a distinct contract
/// (running-max capture, occlusion floor, orientation reset) so a failure names
/// the broken rule instead of "the math changed".
class _Case {
  const _Case(
    this.name, {
    required this.prevFull,
    required this.prevWidth,
    required this.vvWidth,
    required this.vvHeight,
    required this.vvOffsetTop,
    required this.innerHeight,
    required this.clientHeight,
    required this.expectFull,
    required this.expectWidth,
    required this.expectInset,
  });

  final String name;
  final double prevFull;
  final double prevWidth;
  final double vvWidth;
  final double vvHeight;
  final double vvOffsetTop;
  final double innerHeight;
  final double clientHeight;
  final double expectFull;
  final double expectWidth;
  final double expectInset;
}

void main() {
  const cases = <_Case>[
    // Full layout height is the max of all three signals; the panned visual
    // viewport's bottom edge (vvHeight + vvOffsetTop = 650) beats both
    // innerHeight and clientHeight and becomes the reference.
    _Case(
      'captures full layout height from the panned visual-viewport bottom edge',
      prevFull: 0,
      prevWidth: 400,
      vvWidth: 400,
      vvHeight: 400,
      vvOffsetTop: 250,
      innerHeight: 500,
      clientHeight: 600,
      expectFull: 650,
      expectWidth: 400,
      expectInset: 250, // 650 - 400
    ),
    // Standalone-PWA keyboard-up: every live signal has shrunk to the
    // above-keyboard 394, but the running max holds the pre-keyboard 797, so
    // the real ~403px keyboard is recovered even though innerHeight lies.
    _Case(
      'keyboard-up in a standalone PWA keeps the pre-keyboard running max',
      prevFull: 797,
      prevWidth: 390,
      vvWidth: 390,
      vvHeight: 394,
      vvOffsetTop: 0,
      innerHeight: 394,
      clientHeight: 394,
      expectFull: 797,
      expectWidth: 390,
      expectInset: 403, // 797 - 394
    ),
    // Occlusion exactly at the floor is treated as noise, not a keyboard.
    _Case(
      'occlusion exactly at the 80px floor reads as no keyboard',
      prevFull: 480,
      prevWidth: 390,
      vvWidth: 390,
      vvHeight: 400,
      vvOffsetTop: 0,
      innerHeight: 400,
      clientHeight: 400,
      expectFull: 480,
      expectWidth: 390,
      expectInset: 0, // 80 is NOT > 80
    ),
    // One pixel above the floor is a real inset and is reported verbatim.
    _Case(
      'occlusion one pixel above the floor is reported',
      prevFull: 481,
      prevWidth: 390,
      vvWidth: 390,
      vvHeight: 400,
      vvOffsetTop: 0,
      innerHeight: 400,
      clientHeight: 400,
      expectFull: 481,
      expectWidth: 390,
      expectInset: 81, // 481 - 400, and 81 > 80
    ),
    // Well below the floor: safe-area / rounding noise, never a keyboard.
    _Case(
      'occlusion well below the floor is discarded as noise',
      prevFull: 440,
      prevWidth: 390,
      vvWidth: 390,
      vvHeight: 400,
      vvOffsetTop: 0,
      innerHeight: 400,
      clientHeight: 400,
      expectFull: 440,
      expectWidth: 390,
      expectInset: 0, // 40 < 80
    ),
    // Orientation change (>1px width delta) drops the stale 797 and recaptures
    // from the fresh landscape signals — the inset must NOT be 497 (797 - 300).
    _Case(
      'width change beyond 1px resets the running max on orientation change',
      prevFull: 797,
      prevWidth: 390,
      vvWidth: 844,
      vvHeight: 300,
      vvOffsetTop: 0,
      innerHeight: 390,
      clientHeight: 390,
      expectFull: 390, // recaptured, not 797
      expectWidth: 844,
      expectInset: 90, // 390 - 300
    ),
    // Sub-pixel width jitter must NOT reset: the running max and its tracked
    // width survive, so the recovered keyboard inset stays stable.
    _Case(
      'sub-pixel width jitter preserves the running max',
      prevFull: 797,
      prevWidth: 390,
      vvWidth: 390.5,
      vvHeight: 394,
      vvOffsetTop: 0,
      innerHeight: 394,
      clientHeight: 394,
      expectFull: 797,
      expectWidth: 390, // unchanged (jitter ignored)
      expectInset: 403,
    ),
    // Exactly 1px is the boundary of the reset guard (`> 1`): still no reset.
    _Case(
      'width change of exactly 1px does not reset',
      prevFull: 797,
      prevWidth: 390,
      vvWidth: 391,
      vvHeight: 394,
      vvOffsetTop: 0,
      innerHeight: 394,
      clientHeight: 394,
      expectFull: 797,
      expectWidth: 390, // 1 is NOT > 1
      expectInset: 403,
    ),
  ];

  for (final c in cases) {
    test(c.name, () {
      final result = computeKeyboardInset(
        previousFullLayoutHeight: c.prevFull,
        previousTrackedWidth: c.prevWidth,
        vvHeight: c.vvHeight,
        vvWidth: c.vvWidth,
        vvOffsetTop: c.vvOffsetTop,
        innerHeight: c.innerHeight,
        clientHeight: c.clientHeight,
      );
      expect(result.fullLayoutHeight, c.expectFull, reason: 'fullLayoutHeight');
      expect(result.trackedWidth, c.expectWidth, reason: 'trackedWidth');
      expect(result.inset, c.expectInset, reason: 'inset');
    });
  }
}
