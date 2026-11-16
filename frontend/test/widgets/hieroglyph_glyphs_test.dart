import 'package:fireplace/models/chat_background_preference.dart';
import 'package:fireplace/theme/glass_theme.dart';
import 'package:fireplace/widgets/chat_background_pattern.dart';
import 'package:fireplace/widgets/hieroglyph_glyphs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registry has unique glyph names and exactly one leaf', () {
    expect(kHieroGlyphs, isNotEmpty);
    final names = kHieroGlyphs.map((g) => g.name).toList();
    expect(names.toSet().length, names.length, reason: 'names must be unique');
    expect(kHieroGlyphs.where((g) => g.isLeaf).length, 1);
  });

  testWidgets(
    'ChatBackgroundPattern renders the real painter over a full tall column '
    'without throwing',
    (tester) async {
      // Tall surface so the real _TempleColumnsPainter deals many rows across
      // several columns, exercising the actual bag-shuffle over the whole set.
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            extensions: const <ThemeExtension<dynamic>>[GlassTheme.dark],
          ),
          home: const Scaffold(
            body: ChatBackgroundPattern(
              patternColor: Color(0xFF8FC4D0),
              backgroundColor: Color(0xFF000000),
              layer: ChatBackgroundLayer.glyphs,
              child: SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(ChatBackgroundPattern), findsOneWidget);
    },
  );
}
