import 'dart:convert';

import 'package:fireplace/services/device_list/sender_list_info.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

/// The §5.2 layer-2 cross-check (spec §12 amendments (xv)/(xvi)).
///
/// Falsification 16 is the detection half: a frozen but validly-signed view is
/// exposed by the sender's own in-band claim, and only ever confirmed against
/// DAK-verified data we hold ourselves. Falsification 22 is the discipline
/// half: bogus claims in EITHER direction must cost at most one rate-limited
/// re-fetch and must never alarm.
void main() {
  group('SenderListInfo — shape and transport', () {
    test('hash is SHA-256 over the canonical bytes exactly as transported', () {
      // Stable, and a single byte of difference changes it.
      const canonical = 'eyJ1c2VySWQiOjE5MywidmVyc2lvbiI6Mn0=';
      final hash = SenderListInfo.hashListCanonical(canonical);
      expect(hash, SenderListInfo.hashListCanonical(canonical));
      expect(hash, isNot(SenderListInfo.hashListCanonical('$canonical ')));
      // base64 of a 32-byte digest.
      expect(base64Decode(hash).length, 32);
    });

    test('rides inside the E2E plaintext and survives a round trip', () {
      const info = SenderListInfo(
        ownVersion: 2,
        ownListHash: 'peer-hash',
        peerVersion: 5,
        peerListHash: 'our-hash',
      );
      final json = jsonEncode(
        E2eEnvelope.build('hello', senderListInfo: info.toJson()),
      );
      final parsed = E2eEnvelope.parse(json);
      expect(parsed.content, 'hello');
      final back = SenderListInfo.fromJson(parsed.senderListInfo);
      expect(back?.ownVersion, 2);
      expect(back?.peerVersion, 5);
      expect(back?.ownListHash, 'peer-hash');
      expect(back?.peerListHash, 'our-hash');
    });

    test('an older peer omits it, and that parses cleanly', () {
      final json = jsonEncode(E2eEnvelope.build('hello'));
      final parsed = E2eEnvelope.parse(json);
      expect(parsed.senderListInfo, isNull);
      expect(SenderListInfo.fromJson(parsed.senderListInfo), isNull);
    });

    test('a malformed or hostile claim never throws on the receive path', () {
      // Wrong types, wrong shape, empty — all become "no usable claim". A
      // receive path holding someone's message must never blow up on this.
      expect(SenderListInfo.fromJson('not a map'), isNull);
      expect(SenderListInfo.fromJson(<String, dynamic>{}), isNull);
      expect(
        SenderListInfo.fromJson({'ownVersion': 'two', 'ownListHash': 42}),
        isNull,
      );
      final partial = SenderListInfo.fromJson({
        'ownVersion': 3,
        'peerListHash': '',
      });
      expect(partial?.ownVersion, 3);
      expect(partial?.peerListHash, isNull);
    });

    test('a party we hold nothing for is reported ABSENT, not version 0', () {
      const info = SenderListInfo(ownVersion: 2, ownListHash: 'h');
      expect(info.toJson().containsKey('peerVersion'), isFalse);
      expect(info.toJson().containsKey('peerListHash'), isFalse);
    });
  });

  group('SenderListInfoChecker — escalation discipline', () {
    SenderListInfoOutcome evaluate({
      SenderListInfo? claim,
      int? ourVersionOfPeer,
      String? ourHashOfPeer,
      int? ourOwnVersion,
      String? ourOwnHash,
    }) => SenderListInfoChecker.evaluate(
      claim: claim,
      ourVersionOfPeer: ourVersionOfPeer,
      ourHashOfPeer: ourHashOfPeer,
      ourOwnVersion: ourOwnVersion,
      ourOwnHash: ourOwnHash,
    );

    test('no claim, or nothing verified on our side, decides nothing', () {
      expect(evaluate(claim: null), SenderListInfoOutcome.consistent);
      // We hold no verified list, so the claim cannot be evidence of anything.
      expect(
        evaluate(claim: const SenderListInfo(ownVersion: 9)),
        SenderListInfoOutcome.consistent,
      );
    });

    test('matching versions and hashes are consistent', () {
      expect(
        evaluate(
          claim: const SenderListInfo(
            ownVersion: 2,
            ownListHash: 'peer',
            peerVersion: 4,
            peerListHash: 'mine',
          ),
          ourVersionOfPeer: 2,
          ourHashOfPeer: 'peer',
          ourOwnVersion: 4,
          ourOwnHash: 'mine',
        ),
        SenderListInfoOutcome.consistent,
      );
    });

    test(
      'falsification 22: a NEWER claim buys one refresh, never an alarm',
      () {
        expect(
          evaluate(
            claim: const SenderListInfo(ownVersion: 99),
            ourVersionOfPeer: 2,
          ),
          SenderListInfoOutcome.refreshPeerList,
        );
      },
    );

    test(
      'falsification 16: an OLDER claim is a freeze signal only against our own '
      'verified version',
      () {
        expect(
          evaluate(
            claim: const SenderListInfo(ownVersion: 1),
            ourVersionOfPeer: 3,
          ),
          SenderListInfoOutcome.peerListFrozen,
        );
        // Same version, DIFFERENT canonical bytes: two signed views disagree,
        // which is the split view the hash exists to catch.
        expect(
          evaluate(
            claim: const SenderListInfo(ownVersion: 3, ownListHash: 'forged'),
            ourVersionOfPeer: 3,
            ourHashOfPeer: 'genuine',
          ),
          SenderListInfoOutcome.peerListFrozen,
        );
      },
    );

    test('our OWN devices disagreeing is benign in either direction', () {
      expect(
        evaluate(claim: const SenderListInfo(peerVersion: 7), ourOwnVersion: 5),
        SenderListInfoOutcome.ownDevicesSyncing,
      );
      expect(
        evaluate(claim: const SenderListInfo(peerVersion: 3), ourOwnVersion: 5),
        SenderListInfoOutcome.ownDevicesSyncing,
      );
      expect(
        evaluate(
          claim: const SenderListInfo(peerVersion: 5, peerListHash: 'other'),
          ourOwnVersion: 5,
          ourOwnHash: 'ours',
        ),
        SenderListInfoOutcome.ownDevicesSyncing,
      );
    });

    test('the peer claim is judged BEFORE our own skew', () {
      // A claim that is wrong about both must still surface the security-
      // relevant half rather than hiding behind the benign one.
      expect(
        evaluate(
          claim: const SenderListInfo(ownVersion: 1, peerVersion: 9),
          ourVersionOfPeer: 3,
          ourOwnVersion: 5,
        ),
        SenderListInfoOutcome.peerListFrozen,
      );
    });
  });
}
