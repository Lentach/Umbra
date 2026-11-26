import 'dart:ui';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/widgets/message/ping_message_content.dart';
import 'package:fireplace/widgets/ping_effect_overlay.dart';
import 'package:fireplace/widgets/ping_glyph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/l10n.dart';

void main() {
  testWidgets(
    'PingEffectOverlay pumps, completes, and disposes without throw',
    (tester) async {
      var completed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PingEffectOverlay(onComplete: () => completed = true),
          ),
        ),
      );
      await tester.pump();
      final glyph = tester.widget<PingGlyph>(find.byType(PingGlyph));
      expect(glyph.size, 50);
      expect(glyph.color, Colors.white);
      await tester.pump(const Duration(milliseconds: 900));
      expect(completed, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  // Bug 3 residual: leaving the chat INSIDE the 800ms animation unmounts the
  // overlay before forward().then can run onComplete. Without the dispose
  // fallback the showPingEffect flag stays latched and the next chat entry
  // remounts the overlay and replays the sound (same-session replay).
  testWidgets('early unmount still reports completion exactly once', (
    tester,
  ) async {
    var completions = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PingEffectOverlay(onComplete: () => completions++),
        ),
      ),
    );
    // Mid-animation: 300ms of 800ms elapsed, onComplete not yet fired.
    await tester.pump(const Duration(milliseconds: 300));
    expect(completions, 0);

    // Route-pop equivalent: unmount the overlay before the animation ends.
    await tester.pumpWidget(const SizedBox.shrink());
    // Drain the dispose-scheduled microtask.
    await tester.pump();

    expect(completions, 1);

    // The pending forward().then must not double-fire after the timer window.
    await tester.pump(const Duration(milliseconds: 900));
    expect(completions, 1);
  });

  testWidgets('PingGlyph honors its requested compact size and color', (
    tester,
  ) async {
    const color = Color(0xFFEF6C00);
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: PingGlyph(size: 24, color: color)),
      ),
    );

    // The widget actually lays out at the requested size.
    expect(tester.getSize(find.byType(PingGlyph)), const Size.square(24));

    // The painter must actually stroke with the requested color: a real
    // rendered-pixel probe, not a constructor field read-back that cannot fail.
    final painter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byType(PingGlyph),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter!;

    final bytes = await tester.runAsync(() async {
      final recorder = PictureRecorder();
      painter.paint(Canvas(recorder), const Size.square(24));
      final image = await recorder.endRecording().toImage(24, 24);
      final data = await image.toByteData(format: ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    });

    var found = false;
    for (var i = 0; i + 3 < bytes!.length; i += 4) {
      if (bytes[i + 3] < 250) continue; // opaque core pixels only
      final r = bytes[i], g = bytes[i + 1], b = bytes[i + 2];
      if ((r - 0xEF).abs() <= 4 && (g - 0x6C).abs() <= 4 && b <= 4) {
        found = true;
        break;
      }
    }
    expect(found, isTrue,
        reason: 'painter must stroke with the requested color');
  });

  testWidgets('ping message uses the shared glyph beside its label', (
    tester,
  ) async {
    const color = Color(0xFF123456);
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PingMessageContent(isMine: false, textColor: color),
        ),
      ),
    );

    final glyph = tester.widget<PingGlyph>(find.byType(PingGlyph));
    expect(glyph.size, 18);
    expect(glyph.color, color);
    expect(find.text(l10n.ping), findsOneWidget);
    expect(find.byIcon(Icons.campaign), findsNothing);
  });
}
