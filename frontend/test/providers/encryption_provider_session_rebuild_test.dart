import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Reproduces the 2026-06-12 mid-conversation loss (receiver LOG B, msg 8489):
/// the receiver force-rebuilds its session with a peer while the peer's
/// whisper (ctype 2) message is in flight.
///
/// Pre-fix, `ensureSession`'s rebuild path DELETED the SessionRecord first —
/// wiping the current AND all archived ratchet states — so the in-flight
/// message hit `Bad Mac / No valid sessions` and was lost permanently.
/// Post-fix the rebuild builds OVER the record: `processPreKeyBundle` archives
/// the old state itself (libsignal_protocol_dart 0.7.4
/// session_builder.dart:139) and `decryptFromSignal` finds it in
/// `previousSessionStates`, so the in-flight message still decrypts.
///
/// This is a REAL two-party libsignal exchange (X3DH + Double Ratchet), not a
/// fake: the peer runs raw libsignal over in-memory stores.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    "sessionRebuildNeeded also drops the sender's cached device list",
    () async {
      // Peer wedged after a phrase restore, 2026-09-22: the peer's bundle
      // moved to a NEW device id, so the session we are told to rebuild is not
      // the only stale thing we hold — the verified list naming the dead
      // device is what keeps every send and every inbound row pointed at it.
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});

      final provider = EncryptionProvider();
      // `authorization: null` is the one answer that verifies without a chain
      // — enough to prove a list is HELD, and then emptied.
      await provider.adoptDeliveredDeviceList(114, null);
      expect(provider.cachedDeviceList(114), isNotNull);

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
}
