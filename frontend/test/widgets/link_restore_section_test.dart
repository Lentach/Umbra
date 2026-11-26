import 'dart:async';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/screens/link_restore_section.dart';
import 'package:fireplace/services/device_link/identity_backup.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/recovery_phrase.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/passcode_fakes.dart';

/// The gate's (lxxviii) restore door: collapsed button → inline phrase field
/// with the reset prompt's local BIP39 validation → the provider's restore
/// machine, with per-reason failure copy.
void main() {
  late EncryptionProvider provider;
  late List<String> emitted;

  Future<void> pumpSection(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    provider = EncryptionProvider(
      service: EncryptionService(),
      backupCodec: IdentityBackupCodec(
        kdf: FakePasscodeKdf(),
        sealer: FakeContentSealer(),
      ),
    );
    // Seeds `_currentUserId` the way the gate does: an init pass that could
    // not ask the server (no emit wired yet).
    await provider.initializeE2E(9);
    emitted = [];
    provider.setEmitCallback((event, data) {
      emitted.add(event);
      if (event == 'getIdentityBackup') {
        scheduleMicrotask(
          () => provider.onIdentityBackup({'exists': false}),
        );
      }
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<EncryptionProvider>.value(
        value: provider,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(child: LinkRestoreSection()),
          ),
        ),
      ),
    );
  }

  testWidgets('collapsed → expand → malformed phrase never reaches the wire',
      (tester) async {
    await pumpSection(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    expect(find.byKey(const Key('link-gate-restore-field')), findsNothing);
    await tester.tap(find.byKey(const Key('link-gate-restore')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('link-gate-restore-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('link-gate-restore-field')),
      'definitely not twelve bip39 words',
    );
    await tester.tap(find.byKey(const Key('link-gate-restore-submit')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.recoveryPhraseMalformed), findsOneWidget);
    expect(emitted, isEmpty,
        reason: 'a local checksum failure spends no server round trip');
    expect(provider.restoreStage, IdentityRestoreStage.idle);
  });

  testWidgets('a valid phrase runs the machine; noBackup gets its own copy',
      (tester) async {
    await pumpSection(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    await tester.tap(find.byKey(const Key('link-gate-restore')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('link-gate-restore-field')),
      RecoveryPhrase.generate().join(' '),
    );
    await tester.tap(find.byKey(const Key('link-gate-restore-submit')));
    await tester.pumpAndSettle();

    expect(emitted, contains('getIdentityBackup'));
    expect(provider.restoreFailure, IdentityRestoreFailure.noBackup);
    expect(find.text(l10n.linkGateRestoreNoBackup), findsOneWidget);
  });

  // A3-MISC-9 (the gate's copy of the phrase field).
  testWidgets('the phrase field is closed to autocorrect and IME learning',
      (tester) async {
    await pumpSection(tester);

    await tester.tap(find.byKey(const Key('link-gate-restore')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const Key('link-gate-restore-field')),
    );
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.enableIMEPersonalizedLearning, isFalse);
  });
}
