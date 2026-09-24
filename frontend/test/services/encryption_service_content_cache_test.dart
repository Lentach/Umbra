import 'dart:convert';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fireplace/services/encryption_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EncryptionService decrypted content cache', () {
    late EncryptionService service;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      service = EncryptionService();
      await service.initialize(42, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    });

    test('saveDecryptedContent then getDecryptedContent returns stored data', () async {
      await service.saveDecryptedContent(1001, {'content': 'Hello world'});
      final result = await service.getDecryptedContent(1001);
      expect(result, isNotNull);
      expect(result!['content'], 'Hello world');
    });

    test('getDecryptedContent returns null for unknown id', () async {
      final result = await service.getDecryptedContent(9999);
      expect(result, isNull);
    });

    test('saveDecryptedContent persists link preview fields', () async {
      await service.saveDecryptedContent(1002, {
        'content': 'Check this',
        'linkPreviewUrl': 'https://example.com',
        'linkPreviewTitle': 'Example',
      });
      final result = await service.getDecryptedContent(1002);
      expect(result!['linkPreviewUrl'], 'https://example.com');
      expect(result['linkPreviewTitle'], 'Example');
    });

    test('content is isolated per user (different userId cannot read it)', () async {
      await service.saveDecryptedContent(1003, {'content': 'Secret'});

      // Different user
      final other = EncryptionService();
      await other.initialize(99, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      final result = await other.getDecryptedContent(1003);
      expect(result, isNull);
    });

    test('clearAllKeys removes decrypted content cache entries', () async {
      await service.saveDecryptedContent(1004, {'content': 'To be cleared'});
      await service.clearAllKeys();

      // Re-initialize the SAME service against the real post-clear store
      // (like the pending-send Contract 7a) so a stale read here would fail
      // if clearAllKeys left the content behind.
      await service.initialize(42, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      final result = await service.getDecryptedContent(1004);
      expect(result, isNull);
    });

    test('saveDecryptedContent prunes oldest entries above the cache limit', () async {
      final limited = EncryptionService(decryptedContentCacheLimit: 2);
      await limited.initialize(42, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));

      await limited.saveDecryptedContent(1001, {'content': 'oldest'});
      await limited.saveDecryptedContent(1002, {'content': 'middle'});
      await limited.saveDecryptedContent(1003, {'content': 'newest'});

      expect(await limited.getDecryptedContent(1001), isNull);
      expect((await limited.getDecryptedContent(1002))!['content'], 'middle');
      expect((await limited.getDecryptedContent(1003))!['content'], 'newest');
      expect(await limited.retiredMessageIds(), contains(1001));
    });

    test('saveDecryptedContent prunes legacy secure-storage decrypted entries', () async {
      final secureStorage = const FlutterSecureStorage();
      await secureStorage.write(
        key: 'e2e_42_decrypted_1001',
        value: '{"content":"legacy oldest"}',
      );
      await secureStorage.write(
        key: 'e2e_42_decrypted_1002',
        value: '{"content":"legacy middle"}',
      );

      final limited = EncryptionService(decryptedContentCacheLimit: 2);
      await limited.initialize(42, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      await limited.saveDecryptedContent(1003, {'content': 'newest'});

      expect(await limited.getDecryptedContent(1001), isNull);
      expect((await limited.getDecryptedContent(1002))!['content'], 'legacy middle');
      expect((await limited.getDecryptedContent(1003))!['content'], 'newest');
    });

    test('a keyless [Decryption failed] write never destroys stored media keys',
        () async {
      // First decrypt persists the media keys (only chance — ratchet is one-shot).
      await service.saveDecryptedContent(2001, {
        'content': '',
        'messageType': 'VOICE',
        'mediaUrl': 'https://x/media/msgs/a.bin',
        'mediaKey': 'KEYbase64',
        'mediaIv': 'IVbase64',
      });

      // A later transient re-decrypt throws DuplicateMessage and tries to mark
      // the row failed — this must be ignored, the keys must survive.
      await service.saveDecryptedContent(2001, {'content': '[Decryption failed]'});

      final result = await service.getDecryptedContent(2001);
      expect(result, isNotNull);
      expect(result!['mediaKey'], 'KEYbase64');
      expect(result['mediaIv'], 'IVbase64');
      expect(result['messageType'], 'VOICE');
      expect(result['content'], isNot('[Decryption failed]'));
    });

    test('a keyed write still updates an existing keyed entry', () async {
      await service.saveDecryptedContent(2002, {
        'content': '',
        'mediaUrl': 'https://x/old.bin',
        'mediaKey': 'OLD',
        'mediaIv': 'OLDIV',
      });
      await service.saveDecryptedContent(2002, {
        'content': '',
        'mediaUrl': 'https://x/new.bin',
        'mediaKey': 'NEW',
        'mediaIv': 'NEWIV',
      });
      final result = await service.getDecryptedContent(2002);
      expect(result!['mediaKey'], 'NEW');
      expect(result['mediaUrl'], 'https://x/new.bin');
    });

    test('a keyless write still overwrites a keyless (text) entry', () async {
      // Deliberately NOT the "[Decryption failed]" label: a placeholder may
      // never replace real plaintext (encryption_service_reload_race_test).
      // What this covers is that an ordinary text rewrite is still allowed,
      // unlike the keyed-media downgrade guarded just above.
      await service.saveDecryptedContent(2003, {'content': 'hello'});
      await service.saveDecryptedContent(2003, {'content': 'hello again'});
      final result = await service.getDecryptedContent(2003);
      expect(result!['content'], 'hello again');
    });
    /// The plaintext cache is bounded. Pruning used to run a full key scan on
    /// EVERY save, which is why a first entry into a 50-row chat paid 50 scans
    /// to discover it was nowhere near the cap — so the sweep is now gated on a
    /// size estimate instead.
    ///
    /// The estimate is seeded by ONE scan per service instance rather than a
    /// per-session write counter, and this is why: a counter starts at zero on
    /// every app start, so a user who decrypts a handful of messages per launch
    /// would never reach the threshold and the cache would grow forever. On web
    /// that ends at the localStorage quota, where the first thing to fail is
    /// not this cache but `WebSignalKvStore.write` persisting session and
    /// identity records.
    test('the cache stays bounded across service restarts', () async {
      final first = EncryptionService(decryptedContentCacheLimit: 10);
      await first.initialize(42, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      for (var id = 0; id < 10; id++) {
        await first.saveDecryptedContent(id, {'content': 'seed $id'});
      }

      // A NEW instance models an app restart: any per-session write counter
      // resets here, and a few writes must still not push the cache over.
      final restarted = EncryptionService(decryptedContentCacheLimit: 10);
      await restarted.initialize(42, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      for (var id = 10; id < 15; id++) {
        await restarted.saveDecryptedContent(id, {'content': 'after $id'});
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final cached = prefs
          .getKeys()
          .where((k) => k.startsWith('e2e_42_decrypted_'))
          .length;
      expect(
        cached,
        lessThanOrEqualTo(10),
        reason: 'a restart must not let the plaintext cache grow past its cap',
      );
      // Newest survive, oldest evicted.
      expect(await restarted.getDecryptedContent(14), isNotNull);
      expect(await restarted.getDecryptedContent(0), isNull);
    });

    test('clearDecryptedContentCache removes plaintext cache without deleting keys', () async {
      await service.saveDecryptedContent(1005, {'content': 'Local plaintext'});

      final result = await service.clearDecryptedContentCache();

      expect(result.removed, 1);
      expect(result.isComplete, isTrue);
      expect(await service.getDecryptedContent(1005), isNull);
      expect(service.isInitialized, isTrue);
      expect(await service.getIdentityFingerprint(), isNotNull);
    });

    // Pins the in-app "Clear local message cache" scope (Class-A verdict):
    // it removes ONLY persisted plaintext — Signal sessions and identity stay,
    // so a peer's NEXT message on the existing session still decrypts. A user
    // who "cleared cache" and then lost the session did a browser-level
    // site-data clear or reinstall, not this.
    test('clearDecryptedContentCache does NOT delete Signal sessions or identity', () async {
      const secureStorage = FlutterSecureStorage();
      await secureStorage.write(
        key: 'e2e_42_session_7_1',
        value: 'fake-session-record',
      );
      await service.saveDecryptedContent(1006, {'content': 'plain'});

      await service.clearDecryptedContentCache();

      expect(
        await secureStorage.read(key: 'e2e_42_session_7_1'),
        'fake-session-record',
        reason: 'sessions must survive a plaintext-cache clear',
      );
      expect(
        await secureStorage.read(key: 'e2e_42_identity_key_pair'),
        isNotNull,
        reason: 'identity must survive a plaintext-cache clear',
      );
      expect(await service.getDecryptedContent(1006), isNull);
    });

    test('sessionInventoryPeerIds lists only peers with a persisted session', () async {
      // Pre-seed session rows (+ a non-session key that must be ignored) before
      // init. Under flutter test kIsWeb is false, so DualStorage reads these
      // from the FlutterSecureStorage mock.
      //
      // The identity is seeded too, and must be: sessions on disk with NO
      // identity is the partial-loss signature that initialize() now refuses
      // to regenerate over (see encryption_identity_guard_test.dart). That
      // state cannot occur in production, so a fixture must not fake it.
      final identity = generateIdentityKeyPair();
      FlutterSecureStorage.setMockInitialValues({
        'e2e_77_identity_record_v1': jsonEncode(<String, dynamic>{
          'pair': base64Encode(identity.serialize()),
          'registrationId': 4242,
        }),
        'e2e_77_session_49_1': 'fake-record',
        'e2e_77_session_580_1': 'fake-record',
        'e2e_77_signed_pre_key_0': 'not-a-session',
      });
      SharedPreferences.setMockInitialValues({});
      final svc = EncryptionService();
      await svc.initialize(77, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));

      final peers = await svc.sessionInventoryPeerIds();
      expect(peers.toSet(), {'49', '580'},
          reason: 'multi-digit peer ids must parse; non-session keys excluded');
    });

    test('clearAllKeys (account deletion) deletes sessions AND identity', () async {
      const secureStorage = FlutterSecureStorage();
      await secureStorage.write(
        key: 'e2e_42_session_7_1',
        value: 'fake-session-record',
      );

      await service.clearAllKeys();

      expect(await secureStorage.read(key: 'e2e_42_session_7_1'), isNull);
      expect(
        await secureStorage.read(key: 'e2e_42_identity_key_pair'),
        isNull,
      );
    });
    test('stored records retain payload and lifecycle metadata', () async {
      final createdAt = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final expiresAt = createdAt.add(const Duration(hours: 1));

      await service.saveDecryptedContent(
        3001,
        {'content': 'metadata payload', 'messageType': 'TEXT'},
        conversationId: 77,
        createdAt: createdAt,
        expiresAt: expiresAt,
        disappearAfterSeconds: 90,
      );

      final record = await service.getDecryptedContent(3001);
      expect(record!['content'], 'metadata payload');
      expect(record['messageType'], 'TEXT');
      expect(record['_cid'], 77);
      expect(record['_savedAt'], isA<int>());
      expect(record['_createdAt'], createdAt.millisecondsSinceEpoch);
      expect(record['_expiresAt'], expiresAt.millisecondsSinceEpoch);
      expect(record['_disappearAfter'], 90);
    });

    test('per-id purge removes decrypted and raw records idempotently', () async {
      const id = 3002;
      const decryptedKey = 'e2e_42_decrypted_$id';
      const rawKey = 'e2e_42_decrypt_raw_v1_$id';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(decryptedKey, jsonEncode({'content': 'secret'}));
      await prefs.setString(rawKey, jsonEncode({'content': 'raw secret'}));

      final first = await service.removeDecryptedContent([id]);

      expect(first.removed, 1);
      expect(first.isComplete, isTrue);
      expect(prefs.containsKey(decryptedKey), isFalse);
      expect(prefs.containsKey(rawKey), isFalse);

      final second = await service.removeDecryptedContent([id]);
      expect(second.removed, 0);
      expect(second.isComplete, isTrue);
    });

    test('conversation purge lookup scans every saved record', () async {
      await service.saveDecryptedContent(
        3011,
        {'content': 'first'},
        conversationId: 71,
      );
      await service.saveDecryptedContent(
        3012,
        {'content': 'second'},
        conversationId: 71,
      );
      await service.saveDecryptedContent(
        3013,
        {'content': 'other conversation'},
        conversationId: 72,
      );

      expect(await service.messageIdsForConversations([71]), {3011, 3012});
    });

    test('narrower rewrites preserve conversation metadata', () async {
      final expiresAt = DateTime.utc(2026, 7, 1);
      await service.saveDecryptedContent(
        3021,
        {'content': 'first decrypt'},
        conversationId: 81,
        expiresAt: expiresAt,
      );
      // A narrow rewrite carrying only `content`. Not the failure label — that
      // is refused outright when real plaintext is held, and this test is about
      // metadata carry-forward, not the placeholder guard.
      await service.saveDecryptedContent(3021, {'content': 'later decrypt'});

      expect(await service.messageIdsForConversations([81]), {3021});
      final record = await service.getDecryptedContent(3021);
      expect(record!['content'], 'later decrypt');
      expect(record['_expiresAt'], expiresAt.millisecondsSinceEpoch);
    });

    test('expiry sweep destroys only on a REAL server stamp', () async {
      final serverNow = DateTime.now().toUtc();
      await service.saveDecryptedContent(
        3031,
        {'content': 'past grace'},
        expiresAt: serverNow.subtract(const Duration(minutes: 5, seconds: 1)),
      );
      await service.saveDecryptedContent(
        3032,
        {'content': 'inside grace'},
        expiresAt: serverNow.subtract(const Duration(minutes: 4, seconds: 59)),
      );
      // Unstamped read-mode record, far past the OLD never-read fallback.
      // That fallback used to authorize destruction here, and on 2026-08-02 it
      // destroyed five records the server was still serving (the expiry stamp
      // travels on one unacked socket event and had been lost) —
      // LEDGER_RECORD_LOST ×5. An unstamped record must NEVER expire locally;
      // its residue is reconciliation's job. Fail-before proven: the previous
      // expectation (3033 in `due.expired`) goes red against the fixed sweep.
      await service.saveDecryptedContent(
        3033,
        {'content': 'read but stamp lost'},
        createdAt: serverNow.subtract(
          const Duration(days: 30),
        ),
        disappearAfterSeconds: 60,
      );
      await service.saveDecryptedContent(3034, {'content': 'never expires'});

      final due = await service.destroyableMessageIds(
        serverNow: serverNow,
        expiryGrace: const Duration(minutes: 5),
      );

      expect(due.expired, contains(3031));
      expect(due.expired, isNot(contains(3032)));
      expect(
        due.expired,
        isNot(contains(3033)),
        reason: 'a fallback-derived deadline must never authorize destruction',
      );
      expect(due.expired, isNot(contains(3034)));
    });

    test('retention sweep holds future and legacy records', () async {
      final serverNow = DateTime.utc(2026, 7, 1);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'e2e_42_decrypted_3041',
        jsonEncode({
          'content': 'old record',
          '_savedAt': serverNow
              .subtract(EncryptionService.retentionWindow + const Duration(seconds: 1))
              .millisecondsSinceEpoch,
        }),
      );
      await prefs.setString(
        'e2e_42_decrypted_3042',
        jsonEncode({
          'content': 'future record',
          '_savedAt': serverNow
              .add(const Duration(days: 1))
              .millisecondsSinceEpoch,
        }),
      );
      await prefs.setString(
        'e2e_42_decrypted_3043',
        jsonEncode({'content': 'legacy record'}),
      );

      final due = await service.destroyableMessageIds(
        serverNow: serverNow,
        expiryGrace: const Duration(minutes: 5),
      );

      expect(due.retired, {3041});
      expect(due.expired, isEmpty);
      expect(due.retired, isNot(contains(3042)));
      expect(due.retired, isNot(contains(3043)));
    });

    test('purge backlog keeps unresolved work until every item is resolved',
        () async {
      await service.enqueuePurge([3051, 3052], ['2:first', '2:second']);
      final initial = await service.purgeBacklog();
      expect(initial.ids, {3051, 3052});
      expect(initial.ciphertexts, {'2:first', '2:second'});

      await service.resolvePurged([3051], ['2:first']);
      final remaining = await service.purgeBacklog();
      expect(remaining.ids, {3052});
      expect(remaining.ciphertexts, {'2:second'});

      await service.resolvePurged([3052], ['2:second']);
      final cleared = await service.purgeBacklog();
      expect(cleared.ids, isEmpty);
      expect(cleared.ciphertexts, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('e2e_42_purge_pending_v1'), isFalse);
    });
  });

  // metadata-privacy PR2.1: the `_wid`/`_wsid` stamp and the
  // `(senderId, wireId) -> localId` index. Nothing in the app reads the index
  // yet; the box path (PR3.1) will dedup at-least-once deliveries against it,
  // so a miss there re-shows a message and a wrong hit swallows one.
  group('EncryptionService wire id', () {
    late EncryptionService service;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      service = EncryptionService();
      await service.initialize(42, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    });

    test('a later write that names no wire id keeps the stamp', () async {
      await service.saveDecryptedContent(
        5001,
        {'content': 'hi'},
        conversationId: 7,
        wire: (senderId: 77, wireId: 'temp_1758700000000_1-abc'),
      );
      // An edit re-persists the row with new text and no wire id of its own.
      await service.saveDecryptedContent(5001, {'content': 'hi, edited'});

      expect(await service.wireIdIndex(), {
        (senderId: 77, wireId: 'temp_1758700000000_1-abc'): 5001,
      });
    });

    test('a later write cannot move the stamp or its sender', () async {
      await service.saveDecryptedContent(
        5002,
        {'content': 'hi'},
        wire: (senderId: 77, wireId: 'original-wire-id'),
      );
      // An edit envelope is peer-controlled; one claiming a new wire id must
      // not re-point the row, and neither may one naming another sender.
      await service.saveDecryptedContent(
        5002,
        {'content': 'hi, edited'},
        wire: (senderId: 66, wireId: 'hijacked-wire-id'),
      );

      expect(await service.wireIdIndex(), {
        (senderId: 77, wireId: 'original-wire-id'): 5002,
      });
    });

    test('the index spans the content store and the legacy secure store',
        () async {
      await const FlutterSecureStorage().write(
        key: 'e2e_42_decrypted_4001',
        value: jsonEncode({
          'content': 'old',
          '_wid': 'legacy-wire-0001',
          '_wsid': 77,
        }),
      );
      await service.saveDecryptedContent(
        4002,
        {'content': 'new'},
        wire: (senderId: 42, wireId: 'fresh-wire-0002'),
      );
      await service.saveDecryptedContent(4003, {'content': 'no wire id'});

      expect(await service.wireIdIndex(), {
        (senderId: 77, wireId: 'legacy-wire-0001'): 4001,
        (senderId: 42, wireId: 'fresh-wire-0002'): 4002,
      });
    });

    test('the content store wins over a legacy copy of the same record',
        () async {
      await const FlutterSecureStorage().write(
        key: 'e2e_42_decrypted_4010',
        value: jsonEncode({
          'content': 'stale',
          '_wid': 'stale-wire-0010',
          '_wsid': 77,
        }),
      );
      await service.saveDecryptedContent(
        4010,
        {'content': 'live'},
        wire: (senderId: 77, wireId: 'live-wire-0010'),
      );

      expect(await service.wireIdIndex(), {
        (senderId: 77, wireId: 'live-wire-0010'): 4010,
      });
    });

    test("one wire id from two senders resolves to each sender's record",
        () async {
      // A peer sees the wire ids of our sends in plaintext and can stamp one
      // on a message of its own. That claim lands under the PEER's name, so
      // it can neither shadow our copy nor be taken for it — whichever
      // arrives first.
      await service.saveDecryptedContent(
        4030,
        {'content': 'replayed by the peer'},
        wire: (senderId: 77, wireId: 'our-wire-id'),
      );
      await service.saveDecryptedContent(
        4031,
        {'content': 'ours'},
        wire: (senderId: 42, wireId: 'our-wire-id'),
      );

      expect(await service.wireIdIndex(), {
        (senderId: 77, wireId: 'our-wire-id'): 4030,
        (senderId: 42, wireId: 'our-wire-id'): 4031,
      });
    });

    test('a wire id a sender claimed twice resolves to neither', () async {
      // Backstop: the server keeps a sender's token unique
      // (`UNIQUE(senderId, sendToken)`), so two of one sender's records
      // holding one wire id is a contradiction, and neither is trusted.
      await service.saveDecryptedContent(
        4020,
        {'content': 'first'},
        wire: (senderId: 77, wireId: 'shared-wire-id'),
      );
      await service.saveDecryptedContent(
        4021,
        {'content': 'second'},
        wire: (senderId: 77, wireId: 'shared-wire-id'),
      );
      await service.saveDecryptedContent(
        4022,
        {'content': 'unrelated'},
        wire: (senderId: 77, wireId: 'other-wire-id'),
      );

      expect(await service.wireIdIndex(), {
        (senderId: 77, wireId: 'other-wire-id'): 4022,
      });
    });

    test('a wire id stamped without its sender claims nothing', () async {
      // Unscoped, it could be anyone's; resolving it would bring back the
      // unscoped index this key exists to prevent.
      await const FlutterSecureStorage().write(
        key: 'e2e_42_decrypted_4040',
        value: jsonEncode({'content': 'unscoped', '_wid': 'bare-wire-0040'}),
      );
      await service.saveDecryptedContent(
        4041,
        {'content': 'scoped'},
        wire: (senderId: 77, wireId: 'scoped-wire-0041'),
      );

      expect(await service.wireIdIndex(), {
        (senderId: 77, wireId: 'scoped-wire-0041'): 4041,
      });
    });
  });
}
