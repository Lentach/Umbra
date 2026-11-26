import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/peer_identity_fingerprint_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/l10n.dart';

/// Decision 152: the fingerprint dialog is where a friend becomes VERIFIED.
/// Real service and real provider: nothing below fakes `markPeerVerified`.
void main() {
  const markKey = ValueKey('peer-identity-mark-friend-verified');
  const stateKey = ValueKey('peer-identity-verified-state');
  const changedKey = ValueKey('peer-identity-key-changed-open');
  const bobId = 2;

  late EncryptionService alice;
  late EncryptionService bob;
  late EncryptionService newBob;
  late EncryptionProvider enc;

  Future<EncryptionService> started(int userId) async {
    final service = EncryptionService();
    await service.initialize(
      userId,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    return service;
  }

  Map<String, dynamic> bundleOf(EncryptionService peer) {
    final upload = peer.getKeysForUpload()!;
    final keyBundle = (upload['keyBundle'] as Map).cast<String, dynamic>();
    final otp = (upload['oneTimePreKeys'] as List)
        .cast<Map<String, dynamic>>()
        .first;
    return {
      ...keyBundle,
      'oneTimePreKeyId': otp['keyId'],
      'oneTimePreKeyPublic': otp['publicKey'],
    };
  }

  String identityOf(EncryptionService peer) =>
      bundleOf(peer)['identityPublicKey'] as String;

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<EncryptionProvider>.value(
        value: enc,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: RpgTheme.themeDataDarkGray,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPeerIdentityFingerprintDialog(
                context: context,
                peerId: bobId,
                peerName: 'bob',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    alice = await started(1);
    bob = await started(bobId);
    newBob = await started(3);
    await alice.buildSession(
      bobId,
      bundleOf(bob),
      expectedIdentityBase64: null,
    );
    enc = EncryptionProvider(service: alice);
  });

  testWidgets('no standing warning: "Mark as verified" really verifies the '
      'friend, and the dialog then says "Verified"', (tester) async {
    await open(tester);
    expect(find.byKey(markKey), findsOneWidget);
    expect(await alice.isPeerVerified(bobId), isFalse);

    await tester.tap(find.byKey(markKey));
    await tester.pumpAndSettle();

    expect(await alice.isPeerVerified(bobId), isTrue);
    expect(find.byKey(markKey), findsNothing);
    expect(find.byKey(stateKey), findsOneWidget);
    expect(find.text(l10n.peerIdentityVerifiedState), findsOneWidget);
  });

  testWidgets('the anchor moved while the dialog was open: the tap does NOT '
      'verify the new key and the dialog says so', (tester) async {
    await open(tester); // shows K1 (bob's key)
    await tester.runAsync(
      () => alice.buildSession(
        bobId,
        bundleOf(newBob),
        expectedIdentityBase64: identityOf(bob),
      ),
    ); // warnings OFF, unverified: auto-accepted, anchor is K2 now
    expect(await alice.peerTofuIdentityBase64(bobId), identityOf(newBob));

    await tester.tap(find.byKey(markKey));
    await tester.pumpAndSettle();

    expect(await alice.isPeerVerified(bobId), isFalse);
    expect(find.byKey(changedKey), findsOneWidget);
    expect(find.text(l10n.peerIdentityKeyChangedWhileOpen), findsOneWidget);
  });

  testWidgets('confirming a standing change binds the flag to the new key',
      (tester) async {
    alice.keyChangeWarnings = () => true;
    await tester.runAsync(() async {
      await expectLater(
        alice.buildSession(
          bobId,
          bundleOf(newBob),
          expectedIdentityBase64: identityOf(bob),
        ),
        throwsA(isA<AccountIdentityMismatch>()),
      );
    });
    await open(tester);
    expect(find.byKey(markKey), findsNothing);

    await tester.tap(find.text(l10n.peerIdentityMarkVerifiedAction));
    await tester.pumpAndSettle();

    expect(await alice.peerTofuIdentityBase64(bobId), identityOf(newBob));
    expect(await alice.isPeerVerified(bobId), isTrue);
  });
}
