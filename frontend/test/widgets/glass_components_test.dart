import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/glass/glass_dialog.dart';
import 'package:fireplace/widgets/glass/glass_surface.dart';
import 'package:fireplace/widgets/glass/glass_menu.dart';

Widget _host(void Function(BuildContext) onPressed) {
  return MaterialApp(
    theme: RpgTheme.themeDataDarkGray,
    home: Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => onPressed(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('showGlassMenu', () {
    testWidgets('opens, shows entries, returns the tapped value, dismisses', (
      tester,
    ) async {
      String? result = 'unset';
      await tester.pumpWidget(
        _host((context) async {
          result = await showGlassMenu<String>(
            context: context,
            entries: const [
              GlassMenuEntry(value: 'a', child: Text('Alpha')),
              GlassMenuEntry(
                value: 'b',
                child: Text('Beta'),
                destructive: true,
              ),
            ],
          );
        }),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);

      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(result, 'b');
      // menu is gone after selection
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets('barrier tap dismisses and returns null', (tester) async {
      String? result = 'unset';
      await tester.pumpWidget(
        _host((context) async {
          result = await showGlassMenu<String>(
            context: context,
            entries: const [GlassMenuEntry(value: 'a', child: Text('Alpha'))],
          );
        }),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);

      await tester.tapAt(const Offset(5, 5)); // outside the menu
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.text('Alpha'), findsNothing);
    });
  });

  group('GlassDialog', () {
    testWidgets('exposes a scoped, named alert-dialog route in the tree', (
      tester,
    ) async {
      // Android so GlassDialog emits the labelled route wrapper (null on iOS).
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _host((context) {
            showDialog<void>(
              context: context,
              builder: (_) => const GlassDialog(
                title: Text('Delete message?'),
                content: Text('This cannot be undone.'),
              ),
            );
          }),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        // Regression guard for the base-Dialog swap: the computed node must be
        // a scoped + named route (base Dialog omits these; AlertDialog set them)
        // so screen readers announce it as a dialog route.
        final node = tester.getSemantics(find.bySemanticsLabel('Alert'));
        expect(node.flagsCollection.scopesRoute, isTrue);
        expect(node.flagsCollection.namesRoute, isTrue);
      } finally {
        handle.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  testWidgets('menu anchored bottom-right stays on screen and is tappable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? result = 'unset';
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataDarkGray,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showGlassMenu<String>(
                    context: context,
                    entries: const [
                      GlassMenuEntry(value: 'a', child: Text('Alpha')),
                      GlassMenuEntry(value: 'b', child: Text('Beta')),
                    ],
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Delegate flipped the menu above the bottom-anchored trigger and clamped
    // it on-screen, so both entries render and remain tappable.
    final rect = tester.getRect(find.text('Alpha'));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(640));
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(result, 'b');
    expect(tester.takeException(), isNull);
  });

  group('GlassDialog overflow', () {
    testWidgets(
      'tall autofocus content under a keyboard inset does not overflow',
      (tester) async {
        tester.view.physicalSize = const Size(400, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          _host((context) {
            showDialog<void>(
              context: context,
              builder: (_) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(viewInsets: const EdgeInsets.only(bottom: 340)),
                child: GlassDialog(
                  title: const Text('Edit about'),
                  content: const TextField(autofocus: true, maxLines: 2),
                  actions: [
                    TextButton(onPressed: () {}, child: const Text('Save')),
                  ],
                ),
              ),
            );
          }),
        );

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Edit about'), findsOneWidget);
        expect(find.text('Save'), findsOneWidget);
      },
    );
  });

  group('GlassDialog max width and entrance', () {
    Future<void> pumpDialog(WidgetTester tester, {double? maxWidth}) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: RpgTheme.themeDataLight,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => maxWidth == null
                    ? const GlassDialog(title: Text('t'))
                    : GlassDialog(maxWidth: maxWidth, title: const Text('t')),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Finder inDialog(Type type) =>
        find.descendant(of: find.byType(Dialog), matching: find.byType(type));

    testWidgets('explicit maxWidth caps the glass surface on wide layouts', (
      tester,
    ) async {
      await pumpDialog(tester, maxWidth: 400);
      final width = tester.getSize(find.byType(GlassSurface)).width;
      expect(width, lessThanOrEqualTo(400));
    });

    testWidgets('default maxWidth caps at 560 instead of the inset width', (
      tester,
    ) async {
      await pumpDialog(tester);
      final width = tester.getSize(find.byType(GlassSurface)).width;
      expect(width, lessThanOrEqualTo(560));
    });

    testWidgets('entrance scale animation mounts by default', (tester) async {
      await pumpDialog(tester);
      expect(inDialog(TweenAnimationBuilder<double>), findsOneWidget);
    });

    testWidgets('reduce-motion skips the entrance animation', (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpDialog(tester);
      expect(inDialog(TweenAnimationBuilder<double>), findsNothing);
    });
  });
}
