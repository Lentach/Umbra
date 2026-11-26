import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/peer_identity_fingerprint_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/l10n.dart';

/// Decision 152: the fingerprint dialog is where a friend becomes VERIFIED.
class _Verifiable extends EncryptionProvider {
  _Verifiable({this.standing = false});

  final bool standing;
  bool verified = false;

  @override
  Set<int> get peersWithChangedIdentity => standing ? const {2} : const {};

  @override
  Future<PeerIdentityVerification> loadPeerIdentityVerification(
    int peerId, {
    Duration timeout = const Duration(seconds: 10),
  }) async => PeerIdentityVerification(
    pinnedFingerprint: 'AAAA BBBB',
    verified: verified,
  );

  @override
  Future<String?> getIdentityFingerprint() async => 'CCCC DDDD';

  @override
  Future<bool> markPeerVerified(int peerId) async {
    verified = true;
    notifyListeners();
    return true;
  }
}

Future<void> _open(WidgetTester tester, _Verifiable enc) async {
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
              peerId: 2,
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

void main() {
  const markKey = ValueKey('peer-identity-mark-friend-verified');
  const stateKey = ValueKey('peer-identity-verified-state');

  testWidgets('no standing warning: the dialog offers "Mark as verified", and '
      'after it shows "Verified" and no button', (tester) async {
    final enc = _Verifiable();
    await _open(tester, enc);

    expect(find.byKey(markKey), findsOneWidget);
    expect(find.text(l10n.peerIdentityMarkFriendVerifiedAction), findsOneWidget);
    expect(find.byKey(stateKey), findsNothing);

    await tester.tap(find.byKey(markKey));
    await tester.pumpAndSettle();

    expect(enc.verified, isTrue);
    expect(find.byKey(markKey), findsNothing);
    expect(find.text(l10n.peerIdentityVerifiedState), findsOneWidget);
  });

  testWidgets('a standing change has no "Mark as verified" button',
      (tester) async {
    await _open(tester, _Verifiable(standing: true));

    expect(find.byKey(markKey), findsNothing);
  });
}
