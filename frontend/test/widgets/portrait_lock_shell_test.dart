import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/utils/web_keyboard_inset.dart';
import 'package:fireplace/widgets/portrait_lock_shell.dart';
import 'package:fireplace/widgets/portrait_required_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake iOS-WebKit shared inset source (isActive true) with a mutable inset, so
/// the shell's web-inset guard and its ValueListenableBuilder wiring can be
/// driven on the VM where there is no visualViewport.
class _FakeInsetSource implements KeyboardInsetSource {
  _FakeInsetSource(double initial) : _inset = ValueNotifier<double>(initial);

  final ValueNotifier<double> _inset;

  @override
  ValueNotifier<double> get inset => _inset;

  @override
  bool get isActive => true;

  @override
  void dispose() {}

  void set(double value) => _inset.value = value;
}

Widget _shell({required Size size}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: Builder(
    // Override only the logical size; orientation is recomputed from it and
    // viewInsets stays 0 (no Flutter-reported keyboard) so the tests isolate
    // the shared-source web inset.
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(size: size),
      child: const PortraitLockShell(
        child: ColoredBox(
          key: Key('shell-child'),
          color: Color(0xFF101010),
          child: SizedBox.expand(),
        ),
      ),
    ),
  ),
);

void main() {
  // The shared-source override is process-global; reset it so a fake never
  // leaks into another test file.
  tearDown(() => setSharedKeyboardInsetSourceForTest(null));

  // 844x390 is landscape with a 390 shortest side (< 900 phone threshold), and
  // with no keyboard up the rotate overlay must show.
  testWidgets('landscape phone with no keyboard shows the rotate overlay', (
    tester,
  ) async {
    await tester.pumpWidget(_shell(size: const Size(844, 390)));
    await tester.pumpAndSettle();

    expect(find.byType(PortraitRequiredOverlay), findsOneWidget);
    expect(find.byKey(const Key('shell-child')), findsOneWidget);
  });

  // D4 regression: the guard must consult the shared visualViewport inset, not
  // just MediaQuery.viewInsets (which reads 0 on iOS WebKit). A web keyboard
  // inset suppresses the overlay even though the size still reads landscape.
  testWidgets('web keyboard inset suppresses the overlay in landscape (D4)', (
    tester,
  ) async {
    setSharedKeyboardInsetSourceForTest(_FakeInsetSource(300));
    await tester.pumpWidget(_shell(size: const Size(844, 390)));
    await tester.pumpAndSettle();

    expect(find.byType(PortraitRequiredOverlay), findsNothing);
    expect(find.byKey(const Key('shell-child')), findsOneWidget);
  });

  // Proves the ValueListenableBuilder wiring, not just the pure policy: with the
  // shell already mounted and suppressed by a 300px web inset, dropping the
  // inset to 0 must rebuild and reveal the overlay.
  testWidgets('dropping the web keyboard inset while mounted re-shows the overlay', (
    tester,
  ) async {
    final fake = _FakeInsetSource(300);
    setSharedKeyboardInsetSourceForTest(fake);
    await tester.pumpWidget(_shell(size: const Size(844, 390)));
    await tester.pumpAndSettle();
    expect(find.byType(PortraitRequiredOverlay), findsNothing);

    fake.set(0);
    await tester.pump();

    expect(find.byType(PortraitRequiredOverlay), findsOneWidget);
  });

  testWidgets('PortraitRequiredOverlay shows localized rotate message', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('pl'),
        home: const PortraitRequiredOverlay(),
      ),
    );
    expect(find.text('Obróć urządzenie'), findsOneWidget);
    expect(find.textContaining('trybie pionowym'), findsOneWidget);
  });
}
