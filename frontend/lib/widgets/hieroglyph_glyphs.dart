// Hieroglyph/rune paint code for the chat wallpaper. Historically generated
// from an ad-hoc SVG→Dart script, but that generator and its SVG masters were
// never committed — so THIS FILE IS THE SOURCE OF TRUTH and is maintained by
// hand. Edit the paint functions here directly. Keep the visual preview
// `docs/design/liquid-glass/wallpapers/hieroglyphs.html` in sync (same path
// coordinates); there is nothing to "regenerate".
//
// v5 set (owner-approved 2026-07-12): deleted 9 weak signs (cobra, djed,
// bee, dju, pet, seba2/star, per, door-bolt, foot); reworked the scarab
// (L1) into a clearer beetle; added 5 authentic Gardiner signs (was S40,
// tyet/Knot-of-Isis V39, shen-ring V9, reed M17, heart/ib F34) and 9
// Diablo II high runes (Gul, Vex, Ohm, Lo, Sur, Ber, Jah, Cham, Zod) as
// mono-line accents traced from the D2 rune sprites.
//
// v6 set (2026-07-12): added 10 more authentic Gardiner signs — crook (heka
// S38), flail (nekhakha S45), hedjet white crown (S1), deshret red crown
// (S3), nub broad collar (S12), sail/breath (P5), hoe (U6), scribe palette
// (Y3), pool/sh (N37), and the recumbent Anubis jackal (E16). 43 total.
//
// v7 set (owner-approved 2026-07-12): removed was S40, reed M17, pool N37,
// and 4 runes (Gul, Ohm, Ber, Sur). 36 total; 5 high runes remain
// (Vex, Lo, Jah, Cham, Zod).
//
// Leaf silhouette traced from Wikimedia Commons "Cannabis icon.svg"
// (source: svgsilh.com, CC0 / public domain — no attribution required).
//
// Each glyph is centered on (0,0), nominal footprint ~44x44 logical px.
import 'dart:ui';

import 'package:flutter/painting.dart';

/// One hieroglyph: paints with [paintFn] given stroke + fill paints.
class HieroGlyph {
  final String name;

  /// Visually wide/heavy glyphs; the layout forbids two non-wide glyphs in a
  /// row within a column (avoids "pen-stroke" stacks).
  final bool wide;

  /// The rare hero glyph (guaranteed cadence handled by the painter).
  final bool isLeaf;

  final void Function(Canvas canvas, Paint stroke, Paint fill) paintFn;

  const HieroGlyph(
    this.name, {
    required this.wide,
    required this.isLeaf,
    required this.paintFn,
  });
}

/// Owner-approved v7 registry: 30 hieroglyph signs + 5 Diablo II high runes
/// + the CC0 leaf hero (36 total).
final List<HieroGlyph> kHieroGlyphs = <HieroGlyph>[
  HieroGlyph(
    'horus',
    wide: true,
    isLeaf: false,
    paintFn: _paintHorus,
  ),
  HieroGlyph(
    'ankh',
    wide: false,
    isLeaf: false,
    paintFn: _paintAnkh,
  ),
  HieroGlyph(
    'pyramids',
    wide: true,
    isLeaf: false,
    paintFn: _paintPyramids,
  ),
  HieroGlyph(
    'water',
    wide: true,
    isLeaf: false,
    paintFn: _paintWater,
  ),
  HieroGlyph(
    'obelisk',
    wide: false,
    isLeaf: false,
    paintFn: _paintObelisk,
  ),
  HieroGlyph(
    'lotus',
    wide: false,
    isLeaf: false,
    paintFn: _paintLotus,
  ),
  HieroGlyph(
    'feather',
    wide: false,
    isLeaf: false,
    paintFn: _paintFeather,
  ),
  HieroGlyph(
    'neb',
    wide: true,
    isLeaf: false,
    paintFn: _paintNeb,
  ),
  HieroGlyph(
    'boat',
    wide: true,
    isLeaf: false,
    paintFn: _paintBoat,
  ),
  HieroGlyph(
    'ka',
    wide: true,
    isLeaf: false,
    paintFn: _paintKa,
  ),
  HieroGlyph(
    'scarab',
    wide: true,
    isLeaf: false,
    paintFn: _paintScarab,
  ),
  HieroGlyph(
    'leafreal',
    wide: true,
    isLeaf: true,
    paintFn: _paintLeafreal,
  ),
  HieroGlyph(
    'akhet',
    wide: true,
    isLeaf: false,
    paintFn: _paintAkhet,
  ),
  HieroGlyph(
    'nefer',
    wide: false,
    isLeaf: false,
    paintFn: _paintNefer,
  ),
  HieroGlyph(
    'netjer',
    wide: false,
    isLeaf: false,
    paintFn: _paintNetjer,
  ),
  HieroGlyph(
    'sedge',
    wide: false,
    isLeaf: false,
    paintFn: _paintSedge,
  ),
  HieroGlyph(
    'wick',
    wide: false,
    isLeaf: false,
    paintFn: _paintWick,
  ),
  HieroGlyph(
    'sundisc',
    wide: true,
    isLeaf: false,
    paintFn: _paintSundisc,
  ),
  HieroGlyph(
    'cloth',
    wide: false,
    isLeaf: false,
    paintFn: _paintCloth,
  ),
  HieroGlyph(
    'tyet',
    wide: false,
    isLeaf: false,
    paintFn: _paintTyet,
  ),
  HieroGlyph(
    'shen',
    wide: true,
    isLeaf: false,
    paintFn: _paintShen,
  ),
  HieroGlyph(
    'heart',
    wide: false,
    isLeaf: false,
    paintFn: _paintHeart,
  ),
  HieroGlyph(
    'crook',
    wide: false,
    isLeaf: false,
    paintFn: _paintCrook,
  ),
  HieroGlyph(
    'flail',
    wide: false,
    isLeaf: false,
    paintFn: _paintFlail,
  ),
  HieroGlyph(
    'hedjet',
    wide: false,
    isLeaf: false,
    paintFn: _paintHedjet,
  ),
  HieroGlyph(
    'deshret',
    wide: true,
    isLeaf: false,
    paintFn: _paintDeshret,
  ),
  HieroGlyph(
    'nub',
    wide: true,
    isLeaf: false,
    paintFn: _paintNub,
  ),
  HieroGlyph(
    'sail',
    wide: false,
    isLeaf: false,
    paintFn: _paintSail,
  ),
  HieroGlyph(
    'hoe',
    wide: true,
    isLeaf: false,
    paintFn: _paintHoe,
  ),
  HieroGlyph(
    'palette',
    wide: true,
    isLeaf: false,
    paintFn: _paintPalette,
  ),
  HieroGlyph(
    'jackal',
    wide: true,
    isLeaf: false,
    paintFn: _paintJackal,
  ),
  HieroGlyph(
    'vex',
    wide: false,
    isLeaf: false,
    paintFn: _paintVex,
  ),
  HieroGlyph(
    'lo',
    wide: true,
    isLeaf: false,
    paintFn: _paintLo,
  ),
  HieroGlyph(
    'jah',
    wide: true,
    isLeaf: false,
    paintFn: _paintJah,
  ),
  HieroGlyph(
    'cham',
    wide: false,
    isLeaf: false,
    paintFn: _paintCham,
  ),
  HieroGlyph(
    'zod',
    wide: false,
    isLeaf: false,
    paintFn: _paintZod,
  ),
];

void _paintHorus(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-18, 0)
    ..cubicTo(-10, -8, 10, -8, 18, 0)
    ..cubicTo(10, 6, -10, 6, -18, 0)
    ..close();
  c.drawPath(p0, s);
  c.drawOval(
    Rect.fromCenter(center: const Offset(0, -1), width: 8, height: 8),
    s,
  );
  final p2 = Path()
    ..moveTo(-20, -7)
    ..cubicTo(-10, -14, 10, -14, 20, -7);
  c.drawPath(p2, s);
  final p3 = Path()
    ..moveTo(8, 5)
    ..cubicTo(10, 12, 4, 14, 2, 17);
  c.drawPath(p3, s);
  final p4 = Path()
    ..moveTo(-8, 5)
    ..lineTo(-8, 14)
    ..cubicTo(-8, 17, -12, 18, -13, 15);
  c.drawPath(p4, s);
}

void _paintAnkh(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(0, -2)
    ..cubicTo(-9, -2, -12, -9, -12, -14)
    ..cubicTo(-12, -21, -6, -25, 0, -25)
    ..cubicTo(6, -25, 12, -21, 12, -14)
    ..cubicTo(12, -9, 9, -2, 0, -2)
    ..close();
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(0, -2)
    ..lineTo(0, 20);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(-10, 4)
    ..lineTo(10, 4);
  c.drawPath(p2, s);
}

void _paintPyramids(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-22, 12)
    ..lineTo(-4, -16)
    ..lineTo(14, 12)
    ..close();
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(-4, -16)
    ..lineTo(2, 12);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(6, 12)
    ..lineTo(16, -2)
    ..lineTo(26, 12)
    ..close();
  c.drawPath(p2, s);
}


void _paintWater(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-16, -8)
    ..lineTo(-10, -12)
    ..lineTo(-4, -8)
    ..lineTo(2, -12)
    ..lineTo(8, -8)
    ..lineTo(14, -12);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(-16, 0)
    ..lineTo(-10, -4)
    ..lineTo(-4, 0)
    ..lineTo(2, -4)
    ..lineTo(8, 0)
    ..lineTo(14, -4);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(-16, 8)
    ..lineTo(-10, 4)
    ..lineTo(-4, 8)
    ..lineTo(2, 4)
    ..lineTo(8, 8)
    ..lineTo(14, 4);
  c.drawPath(p2, s);
}

void _paintObelisk(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-5, 16)
    ..lineTo(-3, -12)
    ..lineTo(0, -18)
    ..lineTo(3, -12)
    ..lineTo(5, 16)
    ..close();
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(-8, 16)
    ..lineTo(8, 16);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(-3, -4)
    ..lineTo(3, -4);
  c.drawPath(p2, s);
}

void _paintLotus(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(0, -4)
    ..cubicTo(-3, -12, -1, -16, 0, -18)
    ..cubicTo(1, -16, 3, -12, 0, -4)
    ..close();
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(0, -4)
    ..cubicTo(-8, -8, -12, -6, -14, -2)
    ..cubicTo(-9, 0, -4, 0, 0, -4)
    ..close();
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(0, -4)
    ..cubicTo(8, -8, 12, -6, 14, -2)
    ..cubicTo(9, 0, 4, 0, 0, -4)
    ..close();
  c.drawPath(p2, s);
  final p3 = Path()
    ..moveTo(0, -3)
    ..lineTo(0, 16);
  c.drawPath(p3, s);
}

void _paintFeather(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(0, 16)
    ..lineTo(0, -14)
    ..cubicTo(8, -12, 9, 2, 1, 8)
    ..moveTo(0, -14)
    ..cubicTo(-3, -10, -3, 0, 0, 8);
  c.drawPath(p0, s);
}


void _paintNeb(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-13, 2)
    ..lineTo(13, 2)
    ..cubicTo(13, 9, 7, 13, 0, 13)
    ..cubicTo(-7, 13, -13, 9, -13, 2)
    ..close()
    ..moveTo(-13, 5)
    ..lineTo(13, 5);
  c.drawPath(p0, s);
}

void _paintBoat(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-16, -2)
    ..cubicTo(-12, 5, 12, 5, 16, -2)
    ..cubicTo(10, 2, -10, 2, -16, -2)
    ..close();
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(0, -2)
    ..lineTo(0, -12);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(-5, -12)
    ..lineTo(5, -12);
  c.drawPath(p2, s);
}

void _paintKa(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-12, 12)
    ..lineTo(12, 12);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(-9, 12)
    ..lineTo(-9, -4)
    ..cubicTo(-9, -9, -6, -12, -3, -13)
    ..moveTo(9, 12)
    ..lineTo(9, -4)
    ..cubicTo(9, -9, 6, -12, 3, -13);
  c.drawPath(p1, s);
}

void _paintScarab(Canvas c, Paint s, Paint f) {
  c.drawOval(
    Rect.fromCenter(center: const Offset(0, 5), width: 18, height: 22),
    s,
  );
  c.drawOval(
    Rect.fromCenter(center: const Offset(0, -6), width: 13, height: 9),
    s,
  );
  final p0 = Path()
    ..moveTo(-7, -11)
    ..lineTo(-4, -15)
    ..lineTo(-2, -12)
    ..lineTo(0, -16)
    ..lineTo(2, -12)
    ..lineTo(4, -15)
    ..lineTo(7, -11);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(0, 0)
    ..lineTo(0, 15);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(-8, -4)
    ..lineTo(-16, -8)
    ..moveTo(-9, 3)
    ..lineTo(-18, 3)
    ..moveTo(-8, 10)
    ..lineTo(-15, 16)
    ..moveTo(8, -4)
    ..lineTo(16, -8)
    ..moveTo(9, 3)
    ..lineTo(18, 3)
    ..moveTo(8, 10)
    ..lineTo(15, 16);
  c.drawPath(p2, s);
}


void _paintLeafreal(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-0.11, -17.79)
    ..cubicTo(-0.38, -17.25, -0.91, -14.97, -1.03, -13.83)
    ..lineTo(-1.05, -13.65)
    ..lineTo(-1.17, -13.78)
    ..cubicTo(-1.32, -13.94, -1.35, -13.93, -1.49, -13.67)
    ..cubicTo(-1.67, -13.31, -1.79, -12.78, -1.81, -12.32)
    ..cubicTo(-1.81, -12.05, -1.81, -12.04, -1.87, -12.08)
    ..cubicTo(-2.02, -12.19, -2.17, -12.26, -2.19, -12.25)
    ..cubicTo(-2.32, -12.17, -2.48, -10.75, -2.42, -10.18)
    ..cubicTo(-2.41, -10.01, -2.41, -9.94, -2.43, -9.95)
    ..cubicTo(-2.45, -9.96, -2.54, -10.02, -2.63, -10.09)
    ..cubicTo(-2.86, -10.24, -3.03, -10.33, -3.08, -10.31)
    ..cubicTo(-3.15, -10.28, -3.18, -10.08, -3.18, -9.65)
    ..cubicTo(-3.18, -9.05, -3.08, -8.46, -2.91, -8.04)
    ..cubicTo(-2.87, -7.94, -2.85, -7.86, -2.85, -7.86)
    ..cubicTo(-2.85, -7.85, -3, -7.95, -3.18, -8.06)
    ..cubicTo(-3.65, -8.37, -3.69, -8.37, -3.72, -8.01)
    ..cubicTo(-3.78, -7.47, -3.63, -6.62, -3.4, -6.22)
    ..cubicTo(-3.36, -6.14, -3.32, -6.06, -3.33, -6.05)
    ..cubicTo(-3.34, -6.05, -3.43, -6.09, -3.54, -6.15)
    ..cubicTo(-3.87, -6.33, -3.92, -6.36, -4, -6.36)
    ..cubicTo(-4.12, -6.36, -4.14, -6.28, -4.13, -5.99)
    ..cubicTo(-4.1, -5.55, -3.88, -4.83, -3.6, -4.27)
    ..cubicTo(-3.51, -4.09, -3.45, -3.94, -3.47, -3.94)
    ..cubicTo(-3.48, -3.94, -3.6, -4, -3.72, -4.08)
    ..cubicTo(-4.13, -4.32, -4.13, -4.32, -4.2, -4.25)
    ..cubicTo(-4.26, -4.19, -4.26, -4.16, -4.26, -3.86)
    ..cubicTo(-4.26, -3.58, -4.24, -3.5, -4.18, -3.29)
    ..cubicTo(-4.05, -2.89, -3.84, -2.53, -3.57, -2.24)
    ..cubicTo(-3.44, -2.1, -3.43, -2.08, -3.49, -2.08)
    ..cubicTo(-3.53, -2.08, -3.63, -2.1, -3.73, -2.12)
    ..cubicTo(-3.99, -2.19, -4.07, -2.18, -4.13, -2.09)
    ..cubicTo(-4.17, -2.02, -4.17, -2.01, -4.12, -1.78)
    ..cubicTo(-4.06, -1.47, -3.88, -1.01, -3.64, -0.58)
    ..cubicTo(-3.54, -0.4, -3.46, -0.24, -3.47, -0.24)
    ..cubicTo(-3.47, -0.23, -3.55, -0.27, -3.64, -0.33)
    ..cubicTo(-3.86, -0.46, -3.94, -0.47, -4.02, -0.4)
    ..cubicTo(-4.14, -0.28, -4.08, 0.14, -3.87, 0.66)
    ..cubicTo(-3.75, 0.95, -3.6, 1.23, -3.38, 1.51)
    ..lineTo(-3.23, 1.72)
    ..lineTo(-3.38, 1.72)
    ..cubicTo(-3.54, 1.72, -3.7, 1.78, -3.73, 1.84)
    ..cubicTo(-3.76, 1.93, -3.68, 2.15, -3.38, 2.8)
    ..cubicTo(-3.21, 3.16, -3.06, 3.49, -3.05, 3.53)
    ..cubicTo(-3.02, 3.65, -3.1, 3.61, -3.18, 3.45)
    ..cubicTo(-3.22, 3.38, -3.28, 3.29, -3.31, 3.26)
    ..cubicTo(-3.36, 3.2, -3.38, 3.2, -3.45, 3.23)
    ..cubicTo(-3.5, 3.25, -3.57, 3.31, -3.62, 3.35)
    ..cubicTo(-3.71, 3.45, -3.74, 3.45, -3.74, 3.37)
    ..cubicTo(-3.74, 3.25, -3.85, 2.88, -3.95, 2.62)
    ..cubicTo(-4.14, 2.17, -4.44, 1.77, -4.59, 1.77)
    ..cubicTo(-4.69, 1.77, -4.74, 1.85, -4.78, 2.04)
    ..cubicTo(-4.82, 2.23, -4.81, 2.25, -4.97, 1.81)
    ..cubicTo(-5.18, 1.23, -5.49, 0.73, -5.64, 0.73)
    ..cubicTo(-5.71, 0.73, -5.79, 0.82, -5.91, 1.03)
    ..cubicTo(-5.99, 1.18, -6.02, 1.18, -6.02, 1.06)
    ..cubicTo(-6.02, 0.82, -6.15, 0.37, -6.3, 0.09)
    ..cubicTo(-6.53, -0.34, -6.94, -0.66, -7.03, -0.49)
    ..cubicTo(-7.04, -0.46, -7.07, -0.35, -7.09, -0.25)
    ..cubicTo(-7.11, -0.15, -7.13, -0.03, -7.15, 0.03)
    ..lineTo(-7.18, 0.12)
    ..lineTo(-7.26, -0.1)
    ..cubicTo(-7.43, -0.58, -7.82, -1.23, -8.1, -1.51)
    ..cubicTo(-8.33, -1.75, -8.4, -1.71, -8.5, -1.3)
    ..cubicTo(-8.53, -1.16, -8.57, -1.04, -8.58, -1.04)
    ..cubicTo(-8.59, -1.04, -8.62, -1.11, -8.65, -1.19)
    ..cubicTo(-8.75, -1.5, -9.11, -1.97, -9.47, -2.29)
    ..cubicTo(-9.85, -2.61, -9.86, -2.6, -9.96, -1.95)
    ..lineTo(-9.99, -1.74)
    ..lineTo(-10.07, -1.89)
    ..cubicTo(-10.11, -1.97, -10.18, -2.09, -10.22, -2.15)
    ..cubicTo(-10.45, -2.51, -11.02, -3.11, -11.27, -3.24)
    ..cubicTo(-11.39, -3.3, -11.4, -3.3, -11.43, -3.25)
    ..cubicTo(-11.47, -3.2, -11.53, -2.91, -11.53, -2.76)
    ..cubicTo(-11.53, -2.71, -11.54, -2.67, -11.55, -2.67)
    ..cubicTo(-11.57, -2.67, -11.65, -2.74, -11.73, -2.83)
    ..cubicTo(-12.1, -3.22, -12.96, -3.83, -13.12, -3.83)
    ..cubicTo(-13.15, -3.83, -13.17, -3.77, -13.2, -3.66)
    ..lineTo(-13.23, -3.5)
    ..lineTo(-13.45, -3.67)
    ..cubicTo(-13.81, -3.96, -14.37, -4.22, -14.62, -4.22)
    ..lineTo(-14.72, -4.22)
    ..lineTo(-14.7, -4.08)
    ..cubicTo(-14.69, -4, -14.69, -3.94, -14.7, -3.94)
    ..cubicTo(-14.7, -3.94, -14.91, -4.07, -15.15, -4.23)
    ..cubicTo(-16.17, -4.9, -17.46, -5.59, -17.87, -5.68)
    ..cubicTo(-18.02, -5.72, -18.03, -5.67, -17.91, -5.42)
    ..cubicTo(-17.67, -4.91, -16.65, -3.46, -16.04, -2.77)
    ..cubicTo(-15.9, -2.6, -15.89, -2.59, -15.96, -2.59)
    ..cubicTo(-15.99, -2.59, -16.07, -2.58, -16.12, -2.57)
    ..cubicTo(-16.2, -2.55, -16.21, -2.55, -16.19, -2.46)
    ..cubicTo(-16.16, -2.33, -16, -1.99, -15.86, -1.8)
    ..cubicTo(-15.8, -1.7, -15.65, -1.52, -15.54, -1.41)
    ..cubicTo(-15.42, -1.29, -15.33, -1.18, -15.33, -1.17)
    ..cubicTo(-15.33, -1.16, -15.35, -1.15, -15.38, -1.15)
    ..cubicTo(-15.49, -1.15, -15.64, -1.09, -15.64, -1.04)
    ..cubicTo(-15.64, -0.89, -14.8, 0.03, -14.39, 0.33)
    ..lineTo(-14.31, 0.39)
    ..lineTo(-14.5, 0.43)
    ..cubicTo(-14.76, 0.5, -14.91, 0.56, -14.91, 0.61)
    ..cubicTo(-14.91, 0.85, -13.89, 1.63, -13.35, 1.8)
    ..cubicTo(-13.22, 1.84, -13.24, 1.86, -13.53, 1.93)
    ..cubicTo(-13.81, 1.99, -13.94, 2.05, -13.96, 2.1)
    ..cubicTo(-13.99, 2.16, -13.66, 2.49, -13.36, 2.7)
    ..cubicTo(-13.08, 2.91, -12.74, 3.08, -12.53, 3.13)
    ..cubicTo(-12.45, 3.14, -12.39, 3.17, -12.39, 3.18)
    ..cubicTo(-12.4, 3.19, -12.51, 3.24, -12.64, 3.28)
    ..cubicTo(-13.04, 3.41, -13.06, 3.51, -12.76, 3.72)
    ..cubicTo(-12.39, 3.99, -11.81, 4.25, -11.33, 4.37)
    ..cubicTo(-11.03, 4.45, -11.03, 4.44, -11.45, 4.57)
    ..cubicTo(-11.72, 4.66, -11.74, 4.68, -11.72, 4.77)
    ..cubicTo(-11.69, 4.87, -11.55, 5.02, -11.34, 5.15)
    ..cubicTo(-11.01, 5.36, -10.62, 5.48, -10.17, 5.49)
    ..cubicTo(-10.04, 5.5, -9.93, 5.51, -9.93, 5.51)
    ..cubicTo(-9.93, 5.52, -9.98, 5.56, -10.03, 5.6)
    ..cubicTo(-10.34, 5.8, -10.39, 5.9, -10.24, 6.03)
    ..cubicTo(-10.05, 6.19, -9.56, 6.38, -9.05, 6.5)
    ..cubicTo(-8.9, 6.53, -8.78, 6.57, -8.78, 6.57)
    ..cubicTo(-8.78, 6.57, -8.86, 6.6, -8.96, 6.64)
    ..cubicTo(-9.24, 6.73, -9.26, 6.83, -9.06, 7.02)
    ..cubicTo(-8.82, 7.23, -8.23, 7.45, -7.71, 7.51)
    ..lineTo(-7.43, 7.55)
    ..lineTo(-7.53, 7.69)
    ..cubicTo(-7.72, 7.97, -7.72, 7.97, -6.61, 8.31)
    ..cubicTo(-6.33, 8.4, -6.28, 8.42, -6.25, 8.48)
    ..cubicTo(-6.23, 8.53, -6.22, 8.57, -6.23, 8.57)
    ..cubicTo(-6.23, 8.58, -6.31, 8.55, -6.4, 8.5)
    ..cubicTo(-6.65, 8.38, -6.98, 8.27, -7.11, 8.26)
    ..cubicTo(-7.25, 8.26, -7.3, 8.3, -7.27, 8.41)
    ..cubicTo(-7.26, 8.44, -7.25, 8.51, -7.24, 8.56)
    ..lineTo(-7.22, 8.65)
    ..lineTo(-7.34, 8.55)
    ..cubicTo(-7.63, 8.31, -8.12, 8.15, -8.35, 8.21)
    ..cubicTo(-8.41, 8.23, -8.47, 8.26, -8.48, 8.27)
    ..cubicTo(-8.49, 8.29, -8.46, 8.38, -8.4, 8.47)
    ..cubicTo(-8.34, 8.56, -8.3, 8.64, -8.3, 8.65)
    ..cubicTo(-8.3, 8.66, -8.39, 8.62, -8.5, 8.57)
    ..cubicTo(-8.77, 8.44, -9.16, 8.33, -9.41, 8.31)
    ..cubicTo(-9.6, 8.29, -9.62, 8.3, -9.65, 8.35)
    ..cubicTo(-9.67, 8.39, -9.66, 8.43, -9.59, 8.56)
    ..cubicTo(-9.54, 8.65, -9.51, 8.72, -9.51, 8.73)
    ..cubicTo(-9.51, 8.74, -9.58, 8.71, -9.67, 8.68)
    ..cubicTo(-10.03, 8.53, -10.77, 8.5, -10.77, 8.64)
    ..cubicTo(-10.77, 8.65, -10.72, 8.74, -10.65, 8.85)
    ..cubicTo(-10.57, 8.97, -10.54, 9.03, -10.57, 9.02)
    ..cubicTo(-10.91, 8.88, -11.67, 8.83, -11.85, 8.92)
    ..cubicTo(-11.92, 8.96, -11.91, 9, -11.8, 9.17)
    ..lineTo(-11.7, 9.31)
    ..lineTo(-11.95, 9.31)
    ..cubicTo(-12.22, 9.31, -12.75, 9.38, -12.9, 9.42)
    ..cubicTo(-13.01, 9.46, -13.02, 9.48, -12.95, 9.58)
    ..cubicTo(-12.93, 9.62, -12.91, 9.65, -12.91, 9.66)
    ..cubicTo(-12.92, 9.66, -13.04, 9.68, -13.17, 9.7)
    ..cubicTo(-13.53, 9.75, -13.92, 9.91, -13.92, 10)
    ..cubicTo(-13.92, 10.02, -13.9, 10.06, -13.86, 10.08)
    ..cubicTo(-13.79, 10.14, -13.8, 10.14, -14.09, 10.18)
    ..cubicTo(-14.61, 10.26, -15.65, 10.51, -16.01, 10.66)
    ..cubicTo(-16.24, 10.75, -16.25, 10.8, -16.07, 10.88)
    ..cubicTo(-15.78, 11.01, -14.91, 11.2, -14.19, 11.3)
    ..cubicTo(-13.99, 11.33, -13.82, 11.35, -13.81, 11.36)
    ..cubicTo(-13.81, 11.36, -13.82, 11.39, -13.85, 11.42)
    ..cubicTo(-13.88, 11.44, -13.9, 11.48, -13.9, 11.5)
    ..cubicTo(-13.9, 11.58, -13.32, 11.76, -13.03, 11.76)
    ..cubicTo(-12.94, 11.76, -12.86, 11.76, -12.86, 11.77)
    ..cubicTo(-12.86, 11.78, -12.88, 11.83, -12.91, 11.88)
    ..lineTo(-12.97, 11.98)
    ..lineTo(-12.89, 12.01)
    ..cubicTo(-12.76, 12.06, -12.4, 12.1, -12.02, 12.1)
    ..lineTo(-11.65, 12.11)
    ..lineTo(-11.73, 12.22)
    ..cubicTo(-11.91, 12.49, -11.88, 12.52, -11.47, 12.52)
    ..cubicTo(-11.15, 12.52, -10.83, 12.47, -10.6, 12.38)
    ..lineTo(-10.46, 12.32)
    ..lineTo(-10.5, 12.39)
    ..cubicTo(-10.62, 12.58, -10.69, 12.72, -10.68, 12.76)
    ..cubicTo(-10.63, 12.89, -9.92, 12.81, -9.47, 12.62)
    ..cubicTo(-9.42, 12.6, -9.43, 12.62, -9.51, 12.75)
    ..cubicTo(-9.61, 12.93, -9.6, 13.01, -9.49, 13.03)
    ..cubicTo(-9.32, 13.06, -8.79, 12.92, -8.43, 12.74)
    ..lineTo(-8.21, 12.63)
    ..lineTo(-8.32, 12.81)
    ..cubicTo(-8.41, 12.98, -8.41, 13, -8.37, 13.04)
    ..cubicTo(-8.31, 13.11, -8.03, 13.1, -7.81, 13.02)
    ..cubicTo(-7.64, 12.97, -7.43, 12.84, -7.22, 12.68)
    ..cubicTo(-7.15, 12.62, -7.14, 12.62, -7.15, 12.68)
    ..cubicTo(-7.2, 12.83, -7.2, 12.92, -7.17, 12.95)
    ..cubicTo(-7.09, 13.05, -6.8, 12.98, -6.37, 12.75)
    ..cubicTo(-6.11, 12.61, -6.1, 12.61, -6.15, 12.69)
    ..cubicTo(-6.2, 12.79, -6.2, 12.9, -6.14, 12.92)
    ..cubicTo(-5.96, 12.99, -5.44, 12.82, -5.11, 12.57)
    ..lineTo(-4.98, 12.47)
    ..lineTo(-4.97, 12.57)
    ..cubicTo(-4.95, 12.7, -4.89, 12.75, -4.78, 12.71)
    ..cubicTo(-4.73, 12.7, -4.68, 12.7, -4.65, 12.73)
    ..cubicTo(-4.61, 12.76, -4.63, 12.77, -4.8, 12.8)
    ..cubicTo(-5.03, 12.84, -5.23, 12.93, -5.33, 13.06)
    ..lineTo(-5.41, 13.15)
    ..lineTo(-5.34, 13.2)
    ..cubicTo(-5.31, 13.23, -5.26, 13.25, -5.23, 13.25)
    ..cubicTo(-5.14, 13.25, -5.17, 13.3, -5.27, 13.32)
    ..cubicTo(-5.4, 13.34, -5.85, 13.57, -5.92, 13.64)
    ..cubicTo(-5.99, 13.72, -5.96, 13.78, -5.83, 13.82)
    ..lineTo(-5.74, 13.85)
    ..lineTo(-5.94, 13.96)
    ..cubicTo(-6.16, 14.07, -6.41, 14.28, -6.41, 14.36)
    ..cubicTo(-6.41, 14.39, -6.37, 14.41, -6.29, 14.44)
    ..cubicTo(-6.17, 14.47, -6.12, 14.52, -6.19, 14.52)
    ..cubicTo(-6.31, 14.52, -6.88, 14.98, -6.86, 15.05)
    ..cubicTo(-6.85, 15.07, -6.8, 15.11, -6.73, 15.13)
    ..lineTo(-6.62, 15.16)
    ..lineTo(-6.81, 15.35)
    ..cubicTo(-7.14, 15.67, -7.26, 15.87, -7.13, 15.87)
    ..cubicTo(-7.07, 15.87, -7.08, 15.88, -7.2, 16.04)
    ..cubicTo(-7.41, 16.3, -7.49, 16.54, -7.38, 16.54)
    ..cubicTo(-7.34, 16.54, -7.34, 16.55, -7.37, 16.59)
    ..cubicTo(-7.4, 16.62, -7.53, 16.8, -7.68, 17)
    ..cubicTo(-7.98, 17.4, -8.23, 17.78, -8.26, 17.9)
    ..cubicTo(-8.27, 17.96, -8.27, 17.98, -8.22, 17.98)
    ..cubicTo(-8.14, 17.98, -7.49, 17.65, -7.1, 17.4)
    ..cubicTo(-6.81, 17.22, -6.77, 17.2, -6.76, 17.25)
    ..cubicTo(-6.74, 17.35, -6.52, 17.29, -6.24, 17.1)
    ..cubicTo(-6.15, 17.04, -6.08, 17.01, -6.08, 17.03)
    ..cubicTo(-6.07, 17.12, -6.03, 17.14, -5.93, 17.09)
    ..cubicTo(-5.82, 17.03, -5.57, 16.85, -5.43, 16.72)
    ..lineTo(-5.32, 16.62)
    ..lineTo(-5.29, 16.75)
    ..cubicTo(-5.27, 16.82, -5.24, 16.88, -5.22, 16.88)
    ..cubicTo(-5.13, 16.88, -4.78, 16.53, -4.65, 16.31)
    ..lineTo(-4.6, 16.23)
    ..lineTo(-4.57, 16.36)
    ..cubicTo(-4.55, 16.46, -4.53, 16.5, -4.49, 16.51)
    ..cubicTo(-4.42, 16.52, -4.08, 16.17, -4, 16.01)
    ..lineTo(-3.94, 15.89)
    ..lineTo(-3.92, 15.98)
    ..cubicTo(-3.88, 16.12, -3.82, 16.15, -3.72, 16.06)
    ..cubicTo(-3.63, 15.98, -3.45, 15.71, -3.37, 15.52)
    ..cubicTo(-3.31, 15.39, -3.26, 15.37, -3.26, 15.48)
    ..cubicTo(-3.26, 15.51, -3.25, 15.56, -3.23, 15.58)
    ..cubicTo(-3.21, 15.62, -3.2, 15.62, -3.12, 15.58)
    ..cubicTo(-2.99, 15.51, -2.84, 15.28, -2.78, 15.06)
    ..lineTo(-2.74, 14.88)
    ..lineTo(-2.69, 14.95)
    ..cubicTo(-2.66, 14.99, -2.62, 15.02, -2.59, 15.02)
    ..cubicTo(-2.52, 15.02, -2.39, 14.83, -2.28, 14.58)
    ..cubicTo(-2.21, 14.42, -2.19, 14.4, -2.18, 14.45)
    ..cubicTo(-2.15, 14.54, -2.08, 14.55, -2, 14.49)
    ..cubicTo(-1.91, 14.43, -1.72, 14.07, -1.7, 13.92)
    ..cubicTo(-1.68, 13.83, -1.67, 13.81, -1.63, 13.83)
    ..cubicTo(-1.48, 13.89, -1.45, 13.86, -1.29, 13.47)
    ..cubicTo(-1.21, 13.25, -1.18, 13.22, -1.14, 13.28)
    ..cubicTo(-1.13, 13.29, -1.1, 13.31, -1.07, 13.31)
    ..cubicTo(-0.98, 13.31, -0.91, 13.11, -0.85, 12.78)
    ..cubicTo(-0.8, 12.53, -0.79, 12.49, -0.76, 12.53)
    ..cubicTo(-0.72, 12.59, -0.66, 12.59, -0.62, 12.53)
    ..cubicTo(-0.6, 12.52, -0.52, 12.23, -0.44, 11.9)
    ..cubicTo(-0.35, 11.57, -0.27, 11.29, -0.26, 11.28)
    ..cubicTo(-0.25, 11.27, -0.25, 11.33, -0.26, 11.41)
    ..cubicTo(-0.3, 11.74, -0.37, 12.51, -0.39, 12.93)
    ..cubicTo(-0.41, 13.37, -0.4, 13.7, -0.34, 14.23)
    ..cubicTo(-0.24, 15.09, -0.22, 15.31, -0.18, 15.83)
    ..cubicTo(-0.16, 16.16, -0.14, 16.62, -0.15, 16.89)
    ..lineTo(-0.15, 17.38)
    ..lineTo(0.03, 17.39)
    ..cubicTo(0.16, 17.4, 0.21, 17.39, 0.22, 17.36)
    ..cubicTo(0.23, 17.34, 0.23, 16.97, 0.22, 16.53)
    ..cubicTo(0.2, 15.82, 0.18, 15.55, 0.09, 14.66)
    ..cubicTo(0.07, 14.51, 0.04, 14.21, 0.01, 13.98)
    ..cubicTo(-0.03, 13.52, -0.04, 12.98, 0, 12.52)
    ..cubicTo(0.07, 11.74, 0.15, 11, 0.17, 11.02)
    ..cubicTo(0.18, 11.03, 0.24, 11.22, 0.31, 11.45)
    ..cubicTo(0.48, 12.04, 0.61, 12.44, 0.66, 12.51)
    ..cubicTo(0.71, 12.57, 0.82, 12.6, 0.82, 12.55)
    ..cubicTo(0.82, 12.53, 0.83, 12.52, 0.84, 12.52)
    ..cubicTo(0.86, 12.52, 0.87, 12.59, 0.88, 12.66)
    ..cubicTo(0.93, 12.97, 0.99, 13.2, 1.06, 13.27)
    ..cubicTo(1.12, 13.33, 1.13, 13.34, 1.19, 13.3)
    ..cubicTo(1.26, 13.25, 1.26, 13.25, 1.36, 13.52)
    ..cubicTo(1.42, 13.66, 1.49, 13.81, 1.52, 13.84)
    ..cubicTo(1.57, 13.89, 1.58, 13.89, 1.66, 13.85)
    ..lineTo(1.74, 13.81)
    ..lineTo(1.76, 13.92)
    ..cubicTo(1.78, 14.05, 1.91, 14.34, 2.01, 14.45)
    ..cubicTo(2.1, 14.56, 2.17, 14.57, 2.23, 14.48)
    ..cubicTo(2.26, 14.44, 2.28, 14.43, 2.28, 14.46)
    ..cubicTo(2.28, 14.48, 2.33, 14.6, 2.39, 14.73)
    ..cubicTo(2.53, 15.02, 2.62, 15.08, 2.71, 14.95)
    ..lineTo(2.78, 14.87)
    ..lineTo(2.8, 14.99)
    ..cubicTo(2.84, 15.25, 3.11, 15.63, 3.23, 15.61)
    ..cubicTo(3.26, 15.6, 3.29, 15.55, 3.31, 15.47)
    ..lineTo(3.34, 15.34)
    ..lineTo(3.37, 15.45)
    ..cubicTo(3.41, 15.57, 3.64, 15.94, 3.74, 16.04)
    ..cubicTo(3.84, 16.15, 3.9, 16.14, 3.94, 16.01)
    ..lineTo(3.97, 15.89)
    ..lineTo(4.06, 16.04)
    ..cubicTo(4.15, 16.21, 4.45, 16.51, 4.51, 16.51)
    ..cubicTo(4.57, 16.51, 4.58, 16.48, 4.61, 16.34)
    ..lineTo(4.63, 16.22)
    ..lineTo(4.72, 16.36)
    ..cubicTo(4.84, 16.55, 5.19, 16.88, 5.25, 16.87)
    ..cubicTo(5.29, 16.87, 5.31, 16.82, 5.33, 16.75)
    ..lineTo(5.36, 16.63)
    ..lineTo(5.55, 16.79)
    ..cubicTo(5.78, 16.99, 6.03, 17.14, 6.07, 17.12)
    ..cubicTo(6.09, 17.11, 6.1, 17.07, 6.1, 17.04)
    ..cubicTo(6.1, 16.99, 6.11, 16.99, 6.2, 17.06)
    ..cubicTo(6.34, 17.17, 6.65, 17.31, 6.73, 17.29)
    ..cubicTo(6.77, 17.29, 6.79, 17.27, 6.78, 17.24)
    ..cubicTo(6.78, 17.21, 6.78, 17.19, 6.79, 17.19)
    ..cubicTo(6.8, 17.19, 6.91, 17.25, 7.04, 17.34)
    ..cubicTo(7.48, 17.63, 8.15, 17.98, 8.27, 17.98)
    ..cubicTo(8.39, 17.98, 8.03, 17.38, 7.54, 16.77)
    ..cubicTo(7.39, 16.57, 7.38, 16.55, 7.43, 16.53)
    ..cubicTo(7.48, 16.52, 7.49, 16.5, 7.47, 16.43)
    ..cubicTo(7.44, 16.33, 7.33, 16.13, 7.21, 16.01)
    ..cubicTo(7.11, 15.89, 7.1, 15.87, 7.16, 15.87)
    ..cubicTo(7.23, 15.87, 7.24, 15.81, 7.18, 15.73)
    ..cubicTo(7.16, 15.69, 7.03, 15.54, 6.9, 15.41)
    ..cubicTo(6.69, 15.2, 6.67, 15.16, 6.71, 15.15)
    ..cubicTo(6.85, 15.1, 6.89, 15.07, 6.89, 15.04)
    ..cubicTo(6.89, 14.97, 6.54, 14.67, 6.35, 14.57)
    ..lineTo(6.18, 14.48)
    ..lineTo(6.31, 14.44)
    ..cubicTo(6.41, 14.41, 6.44, 14.39, 6.44, 14.35)
    ..cubicTo(6.44, 14.27, 6.18, 14.05, 5.97, 13.94)
    ..lineTo(5.79, 13.86)
    ..lineTo(5.88, 13.82)
    ..cubicTo(5.99, 13.77, 6.01, 13.71, 5.94, 13.63)
    ..cubicTo(5.86, 13.55, 5.52, 13.38, 5.33, 13.33)
    ..cubicTo(5.21, 13.29, 5.16, 13.25, 5.25, 13.25)
    ..cubicTo(5.31, 13.25, 5.43, 13.19, 5.43, 13.15)
    ..cubicTo(5.43, 13.1, 5.26, 12.95, 5.13, 12.89)
    ..cubicTo(5.07, 12.86, 4.93, 12.82, 4.82, 12.8)
    ..cubicTo(4.68, 12.77, 4.64, 12.76, 4.68, 12.74)
    ..cubicTo(4.71, 12.72, 4.77, 12.71, 4.81, 12.72)
    ..cubicTo(4.91, 12.74, 4.98, 12.68, 4.98, 12.57)
    ..cubicTo(4.98, 12.52, 4.99, 12.49, 5, 12.49)
    ..cubicTo(5.01, 12.49, 5.1, 12.55, 5.21, 12.62)
    ..cubicTo(5.48, 12.8, 5.79, 12.92, 6, 12.92)
    ..cubicTo(6.21, 12.93, 6.25, 12.88, 6.18, 12.73)
    ..cubicTo(6.15, 12.68, 6.14, 12.63, 6.14, 12.63)
    ..cubicTo(6.15, 12.63, 6.28, 12.7, 6.43, 12.77)
    ..cubicTo(6.75, 12.93, 6.96, 13, 7.09, 12.99)
    ..lineTo(7.19, 12.98)
    ..lineTo(7.18, 12.8)
    ..lineTo(7.18, 12.63)
    ..lineTo(7.29, 12.73)
    ..cubicTo(7.57, 12.97, 8.08, 13.14, 8.31, 13.08)
    ..cubicTo(8.43, 13.04, 8.44, 13, 8.33, 12.81)
    ..cubicTo(8.28, 12.73, 8.24, 12.67, 8.24, 12.66)
    ..cubicTo(8.24, 12.65, 8.34, 12.69, 8.46, 12.75)
    ..cubicTo(8.85, 12.94, 9.38, 13.07, 9.53, 13.02)
    ..cubicTo(9.61, 12.99, 9.61, 12.91, 9.52, 12.75)
    ..cubicTo(9.48, 12.68, 9.45, 12.62, 9.46, 12.61)
    ..cubicTo(9.47, 12.61, 9.52, 12.63, 9.59, 12.66)
    ..cubicTo(9.78, 12.75, 10.06, 12.81, 10.37, 12.81)
    ..cubicTo(10.77, 12.81, 10.78, 12.79, 10.53, 12.42)
    ..cubicTo(10.48, 12.34, 10.48, 12.34, 10.53, 12.36)
    ..cubicTo(10.82, 12.47, 11.56, 12.56, 11.77, 12.51)
    ..cubicTo(11.84, 12.49, 11.87, 12.39, 11.82, 12.33)
    ..cubicTo(11.81, 12.32, 11.77, 12.26, 11.74, 12.21)
    ..lineTo(11.68, 12.11)
    ..lineTo(12.04, 12.11)
    ..cubicTo(12.44, 12.1, 12.86, 12.05, 12.93, 12)
    ..cubicTo(12.97, 11.97, 12.97, 11.96, 12.93, 11.88)
    ..cubicTo(12.9, 11.83, 12.88, 11.78, 12.88, 11.77)
    ..cubicTo(12.88, 11.76, 12.97, 11.76, 13.06, 11.76)
    ..cubicTo(13.35, 11.76, 13.85, 11.61, 13.91, 11.5)
    ..cubicTo(13.92, 11.48, 13.91, 11.45, 13.87, 11.42)
    ..cubicTo(13.84, 11.39, 13.81, 11.36, 13.81, 11.36)
    ..cubicTo(13.81, 11.35, 13.9, 11.33, 14.02, 11.33)
    ..cubicTo(14.29, 11.3, 15.22, 11.13, 15.55, 11.04)
    ..cubicTo(16.01, 10.93, 16.23, 10.84, 16.23, 10.77)
    ..cubicTo(16.23, 10.68, 15.04, 10.34, 14.19, 10.2)
    ..cubicTo(13.81, 10.13, 13.82, 10.14, 13.89, 10.06)
    ..lineTo(13.96, 9.99)
    ..lineTo(13.88, 9.94)
    ..cubicTo(13.74, 9.82, 13.26, 9.68, 13.02, 9.68)
    ..lineTo(12.91, 9.68)
    ..lineTo(12.97, 9.58)
    ..cubicTo(13.01, 9.51, 13.02, 9.48, 12.99, 9.46)
    ..cubicTo(12.93, 9.41, 12.48, 9.34, 12.1, 9.32)
    ..lineTo(11.74, 9.3)
    ..lineTo(11.84, 9.13)
    ..cubicTo(11.93, 8.98, 11.94, 8.97, 11.89, 8.93)
    ..cubicTo(11.76, 8.84, 11.09, 8.86, 10.74, 8.97)
    ..cubicTo(10.64, 9, 10.56, 9.02, 10.56, 9.02)
    ..cubicTo(10.55, 9.02, 10.6, 8.94, 10.66, 8.85)
    ..cubicTo(10.84, 8.58, 10.82, 8.55, 10.41, 8.55)
    ..cubicTo(10.15, 8.55, 9.81, 8.61, 9.63, 8.69)
    ..lineTo(9.51, 8.75)
    ..lineTo(9.59, 8.6)
    ..cubicTo(9.75, 8.32, 9.69, 8.26, 9.31, 8.32)
    ..cubicTo(9.02, 8.36, 8.65, 8.49, 8.32, 8.66)
    ..cubicTo(8.31, 8.66, 8.34, 8.59, 8.4, 8.5)
    ..cubicTo(8.52, 8.3, 8.51, 8.24, 8.35, 8.21)
    ..cubicTo(8.1, 8.15, 7.65, 8.31, 7.33, 8.56)
    ..cubicTo(7.24, 8.63, 7.22, 8.64, 7.24, 8.59)
    ..cubicTo(7.25, 8.57, 7.27, 8.49, 7.28, 8.42)
    ..cubicTo(7.29, 8.31, 7.29, 8.3, 7.22, 8.27)
    ..cubicTo(7.13, 8.23, 6.87, 8.29, 6.53, 8.45)
    ..cubicTo(6.39, 8.52, 6.26, 8.58, 6.24, 8.58)
    ..cubicTo(6.23, 8.58, 6.24, 8.54, 6.27, 8.5)
    ..cubicTo(6.31, 8.42, 6.35, 8.4, 6.6, 8.32)
    ..cubicTo(7.25, 8.12, 7.48, 8.05, 7.55, 8)
    ..cubicTo(7.65, 7.94, 7.65, 7.83, 7.52, 7.67)
    ..lineTo(7.42, 7.54)
    ..lineTo(7.55, 7.54)
    ..cubicTo(7.73, 7.54, 8.19, 7.44, 8.44, 7.36)
    ..cubicTo(9.16, 7.09, 9.41, 6.78, 9, 6.65)
    ..cubicTo(8.91, 6.63, 8.83, 6.6, 8.8, 6.59)
    ..cubicTo(8.78, 6.59, 8.93, 6.54, 9.13, 6.48)
    ..cubicTo(9.68, 6.34, 10.12, 6.16, 10.26, 6.01)
    ..cubicTo(10.37, 5.9, 10.33, 5.83, 10.12, 5.67)
    ..lineTo(9.93, 5.53)
    ..lineTo(10.2, 5.51)
    ..cubicTo(10.78, 5.46, 11.28, 5.27, 11.57, 4.98)
    ..cubicTo(11.73, 4.82, 11.76, 4.73, 11.7, 4.68)
    ..cubicTo(11.68, 4.66, 11.54, 4.61, 11.38, 4.56)
    ..cubicTo(11.24, 4.51, 11.12, 4.46, 11.13, 4.44)
    ..cubicTo(11.14, 4.43, 11.16, 4.42, 11.18, 4.42)
    ..cubicTo(11.27, 4.42, 11.71, 4.27, 12, 4.15)
    ..cubicTo(12.56, 3.91, 12.97, 3.63, 12.97, 3.5)
    ..cubicTo(12.97, 3.41, 12.89, 3.36, 12.61, 3.28)
    ..cubicTo(12.48, 3.24, 12.38, 3.2, 12.38, 3.18)
    ..cubicTo(12.38, 3.17, 12.45, 3.15, 12.54, 3.13)
    ..cubicTo(12.73, 3.09, 13.07, 2.92, 13.33, 2.74)
    ..cubicTo(13.6, 2.55, 13.87, 2.3, 13.93, 2.2)
    ..cubicTo(13.98, 2.12, 13.98, 2.12, 13.93, 2.07)
    ..cubicTo(13.9, 2.05, 13.75, 1.99, 13.6, 1.96)
    ..cubicTo(13.45, 1.92, 13.3, 1.88, 13.28, 1.87)
    ..cubicTo(13.25, 1.86, 13.34, 1.81, 13.47, 1.76)
    ..cubicTo(13.59, 1.71, 13.8, 1.6, 13.94, 1.52)
    ..cubicTo(14.39, 1.23, 14.91, 0.77, 14.91, 0.64)
    ..cubicTo(14.91, 0.57, 14.81, 0.52, 14.56, 0.46)
    ..cubicTo(14.44, 0.42, 14.34, 0.39, 14.33, 0.39)
    ..cubicTo(14.32, 0.38, 14.35, 0.35, 14.39, 0.33)
    ..cubicTo(14.74, 0.1, 15.64, -0.89, 15.64, -1.04)
    ..cubicTo(15.64, -1.07, 15.6, -1.1, 15.49, -1.13)
    ..cubicTo(15.4, -1.14, 15.33, -1.17, 15.33, -1.18)
    ..cubicTo(15.33, -1.19, 15.4, -1.26, 15.49, -1.35)
    ..cubicTo(15.57, -1.43, 15.71, -1.58, 15.78, -1.68)
    ..cubicTo(15.95, -1.9, 16.17, -2.34, 16.18, -2.46)
    ..cubicTo(16.19, -2.54, 16.19, -2.55, 16.04, -2.55)
    ..cubicTo(15.96, -2.56, 15.89, -2.57, 15.89, -2.58)
    ..cubicTo(15.89, -2.59, 15.97, -2.68, 16.07, -2.79)
    ..cubicTo(16.47, -3.25, 17.17, -4.2, 17.55, -4.78)
    ..cubicTo(17.76, -5.1, 18, -5.57, 18, -5.65)
    ..cubicTo(18, -5.86, 16.41, -5.06, 15.05, -4.16)
    ..lineTo(14.68, -3.91)
    ..lineTo(14.7, -4.05)
    ..cubicTo(14.72, -4.23, 14.69, -4.24, 14.44, -4.18)
    ..cubicTo(14.1, -4.08, 13.62, -3.82, 13.38, -3.6)
    ..cubicTo(13.31, -3.53, 13.24, -3.49, 13.24, -3.49)
    ..cubicTo(13.24, -3.5, 13.22, -3.58, 13.2, -3.67)
    ..cubicTo(13.17, -3.79, 13.15, -3.83, 13.11, -3.83)
    ..cubicTo(12.98, -3.83, 12.18, -3.25, 11.78, -2.88)
    ..cubicTo(11.67, -2.77, 11.56, -2.67, 11.56, -2.67)
    ..cubicTo(11.55, -2.67, 11.53, -2.77, 11.52, -2.87)
    ..cubicTo(11.5, -3.13, 11.43, -3.28, 11.35, -3.27)
    ..cubicTo(11.25, -3.25, 11.07, -3.11, 10.79, -2.83)
    ..cubicTo(10.46, -2.5, 10.26, -2.24, 10.1, -1.94)
    ..lineTo(9.99, -1.74)
    ..lineTo(9.96, -1.99)
    ..cubicTo(9.9, -2.46, 9.85, -2.55, 9.71, -2.47)
    ..cubicTo(9.6, -2.41, 9.13, -1.95, 8.97, -1.75)
    ..cubicTo(8.82, -1.55, 8.61, -1.14, 8.61, -1.06)
    ..cubicTo(8.61, -0.95, 8.55, -1.05, 8.52, -1.23)
    ..cubicTo(8.46, -1.59, 8.38, -1.7, 8.25, -1.63)
    ..cubicTo(8, -1.5, 7.47, -0.66, 7.27, -0.1)
    ..cubicTo(7.23, 0.02, 7.19, 0.11, 7.18, 0.1)
    ..cubicTo(7.17, 0.1, 7.15, -0.02, 7.11, -0.16)
    ..cubicTo(7.09, -0.3, 7.06, -0.44, 7.05, -0.47)
    ..cubicTo(7.04, -0.51, 7.01, -0.53, 6.96, -0.53)
    ..cubicTo(6.85, -0.53, 6.75, -0.47, 6.57, -0.28)
    ..cubicTo(6.31, 0.01, 6.08, 0.53, 6.03, 0.99)
    ..cubicTo(6.02, 1.08, 6, 1.14, 5.99, 1.14)
    ..cubicTo(5.98, 1.13, 5.92, 1.04, 5.85, 0.93)
    ..cubicTo(5.72, 0.71, 5.67, 0.68, 5.53, 0.79)
    ..cubicTo(5.38, 0.91, 5.07, 1.51, 4.91, 2)
    ..cubicTo(4.88, 2.08, 4.85, 2.16, 4.84, 2.17)
    ..cubicTo(4.83, 2.19, 4.8, 2.12, 4.78, 2.04)
    ..cubicTo(4.75, 1.87, 4.69, 1.77, 4.62, 1.77)
    ..cubicTo(4.35, 1.77, 3.88, 2.6, 3.76, 3.26)
    ..lineTo(3.73, 3.46)
    ..lineTo(3.61, 3.34)
    ..cubicTo(3.43, 3.18, 3.34, 3.19, 3.24, 3.38)
    ..cubicTo(3.14, 3.56, 3.1, 3.6, 3.06, 3.6)
    ..cubicTo(3.01, 3.6, 3.06, 3.46, 3.34, 2.87)
    ..cubicTo(3.65, 2.22, 3.75, 1.98, 3.74, 1.88)
    ..cubicTo(3.72, 1.79, 3.57, 1.72, 3.38, 1.72)
    ..lineTo(3.23, 1.72)
    ..lineTo(3.38, 1.51)
    ..cubicTo(3.6, 1.23, 3.75, 0.95, 3.87, 0.66)
    ..cubicTo(4.08, 0.14, 4.14, -0.28, 4.02, -0.4)
    ..cubicTo(3.94, -0.47, 3.84, -0.46, 3.63, -0.33)
    ..cubicTo(3.54, -0.27, 3.47, -0.23, 3.47, -0.24)
    ..cubicTo(3.46, -0.24, 3.53, -0.39, 3.62, -0.55)
    ..cubicTo(4, -1.24, 4.22, -1.89, 4.13, -2.08)
    ..cubicTo(4.1, -2.15, 4.08, -2.17, 3.98, -2.17)
    ..cubicTo(3.92, -2.16, 3.79, -2.15, 3.7, -2.12)
    ..cubicTo(3.42, -2.06, 3.4, -2.06, 3.54, -2.2)
    ..cubicTo(3.81, -2.49, 4.03, -2.86, 4.17, -3.26)
    ..cubicTo(4.25, -3.5, 4.26, -3.56, 4.26, -3.86)
    ..cubicTo(4.26, -4.16, 4.26, -4.19, 4.2, -4.25)
    ..lineTo(4.14, -4.31)
    ..lineTo(3.81, -4.13)
    ..cubicTo(3.52, -3.96, 3.43, -3.92, 3.43, -3.95)
    ..cubicTo(3.43, -3.96, 3.47, -4.03, 3.51, -4.1)
    ..cubicTo(3.9, -4.77, 4.24, -6.05, 4.11, -6.3)
    ..cubicTo(4.06, -6.39, 3.94, -6.37, 3.68, -6.22)
    ..cubicTo(3.44, -6.08, 3.31, -6.02, 3.32, -6.06)
    ..cubicTo(3.33, -6.08, 3.37, -6.17, 3.42, -6.26)
    ..cubicTo(3.58, -6.57, 3.68, -6.99, 3.73, -7.56)
    ..cubicTo(3.75, -7.84, 3.72, -8.19, 3.67, -8.26)
    ..cubicTo(3.62, -8.33, 3.53, -8.3, 3.18, -8.06)
    ..cubicTo(3, -7.95, 2.85, -7.85, 2.85, -7.86)
    ..cubicTo(2.85, -7.86, 2.88, -7.96, 2.93, -8.09)
    ..cubicTo(3.09, -8.51, 3.18, -9.06, 3.18, -9.68)
    ..cubicTo(3.18, -10.09, 3.15, -10.28, 3.08, -10.31)
    ..cubicTo(3.02, -10.33, 2.82, -10.22, 2.59, -10.06)
    ..cubicTo(2.5, -9.99, 2.42, -9.93, 2.41, -9.93)
    ..cubicTo(2.41, -9.93, 2.41, -10.04, 2.42, -10.18)
    ..cubicTo(2.48, -10.75, 2.32, -12.17, 2.19, -12.25)
    ..cubicTo(2.17, -12.27, 2.02, -12.19, 1.86, -12.07)
    ..cubicTo(1.79, -12.03, 1.79, -12.03, 1.81, -12.1)
    ..cubicTo(1.83, -12.2, 1.79, -12.71, 1.73, -12.95)
    ..cubicTo(1.64, -13.35, 1.42, -13.85, 1.32, -13.89)
    ..cubicTo(1.3, -13.9, 1.24, -13.86, 1.16, -13.78)
    ..lineTo(1.05, -13.65)
    ..lineTo(1.01, -13.92)
    ..cubicTo(0.94, -14.55, 0.69, -15.8, 0.49, -16.61)
    ..cubicTo(0.31, -17.32, 0.08, -17.95, 0, -17.95)
    ..cubicTo(-0.01, -17.95, -0.06, -17.87, -0.11, -17.79)
    ..close();
  c.drawPath(p0, f);
}

void _paintAkhet(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-20, 8)
    ..cubicTo(-12, 8, -10, 4, -6, 4)
    ..lineTo(6, 4)
    ..cubicTo(10, 4, 12, 8, 20, 8);
  c.drawPath(p0, s);
  c.drawOval(
    Rect.fromCenter(center: const Offset(0, -3), width: 14, height: 14),
    s,
  );
  final p2 = Path()
    ..moveTo(-6, 4)
    ..cubicTo(-4, 1, 4, 1, 6, 4);
  c.drawPath(p2, s);
}



void _paintNefer(Canvas c, Paint s, Paint f) {
  c.drawOval(
    Rect.fromCenter(center: const Offset(0, 9), width: 12, height: 14),
    s,
  );
  final p1 = Path()
    ..moveTo(0, 2)
    ..lineTo(0, -16);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(-5, -10)
    ..lineTo(5, -10);
  c.drawPath(p2, s);
  final p3 = Path()
    ..moveTo(-5, -6)
    ..lineTo(5, -6);
  c.drawPath(p3, s);
}

void _paintNetjer(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-2, -16)
    ..lineTo(-2, 16);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(-2, -16)
    ..lineTo(10, -13)
    ..lineTo(-2, -7);
  c.drawPath(p1, s);
}


void _paintSedge(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(0, 16)
    ..lineTo(0, -6);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(0, -6)
    ..cubicTo(-6, -8, -8, -14, -6, -18)
    ..cubicTo(-2, -16, 0, -11, 0, -6)
    ..close();
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(0, -8)
    ..cubicTo(3, -12, 7, -13, 9, -11)
    ..cubicTo(7, -8, 3, -7, 0, -8);
  c.drawPath(p2, s);
}

void _paintWick(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-2, 16)
    ..cubicTo(-7, 12, -7, 7, -2, 4)
    ..cubicTo(3, 1, 3, -4, -2, -7)
    ..cubicTo(-7, -10, -7, -15, -2, -18);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(2, 16)
    ..cubicTo(7, 12, 7, 7, 2, 4)
    ..cubicTo(-3, 1, -3, -4, 2, -7)
    ..cubicTo(7, -10, 7, -15, 2, -18);
  c.drawPath(p1, s);
}

void _paintSundisc(Canvas c, Paint s, Paint f) {
  c.drawOval(
    Rect.fromCenter(center: const Offset(0, 0), width: 18, height: 18),
    s,
  );
  c.drawOval(
    Rect.fromCenter(center: const Offset(0, 0), width: 4.4, height: 4.4),
    s,
  );
}




void _paintCloth(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(0, -14)
    ..lineTo(0, 14);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(0, -14)
    ..lineTo(6, -8)
    ..lineTo(0, -2)
    ..moveTo(0, 0)
    ..lineTo(6, 6)
    ..lineTo(0, 12);
  c.drawPath(p1, s);
}


void _paintTyet(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(0, -6)
    ..cubicTo(-5, -6, -7, -12, -4, -16)
    ..cubicTo(-1, -20, 1, -20, 4, -16)
    ..cubicTo(7, -12, 5, -6, 0, -6)
    ..close();
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(0, -6)
    ..lineTo(0, 16);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(0, -3)
    ..cubicTo(-7, -2, -8, 5, -3, 7)
    ..cubicTo(-1, 7.5, -1, 9, -2, 10);
  c.drawPath(p2, s);
  final p3 = Path()
    ..moveTo(0, -3)
    ..cubicTo(7, -2, 8, 5, 3, 7)
    ..cubicTo(1, 7.5, 1, 9, 2, 10);
  c.drawPath(p3, s);
}

void _paintShen(Canvas c, Paint s, Paint f) {
  c.drawOval(
    Rect.fromCenter(center: const Offset(0, -3), width: 20, height: 20),
    s,
  );
  final p0 = Path()
    ..moveTo(-9, 7)
    ..lineTo(-9, 12)
    ..moveTo(9, 7)
    ..lineTo(9, 12)
    ..moveTo(-10, 12)
    ..lineTo(10, 12);
  c.drawPath(p0, s);
}


void _paintHeart(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-8, -2)
    ..cubicTo(-11, 6, -6, 15, 0, 15)
    ..cubicTo(6, 15, 11, 6, 8, -2)
    ..cubicTo(6, -7, -6, -7, -8, -2)
    ..close();
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(-5, -6)
    ..lineTo(-6, -12)
    ..moveTo(5, -6)
    ..lineTo(6, -12)
    ..moveTo(-7, -12)
    ..lineTo(7, -12);
  c.drawPath(p1, s);
}


void _paintVex(Canvas c, Paint s, Paint f) {
  c.drawOval(
    Rect.fromCenter(center: const Offset(-8, 7), width: 5.5, height: 5.5),
    f,
  );
  final p0 = Path()
    ..moveTo(-6, 6)
    ..lineTo(2, 3);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(2, 8)
    ..lineTo(2, -9)
    ..cubicTo(2, -14, 9, -14, 8, -9)
    ..cubicTo(7.5, -6, 5, -6, 5, -8);
  c.drawPath(p1, s);
}


void _paintLo(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(0, -13)
    ..cubicTo(-11, -13, -16, -2, -11, 5)
    ..cubicTo(-9, 9, -4, 9, -4, 4);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(0, -13)
    ..cubicTo(11, -13, 16, -2, 11, 5)
    ..cubicTo(9, 9, 4, 9, 4, 4);
  c.drawPath(p1, s);
  c.drawOval(
    Rect.fromCenter(center: const Offset(-4, 5), width: 2.6, height: 2.6),
    f,
  );
  c.drawOval(
    Rect.fromCenter(center: const Offset(4, 5), width: 2.6, height: 2.6),
    f,
  );
}



void _paintJah(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-9, -14)
    ..lineTo(-9, 14);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(9, -14)
    ..lineTo(9, 14);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(-9, -12)
    ..lineTo(9, 5)
    ..moveTo(9, -12)
    ..lineTo(-9, 5);
  c.drawPath(p2, s);
  c.drawOval(
    Rect.fromCenter(center: const Offset(0, 14), width: 3, height: 3),
    s,
  );
}

void _paintCham(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-6, -15)
    ..lineTo(-6, 15);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(-6, -14)
    ..lineTo(8, -7)
    ..lineTo(-6, 0)
    ..moveTo(-6, 0)
    ..lineTo(8, 7)
    ..lineTo(-6, 14);
  c.drawPath(p1, s);
}

void _paintZod(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(6, -11)
    ..lineTo(-4, -6)
    ..lineTo(5, -1)
    ..lineTo(-5, 5)
    ..lineTo(2, 11);
  c.drawPath(p0, s);
  c.drawOval(
    Rect.fromCenter(center: const Offset(9, -13), width: 4, height: 4),
    s,
  );
  c.drawOval(
    Rect.fromCenter(center: const Offset(-6, 13), width: 2.6, height: 2.6),
    s,
  );
  c.drawOval(
    Rect.fromCenter(center: const Offset(0, 15), width: 2.6, height: 2.6),
    s,
  );
}

void _paintCrook(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-1, 16)
    ..lineTo(-1, -8)
    ..cubicTo(-1, -16, 9, -16, 9, -9)
    ..cubicTo(9, -6, 5, -6, 4, -9);
  c.drawPath(p0, s);
}

void _paintFlail(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(0, -16)
    ..lineTo(0, -8);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(-3, -8)
    ..lineTo(3, -8);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(-3, -8)
    ..cubicTo(-6, -2, -8, 4, -7, 10);
  c.drawPath(p2, s);
  final p3 = Path()
    ..moveTo(0, -8)
    ..lineTo(0, 11);
  c.drawPath(p3, s);
  final p4 = Path()
    ..moveTo(3, -8)
    ..cubicTo(6, -2, 8, 4, 7, 10);
  c.drawPath(p4, s);
  c.drawOval(
    Rect.fromCenter(center: const Offset(-7, 11), width: 3, height: 3),
    f,
  );
  c.drawOval(
    Rect.fromCenter(center: const Offset(0, 12), width: 3, height: 3),
    f,
  );
  c.drawOval(
    Rect.fromCenter(center: const Offset(7, 11), width: 3, height: 3),
    f,
  );
}

void _paintHedjet(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-7, 16)
    ..cubicTo(-8, 4, -8, -8, -3, -15)
    ..cubicTo(-1, -18, 1, -18, 3, -15)
    ..cubicTo(8, -8, 8, 4, 7, 16);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(-8, 16)
    ..lineTo(8, 16);
  c.drawPath(p1, s);
}

void _paintDeshret(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-8, 12)
    ..lineTo(-8, -13)
    ..lineTo(3, -13)
    ..lineTo(5, 5);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(-8, 12)
    ..lineTo(6, 12);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(5, 5)
    ..cubicTo(12, 4, 13, -3, 9, -6)
    ..cubicTo(7, -8, 5, -6, 6, -4);
  c.drawPath(p2, s);
}

void _paintNub(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-14, -7)
    ..cubicTo(-14, 8, 14, 8, 14, -7);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(-11, -7)
    ..cubicTo(-11, 5, 11, 5, 11, -7);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(-14, -7)
    ..lineTo(-11, -7);
  c.drawPath(p2, s);
  final p3 = Path()
    ..moveTo(14, -7)
    ..lineTo(11, -7);
  c.drawPath(p3, s);
  c.drawOval(
    Rect.fromCenter(center: const Offset(-6, 6.5), width: 2.4, height: 2.4),
    f,
  );
  c.drawOval(
    Rect.fromCenter(center: const Offset(0, 7.3), width: 2.4, height: 2.4),
    f,
  );
  c.drawOval(
    Rect.fromCenter(center: const Offset(6, 6.5), width: 2.4, height: 2.4),
    f,
  );
}

void _paintSail(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(0, 16)
    ..lineTo(0, -15);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(0, -13)
    ..lineTo(9, -13);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(0, 5)
    ..lineTo(7, 5);
  c.drawPath(p2, s);
  final p3 = Path()
    ..moveTo(9, -13)
    ..cubicTo(13, -5, 11, 2, 7, 5);
  c.drawPath(p3, s);
}

void _paintHoe(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-13, 8)
    ..lineTo(10, -10);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(-13, 8)
    ..lineTo(3, 12);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(-7, 7)
    ..cubicTo(-5, 4, -2, 5, -1, 8);
  c.drawPath(p2, s);
}

void _paintPalette(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-14, -1)
    ..lineTo(8, -1)
    ..lineTo(8, 3)
    ..lineTo(-14, 3)
    ..close();
  c.drawPath(p0, s);
  c.drawOval(
    Rect.fromCenter(center: const Offset(2, 1), width: 2.6, height: 2.6),
    f,
  );
  c.drawOval(
    Rect.fromCenter(center: const Offset(6, 1), width: 2.6, height: 2.6),
    f,
  );
  final p1 = Path()
    ..moveTo(-13, 1)
    ..lineTo(-18, -13);
  c.drawPath(p1, s);
}


void _paintJackal(Canvas c, Paint s, Paint f) {
  final p0 = Path()
    ..moveTo(-16, -4)
    ..cubicTo(-10, -6, 4, -6, 14, -3);
  c.drawPath(p0, s);
  final p1 = Path()
    ..moveTo(-16, -4)
    ..cubicTo(-18, -5, -18, -9, -16, -12);
  c.drawPath(p1, s);
  final p2 = Path()
    ..moveTo(-16, -12)
    ..lineTo(-18, -19);
  c.drawPath(p2, s);
  final p3 = Path()
    ..moveTo(-16, -12)
    ..lineTo(-13, -19);
  c.drawPath(p3, s);
  final p4 = Path()
    ..moveTo(-16, -12)
    ..cubicTo(-21, -11, -22, -7, -19, -5);
  c.drawPath(p4, s);
  final p5 = Path()
    ..moveTo(-9, -3)
    ..lineTo(-9, 10)
    ..moveTo(-5, -3)
    ..lineTo(-5, 10);
  c.drawPath(p5, s);
  final p6 = Path()
    ..moveTo(6, -4)
    ..lineTo(6, 10)
    ..moveTo(10, -4)
    ..lineTo(10, 10);
  c.drawPath(p6, s);
  final p7 = Path()
    ..moveTo(-9, 10)
    ..lineTo(10, 10);
  c.drawPath(p7, s);
  final p8 = Path()
    ..moveTo(14, -3)
    ..cubicTo(18, -1, 18, 7, 13, 9);
  c.drawPath(p8, s);
}
