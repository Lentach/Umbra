import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption/signal_stores.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';

/// In-memory [DualStorage] whose armed `session_` write parks until released.
class _GatedSessionStorage extends DualStorage {
  _GatedSessionStorage() : super(const FlutterSecureStorage());

  final Map<String, String> store = {};
  bool armed = false;
  Completer<void>? parked;
  final Completer<void> released = Completer<void>();

  @override
  Future<void> write({required String key, required String value}) async {
    if (armed && key.contains('session_')) {
      armed = false;
      parked!.complete();
      await released.future;
    }
    store[key] = value;
  }

  @override
  Future<String?> read({required String key}) async => store[key];

  @override
  Future<void> delete({required String key}) async => store.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EncryptionProvider — decrypted content delegation', () {
    late EncryptionProvider provider;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      provider = EncryptionProvider();
      // The identity guard needs an explicit server "no bundle" before it
      // will generate keys; every other socket event is silently ignored.
      provider.setEmitCallback((event, data) {
        if (event == 'checkOwnKeyBundle') {
          provider.onOwnKeyBundleStatus({'exists': false});
        }
      });
      await provider.initializeE2E(42);
    });

    test('saveDecryptedContent + getDecryptedContent round-trip', () async {
      await provider.saveDecryptedContent(1001, {'content': 'Hello world'});
      final result = await provider.getDecryptedContent(1001);
      expect(result, isNotNull);
      expect(result!['content'], 'Hello world');
    });

    test('getDecryptedContent returns null for unknown id', () async {
      final result = await provider.getDecryptedContent(9999);
      expect(result, isNull);
    });

    test('saveDecryptedContent before initializeE2E does not throw', () async {
      // Provider without initializeE2E — _userId is null.
      // Documented contract: silent no-op, never throws.
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final uninitializedProvider = EncryptionProvider();
      await expectLater(
        uninitializedProvider.saveDecryptedContent(1, {'content': 'test'}),
        completes,
      );
      final result = await uninitializedProvider.getDecryptedContent(1);
      expect(result, isNull);
    });

    test('saveDecryptedContent persists all envelope fields', () async {
      await provider.saveDecryptedContent(1002, {
        'content': 'Check this',
        'messageType': 'TEXT',
        'linkPreviewUrl': 'https://example.com',
        'linkPreviewTitle': 'Example',
      });
      final result = await provider.getDecryptedContent(1002);
      expect(result!['content'], 'Check this');
      expect(result['messageType'], 'TEXT');
      expect(result['linkPreviewUrl'], 'https://example.com');
      expect(result['linkPreviewTitle'], 'Example');
    });

    test(
      'clearLocalDecryptedContentCache removes persisted plaintext cache only',
      () async {
        await provider.saveDecryptedContent(1003, {
          'content': 'Cached message',
        });

        final result = await provider.clearLocalDecryptedContentCache();

        expect(result.removed, 1);
        expect(result.isComplete, isTrue);
        expect(await provider.getDecryptedContent(1003), isNull);
        expect(provider.isE2EReady, isTrue);
        expect(await provider.getIdentityFingerprint(), isNotNull);
      },
    );

    test(
      'purgeLocalPlaintext forgets the ledger entries of confirmed purges',
      () async {
        // Fail-before: a deliberately purged id kept its ledger entry, so the
        // next time the server served that row the gate read the absence as
        // UNEXPECTED loss — LEDGER_RECORD_LOST plus a permanent retire, for an
        // ordered deletion (the 2026-08-02 dump's exact ambiguity).
        await provider.saveDecryptedContent(1101, {'content': 'doomed'});
        await provider.flushDecryptedLedger();

        final result = await provider.purgeLocalPlaintext([1101]);

        // NOT asserting isComplete: on the test VM path_provider is absent,
        // so AudioCacheStore.remove fails the directory resolve and reports
        // every id — by design ("cannot say whether audio is on disk").
        // Ledger hygiene deliberately keys on the TEXT-record removal alone,
        // which did confirm: the record must be gone and the entry dropped.
        expect(await provider.getDecryptedContent(1101), isNull);
        expect(result.removed, 1);
        final sets = await provider.diagStorageSets();
        expect(sets.ledger, isNot(contains(1101)),
            reason: 'persisted ledger must drop the id');
      },
    );
  });

  group('EncryptionProvider — race and idempotency guards', () {
    late EncryptionProvider provider;
    late List<Map<String, dynamic>> emitted;

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
      await provider.initializeE2E(7);
    });

    test(
      'duplicate preKeyBundleResponse is ignored after first completion',
      () async {
        final future = provider.ensureSession(99);
        await Future<void>.delayed(Duration.zero);
        provider.onPreKeyBundleResponse({'userId': 99, 'bundle': null});
        provider.onPreKeyBundleResponse({'userId': 99, 'bundle': null});
        await expectLater(future, throwsStateError);
        expect(provider.pendingPreKeyFetches.containsKey((99, 1)), isFalse);
        final fetchEvents = emitted.where(
          (e) => e['event'] == 'fetchPreKeyBundle',
        );
        expect(fetchEvents.length, 1);
      },
    );

    test('a session build that JOINS an unanswered bundle fetch fails with it '
        '— never waits forever', () {
      fakeAsync((fake) {
        Object? ownerOutcome;
        Object? joinerOutcome;
        unawaited(provider.ensureSession(99).then<void>(
          (_) => ownerOutcome = 'built',
          onError: (Object e) => ownerOutcome = e,
        ));
        fake.flushMicrotasks();
        unawaited(provider.ensureSession(99).then<void>(
          (_) => joinerOutcome = 'built',
          onError: (Object e) => joinerOutcome = e,
        ));
        fake.flushMicrotasks();
        expect(
          emitted.where((e) => e['event'] == 'fetchPreKeyBundle').length,
          1,
          reason: 'the second build joins the first fetch',
        );

        fake.elapse(const Duration(seconds: 11));
        fake.flushMicrotasks();
        expect(ownerOutcome, isA<TimeoutException>());
        expect(
          joinerOutcome,
          isA<TimeoutException>(),
          reason: 'the joiner must fail with the shared fetch, not hang',
        );
      });
    });

    test('preKeysLow handler is reentrant-safe', () async {
      final initialUploads = emitted
          .where((e) => e['event'] == 'uploadOneTimePreKeys')
          .length;
      provider.onPreKeysLow({'remaining': 1});
      provider.onPreKeysLow({'remaining': 1});
      await Future<void>.delayed(Duration.zero);
      final uploads = emitted.where(
        (e) => e['event'] == 'uploadOneTimePreKeys',
      );
      expect(uploads.length - initialUploads, 1);
    });
    test(
      'null identity defers without upload and later initialized identity uploads tagged OTPs',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        final deferredEmits = <Map<String, dynamic>>[];
        final deferred = EncryptionProvider()
          ..setEmitCallback((event, data) {
            deferredEmits.add({'event': event, 'data': data});
          });
        deferred.onPreKeysLow({'remaining': 0});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          deferredEmits.where((e) => e['event'] == 'uploadOneTimePreKeys'),
          isEmpty,
        );
        expect(
          E2ePersistentDiag.entries.any(
            (e) => e.contains('OTP_REPLENISH_DEFERRED'),
          ),
          isTrue,
        );

        final taggedEmits = <Map<String, dynamic>>[];
        final ready = EncryptionProvider();
        ready.setEmitCallback((event, data) {
          taggedEmits.add({'event': event, 'data': data});
          if (event == 'checkOwnKeyBundle') {
            ready.onOwnKeyBundleStatus({'exists': false});
          }
        });
        await ready.initializeE2E(8);
        ready.onPreKeysLow({'remaining': 0});
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final uploads = taggedEmits
            .where((e) => e['event'] == 'uploadOneTimePreKeys')
            .map((e) => e['data'] as Map<String, dynamic>);
      expect(uploads, isNotEmpty);
      expect(uploads.last['identityPublicKey'], isA<String>());
      expect((uploads.last['identityPublicKey'] as String), isNotEmpty);
      },
    );
  });

  // Reproduces the 2026-06-12 mid-conversation loss (receiver LOG B, msg 8489):
  // the receiver force-rebuilds its session with a peer while the peer's
  // whisper (ctype 2) message is in flight.
  //
  // Pre-fix, `ensureSession`'s rebuild path DELETED the SessionRecord first —
  // wiping the current AND all archived ratchet states — so the in-flight
  // message hit `Bad Mac / No valid sessions` and was lost permanently.
  // Post-fix the rebuild builds OVER the record: `processPreKeyBundle` archives
  // the old state itself (libsignal_protocol_dart 0.7.4
  // session_builder.dart:139) and `decryptFromSignal` finds it in
  // `previousSessionStates`, so the in-flight message still decrypts.
  //
  // This is a REAL two-party libsignal exchange (X3DH + Double Ratchet), not a
  // fake: the peer runs raw libsignal over in-memory stores.
  group('EncryptionProvider — session rebuild', () {
    test(
      'forced send-side rebuild keeps the peer\'s in-flight whisper message decryptable',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});

        const ourUserId = 1;
        const peerUserId = 2;
        final ourAddress = SignalProtocolAddress(ourUserId.toString(), 1);

        // --- Our side: the real EncryptionProvider over mock storage. ---
        final provider = EncryptionProvider();
        Map<String, dynamic>? ourUploadedBundle;
        var ourUploadedOtps = <Map<String, dynamic>>[];
        Map<String, dynamic>? peerBundleToServe;
        provider.setEmitCallback((event, data) {
          if (event == 'checkOwnKeyBundle') {
            // Fresh install: the server has no bundle for us yet.
            provider.onOwnKeyBundleStatus({'exists': false});
          } else if (event == 'uploadKeyBundle') {
            ourUploadedBundle = (data as Map).cast<String, dynamic>();
            // The client publishes the identity FIRST and releases its one-time
            // pre-keys on this ack (2026-08-19): key material is only accepted
            // under an identity the account actually publishes, so a fake server
            // that never answers would never see the keys either.
            scheduleMicrotask(
              () => provider.onKeyBundleUploaded({'success': true}),
            );
          } else if (event == 'uploadOneTimePreKeys') {
            ourUploadedOtps = ((data as Map)['keys'] as List)
                .cast<Map<String, dynamic>>();
          } else if (event == 'fetchPreKeyBundle') {
            // Serve the peer's bundle asynchronously, like the server would.
            scheduleMicrotask(
              () => provider.onPreKeyBundleResponse({
                'userId': peerUserId,
                'bundle': peerBundleToServe,
              }),
            );
          }
        });
        await provider.initializeE2E(ourUserId);
        expect(
          ourUploadedBundle,
          isNotNull,
          reason: 'fresh install must upload a key bundle',
        );
        // Let the ack (and the pre-key release it triggers) land.
        await Future<void>.delayed(Duration.zero);
        expect(
          ourUploadedOtps,
          isNotEmpty,
          reason: 'the bundle ack releases the one-time pre-keys',
        );

        // --- Peer side: raw libsignal with in-memory stores. ---
        final peerIdentity = generateIdentityKeyPair();
        final peerRegistrationId = generateRegistrationId(false);
        final peerStore = InMemorySignalProtocolStore(
          peerIdentity,
          peerRegistrationId,
        );
        final peerSignedPreKey = generateSignedPreKey(peerIdentity, 0);
        await peerStore.storeSignedPreKey(0, peerSignedPreKey);
        final peerOtps = generatePreKeys(0, 2);
        for (final pk in peerOtps) {
          await peerStore.storePreKey(pk.id, pk);
        }
        peerBundleToServe = {
          'registrationId': peerRegistrationId,
          'identityPublicKey': base64Encode(
            peerIdentity.getPublicKey().serialize(),
          ),
          'signedPreKeyId': 0,
          'signedPreKeyPublic': base64Encode(
            peerSignedPreKey.getKeyPair().publicKey.serialize(),
          ),
          'signedPreKeySignature': base64Encode(peerSignedPreKey.signature),
          'oneTimePreKeyId': peerOtps[0].id,
          'oneTimePreKeyPublic': base64Encode(
            peerOtps[0].getKeyPair().publicKey.serialize(),
          ),
        };

        // Peer builds a session to US from our uploaded bundle (X3DH initiator).
        final ourOtp = ourUploadedOtps.first;
        final ourBundleForPeer = PreKeyBundle(
          ourUploadedBundle!['registrationId'] as int,
          1,
          ourOtp['keyId'] as int,
          Curve.decodePoint(base64Decode(ourOtp['publicKey'] as String), 0),
          ourUploadedBundle!['signedPreKeyId'] as int,
          Curve.decodePoint(
            base64Decode(ourUploadedBundle!['signedPreKeyPublic'] as String),
            0,
          ),
          base64Decode(ourUploadedBundle!['signedPreKeySignature'] as String),
          IdentityKey.fromBytes(
            base64Decode(ourUploadedBundle!['identityPublicKey'] as String),
            0,
          ),
        );
        await SessionBuilder.fromSignalStore(
          peerStore,
          ourAddress,
        ).processPreKeyBundle(ourBundleForPeer);
        final peerCipher = SessionCipher.fromStore(peerStore, ourAddress);

        String wire(CiphertextMessage m) =>
            '${m.getType()}:${base64Encode(m.serialize())}';

        // 1. Peer -> us (PreKey message). Establishes our (Bob) session.
        final msgA = await peerCipher.encrypt(
          Uint8List.fromList(utf8.encode('hello-A')),
        );
        expect(msgA.getType(), CiphertextMessage.prekeyType);
        expect(await provider.decrypt(peerUserId, wire(msgA)), 'hello-A');

        // 2. We reply so the peer's session is acknowledged
        //    (their next send becomes a plain whisper message).
        final replyWire = await provider.encrypt(peerUserId, 'reply-R');
        final colonIdx = replyWire.indexOf(':');
        final replyType = int.parse(replyWire.substring(0, colonIdx));
        final replyBody = base64Decode(replyWire.substring(colonIdx + 1));
        final replyPlain = replyType == CiphertextMessage.prekeyType
            ? await peerCipher.decrypt(PreKeySignalMessage(replyBody))
            : await peerCipher.decryptFromSignal(
                SignalMessage.fromSerialized(replyBody),
              );
        expect(utf8.decode(replyPlain), 'reply-R');

        // 3. Peer sends msg B — a WHISPER (ctype 2) — and it is "in flight".
        final msgB = await peerCipher.encrypt(
          Uint8List.fromList(utf8.encode('in-flight-B')),
        );
        expect(
          msgB.getType(),
          CiphertextMessage.whisperType,
          reason: 'after our reply the peer session is acknowledged',
        );

        // 4. WE force a session rebuild before reading B — the exact LOG-B
        //    sequence (SESSION_ENSURE needsRebuild:true on hasSession:true,
        //    then an outbound encrypt on the fresh session).
        provider.markSessionRebuild(peerUserId);
        await provider.ensureSession(peerUserId);
        await provider.encrypt(peerUserId, 'post-rebuild-send');

        // 5. Msg B must STILL decrypt: the rebuild must ARCHIVE the old ratchet
        //    state, never delete it. (Pre-fix: deleteSession before buildSession
        //    -> 'Bad Mac' / 'No valid sessions' -> permanent loss, msg 8489.)
        expect(await provider.decrypt(peerUserId, wire(msgB)), 'in-flight-B');
      },
    );

    test(
      'ENC-06: a second ensureSession during a forced rebuild waits for it',
      () async {
        // Fail-before: caller A consumed the force-rebuild mark, so caller B
        // (arriving while A's bundle fetch was unanswered) read
        // needsRebuild:false on hasSession:true and returned at once — its
        // caller then encrypts on the very session the rebuild replaces.
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        const peerUserId = 2;

        final peerIdentity = generateIdentityKeyPair();
        final peerSignedPreKey = generateSignedPreKey(peerIdentity, 0);
        final peerOtp = generatePreKeys(0, 1).single;
        final peerBundle = <String, dynamic>{
          'registrationId': generateRegistrationId(false),
          'identityPublicKey': base64Encode(
            peerIdentity.getPublicKey().serialize(),
          ),
          'signedPreKeyId': 0,
          'signedPreKeyPublic': base64Encode(
            peerSignedPreKey.getKeyPair().publicKey.serialize(),
          ),
          'signedPreKeySignature': base64Encode(peerSignedPreKey.signature),
          'oneTimePreKeyId': peerOtp.id,
          'oneTimePreKeyPublic': base64Encode(
            peerOtp.getKeyPair().publicKey.serialize(),
          ),
        };

        final provider = EncryptionProvider();
        var fetches = 0;
        var answerFetches = true;
        void answer() => provider.onPreKeyBundleResponse({
          'userId': peerUserId,
          'bundle': peerBundle,
        });
        provider.setEmitCallback((event, data) {
          if (event == 'checkOwnKeyBundle') {
            provider.onOwnKeyBundleStatus({'exists': false});
          } else if (event == 'fetchPreKeyBundle') {
            fetches++;
            if (answerFetches) scheduleMicrotask(answer);
          }
        });
        await provider.initializeE2E(1);

        // A session exists.
        await provider.ensureSession(peerUserId);
        expect(fetches, 1);

        // The rebuild's bundle fetch stays unanswered: the build is in flight.
        answerFetches = false;
        provider.markSessionRebuild(peerUserId);
        var firstDone = false;
        var secondDone = false;
        final first = provider
            .ensureSession(peerUserId)
            .then((_) => firstDone = true);
        await pumpEventQueue();
        expect(fetches, 2, reason: 'the first caller started the rebuild');
        final second = provider
            .ensureSession(peerUserId)
            .then((_) => secondDone = true);
        await pumpEventQueue();

        expect(firstDone, isFalse);
        expect(
          secondDone,
          isFalse,
          reason: 'the second caller must not get the old session back '
              'while its rebuild is in flight',
        );

        answer();
        await Future.wait([first, second]);
        expect(fetches, 2, reason: 'the second caller joined, it did not fetch');
        expect(provider.needsSessionRebuild(peerUserId), isFalse);
      },
    );

    test(
      'ENC-06: a second ensureSession during a forced rebuild of a box friend '
      'waits for it',
      () async {
        // Fail-before: the served-bundle branch never joined a single flight,
        // so the second caller returned on the old session at once.
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        const peerUserId = 2;
        final peerIdentity = generateIdentityKeyPair();
        final peerSigned = generateSignedPreKey(peerIdentity, 0);
        final peerOtp = generatePreKeys(0, 1).single;
        final bundle = <String, dynamic>{
          'registrationId': generateRegistrationId(false),
          'identityPublicKey': base64Encode(
            peerIdentity.getPublicKey().serialize(),
          ),
          'signedPreKeyId': 0,
          'signedPreKeyPublic': base64Encode(
            peerSigned.getKeyPair().publicKey.serialize(),
          ),
          'signedPreKeySignature': base64Encode(peerSigned.signature),
          'oneTimePreKeyId': peerOtp.id,
          'oneTimePreKeyPublic': base64Encode(
            peerOtp.getKeyPair().publicKey.serialize(),
          ),
        };
        final storage = _GatedSessionStorage();
        final provider = EncryptionProvider();
        provider.encryptionService.debugSetDualStorage(storage);
        provider
          ..isBoxOnlyPeer = ((_) => true)
          ..servedBundleFor = ((_, _) => bundle)
          ..setEmitCallback((event, data) {
            if (event == 'checkOwnKeyBundle') {
              provider.onOwnKeyBundleStatus({'exists': false});
            }
          });
        await provider.initializeE2E(1);
        await provider.ensureSession(peerUserId);

        storage
          ..parked = Completer<void>()
          ..armed = true;
        provider.markSessionRebuild(peerUserId);
        var secondDone = false;
        final first = provider.ensureSession(peerUserId);
        await storage.parked!.future;
        final second = provider
            .ensureSession(peerUserId)
            .then((_) => secondDone = true);
        await pumpEventQueue();
        expect(
          secondDone,
          isFalse,
          reason: 'the rebuild is still storing its session',
        );

        storage.released.complete();
        await Future.wait([first, second]);
        expect(provider.needsSessionRebuild(peerUserId), isFalse);
      },
    );

    test(
      "sessionRebuildNeeded also drops the sender's cached device list",
      () async {
        // Peer wedged after a phrase restore, 2026-09-22: the peer's bundle
        // moved to a NEW device id, so the session we are told to rebuild is not
        // the only stale thing we hold — the verified list naming the dead
        // device is what keeps every send and every inbound row pointed at it.
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});

        // The provider's clock is moved past the relookup floor after the list
        // is held: a friend's list is dropped only when a lookup may be bought.
        var now = DateTime.utc(2026, 11, 4);
        final provider = EncryptionProvider(clock: () => now);
        provider
          ..setEmitCallback((event, data) {
            if (event == 'checkOwnKeyBundle') {
              provider.onOwnKeyBundleStatus({'exists': false});
            }
          })
          ..listsByHandle = ((peer) => peer == 114)
          // `authorization: null` is the one answer that verifies without a
          // chain — enough to prove a list is HELD, and then emptied.
          ..lookupBoxPeerList = ((peer) async => null);
        await provider.initializeE2E(7);
        await provider.getVerifiedDeviceList(114);
        expect(provider.cachedDeviceList(114), isNotNull);
        now = now.add(kBoxRelookupFloor * 2);

        provider.onSessionRebuildNeeded({'fromUserId': 114});

        expect(
          provider.cachedDeviceList(114),
          isNull,
          reason: 'the next send or inbound row must refetch, not reuse it',
        );
        expect(
          provider.needsSessionRebuild(114),
          isTrue,
          reason: 'the force-rebuild mark is additive, never replaced',
        );
      },
    );
  });
}
