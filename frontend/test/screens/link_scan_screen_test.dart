import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/screens/link_scan_screen.dart';
import 'package:fireplace/widgets/link_qr_scanner.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// The full-screen scanner route has exactly four exits and pops exactly
/// once. A ceremony screen acts on the popped value, so a route that pops
/// twice (scan + unsupported from a build-phase errorBuilder) or answers
/// the wrong shape sends the ceremony down the wrong branch.
class _FakeScanner extends StatelessWidget {
  const _FakeScanner({required this.onCode, this.onUnsupported});
  final void Function(String) onCode;
  final VoidCallback? onUnsupported;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(
        key: const Key('fake-scan-hit'),
        onPressed: () => onCode('fp-link.v2.raw'),
        child: const Text('scan'),
      ),
      TextButton(
        key: const Key('fake-scan-unsupported'),
        onPressed: onUnsupported,
        child: const Text('unsupported'),
      ),
      TextButton(
        key: const Key('fake-scan-both'),
        onPressed: () {
          onCode('fp-link.v2.raw');
          onUnsupported?.call();
        },
        child: const Text('both'),
      ),
    ],
  );
}

void main() {
  Future<List<LinkScanResult?>> pump(WidgetTester tester) async {
    final results = <LinkScanResult?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const Key('open'),
              onPressed: () async {
                results.add(
                  await Navigator.of(context).push<LinkScanResult>(
                    MaterialPageRoute(
                      fullscreenDialog: true,
                      builder: (_) => LinkScanScreen(
                        scannerBuilder: ({required onCode, onUnsupported}) =>
                            _FakeScanner(
                              onCode: onCode,
                              onUnsupported: onUnsupported,
                            ),
                      ),
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(find.byType(LinkScanScreen), findsOneWidget);
    return results;
  }

  testWidgets('a decoded code pops LinkScanCode with the raw text', (
    tester,
  ) async {
    final results = await pump(tester);
    await tester.tap(find.byKey(const Key('fake-scan-hit')));
    await tester.pumpAndSettle();
    expect(find.byType(LinkScanScreen), findsNothing);
    expect(results, hasLength(1));
    expect((results.single! as LinkScanCode).code, 'fp-link.v2.raw');
  });

  testWidgets('an unsupported scanner pops LinkScanUnsupported', (
    tester,
  ) async {
    final results = await pump(tester);
    await tester.tap(find.byKey(const Key('fake-scan-unsupported')));
    await tester.pumpAndSettle();
    expect(results.single, isA<LinkScanUnsupported>());
  });

  testWidgets('"enter manually" pops LinkScanManual; X pops null', (
    tester,
  ) async {
    var results = await pump(tester);
    await tester.tap(find.byKey(const Key('link-scan-manual')));
    await tester.pumpAndSettle();
    expect(results.single, isA<LinkScanManual>());

    results = await pump(tester);
    await tester.tap(find.byKey(const Key('link-scan-close')));
    await tester.pumpAndSettle();
    expect(results, [null]);
  });

  testWidgets('two callbacks in one frame pop ONCE, with the first answer', (
    tester,
  ) async {
    final results = await pump(tester);
    await tester.tap(find.byKey(const Key('fake-scan-both')));
    await tester.pumpAndSettle();
    expect(results, hasLength(1), reason: 'a second pop would close the caller');
    expect(results.single, isA<LinkScanCode>());
    expect(tester.takeException(), isNull);
  });

  // The VM test host resolves the LinkQrScanner facade to the NATIVE impl
  // (dart.library.io), where the host is neither Android nor iOS — i.e. the
  // unsupported path, exactly what a desktop native build would hit.
  // Falsification for the unsupported contract: an impl that mounted
  // MobileScanner regardless, or never fired onUnsupported, fails below.
  testWidgets('unsupported host renders nothing and reports it once', (
    tester,
  ) async {
    final codes = <String>[];
    var unsupportedCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LinkQrScanner(
          onCode: codes.add,
          onUnsupported: () => unsupportedCalls++,
        ),
      ),
    );
    // The widget mounts without throwing…
    expect(find.byType(LinkQrScanner), findsOneWidget);
    // …and after the first frame the unsupported callback has fired ONCE.
    await tester.pump();
    expect(unsupportedCalls, 1);
    expect(codes, isEmpty);
    // No camera pipeline was mounted.
    expect(find.byType(MobileScanner), findsNothing);
    // A rebuild does not re-report.
    await tester.pump();
    expect(unsupportedCalls, 1);
  });

  test('linkQrScanSupported answers false off Android/iOS', () async {
    expect(await linkQrScanSupported(), isFalse);
  });
}
