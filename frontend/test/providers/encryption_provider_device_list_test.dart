import 'dart:async';
import 'dart:convert';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stage C2 of T4 (spec §5.2, amendment (vi)): the send path's verified
/// device-list cache. Every trusted list ran the I7 chain (TOFU IK → E →
/// DAK → list signature → canonical parse → version); nothing is EVER
/// trusted on the server's bare word, and a fetch that cannot be verified
/// fails the caller instead of degrading to a guessed device set
/// (falsifications 3, 4, 9).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ownUserId = 7;
  const peerId = 42;

  late EncryptionProvider provider;
  late List<Map<String, dynamic>> emitted;
  late DeviceAuthorityEngine peerEngine;
  late IdentityKeyPair peerIdentity;
  late Map<String, dynamic> enrollmentPayload;

  /// The wire `authorization` map `getDeviceList` answers with, as the
  /// backend serves it (chat-device-list.service.ts).
  Map<String, dynamic> authorizationV1() => {
    'dakPub': enrollmentPayload['dakPub'],
    'enrollmentSig': enrollmentPayload['enrollmentSig'],
    'enrollmentCreatedAt': enrollmentPayload['createdAt'],
    'listVersion': 1,
    'listSignature': enrollmentPayload['listSignature'],
    'listCanonical': enrollmentPayload['listCanonical'],
  };

  /// A later DAK-signed version of the peer's list ([version], devices 1+2).
  Map<String, dynamic> authorizationAt(int version) {
    final signed = peerEngine.signList(
      DeviceList(
        userId: peerId,
        version: version,
        devices: const [
          DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
          DeviceListEntry(deviceId: 2, platform: 'web', addedAtMs: 2000),
        ],
      ),
    );
    return {
      'dakPub': enrollmentPayload['dakPub'],
      'enrollmentSig': enrollmentPayload['enrollmentSig'],
      'enrollmentCreatedAt': enrollmentPayload['createdAt'],
      'listVersion': version,
      'listSignature': signed['listSignature'],
      'listCanonical': signed['listCanonical'],
    };
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    emitted = <Map<String, dynamic>>[];
    provider = EncryptionProvider();
    provider.setEmitCallback((event, data) {
      emitted.add({'event': event, 'data': data});
      if (event == 'checkOwnKeyBundle') {
        provider.onOwnKeyBundleStatus({'exists': false});
      }
    });
    await provider.initializeE2E(ownUserId);

    peerEngine = DeviceAuthorityEngine();
    peerIdentity = generateIdentityKeyPair();
    enrollmentPayload = peerEngine.mintEnrollment(
      userId: peerId,
      identity: peerIdentity,
      createdAtMs: 1234567890,
    );
    // TOFU-pin the peer's identity, exactly as a first inbound bundle would.
    await provider.encryptionService.debugSavePeerIdentity(
      peerId,
      base64Encode(peerIdentity.getPublicKey().serialize()),
    );
  });

  int deviceListFetchCount() =>
      emitted.where((e) => e['event'] == 'getDeviceList').length;

  test('a verified list is cached and reused without a second fetch', () async {
    provider.setEmitCallback((event, data) {
      emitted.add({'event': event, 'data': data});
      if (event == 'getDeviceList') {
        provider.onDeviceList({
          'userId': peerId,
          'authorization': authorizationV1(),
        });
      }
    });
    final first = await provider.getVerifiedDeviceList(peerId);
    expect(first.enrolled, isTrue);
    expect(first.version, 1);
    expect(first.liveDeviceIds, [1]);
    expect(deviceListFetchCount(), 1);

    final second = await provider.getVerifiedDeviceList(peerId);
    expect(
      identical(first, second),
      isTrue,
      reason: 'cache hit must not refetch',
    );
    expect(deviceListFetchCount(), 1);
  });

  test(
    'an invalid chain is rejected and NOT cached (falsification 4)',
    () async {
      final forged = authorizationV1();
      // Signature from a DAK the enrollment never authorized.
      final impostor = DeviceAuthorityEngine();
      impostor.mintEnrollment(
        userId: peerId,
        identity: generateIdentityKeyPair(),
        createdAtMs: 99,
      );
      final resigned = impostor.signList(
        DeviceList(
          userId: peerId,
          version: 1,
          devices: const [
            DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 0),
          ],
        ),
      );
      forged['listCanonical'] = resigned['listCanonical'];
      forged['listSignature'] = resigned['listSignature'];

      provider.setEmitCallback((event, data) {
        emitted.add({'event': event, 'data': data});
        if (event == 'getDeviceList') {
          provider.onDeviceList({'userId': peerId, 'authorization': forged});
        }
      });
      await expectLater(
        provider.getVerifiedDeviceList(peerId),
        throwsA(
          isA<DeviceListVerificationException>().having(
            (e) => e.reason,
            'reason',
            'invalid_list_signature',
          ),
        ),
      );
      expect(
        provider.cachedDeviceList(peerId),
        isNull,
        reason: 'a refused list must never enter the cache',
      );
    },
  );

  test('a served ROLLBACK is detected against the pinned version, even '
      'after invalidation (falsification 3)', () async {
    var serveVersion = 2;
    provider.setEmitCallback((event, data) {
      emitted.add({'event': event, 'data': data});
      if (event == 'getDeviceList') {
        provider.onDeviceList({
          'userId': peerId,
          'authorization': serveVersion == 1
              ? authorizationV1()
              : authorizationAt(2),
        });
      }
    });
    final v2 = await provider.getVerifiedDeviceList(peerId);
    expect(v2.version, 2);
    expect(v2.liveDeviceIds, [1, 2]);

    // The cache entry is dropped (deviceListChanged), but the PIN survives:
    // a correctly-signed OLDER list must still be refused.
    provider.invalidateDeviceList(peerId);
    serveVersion = 1;
    await expectLater(
      provider.getVerifiedDeviceList(peerId),
      throwsA(
        isA<DeviceListVerificationException>().having(
          (e) => e.reason,
          'reason',
          'version_rollback',
        ),
      ),
    );
    expect(provider.cachedDeviceList(peerId), isNull);
  });

  test('re-serving the SAME pinned version is a legitimate refresh, '
      'not a rollback', () async {
    provider.setEmitCallback((event, data) {
      emitted.add({'event': event, 'data': data});
      if (event == 'getDeviceList') {
        provider.onDeviceList({
          'userId': peerId,
          'authorization': authorizationAt(2),
        });
      }
    });
    await provider.getVerifiedDeviceList(peerId);
    final refreshed = await provider.getVerifiedDeviceList(
      peerId,
      forceRefresh: true,
    );
    expect(refreshed.version, 2);
  });

  test('a non-enrolled peer (authorization: null) is single-device: '
      'device 1 only, no version', () async {
    provider.setEmitCallback((event, data) {
      emitted.add({'event': event, 'data': data});
      if (event == 'getDeviceList') {
        provider.onDeviceList({'userId': peerId, 'authorization': null});
      }
    });
    final list = await provider.getVerifiedDeviceList(peerId);
    expect(list.enrolled, isFalse);
    expect(list.version, isNull);
    expect(list.liveDeviceIds, [1]);
  });

  test('an authorization:null answer for an ALREADY-ENROLLED party is refused '
      'as a rollback, not cached as single-device (amendment (xix))', () async {
    var serveEnrolled = true;
    provider.setEmitCallback((event, data) {
      emitted.add({'event': event, 'data': data});
      if (event == 'getDeviceList') {
        provider.onDeviceList({
          'userId': peerId,
          'authorization': serveEnrolled ? authorizationAt(2) : null,
        });
      }
    });
    final v2 = await provider.getVerifiedDeviceList(peerId);
    expect(v2.liveDeviceIds, [1, 2]);

    // Enrollment is durable (§5.2), so "no enrollment row" for a party we
    // already verified is never legitimate. Caching it would narrow the
    // fan-out to device 1 and silently drop that party's other devices.
    provider.invalidateDeviceList(peerId);
    serveEnrolled = false;
    await expectLater(
      provider.getVerifiedDeviceList(peerId),
      throwsA(
        isA<DeviceListVerificationException>().having(
          (e) => e.reason,
          'reason',
          'version_rollback',
        ),
      ),
    );
    expect(
      provider.cachedDeviceList(peerId),
      isNull,
      reason: 'a refused downgrade must never enter the cache',
    );
  });

  test('an unanswered fetch times out with an error — never a guessed list '
      '(falsification 9)', () async {
    await expectLater(
      provider.getVerifiedDeviceList(
        peerId,
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(provider.cachedDeviceList(peerId), isNull);
  });

  test('a caller that JOINS an unanswered fetch fails with it — never waits '
      'forever (a lost answer stalled every box send, 0.2.66)', () async {
    // The first lookup's request died with a replaced socket; the next
    // connect's refresh asks again and joins it.
    final first = provider.getVerifiedDeviceList(
      peerId,
      timeout: const Duration(milliseconds: 50),
    );
    final joiner = provider.getVerifiedDeviceList(
      peerId,
      timeout: const Duration(milliseconds: 50),
    );
    await expectLater(first, throwsA(isA<TimeoutException>()));
    await expectLater(
      joiner.timeout(const Duration(seconds: 2)),
      throwsA(
        isA<TimeoutException>().having(
          (e) => e.message,
          'message',
          contains('Device list fetch'),
        ),
      ),
      reason: 'the joiner must fail with the shared fetch, not hang',
    );
    expect(deviceListFetchCount(), 1, reason: 'the joiner sends nothing');
  });

  test(
    'an enrolled answer for a peer with NO pinned identity fails closed',
    () async {
      const strangerId = 314;
      provider.setEmitCallback((event, data) {
        emitted.add({'event': event, 'data': data});
        if (event == 'getDeviceList') {
          // A structurally valid record, but this client holds no TOFU key
          // for the stranger — the chain has no anchor, so nothing verifies.
          provider.onDeviceList({
            'userId': strangerId,
            'authorization': authorizationV1(),
          });
        }
      });
      await expectLater(
        provider.getVerifiedDeviceList(strangerId),
        throwsA(
          isA<DeviceListVerificationException>().having(
            (e) => e.reason,
            'reason',
            'no_tofu_identity',
          ),
        ),
      );
      expect(provider.cachedDeviceList(strangerId), isNull);
    },
  );

  test(
    'batched lookups started in one turn leave as ONE getDeviceLists frame '
    'naming every user, and each resolves from its own deviceList answer '
    '(item 5, E20a)',
    () async {
      final frames = <Map<String, dynamic>>[];
      provider.setEmitCallback((event, data) {
        frames.add({'event': event, 'data': data});
      });

      final lookups = [
        for (final user in [peerId, 43, 44])
          provider.getVerifiedDeviceList(
            user,
            forceRefresh: true,
            batched: true,
          ),
      ];
      await pumpEventQueue();

      expect(frames, [
        {
          'event': 'getDeviceLists',
          'data': {
            'userIds': [peerId, 43, 44],
          },
        },
      ]);
      provider
        ..onDeviceList({'userId': 44, 'authorization': null})
        ..onDeviceList({'userId': peerId, 'authorization': authorizationV1()})
        ..onDeviceList({'userId': 43, 'authorization': null});
      final lists = await Future.wait(lookups);
      expect(lists.map((l) => l.enrolled), [isTrue, isFalse, isFalse]);
    },
  );

  test('a lone batched lookup goes out as the plain getDeviceList', () async {
    final frames = <String>[];
    provider.setEmitCallback((event, data) {
      frames.add(event);
      if (event == 'getDeviceList') {
        provider.onDeviceList({'userId': peerId, 'authorization': null});
      }
    });

    await provider.getVerifiedDeviceList(peerId, batched: true);

    expect(frames, ['getDeviceList']);
  });

  group('a friend is looked up by handle, never by id (decision 114)', () {
    const stranger = 99;

    // Mutation: `_fetchDeviceListAnswer` asks `isBoxOnlyPeer` alone.
    test('its list comes from the handle lookup and no id leaves', () async {
      final lookups = <int>[];
      provider
        ..listsByHandle = ((peer) => peer == peerId)
        ..lookupBoxPeerList = (peer) async {
          lookups.add(peer);
          return authorizationV1();
        };

      final list = await provider.getVerifiedDeviceList(
        peerId,
        timeout: const Duration(milliseconds: 200),
      );

      expect(list.enrolled, isTrue);
      expect(list.liveDeviceIds, [1]);
      expect(lookups, [peerId]);
      expect(
        emitted.where(
          (e) => e['event'] == 'getDeviceList' || e['event'] == 'getDeviceLists',
        ),
        isEmpty,
      );
      // Held now: asking again costs nothing, and the one lookup per account
      // per process (E15h) is not spent twice.
      await provider.getVerifiedDeviceList(peerId);
      expect(lookups, [peerId]);
    });

    // Mutation: `listIsByHandle` answers true for everyone.
    test('the own list and a peer with no record still go by id', () async {
      provider
        ..listsByHandle = ((peer) => peer == peerId)
        ..lookupBoxPeerList = (peer) async => fail('looked up $peer');

      for (final user in [ownUserId, stranger]) {
        await expectLater(
          provider.getVerifiedDeviceList(
            user,
            timeout: const Duration(milliseconds: 50),
          ),
          throwsA(isA<TimeoutException>()),
        );
      }

      expect(
        emitted
            .where((e) => e['event'] == 'getDeviceList')
            .map((e) => (e['data'] as Map)['userId']),
        [ownUserId, stranger],
      );
    });
  });
}
