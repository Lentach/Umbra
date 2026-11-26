import 'dart:convert';

import 'package:fireplace/widgets/user_card/shared_media_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A3-MSG-B-11: the user card's fullscreen photo must not outlive its message.
void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  testWidgets('the fullscreen photo closes when its message is gone', (
    tester,
  ) async {
    final gone = ValueNotifier<bool>(false);
    addTearDown(gone.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSharedMediaFullscreen(
              context,
              png,
              goneWatch: (changes: gone, isGone: () => gone.value),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);

    gone.value = true;
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('a change that keeps the message leaves it open', (tester) async {
    final changes = ValueNotifier<int>(0);
    addTearDown(changes.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSharedMediaFullscreen(
              context,
              png,
              goneWatch: (changes: changes, isGone: () => false),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    changes.value++;
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });
}
