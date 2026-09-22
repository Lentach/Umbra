// The storage-loss notice must not cover the device-link gate.
//
// `PasscodeGate` is the `MaterialApp.builder` wrapper, so its loss layer sits
// above the WHOLE navigator — including the gate `AuthGate` mounts when the
// account's identity is gone. Driven on a Pixel_7 (2026-09-22, Run C′): a
// Keystore-only loss kills the SQLCipher key and the Signal identity in one
// go, so the boot latches the loss AND opens the gate at the same moment, and
// the user saw a file-only "restore from backup / continue" screen whose copy
// never mentioned the identity. The phrase door — the one path that brings the
// account's keys back — was underneath, one unhinted "continue" away.
//
// Contract: while the identity gate stands, the loss notice yields; the latch
// is process-scoped, so the notice appears the moment the gate releases.

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/screens/storage_loss_screen.dart';
import 'package:fireplace/services/backup/storage_loss.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/passcode_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/passcode_fakes.dart';

const _currentUserJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoiYWxpY2UiLCJ0YWciOiIwMDAxIiwiZXhwIjo5OTk5OTk5OTl9.abc';

const _shell = Key('shell');

/// Stands in for the boot verdict: `needsDeviceLink` is what `AuthGate`
/// mounts the gate on, and it flips false only when a restore finishes.
class _GatedEncryption extends EncryptionProvider {
  bool _gated = true;

  @override
  bool get needsDeviceLink => _gated;

  @override
  bool get identityCheckUnavailable => false;

  void release() {
    _gated = false;
    notifyListeners();
  }
}

Widget _host({
  required PasscodeProvider passcode,
  required AuthProvider auth,
  required EncryptionProvider encryption,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: passcode),
    ChangeNotifierProvider.value(value: auth),
    ChangeNotifierProvider.value(value: encryption),
  ],
  child: MaterialApp(
    theme: RpgTheme.themeDataLight,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: const PasscodeGate(
      child: Scaffold(body: Text('SHELL', key: _shell)),
    ),
  ),
);

void main() {
  setUp(StorageLoss.resetForTest);

  testWidgets(
    'the loss notice yields to the identity gate and appears once it releases',
    (tester) async {
      final passcode = PasscodeProvider(
        store: MemoryPasscodeStore(),
        kdf: FakePasscodeKdf(),
        nowMs: () => 1757000000000,
      );
      await passcode.initialize();
      final auth = AuthProvider()..setAccessTokenForTest(_currentUserJwt);
      final encryption = _GatedEncryption();

      await tester.pumpWidget(
        _host(passcode: passcode, auth: auth, encryption: encryption),
      );
      await tester.pumpAndSettle();

      // The latch is set while the content store opens — after this layer
      // first built, exactly like production.
      StorageLoss.record('db-recreate');
      await tester.pumpAndSettle();

      expect(
        find.byType(StorageLossScreen),
        findsNothing,
        reason: 'the gate holds the phrase door; covering it hides the one '
            'path that restores the account keys',
      );

      encryption.release();
      await tester.pumpAndSettle();

      expect(find.byType(StorageLossScreen), findsOneWidget);
      expect(StorageLoss.lostThisBoot, isTrue);
    },
  );
}
