import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/glass/glass_top_bar.dart';
import 'package:fireplace/widgets/top_snackbar.dart';

import '../support/l10n.dart';

// Guards the fix for the toast covering the app-bar back arrow: the overlay must
// sit BELOW the GlassTopBar band, including the status-bar (notch) inset — not
// at top:0 where it hid the back arrow for the whole 2.5s duration.
//
// The inset is set at the WINDOW level (tester.view) so the root Overlay and the
// screen's SafeArea read the same padding, mirroring a real device.
void main() {
  testWidgets('top snackbar clears the back-arrow band', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 47); // iPhone notch
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataDarkGray,
        home: Scaffold(
          extendBodyBehindAppBar: true,
          appBar: GlassTopBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {},
            ),
            title: const Text('Peer'),
          ),
          body: Builder(
            builder: (ctx) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                showTopSnackBar(ctx, l10n.antiQuantumNoteSent);
              });
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    await tester.pump(); // run the post-frame callback + insert overlay
    await tester.pump();

    final arrowBottom = tester.getRect(find.byIcon(Icons.arrow_back)).bottom;
    final toastTop = tester.getRect(find.text(l10n.antiQuantumNoteSent)).top;

    expect(
      toastTop,
      greaterThanOrEqualTo(arrowBottom),
      reason: 'toast ($toastTop) must not overlap back arrow ($arrowBottom)',
    );

    await tester.pump(const Duration(seconds: 3)); // let auto-dismiss fire
  });

  testWidgets(
    'default top snackbar remains non-interactive',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: RpgTheme.themeDataDarkGray,
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  showTopSnackBar(ctx, 'Plain notification');
                });
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Plain notification'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is IgnorePointer && widget.ignoring,
        ),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'action top snackbar invokes its callback and dismisses',
    (tester) async {
      var taps = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: RpgTheme.themeDataDarkGray,
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  showTopSnackBar(
                    ctx,
                    l10n.invitationAccepted,
                    actionLabel: l10n.invitationOpenChat,
                    onTap: () => taps += 1,
                  );
                });
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text(l10n.invitationOpenChat), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is IgnorePointer && widget.ignoring,
        ),
        findsNothing,
      );

      await tester.tap(find.text(l10n.invitationOpenChat));
      await tester.pump();

      expect(taps, 1);
      expect(find.text(l10n.invitationAccepted), findsNothing);

      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'default toast uses themed surface with border and info icon',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: RpgTheme.themeDataDarkGray,
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  showTopSnackBar(ctx, 'Themed notification');
                });
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final context = tester.element(find.text('Themed notification'));
      final scheme = Theme.of(context).colorScheme;

      final material = tester.widget<Material>(
        find
            .ancestor(
              of: find.text('Themed notification'),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, scheme.surfaceContainerHighest);
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.side.color, scheme.outlineVariant);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);

      final text = tester.widget<Text>(find.text('Themed notification'));
      expect(text.style?.color, scheme.onSurface);

      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'explicit backgroundColor keeps the legacy borderless look',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: RpgTheme.themeDataDarkGray,
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  showTopSnackBar(
                    ctx,
                    'Error notification',
                    backgroundColor: RpgTheme.errorColor,
                  );
                });
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final material = tester.widget<Material>(
        find
            .ancestor(
              of: find.text('Error notification'),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, RpgTheme.errorColor);
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.side, BorderSide.none);
      expect(find.byIcon(Icons.info_outline), findsNothing);

      final text = tester.widget<Text>(find.text('Error notification'));
      expect(text.style?.color, RpgTheme.readableOn(RpgTheme.errorColor));

      await tester.pump(const Duration(seconds: 3));
    },
  );
}
