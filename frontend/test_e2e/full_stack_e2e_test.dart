// Full-stack two-account E2E Signal wire harness.
//
// NOT part of the default `flutter test` suite — this directory is a sibling
// of `test/` precisely so `flutter test` (local + CI) never picks it up.
//
// Invocation contract:
//
//   docker-compose up                     # repo root: backend :3000 + Postgres
//   cd frontend && flutter test test_e2e
//
// What it proves, over the REAL wire (REST auth -> Socket.IO -> ChatGateway ->
// DTO validation -> Postgres -> broadcast) with REAL libsignal on both ends:
//   1. register -> socketReady (parseable, plausible serverTime) -> WS key upload
//   2. friend request/accept -> conversation open
//   3. first message is PreKey (3:), server stores only '[encrypted]',
//      recipient decrypts the exact plaintext
//   4. replies ratchet to whisper (2:) in both directions, in order
//   5. mid-conversation session rebuild (deleteSession -> fetch bundle ->
//      PreKey again) — the shape of the 2026-07 field incidents
//   6. editMessage swaps ciphertext (messageEdited both sides, re-decrypt);
//      non-sender edit rejected with not_sender
//   7. reactions round-trip (reactionUpdated both sides)
//
// Fresh accounts EVERY run, by design: the server never purges unused
// one-time pre-keys and serves them oldest-first, so reusing accounts with
// fresh client keys would deterministically produce phantom bad-MAC failures.
// Register throttle is 10/hr per IP; `docker compose restart backend` resets
// the in-memory counters when iterating.
// Each run leaves 2 throwaway accounts (+1 conversation, ~11 messages, key
// bundles/OTPs) in the TARGET dev DB — harmless local cruft; never point
// E2E_BASE_URL at production.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/device_link/link_crypto.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/e2e_test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Must come AFTER binding init: the binding's HttpOverrides answers every
  // real request with 400, which would silently break REST and the WS upgrade.
  enableRealNetwork();

  final baseUrl = e2eBaseUrl();
  final runTag = DateTime.now().millisecondsSinceEpoch.toString();

  late E2eClient alice;
  late E2eClient bob;
  late int conversationId;
  // Shared by the T2 device-list group (which enrolls alice) and the T3
  // provisioning group (which signs later mutations): the DAK private key
  // exists ONLY inside this engine instance.
  final engine = DeviceAuthorityEngine();

  /// Asserts the `"{type}:{base64}"` wire format and returns the type
  /// (3 = PreKeySignalMessage, 2 = SignalMessage/whisper).
  int wireType(String ciphertext) {
    expect(
      ciphertext,
      matches(RegExp(r'^\d+:[A-Za-z0-9+/]+=*$')),
      reason: 'ciphertext must be "{type}:{base64}"',
    );
    return int.parse(ciphertext.substring(0, ciphertext.indexOf(':')));
  }

  /// Pins the server clock field which protects irreversible expiry purges.
  void expectSocketReadyServerTime(dynamic payload, String clientLabel) {
    expect(
      payload,
      isA<Map<dynamic, dynamic>>(),
      reason: '$clientLabel socketReady must carry an object payload',
    );
    final serverTime = (payload as Map)['serverTime'];
    expect(
      serverTime,
      isA<String>(),
      reason: '$clientLabel socketReady.serverTime must be a string',
    );

    final serverTimeString = serverTime as String;
    expect(
      serverTimeString,
      isNotEmpty,
      reason: '$clientLabel socketReady.serverTime must not be empty',
    );
    final parsed = DateTime.tryParse(serverTimeString);
    expect(
      parsed,
      isNotNull,
      reason:
          '$clientLabel socketReady.serverTime must be a parseable ISO-8601 instant',
    );
    expect(
      parsed!.isUtc,
      isTrue,
      reason: '$clientLabel socketReady.serverTime must be UTC',
    );
    expect(
      parsed.difference(DateTime.now().toUtc()).abs(),
      lessThan(const Duration(minutes: 5)),
      reason:
          '$clientLabel socketReady.serverTime must be close to the test machine clock',
    );
  }

  /// Sends [content] from [sender] to [recipient] and asserts the full wire
  /// round trip: messageSent shape on the sender, newMessage on the
  /// recipient, exact plaintext after decrypt. Returns the server message id.
  Future<int> roundTrip(
    E2eClient sender,
    E2eClient recipient,
    String content, {
    required String tempId,
    required int expectedWireType,
  }) async {
    final ciphertext = await sender.encryptText(recipient.userId, content);
    expect(
      wireType(ciphertext),
      expectedWireType,
      reason: 'unexpected ciphertext type for tempId=$tempId',
    );

    final sent = await sender.sendEncrypted(
      recipient.userId,
      ciphertext,
      tempId: tempId,
    );
    expect(
      sent['content'],
      '[encrypted]',
      reason: 'server must never store plaintext',
    );
    expect(sent['encryptedContent'], ciphertext);
    expect(sent['senderId'], sender.userId);
    expect(sent['conversationId'], conversationId);
    expect(sent['deliveryStatus'], 'SENT');
    expect(sent['messageType'], 'TEXT');
    expect(sent['editedAt'], isNull);
    final messageId = sent['id'] as int;
    expect(messageId, greaterThan(0));

    final received = await recipient.awaitNewMessage(tempId);
    expect(received['id'], messageId);
    expect(received['content'], '[encrypted]');
    expect(received['encryptedContent'], ciphertext);

    final plaintext = await recipient.decryptText(
      sender.userId,
      received['encryptedContent'] as String,
    );
    expect(plaintext, content);
    return messageId;
  }

  setUpAll(() async {
    await requireBackendUp(baseUrl);

    // In-memory Signal key storage, same pattern as the in-process roundtrip
    // test. Both clients share one mock store via per-user key prefixes.
    // The analyzer only recognizes @visibleForTesting use under `test/`;
    // this IS a test, deliberately outside the default suite dir.
    // ignore: invalid_use_of_visible_for_testing_member
    FlutterSecureStorage.setMockInitialValues({});
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});

    alice = E2eClient('alice', baseUrl);
    bob = E2eClient('bob', baseUrl);

    // 1. Fresh accounts + tokens (REST).
    await alice.registerFresh();
    await bob.registerFresh();

    // 2. Real sockets, authenticated via handshake auth token.
    final aliceSocketReady = await alice.connectSocket();
    expectSocketReadyServerTime(aliceSocketReady, alice.label);
    await bob.connectSocket();

    // 3. Signal identity + key bundle upload (WS, like EncryptionProvider).
    await alice.initializeAndUploadKeys();
    await bob.initializeAndUploadKeys();

    // 4. Friendship: request over WS, accept on the receiving side.
    //
    // This also proves the GHOST INVITE contract across the tier boundary.
    // The backend emits `sentRequestsList` and the client parses it, but each
    // side is unit-tested against a mock, so only a live socket shows whether
    // the SENDER's own list is the one being refreshed. That is the half that
    // mocks cannot prove.
    //
    // Every wait below is preceded by a discard. Connecting already buffers an
    // empty `sentRequestsList`, and `EventLog.next` matches the first buffered
    // payload satisfying its predicate — so without discarding, a "must be
    // empty" wait happily consumes the empty from CONNECT time and passes even
    // if the action emitted nothing at all.
    alice.events.discard('sentRequestsList');
    alice.socketService.sendFriendRequest(bob.userId);

    final aliceGhosts =
        await alice.events.next(
              'sentRequestsList',
              where: (p) =>
                  p is List &&
                  p.any(
                    (e) =>
                        e is Map &&
                        e['receiver'] is Map &&
                        (e['receiver'] as Map)['id'] == bob.userId,
                  ),
              reason: 'sender must see their own outbound invite as a ghost',
            )
            as List;
    expect(
      aliceGhosts.length,
      1,
      reason: 'exactly the one invite alice just sent',
    );

    final rejected =
        await bob.events.next(
              'newFriendRequest',
              where: (p) =>
                  p is Map &&
                  p['sender'] is Map &&
                  (p['sender'] as Map)['id'] == alice.userId,
              reason: 'bob receiving alice first friend request',
            )
            as Map;

    // REJECT first. This is the riskier half of the lifecycle: the reject
    // path had to have `server` + `onlineUsers` threaded into it to reach the
    // ORIGINAL SENDER at all, and a mock cannot show which socket was hit.
    alice.events.discard('sentRequestsList');
    bob.socketService.rejectFriendRequest(rejected['id'] as int);
    await alice.events.next(
      'sentRequestsList',
      where: (p) => p is List && p.isEmpty,
      reason: 'rejecting must clear the sender ghost',
    );

    // Re-send, then accept, so the rest of the flow still has a friendship.
    alice.events.discard('sentRequestsList');
    alice.socketService.sendFriendRequest(bob.userId);
    await alice.events.next(
      'sentRequestsList',
      where: (p) =>
          p is List &&
          p.any(
            (e) =>
                e is Map &&
                e['receiver'] is Map &&
                (e['receiver'] as Map)['id'] == bob.userId,
          ),
      reason: 'the re-sent invite is a ghost again',
    );

    final request =
        await bob.events.next(
              'newFriendRequest',
              where: (p) =>
                  p is Map &&
                  p['sender'] is Map &&
                  (p['sender'] as Map)['id'] == alice.userId &&
                  p['id'] != rejected['id'],
              reason: 'bob receiving the re-sent request',
            )
            as Map;
    alice.events.discard('sentRequestsList');
    bob.events.discard('friendRequestAccepted');
    alice.events.discard('friendRequestAccepted');
    bob.events.discard('openConversation');
    alice.events.discard('openConversation');
    bob.socketService.acceptFriendRequest(request['id'] as int);
    final aliceAccepted =
        await alice.events.next(
              'friendRequestAccepted',
              reason: 'alice accept confirmation',
            )
            as Map;
    final bobAccepted =
        await bob.events.next(
              'friendRequestAccepted',
              reason: 'bob accept confirmation',
            )
            as Map;
    expect(
      aliceAccepted['conversationId'],
      isA<int>(),
      reason: 'alice accepted payload must carry a conversation id',
    );
    expect(
      bobAccepted['conversationId'],
      isA<int>(),
      reason: 'bob accepted payload must carry a conversation id',
    );
    expect(
      aliceAccepted['chatReady'],
      isTrue,
      reason: 'alice accepted payload must report chat readiness',
    );
    expect(
      bobAccepted['chatReady'],
      isTrue,
      reason: 'bob accepted payload must report chat readiness',
    );
    final aliceConversationId = aliceAccepted['conversationId'] as int;
    final bobConversationId = bobAccepted['conversationId'] as int;
    expect(
      bobConversationId,
      aliceConversationId,
      reason: 'both accepted payloads must identify the same conversation',
    );

    // The ghost must CLEAR on the sender's side once the invite resolves —
    // a ghost that outlives its invite is the whole failure mode here.
    await alice.events.next(
      'sentRequestsList',
      where: (p) => p is List && p.isEmpty,
      reason: 'accepting must clear the sender ghost',
    );

    // 5. Accepting reserves openConversation for explicit user intent only.
    await bob.events.none(
      'openConversation',
      within: const Duration(seconds: 3),
      reason: 'accepting an invitation must not auto-open chat',
    );
    alice.events.discard('openConversation');
    alice.socketService.startConversation(bob.userId);
    final aliceOpen =
        await alice.events.next(
              'openConversation',
              reason: 'alice startConversation',
            )
            as Map;
    conversationId = bobConversationId;
    expect(
      aliceOpen['conversationId'],
      conversationId,
      reason: 'startConversation must use the accepted conversation',
    );
  });

  tearDownAll(() {
    alice.dispose();
    bob.dispose();
  });

  group('full-stack E2E wire', () {
    test(
      'first message travels as PreKey (3:), server blind, peer decrypts',
      () async {
        final bundle = await alice.fetchBundleFor(bob.userId);
        expect(bundle['identityPublicKey'], isA<String>());
        expect(
          bundle['oneTimePreKeyId'],
          isNotNull,
          reason: 'fresh account must have unused one-time pre-keys',
        );
        await alice.encryption.buildSession(bob.userId, bundle, expectedIdentityBase64: null);

        await roundTrip(
          alice,
          bob,
          'first-contact-$runTag',
          tempId: 't1-$runTag',
          expectedWireType: 3,
        );
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'replies ratchet to whisper (2:) in both directions, in order',
      () async {
        await roundTrip(
          bob,
          alice,
          'reply-1-$runTag',
          tempId: 't2-$runTag',
          expectedWireType: 2,
        );
        await roundTrip(
          alice,
          bob,
          'msg-2-$runTag',
          tempId: 't3-$runTag',
          expectedWireType: 2,
        );
        await roundTrip(
          bob,
          alice,
          'reply-2-$runTag',
          tempId: 't4-$runTag',
          expectedWireType: 2,
        );

        // Same plaintext twice must produce different ciphertexts (ratchet
        // advanced), and both must decrypt.
        final ct1 = await alice.encryptText(bob.userId, 'twin-$runTag');
        final ct2 = await alice.encryptText(bob.userId, 'twin-$runTag');
        expect(ct1, isNot(ct2), reason: 'ratchet must advance per message');
        await alice.sendEncrypted(bob.userId, ct1, tempId: 't5-$runTag');
        await alice.sendEncrypted(bob.userId, ct2, tempId: 't6-$runTag');
        final r1 = await bob.awaitNewMessage('t5-$runTag');
        final r2 = await bob.awaitNewMessage('t6-$runTag');
        expect(
          await bob.decryptText(alice.userId, r1['encryptedContent'] as String),
          'twin-$runTag',
        );
        expect(
          await bob.decryptText(alice.userId, r2['encryptedContent'] as String),
          'twin-$runTag',
        );
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'mid-conversation session rebuild goes PreKey (3:) and peer recovers',
      () async {
        // The 2026-07 field-incident shape: sender loses/rebuilds its session
        // mid-conversation; next message is a type-3 that the receiver must
        // process over its existing session state.
        await alice.encryption.deleteSession(bob.userId);
        final bundle = await alice.fetchBundleFor(bob.userId);
        await alice.encryption.buildSession(bob.userId, bundle, expectedIdentityBase64: null);

        await roundTrip(
          alice,
          bob,
          'post-rebuild-$runTag',
          tempId: 't7-$runTag',
          expectedWireType: 3,
        );

        // Bidirectional sanity after the rebuild.
        await roundTrip(
          bob,
          alice,
          'post-rebuild-reply-$runTag',
          tempId: 't8-$runTag',
          expectedWireType: 2,
        );
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'edit swaps ciphertext; both sides get messageEdited; peer re-decrypts',
      () async {
        final messageId = await roundTrip(
          alice,
          bob,
          'original-$runTag',
          tempId: 't9-$runTag',
          expectedWireType: 2,
        );

        final editedPlaintext = 'edited-$runTag';
        final newCiphertext = await alice.encryptText(
          bob.userId,
          editedPlaintext,
        );
        expect(
          wireType(newCiphertext),
          2,
          reason: 'edit rides the existing session',
        );
        alice.emitEditMessage(messageId, newCiphertext);

        // The PEER gets the new ciphertext, normalized into its device-1
        // envelope at ingest (§8 compat).
        final peerEdit = await bob.awaitMessageEdited(messageId);
        expect(peerEdit['conversationId'], conversationId);
        expect(peerEdit['content'], '[encrypted]');
        expect(peerEdit['encryptedContent'], newCiphertext);
        expect(
          DateTime.tryParse(peerEdit['editedAt'] as String),
          isNotNull,
          reason: 'editedAt must be an ISO timestamp',
        );

        // The EDITING device is the PRODUCER of that ciphertext (amendment
        // (xxx)), so its echo carries none: it holds the plaintext already and
        // must never be handed a ciphertext of its own to decrypt.
        final ownEcho = await alice.awaitMessageEdited(messageId);
        expect(ownEcho['encryptedContent'], isNull);
        expect(ownEcho['originDeviceId'], 1);
        expect(DateTime.tryParse(ownEcho['editedAt'] as String), isNotNull);

        expect(
          await bob.decryptText(alice.userId, newCiphertext),
          editedPlaintext,
        );
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'edit by non-sender is rejected with not_sender',
      () async {
        final messageId = await roundTrip(
          alice,
          bob,
          'no-touching-$runTag',
          tempId: 't10-$runTag',
          expectedWireType: 2,
        );

        // Rejected before any store/decrypt, so a placeholder string is fine
        // (and never advances either ratchet).
        bob.emitEditMessage(messageId, 'rejected-probe-$runTag');
        final failed =
            await bob.events.next(
                  'editMessageFailed',
                  where: (p) => p is Map && p['messageId'] == messageId,
                  reason: 'bob edit rejection',
                )
                as Map;
        expect(failed['reason'], 'not_sender');
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'a legacy plaintext reaction still round-trips and clears on removal',
      () async {
        // The compat window (design §3.3): the server accepts a plain emoji as
        // a reaction key so clients that have not updated keep working. Driven
        // on the RAW socket, because the app's own provider now blinds every
        // reaction into a token — this case exists to prove the OLD shape is
        // still served, so it must not go through the new client path.
        final messageId = await roundTrip(
          alice,
          bob,
          'react-target-$runTag',
          tempId: 't11-$runTag',
          expectedWireType: 2,
        );

        bob.socketService.socket!.emit('addReaction', {
          'messageId': messageId,
          'emoji': '🔥',
        });
        for (final client in [alice, bob]) {
          final updated =
              await client.events.next(
                    'reactionUpdated',
                    where: (p) => p is Map && p['messageId'] == messageId,
                    reason: '${client.label} reaction add',
                  )
                  as Map;
          expect(updated['conversationId'], conversationId);
          expect((updated['reactions'] as Map)['🔥'], [bob.userId]);
        }

        // Removal names a DIFFERENT key than the one stored, which is the
        // real compat hazard: an updated client only knows its token. The
        // server drops the user's single reaction regardless of the key, so
        // the chip clears instead of staying lit forever.
        bob.socketService.socket!.emit('removeReaction', {
          'messageId': messageId,
          'emoji': 'AAAAAAAAAAAAAAAAAAAAAA',
        });
        for (final client in [alice, bob]) {
          final updated =
              await client.events.next(
                    'reactionUpdated',
                    where: (p) => p is Map && p['messageId'] == messageId,
                    reason: '${client.label} reaction remove',
                  )
                  as Map;
          expect(updated['reactions'], isEmpty);
        }
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'delete destroys the local plaintext and leaves the Signal session alive',
      () async {
        final plaintext = 'purge-me-$runTag';
        final messageId = await roundTrip(
          alice,
          bob,
          plaintext,
          tempId: 't12-$runTag',
          expectedWireType: 2,
        );

        // Persist exactly as the app does at decrypt time, including the
        // envelope metadata the sweeps select on.
        await bob.encryption.saveDecryptedContent(
          messageId,
          {'content': plaintext},
          conversationId: conversationId,
          createdAt: DateTime.now().toUtc(),
        );
        expect(
          (await bob.encryption.getDecryptedContent(messageId))?['content'],
          plaintext,
          reason:
              'precondition: the only copy of the plaintext is on the device',
        );

        // Real server delete over the real wire, hard-deleting the row.
        alice.emitDeleteMessage(messageId, forEveryone: true);
        for (final client in [alice, bob]) {
          await client.events.next(
            'messageDeleted',
            where: (p) => p is Map && p['messageId'] == messageId,
            reason: '${client.label} messageDeleted',
          );
        }

        // What the app's messageDeleted handler does. Asserted against a REAL
        // store with real Signal state present, because the risk is not that
        // the delete fails — it is that destroying plaintext also damages the
        // session and bricks the conversation.
        final purge = await bob.encryption.removeDecryptedContent([messageId]);
        expect(purge.isComplete, isTrue);
        expect(purge.removed, 1);
        expect(
          await bob.encryption.getDecryptedContent(messageId),
          isNull,
          reason: 'deleting a message must destroy its local plaintext',
        );

        // The session survived: new traffic still ratchets and decrypts. A
        // purge that quietly broke this would trade one bug for a worse one.
        await roundTrip(
          alice,
          bob,
          'after-purge-$runTag',
          tempId: 't13-$runTag',
          expectedWireType: 2,
        );
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'getServedMessageIds answers from the real history rules',
      () async {
        // The reconcile pass destroys the local plaintext of every id MISSING
        // from this answer, so a wrong "not served" is permanent data loss.
        // Mocked unit tests cannot see the assembled SQL; this can.
        final mine = await roundTrip(
          alice,
          bob,
          'served-mine-$runTag',
          tempId: 't14-$runTag',
          expectedWireType: 2,
        );
        final theirs = await roundTrip(
          bob,
          alice,
          'served-theirs-$runTag',
          tempId: 't15-$runTag',
          expectedWireType: 2,
        );
        final deleted = await roundTrip(
          alice,
          bob,
          'served-deleted-$runTag',
          tempId: 't16-$runTag',
          expectedWireType: 2,
        );
        final hiddenForBob = await roundTrip(
          alice,
          bob,
          'served-hidden-$runTag',
          tempId: 't17-$runTag',
          expectedWireType: 2,
        );

        alice.emitDeleteMessage(deleted, forEveryone: true);
        for (final client in [alice, bob]) {
          await client.events.next(
            'messageDeleted',
            where: (p) => p is Map && p['messageId'] == deleted,
            reason: '${client.label} hard delete',
          );
        }

        bob.emitDeleteMessage(hiddenForBob, forEveryone: false);
        await bob.events.next(
          'messageDeleted',
          where: (p) => p is Map && p['messageId'] == hiddenForBob,
          reason: 'bob delete-for-me',
        );

        const unknownId = 2147483000;
        final forAlice = await alice.servedMessageIds([
          mine,
          theirs,
          deleted,
          hiddenForBob,
          unknownId,
        ]);

        // THE trap: every unread-count query in MessagesService carries
        // `sender != me`. Copying one into the existence check would report
        // the user's entire outgoing history as gone and destroy it.
        expect(
          forAlice,
          contains(mine),
          reason: 'a message the caller SENT is still served',
        );
        expect(forAlice, contains(theirs));
        expect(
          forAlice,
          contains(hiddenForBob),
          reason: "bob's delete-for-me must not affect alice",
        );
        expect(forAlice, isNot(contains(deleted)));
        expect(forAlice, isNot(contains(unknownId)));

        final forBob = await bob.servedMessageIds([
          mine,
          theirs,
          deleted,
          hiddenForBob,
        ]);
        expect(forBob, contains(mine));
        expect(forBob, contains(theirs));
        expect(forBob, isNot(contains(deleted)));
        expect(
          forBob,
          isNot(contains(hiddenForBob)),
          reason: 'delete-for-me must read as gone for the user who did it',
        );
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test('a retry carrying the same sendToken re-acks the committed row and '
        'writes no second message (Phase 1 §5.4)', () async {
      // A lost ack is the dangerous case: the sending device holds the ONLY
      // plaintext copy until the ack lands, so a retry must recover the row
      // the server already wrote instead of duplicating the message.
      final token = 'tok-$runTag-${DateTime.now().microsecondsSinceEpoch}';
      final ciphertext = await alice.encryptText(
        bob.userId,
        'idempotent-$runTag',
      );

      final first = await alice.sendWithToken(
        bob.userId,
        ciphertext,
        tempId: 'tok-a-$runTag',
        sendToken: token,
      );
      final messageId = (first['id'] as num).toInt();
      expect(
        first['originDeviceId'],
        1,
        reason: 'the server records which device produced the message',
      );

      // Same token, new tempId: this is the client retrying, not a new send.
      final retry = await alice.sendWithToken(
        bob.userId,
        ciphertext,
        tempId: 'tok-b-$runTag',
        sendToken: token,
      );

      expect(
        (retry['id'] as num).toInt(),
        messageId,
        reason: 'the retry must resolve to the committed row',
      );
      // And the recipient must not see it twice — Signal decryption is not
      // idempotent, so a second delivery of the same ciphertext would fail
      // into the session-destroying policy.
      await bob.events.none(
        'newMessage',
        within: const Duration(seconds: 3),
        where: (p) => p is Map && p['tempId'] == 'tok-b-$runTag',
        reason: 'a retry must not deliver the message a second time',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    // Phase 1 (spec §4 + §5.1 + §8): key material is namespaced by
    // (userId, deviceId), the device a bundle lands in comes from the
    // SESSION, and a device that published nothing is served nothing.
    //
    // Hosted here rather than in a file of its own because /auth/register is
    // throttled 10/hr per IP and this suite already spends every one of them;
    // alice is an account with real published keys, which is all this needs.
    group('per-device key material (Phase 1 §4)', () {
      late String sharedIdentity;
      late int deviceOneRegistration;

      setUpAll(() async {
        final deviceOne = await alice.fetchBundleFor(alice.userId, deviceId: 1);
        sharedIdentity = deviceOne['identityPublicKey'] as String;
        deviceOneRegistration = deviceOne['registrationId'] as int;
      });

      test(
        'an upload lands on the SESSION\'s device, whatever the payload claims',
        () async {
          // A client naming someone else's device could scatter key material
          // across namespaces peers later fetch, or park a bundle where the
          // account's real device-1 lookup never sees it (spec §5.1). The
          // SAME-install re-upload (same registrationId — amendment (lxiv))
          // proves the claim is ignored:
          final claimed = await alice.uploadDeviceKeyBundle(
            deviceId: 2,
            identityPublicKey: sharedIdentity,
            registrationId: deviceOneRegistration,
          );
          expect(claimed['success'], isTrue);

          // It went to device 1 — this session's device...
          final one = await alice.fetchBundleFor(alice.userId, deviceId: 1);
          expect(one['registrationId'], deviceOneRegistration);
          expect(
            one['identityPublicKey'],
            sharedIdentity,
            reason: 'the account identity is unchanged, so no lock refusal',
          );

          // ...and device 2 still does not exist.
          final two = await alice.fetchBundleRawFor(alice.userId, deviceId: 2);
          expect(two['bundle'], isNull);

          // Amendment (lxiv) clause 1: the same upload with a DIFFERENT
          // registrationId is by construction a foreign install writing into a
          // namespace it does not own (identity and registrationId are minted
          // together, once) — the revoked-device-signs-back-in shape whose
          // clobber mixes two installs' X3DH halves. Refused, nothing written.
          // Pre-(lxiv) this very upload SUCCEEDED and this test asserted the
          // clobber landing; the contract changed deliberately.
          final foreign = await alice.uploadDeviceKeyBundle(
            deviceId: 2,
            identityPublicKey: sharedIdentity,
            registrationId: deviceOneRegistration + 1,
          );
          expect(foreign['success'], isFalse);
          expect(foreign['error'], 'device_material_conflict');
          final after = await alice.fetchBundleFor(alice.userId, deviceId: 1);
          expect(
            after['registrationId'],
            deviceOneRegistration,
            reason: 'a refused foreign write must leave the row untouched',
          );
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );

      test(
        'one-time pre-keys follow the session device too',
        () async {
          await alice.uploadDeviceOneTimePreKeys(
            deviceId: 2,
            identityPublicKey: sharedIdentity,
            keyIds: const [900, 901],
            publicKeyPrefix: 'claimed-dev2-otp-',
          );

          // Device 2 has no bundle, so nothing is served for it at all.
          final two = await alice.fetchBundleRawFor(alice.userId, deviceId: 2);
          expect(two['bundle'], isNull);

          // The keys landed in device 1's namespace, where this session lives.
          final one = await alice.fetchBundleFor(alice.userId, deviceId: 1);
          expect(one['oneTimePreKeyPublic'], isNotNull);
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );

      test(
        'an unknown device is served nothing, never another device\'s keys',
        () async {
          // Fail-closed: serving device 1's bundle for a device that never
          // uploaded one would build a session no such device can decrypt.
          final missing = await alice.fetchBundleRawFor(
            alice.userId,
            deviceId: 97,
          );

          expect(missing['bundle'], isNull);
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );

      test(
        'a client that names no device still gets device 1 (§8 rollout)',
        () async {
          final legacy = await alice.fetchBundleFor(alice.userId);

          expect(legacy['identityPublicKey'], sharedIdentity);
          expect(legacy['registrationId'], deviceOneRegistration);
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );
    });

    // Phase 2 T2 (spec §3/§5.2 + §12 amendments (d)/(g)): DAK enrollment,
    // the DAK-signed device list, and its falsifications — 2 (IK-signed
    // mutation), 3 (rollback/replay), 23 (byte-exact canonical), 25
    // (cross-construction signatures). Reuses alice (enrolling primary) and
    // bob (verifying peer): the register throttle budget is spent
    // (10/hr/IP across the suite), so NO new accounts here.
    group('DAK-signed device list (Phase 2 T2)', () {
      late IdentityKeyPair aliceIdentity;
      late int enrolledCreatedAt;
      late Map<String, dynamic> enrollPayload;
      late Map<String, dynamic> enrolledAuthorization;

      setUpAll(() async {
        aliceIdentity = IdentityKeyPair.fromSerialized(
          base64Decode(await alice.exportIdentityPair()),
        );
      });

      test('enrollment pins DAK + v1 signed list, serves it byte-exact, and a '
          'peer chain-verifies IK→E→DAK→list (I7, falsification 23)', () async {
        // An unenrolled account answers null — the fail-closed shape a
        // legacy-server probe also relies on (§8).
        final before = await bob.fetchDeviceList(alice.userId);
        expect(before['authorization'], isNull);

        alice.events.discard('deviceListChanged');
        enrolledCreatedAt = DateTime.now().millisecondsSinceEpoch;
        final result = await engine.enroll(
          userId: alice.userId,
          identity: aliceIdentity,
          createdAtMs: enrolledCreatedAt,
          send: (payload) {
            enrollPayload = payload;
            return alice.enrollDeviceAuthority(payload);
          },
        );
        expect(result.accepted, isTrue, reason: 'error=${result.error}');

        // The account's sessions learn about the accepted write (§7 row
        // 424: deviceListChanged).
        final changed = await alice.events.next(
          'deviceListChanged',
          where: (p) => p is Map && p['userId'] == alice.userId,
          reason: 'alice deviceListChanged v1',
        );
        expect((changed as Map)['listVersion'], 1);

        // Served BYTE-EXACT: the stored base64 is the minted base64,
        // character for character (falsification 23 transport rule).
        final own = await alice.fetchDeviceList(alice.userId);
        final auth = (own['authorization'] as Map).cast<String, dynamic>();
        expect(auth['listCanonical'], enrollPayload['listCanonical']);
        expect(auth['listSignature'], enrollPayload['listSignature']);
        expect(auth['dakPub'], enrollPayload['dakPub']);
        expect(auth['enrollmentSig'], enrollPayload['enrollmentSig']);
        expect(
          auth['enrollmentCreatedAt'],
          enrolledCreatedAt,
          reason: 'peers re-verify E over the exact signed createdAt',
        );
        expect(auth['listVersion'], 1);

        // Peer view: bob fetches the list and verifies the FULL chain
        // against his TOFU'd view of alice's identity key (I7).
        final tofu = await bob.fetchBundleFor(alice.userId);
        final answer = await bob.fetchDeviceList(alice.userId);
        enrolledAuthorization = (answer['authorization'] as Map)
            .cast<String, dynamic>();
        expect(
          enrolledAuthorization['listCanonical'],
          enrollPayload['listCanonical'],
          reason: 'listCanonical must survive the wire byte-exact',
        );
        final verdict = DeviceAuthorityEngine.verifyPeerDeviceList(
          authorization: enrolledAuthorization,
          tofuIdentityKeyBase64: tofu['identityPublicKey'] as String,
          expectedUserId: alice.userId,
        );
        expect(verdict.ok, isTrue, reason: 'reason=${verdict.reason}');
        expect(verdict.deviceList!.devices.single.deviceId, 1);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test(
        'one-time pre-keys under an UNPUBLISHED identity are refused on an '
        'ENROLLED account and the published pool survives (§5.1)',
        () async {
          // Observed live 2026-08-18: the lock refused a session's identity and
          // that same session still upserted 20 OTPs over the legitimate
          // device's keyId 0..19 slots. Unservable (the fetch filter pins the
          // published identity) but the victim's pool went empty until a peer
          // fetch re-triggered replenishment.
          //
          // Runs AFTER alice's enrolment: since (lxxiii) clause 1 the OTP site
          // is exempt on an UN-enrolled account (bundle + OTPs are emitted back
          // to back and the keys may land first), so only an enrolled account
          // refuses here.
          final before = await alice.fetchBundleFor(alice.userId, deviceId: 1);
          final publishedIdentity = before['identityPublicKey'] as String;

          await alice.uploadDeviceOneTimePreKeys(
            deviceId: 1,
            identityPublicKey: 'unpublished-identity-$runTag',
            keyIds: const [0, 1],
            publicKeyPrefix: 'foreign-otp-',
            expectRefusal: 'identity_locked',
          );

          // The account still serves a key, and never the refused epoch's.
          final served = await alice.fetchBundleFor(alice.userId, deviceId: 1);
          expect(served['identityPublicKey'], publishedIdentity);
          final otp = served['oneTimePreKeyPublic'] as String?;
          expect(
            otp,
            isNotNull,
            reason: 'the refusal must not have emptied the pool',
          );
          expect(otp, isNot(startsWith('foreign-otp-')));
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );

      test('a second enrollment is refused — first-write-wins, the DAK '
          'authority is born once (I2)', () async {
        final second = DeviceAuthorityEngine();
        final result = await second.enroll(
          userId: alice.userId,
          identity: aliceIdentity,
          send: alice.enrollDeviceAuthority,
        );
        expect(result.accepted, isFalse);
        expect(result.error, 'already_enrolled');

        // Nothing moved: the pinned enrollment is the original one.
        final own = await alice.fetchDeviceList(alice.userId);
        final auth = (own['authorization'] as Map).cast<String, dynamic>();
        expect(auth['dakPub'], enrollPayload['dakPub']);
        expect(auth['listVersion'], 1);
      }, timeout: const Timeout(Duration(minutes: 1)));

      test('a list mutation signed by IK instead of DAK is rejected by the '
          'server and by the peer verifier (falsification 2)', () async {
        final canonical = encodeCanonicalDeviceList(
          DeviceList(
            userId: alice.userId,
            version: 2,
            devices: [
              DeviceListEntry(
                deviceId: 1,
                platform: 'android',
                addedAtMs: enrolledCreatedAt,
              ),
            ],
          ),
        );
        // Signed with the CORRECT list context but the WRONG authority:
        // the account's identity key (what a compromised linked PWA holds).
        final ikSignature = Curve.calculateSignature(
          aliceIdentity.getPrivateKey(),
          buildDeviceListMessage(canonical),
        );
        final answer = await alice.updateDeviceList({
          'listCanonical': base64Encode(canonical),
          'listSignature': base64Encode(ikSignature),
        });
        expect(answer['success'], isFalse);
        expect(answer['error'], 'invalid_list_signature');

        // Client half: the same forgery presented as a getDeviceList
        // answer is refused by the chain verifier.
        final verdict = DeviceAuthorityEngine.verifyPeerDeviceList(
          authorization: {
            ...enrolledAuthorization,
            'listVersion': 2,
            'listCanonical': base64Encode(canonical),
            'listSignature': base64Encode(ikSignature),
          },
          tofuIdentityKeyBase64: base64Encode(
            aliceIdentity.getPublicKey().serialize(),
          ),
          expectedUserId: alice.userId,
        );
        expect(verdict.ok, isFalse);
        expect(verdict.reason, 'invalid_list_signature');

        // The stored list did not move.
        final own = await alice.fetchDeviceList(alice.userId);
        expect((own['authorization'] as Map)['listVersion'], 1);
      }, timeout: const Timeout(Duration(minutes: 1)));

      test('version rollback, replay, and unsigned mutations are refused '
          'loudly; a valid v2 advances (falsification 3)', () async {
        final v2 = DeviceList(
          userId: alice.userId,
          version: 2,
          devices: [
            DeviceListEntry(
              deviceId: 1,
              platform: 'android',
              addedAtMs: enrolledCreatedAt,
              name: 'primary',
            ),
          ],
        );
        alice.events.discard('deviceListChanged');
        final v2Payload = engine.signList(v2);
        final accepted = await alice.updateDeviceList(v2Payload);
        expect(accepted['success'], isTrue, reason: '$accepted');
        expect(accepted['listVersion'], 2);
        final changed = await alice.events.next(
          'deviceListChanged',
          where: (p) => p is Map && p['listVersion'] == 2,
          reason: 'alice deviceListChanged v2',
        );
        expect((changed as Map)['userId'], alice.userId);

        // Replay of the accepted v2 → refused (version <= stored).
        final replayed = await alice.updateDeviceList(v2Payload);
        expect(replayed['success'], isFalse);
        expect(replayed['error'], 'stale_version');

        // Rollback: a FRESH valid signature over version 1 → refused.
        final rollback = await alice.updateDeviceList(
          engine.signList(
            DeviceList(
              userId: alice.userId,
              version: 1,
              devices: [
                DeviceListEntry(
                  deviceId: 1,
                  platform: 'android',
                  addedAtMs: enrolledCreatedAt,
                ),
              ],
            ),
          ),
        );
        expect(rollback['success'], isFalse);
        expect(rollback['error'], 'stale_version');

        // Unsigned/garbage signature at a NEW version → refused.
        final v3 = engine.signList(
          DeviceList(userId: alice.userId, version: 3, devices: v2.devices),
        );
        final unsigned = await alice.updateDeviceList({
          'listCanonical': v3['listCanonical'],
          'listSignature': base64Encode(Uint8List(64)),
        });
        expect(unsigned['success'], isFalse);
        expect(unsigned['error'], 'invalid_list_signature');

        // The stored list is exactly the accepted v2, byte-exact.
        final own = await alice.fetchDeviceList(alice.userId);
        final auth = (own['authorization'] as Map).cast<String, dynamic>();
        expect(auth['listVersion'], 2);
        expect(auth['listCanonical'], v2Payload['listCanonical']);

        // Client half of the rollback flag: a peer that pinned v2 and is
        // then served the old v1 answer raises the LOUD flag (I7).
        final verdict = DeviceAuthorityEngine.verifyPeerDeviceList(
          authorization: enrolledAuthorization,
          tofuIdentityKeyBase64: base64Encode(
            aliceIdentity.getPublicKey().serialize(),
          ),
          expectedUserId: alice.userId,
          previousVersion: 2,
        );
        expect(verdict.ok, isFalse);
        expect(verdict.reason, 'version_rollback');
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('an ambiguous canonical is rejected AT PARSE even when correctly '
          'DAK-signed (falsification 23)', () async {
        // Duplicate-key bytes a canonical writer can never produce, signed
        // with the REAL enrolled DAK so only the parser can refuse them.
        final duplicateKey = Uint8List.fromList(
          utf8.encode(
            '{"userId":${alice.userId},"version":4,"version":4,"devices":'
            '[{"addedAt":1,"deviceId":1,"platform":"android"}]}',
          ),
        );
        // ignore: invalid_use_of_visible_for_testing_member
        final dupSig = engine.debugSignCanonicalBytes(duplicateKey);
        final dup = await alice.updateDeviceList({
          'listCanonical': base64Encode(duplicateKey),
          'listSignature': base64Encode(dupSig),
        });
        expect(dup['success'], isFalse);
        expect(dup['error'], 'invalid_canonical');

        // Whitespace re-serialization of a valid list: same rejection.
        final whitespace = Uint8List.fromList(
          utf8.encode(
            '{"userId":${alice.userId}, "version":4,"devices":'
            '[{"addedAt":1,"deviceId":1,"platform":"android"}]}',
          ),
        );
        // ignore: invalid_use_of_visible_for_testing_member
        final wsSig = engine.debugSignCanonicalBytes(whitespace);
        final ws = await alice.updateDeviceList({
          'listCanonical': base64Encode(whitespace),
          'listSignature': base64Encode(wsSig),
        });
        expect(ws['success'], isFalse);
        expect(ws['error'], 'invalid_canonical');

        // The client parser refuses the identical bytes (shared grammar).
        expect(
          () => parseCanonicalDeviceList(duplicateKey),
          throwsA(isA<CanonicalDeviceListException>()),
        );

        final own = await alice.fetchDeviceList(alice.userId);
        expect((own['authorization'] as Map)['listVersion'], 2);
      }, timeout: const Timeout(Duration(minutes: 1)));

      test('a signature minted for one construction is rejected by every '
          'other construction\'s verifier (falsification 25)', () async {
        // Enrollment signature presented as a list signature.
        final crossList = await alice.updateDeviceList({
          'listCanonical': enrollPayload['listCanonical'],
          'listSignature': enrollPayload['enrollmentSig'],
        });
        expect(crossList['success'], isFalse);
        expect(crossList['error'], 'invalid_list_signature');

        // bob (unenrolled) attempts enrollment whose E-slot carries other
        // constructions' signatures. His engine mints honestly, then the
        // signature is swapped — everything else stays valid.
        final bobIdentity = IdentityKeyPair.fromSerialized(
          base64Decode(await bob.exportIdentityPair()),
        );
        final bobEngine = DeviceAuthorityEngine();
        final bobPayload = bobEngine.mintEnrollment(
          userId: bob.userId,
          identity: bobIdentity,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        );

        // (a) The DAK list signature presented as the enrollment sig.
        final listAsEnroll = await bob.enrollDeviceAuthority({
          ...bobPayload,
          'enrollmentSig': bobPayload['listSignature'],
        });
        expect(listAsEnroll['success'], isFalse);
        expect(listAsEnroll['error'], 'invalid_enrollment_signature');

        // (b) A FROZEN §6.1 registration-lock signature (0x05-leading
        // layout, no context) presented as the enrollment sig — the
        // CVE-2022-39250-class replay amendment (d) exists to kill.
        final ikSerialized = bobIdentity.getPublicKey().serialize();
        final lockMessage = Uint8List.fromList([
          ...ikSerialized,
          ...utf8.encode('${bob.userId}'),
          ...List<int>.generate(32, (i) => i),
        ]);
        final lockSig = Curve.calculateSignature(
          bobIdentity.getPrivateKey(),
          lockMessage,
        );
        final lockAsEnroll = await bob.enrollDeviceAuthority({
          ...bobPayload,
          'enrollmentSig': base64Encode(lockSig),
        });
        expect(lockAsEnroll['success'], isFalse);
        expect(lockAsEnroll['error'], 'invalid_enrollment_signature');

        // The refusals wrote nothing: bob is still unenrolled.
        final bobOwn = await bob.fetchDeviceList(bob.userId);
        expect(bobOwn['authorization'], isNull);
      }, timeout: const Timeout(Duration(minutes: 1)));
    });

    // Phase 2 T3 (spec §5.1 + §12 amendments (a)-(c)/(i)-(iv)): the
    // provisioning ceremony — two-round DH-bound SAS, secrets last,
    // two-phase commit. Falsifications 8 (session-bound one-shot complete),
    // 18 (two-phase kill + abort), 20 (concurrent double-link) and the
    // amendment (a) idempotency extensions. Reuses alice (the T2 group left
    // her ENROLLED and the shared `engine` holds her real DAK) — the
    // register throttle budget is spent, so the "new device" is a second
    // authenticated session of her account (adoptAccountFrom), exactly the
    // §5.1 shape: N is logged in, deviceId pending.
    group('provisioning ceremony (Phase 2 T3 §5.1)', () {
      late IdentityKeyPair aliceIdentity;

      setUpAll(() async {
        aliceIdentity = IdentityKeyPair.fromSerialized(
          base64Decode(await alice.exportIdentityPair()),
        );
      });

      /// Alice's authorization as the server currently serves it.
      Future<Map<String, dynamic>> currentAuth() async {
        final own = await alice.fetchDeviceList(alice.userId);
        return (own['authorization'] as Map).cast<String, dynamic>();
      }

      /// DAK-signs the STORED list plus one new entry for [deviceId]
      /// (platform label, NO name — amendment (i)) at version stored+1.
      Future<Map<String, dynamic>> signAddedDevice(int deviceId) async {
        final auth = await currentAuth();
        final stored = parseCanonicalDeviceList(
          base64Decode(auth['listCanonical'] as String),
        );
        return engine.signList(
          DeviceList(
            userId: alice.userId,
            version: stored.version + 1,
            devices: [
              ...stored.devices,
              DeviceListEntry(
                deviceId: deviceId,
                platform: 'harness',
                addedAtMs: DateTime.now().millisecondsSinceEpoch,
              ),
            ],
          ),
        );
      }

      /// The IK-bearing blob payload the primary seals for the new device.
      LinkBlobPayload blobPayloadFor(int deviceId, Map<String, dynamic> auth) =>
          LinkBlobPayload(
            userId: alice.userId,
            deviceId: deviceId,
            ikPub: base64Encode(aliceIdentity.getPublicKey().serialize()),
            ikPriv: base64Encode(aliceIdentity.getPrivateKey().serialize()),
            dakPub: auth['dakPub'] as String,
            enrollmentCreatedAt: auth['enrollmentCreatedAt'] as int,
            enrollmentSig: auth['enrollmentSig'] as String,
          );

      /// ONE extra device of alice, linked through the real ceremony and shared
      /// by every contract that needs a non-primary own device.
      ///
      /// Deliberately memoized, and the reason is a hard budget: the server
      /// throttles `provisioningComplete` to 10 per 15 minutes keyed by USER
      /// (`WsThrottlerGuard.getTracker`), and every ceremony client here adopts
      /// ALICE's account. This suite already spends exactly that budget on the
      /// refusal contracts above, so one more full ceremony gets no answer at
      /// all — the guard throws instead of emitting, so the 11th caller just
      /// times out. Sharing the device keeps the suite inside the cap.
      E2eClient? sharedDeviceClient;
      int? sharedDeviceId;

      Future<(E2eClient, int)> secondDeviceOfAlice() async {
        final existing = sharedDeviceClient;
        if (existing != null) return (existing, sharedDeviceId!);

        final device = E2eClient('aliceSecondDevice', baseUrl)
          ..adoptAccountFrom(alice);
        await device.connectSocket();

        final ephN = generateLinkEphemeral();
        final opened = await device.openProvisioning();
        final provisioningId = opened['provisioningId'] as String;
        final ephP = generateLinkEphemeral();
        final ack = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: base64Encode(linkEphemeralPublicBytes(ephP)),
        );
        final assignedId = ack['deviceId'] as int;
        final staged = await signAddedDevice(assignedId);
        final auth = await currentAuth();
        final transcript = linkTranscript(
          provisioningId: provisioningId,
          ephPubN: linkEphemeralPublicBytes(ephN),
          ephPubP: linkEphemeralPublicBytes(ephP),
        );
        final sdh = linkSharedSecret(
          theirEphPub: linkEphemeralPublicBytes(ephN),
          ownEphPriv: ephP.privateKey,
        );
        final sealed = sealLinkBlob(
          keys: deriveLinkBlobKeys(sharedSecret: sdh, transcript: transcript),
          payload: blobPayloadFor(assignedId, auth),
        );
        final acked = await alice.provisionDevice({
          'provisioningId': provisioningId,
          'blob': base64Encode(sealed),
          'listCanonical': staged['listCanonical'],
          'listSignature': staged['listSignature'],
        });
        expect(acked['success'], isTrue, reason: '$acked');
        final completed = await device.provisioningComplete(provisioningId);
        expect(completed['success'], isTrue, reason: '$completed');

        // Rebind: only now is this socket authenticated as the new device.
        device.socketService.disconnect();
        device.accessToken = completed['access_token'] as String;
        await device.connectSocket();

        sharedDeviceClient = device;
        sharedDeviceId = assignedId;
        return (device, assignedId);
      }

      tearDownAll(() => sharedDeviceClient?.dispose());

      test('full link: open → OOB code → hello → equal SAS → staged blob+list '
          '→ one-shot session-bound commit → rebind → keys land on the new '
          'device, device 1 untouched (§5.1, falsification 8, amendments '
          '(a)/(b)/(iii))', () async {
        final n = E2eClient('linkN', baseUrl);
        n.adoptAccountFrom(alice);
        await n.connectSocket();
        addTearDown(n.dispose);

        // Device 1's bundle as served BEFORE the ceremony: the primary's key
        // material must be byte-identical after N uploads its own.
        final deviceOneBefore = await bob.fetchBundleFor(
          alice.userId,
          deviceId: 1,
        );

        // N opens. The answer carries NO deviceId — N learns its id from the
        // decrypted blob only (amendment (a)).
        final ephN = generateLinkEphemeral();
        final opened = await n.openProvisioning();
        expect(opened['success'], isTrue, reason: '$opened');
        expect(opened.containsKey('deviceId'), isFalse);
        final provisioningId = opened['provisioningId'] as String;

        // The OOB code round-trips the new device's ephemeral WITHOUT the
        // server (amendment (c)): this string is the only channel it ever
        // travels. The role segment names the DISPLAYING side — here `n`,
        // the default, i.e. the classic v1-shaped ceremony ((lxxvii) cl. 2).
        final code = LinkOobCode(
          provisioningId: provisioningId,
          ephPub: linkEphemeralPublicBytes(ephN),
          platform: 'harness',
        ).encode();
        final scanned = LinkOobCode.tryParse(code);
        expect(scanned, isNotNull);
        expect(scanned!.provisioningId, provisioningId);
        expect(scanned.role, LinkRole.newDevice);

        // Primary hello: the ack is how the primary learns the id it must
        // sign; the relay reaches N's opener socket.
        final ephP = generateLinkEphemeral();
        final ephPubP = base64Encode(linkEphemeralPublicBytes(ephP));
        final ack = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: ephPubP,
        );
        expect(ack['success'], isTrue, reason: '$ack');
        final assignedId = ack['deviceId'] as int;
        expect(assignedId, greaterThanOrEqualTo(2));
        final relayed = await n.events.next(
          'provisioningHello',
          where: (p) => p is Map && p['provisioningId'] == provisioningId,
          reason: 'hello relay to the opener socket',
        );
        expect((relayed as Map)['ephPubP'], ephPubP);

        // Idempotency (amendment (a)): the SAME ephemeral re-acks success
        // with the SAME memoized id; a DIFFERENT one is refused.
        final retried = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: ephPubP,
        );
        expect(retried['success'], isTrue);
        expect(retried['deviceId'], assignedId);
        final rogue = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: base64Encode(
            linkEphemeralPublicBytes(generateLinkEphemeral()),
          ),
        );
        expect(rogue['success'], isFalse);
        expect(rogue['error'], 'ephemeral_already_pinned');

        // Both sides derive the SAS from their OWN DH computation over the
        // pinned transcript — equal, and formatted for humans (§12 (ii)).
        final transcript = linkTranscript(
          provisioningId: provisioningId,
          ephPubN: scanned.ephPub,
          ephPubP: base64Decode(ephPubP),
        );
        final sdhP = linkSharedSecret(
          theirEphPub: scanned.ephPub,
          ownEphPriv: ephP.privateKey,
        );
        final sdhN = linkSharedSecret(
          theirEphPub: base64Decode(relayed['ephPubP'] as String),
          ownEphPriv: ephN.privateKey,
        );
        final sasP = deriveLinkSas(sharedSecret: sdhP, transcript: transcript);
        final sasN = deriveLinkSas(sharedSecret: sdhN, transcript: transcript);
        expect(sasP, sasN, reason: 'both humans must read the same code');
        expect(sasP, matches(RegExp(r'^\d{3} \d{3}$')));

        // Primary approves: blob under the SAS-verified secret + the signed
        // v+1 list adding EXACTLY the assigned id. N receives the blob push.
        final auth = await currentAuth();
        final versionBefore = auth['listVersion'] as int;
        final blob = sealLinkBlob(
          keys: deriveLinkBlobKeys(sharedSecret: sdhP, transcript: transcript),
          payload: blobPayloadFor(assignedId, auth),
        );
        final staged = await signAddedDevice(assignedId);
        final acked = await alice.provisionDevice({
          'provisioningId': provisioningId,
          'blob': base64Encode(blob),
          'listCanonical': staged['listCanonical'],
          'listSignature': staged['listSignature'],
        });
        expect(acked['success'], isTrue, reason: '$acked');
        final pushed = await n.events.next(
          'provisioningBlob',
          where: (p) => p is Map && p['provisioningId'] == provisioningId,
          reason: 'blob push to the opener socket',
        );

        // N opens the blob under ITS OWN derivation: the identity, the DAK
        // pin, and the assigned id arrive intact (secrets-last, I3) — and N
        // can re-verify its own enrollment chain from the blob alone.
        final payload = openLinkBlob(
          keys: deriveLinkBlobKeys(sharedSecret: sdhN, transcript: transcript),
          blob: base64Decode((pushed as Map)['blob'] as String),
        );
        expect(payload.deviceId, assignedId);
        expect(payload.userId, alice.userId);
        expect(
          payload.ikPub,
          base64Encode(aliceIdentity.getPublicKey().serialize()),
        );
        expect(payload.dakPub, auth['dakPub']);
        expect(
          verifyEnrollmentSignature(
            identityPubSerialized: base64Decode(payload.ikPub),
            userId: payload.userId,
            dakPubSerialized: base64Decode(payload.dakPub),
            createdAtMs: payload.enrollmentCreatedAt,
            signature: base64Decode(payload.enrollmentSig),
          ),
          isTrue,
          reason: 'N re-verifies IK→E→DAK from the blob fields',
        );

        // Falsification 8: a complete from ANOTHER session of the same
        // account — authenticated, primary, knows the id — is refused.
        final foreign = await alice.provisioningComplete(provisioningId);
        expect(foreign['success'], isFalse);
        expect(foreign['error'], 'not_opener');

        // One-shot commit on the opener socket. The deviceId-bound token
        // pair travels in the answer (amendments (b)/(iii)).
        alice.events.discard('deviceListChanged');
        final completed = await n.provisioningComplete(provisioningId);
        expect(completed['success'], isTrue, reason: '$completed');
        expect(completed['deviceId'], assignedId);
        final rebindToken = completed['access_token'] as String;
        expect(completed['refresh_token'], isA<String>());
        expect(rebindToken, isNot(alice.accessToken));

        // The stage is retired, not forgotten: a duplicate complete is
        // answered as such, and the blob can NEVER be re-fetched after
        // commit (amendment (a)).
        final duplicate = await n.provisioningComplete(provisioningId);
        expect(duplicate['success'], isFalse);
        expect(duplicate['error'], 'already_completed');
        final refetch = await n.fetchProvisioningBlobAnswer(provisioningId);
        expect(refetch['error'], 'no_blob');

        // Every session of the account learns about the committed mutation,
        // and the list advanced by exactly the staged bytes.
        final changed = await alice.events.next(
          'deviceListChanged',
          where: (p) => p is Map && p['listVersion'] == versionBefore + 1,
          reason: 'commit broadcast',
        );
        expect((changed as Map)['userId'], alice.userId);
        final after = await currentAuth();
        expect(after['listVersion'], versionBefore + 1);
        expect(after['listCanonical'], staged['listCanonical']);

        // Rebind (amendment (b)): N reconnects under the deviceId-bound
        // token and only THEN uploads key material — which lands on ITS
        // device (the session id rules; the payload id is ignored).
        n.socketService.disconnect();
        n.accessToken = rebindToken;
        await n.connectSocket();
        final uploaded = await n.uploadDeviceKeyBundle(
          deviceId: assignedId,
          identityPublicKey: deviceOneBefore['identityPublicKey'] as String,
          registrationId: 7777,
        );
        expect(uploaded['success'], isTrue, reason: '$uploaded');
        await n.uploadDeviceOneTimePreKeys(
          deviceId: assignedId,
          identityPublicKey: deviceOneBefore['identityPublicKey'] as String,
          keyIds: const [0, 1],
          publicKeyPrefix: 'link-n-otp-',
        );
        final deviceN = await bob.fetchBundleFor(
          alice.userId,
          deviceId: assignedId,
        );
        expect(deviceN['registrationId'], 7777);

        // The primary's device-1 bundle is untouched by all of it.
        final deviceOneAfter = await bob.fetchBundleFor(
          alice.userId,
          deviceId: 1,
        );
        expect(
          deviceOneAfter['identityPublicKey'],
          deviceOneBefore['identityPublicKey'],
        );
        expect(
          deviceOneAfter['registrationId'],
          deviceOneBefore['registrationId'],
        );
        expect(
          deviceOneAfter['signedPreKeyPublic'],
          deviceOneBefore['signedPreKeyPublic'],
        );
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('two-phase kill: no complete → nothing committed, blob '
          're-fetchable by the opener ONLY; cancel discards the stage '
          '(falsification 18, §5.1 abort hygiene)', () async {
        final n = E2eClient('linkAbort', baseUrl);
        n.adoptAccountFrom(alice);
        await n.connectSocket();
        addTearDown(n.dispose);

        // An unenrolled account cannot even open (§5.1 needs a pinned DAK).
        final unenrolled = await bob.openProvisioning();
        expect(unenrolled['success'], isFalse);
        expect(unenrolled['error'], 'not_enrolled');

        final ephN = generateLinkEphemeral();
        final opened = await n.openProvisioning();
        expect(opened['success'], isTrue, reason: '$opened');
        final provisioningId = opened['provisioningId'] as String;
        final ephP = generateLinkEphemeral();
        final ephPubP = base64Encode(linkEphemeralPublicBytes(ephP));
        final ack = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: ephPubP,
        );
        expect(ack['success'], isTrue, reason: '$ack');
        final assignedId = ack['deviceId'] as int;

        final transcript = linkTranscript(
          provisioningId: provisioningId,
          ephPubN: linkEphemeralPublicBytes(ephN),
          ephPubP: base64Decode(ephPubP),
        );
        final sdh = linkSharedSecret(
          theirEphPub: linkEphemeralPublicBytes(ephN),
          ownEphPriv: ephP.privateKey,
        );
        final auth = await currentAuth();
        final versionBefore = auth['listVersion'] as int;
        final staged = await signAddedDevice(assignedId);
        final acked = await alice.provisionDevice({
          'provisioningId': provisioningId,
          'blob': base64Encode(
            sealLinkBlob(
              keys: deriveLinkBlobKeys(
                sharedSecret: sdh,
                transcript: transcript,
              ),
              payload: blobPayloadFor(assignedId, auth),
            ),
          ),
          'listCanonical': staged['listCanonical'],
          'listSignature': staged['listSignature'],
        });
        expect(acked['success'], isTrue, reason: '$acked');
        await n.events.next(
          'provisioningBlob',
          where: (p) => p is Map && p['provisioningId'] == provisioningId,
          reason: 'blob push before the kill',
        );

        // The ceremony dies HERE — N never completes. Nothing committed:
        final after = await currentAuth();
        expect(after['listVersion'], versionBefore);
        // The allocated id was never activated; no bundle is served for it.
        final ghost = await bob.fetchBundleRawFor(
          alice.userId,
          deviceId: assignedId,
        );
        expect(ghost['bundle'], isNull);

        // The blob stays re-fetchable until TTL — from the opener ONLY.
        final refetch = await n.fetchProvisioningBlobAnswer(provisioningId);
        expect(refetch['blob'], isA<String>());
        final foreignFetch = await alice.fetchProvisioningBlobAnswer(
          provisioningId,
        );
        expect(foreignFetch['success'], isFalse);
        expect(foreignFetch['error'], 'not_opener');

        // Stage existence never leaks: a bogus id and a FOREIGN ACCOUNT's
        // probe of the real id are answered identically (falsification 8's
        // "knowledge of provisioningId alone drives nothing").
        final bogus = await n.provisioningComplete(
          '00000000-0000-4000-8000-000000000000',
        );
        expect(bogus['error'], 'unknown_stage');
        final crossAccount = await bob.provisioningComplete(provisioningId);
        expect(crossAccount['error'], 'unknown_stage');

        // Cancel — from another authenticated session of the account —
        // discards the stage and tells the opener (I1 abort hygiene).
        n.events.discard('provisioningCancelled');
        final cancelled = await alice.cancelProvisioning(provisioningId);
        expect(cancelled['success'], isTrue, reason: '$cancelled');
        await n.events.next(
          'provisioningCancelled',
          where: (p) => p is Map && p['provisioningId'] == provisioningId,
          reason: 'cancel notice to the opener',
        );
        final gone = await n.fetchProvisioningBlobAnswer(provisioningId);
        expect(gone['error'], 'unknown_stage');
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('(lxxvii) flipped ceremony: the PRIMARY opens, the NEW device says '
          'hello, the relay carries the assigned deviceId, and only the '
          'primary may stage the blob (falsification F4)', () async {
        final n = E2eClient('linkFlipN', baseUrl)..adoptAccountFrom(alice);
        await n.connectSocket();
        addTearDown(n.dispose);

        // Alice — the enrolled primary — holds the ceremony open. Answer
        // shape is unchanged: still no deviceId (amendment (a)).
        alice.events.discard('provisioningHello');
        final ephP = generateLinkEphemeral();
        final opened = await alice.openProvisioning(role: 'primary');
        expect(opened['success'], isTrue, reason: '$opened');
        expect(opened.containsKey('deviceId'), isFalse);
        final provisioningId = opened['provisioningId'] as String;

        // The primary's code carries ITS ephemeral out of band, tagged `p` —
        // the whole point of (lxxvii) clause 2: either side may scan.
        final scanned = LinkOobCode.tryParse(
          LinkOobCode(
            provisioningId: provisioningId,
            ephPub: linkEphemeralPublicBytes(ephP),
            platform: 'harness',
            role: LinkRole.primary,
          ).encode(),
        );
        expect(scanned, isNotNull);
        expect(scanned!.role, LinkRole.primary);

        // The NEW device says hello. Its ack AND the relay to the opener
        // carry the allocated deviceId — with the primary on the opener
        // socket, the relay is the ONLY way it learns the id it must sign.
        final ephN = generateLinkEphemeral();
        final ephPubN = base64Encode(linkEphemeralPublicBytes(ephN));
        final ack = await n.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: ephPubN,
        );
        expect(ack['success'], isTrue, reason: '$ack');
        final assignedId = ack['deviceId'] as int;
        expect(assignedId, greaterThanOrEqualTo(2));
        final relayed = await alice.awaitProvisioningHelloRelay();
        expect(relayed['provisioningId'], provisioningId);
        expect(relayed['ephPubP'], ephPubN);
        expect(
          relayed['deviceId'],
          assignedId,
          reason: 'the primary signs the list for exactly this id',
        );

        // The SAS stays DH-bound to both ephemerals: which socket said hello
        // is not a crypto input, which is what makes the flip safe.
        final transcript = linkTranscript(
          provisioningId: provisioningId,
          ephPubN: base64Decode(relayed['ephPubP'] as String),
          ephPubP: linkEphemeralPublicBytes(ephP),
        );
        final sdhP = linkSharedSecret(
          theirEphPub: base64Decode(relayed['ephPubP'] as String),
          ownEphPriv: ephP.privateKey,
        );
        final sdhN = linkSharedSecret(
          theirEphPub: scanned.ephPub,
          ownEphPriv: ephN.privateKey,
        );
        expect(
          deriveLinkSas(sharedSecret: sdhN, transcript: transcript),
          deriveLinkSas(sharedSecret: sdhP, transcript: transcript),
          reason: 'both humans still read the same code',
        );

        // F4: the new device holds no DAK, so ITS blob is refused — an
        // authenticated session of the account is not a role.
        final auth = await currentAuth();
        final staged = await signAddedDevice(assignedId);
        final blob = base64Encode(
          sealLinkBlob(
            keys: deriveLinkBlobKeys(
              sharedSecret: sdhP,
              transcript: transcript,
            ),
            payload: blobPayloadFor(assignedId, auth),
          ),
        );
        final stagePayload = {
          'provisioningId': provisioningId,
          'blob': blob,
          'listCanonical': staged['listCanonical'],
          'listSignature': staged['listSignature'],
        };
        final refused = await n.provisionDevice(stagePayload);
        expect(refused['success'], isFalse);
        expect(refused['error'], 'not_primary');

        // The primary — the OPENER here — is accepted, and the blob is
        // relayed to the NEW device's socket, never back to the opener.
        n.events.discard('provisioningBlob');
        final acked = await alice.provisionDevice(stagePayload);
        expect(acked['success'], isTrue, reason: '$acked');
        final pushed = await n.events.next(
          'provisioningBlob',
          where: (p) => p is Map && p['provisioningId'] == provisioningId,
          reason: 'blob relay to the new device (F4)',
        );
        expect((pushed as Map)['blob'], blob);

        // Re-fetch binds to the hello side now, and the opener is refused by
        // the SAME v1 `not_opener` code.
        final refetch = await n.fetchProvisioningBlobAnswer(provisioningId);
        expect(refetch['blob'], blob);
        final byPrimary = await alice.fetchProvisioningBlobAnswer(
          provisioningId,
        );
        expect(byPrimary['success'], isFalse);
        expect(byPrimary['error'], 'not_opener');

        // The new device opens the blob under ITS own derivation: the
        // identity really crossed the flipped ceremony.
        final delivered = openLinkBlob(
          keys: deriveLinkBlobKeys(sharedSecret: sdhN, transcript: transcript),
          blob: base64Decode(refetch['blob'] as String),
        );
        expect(delivered.deviceId, assignedId);
        expect(delivered.userId, alice.userId);
        expect(
          delivered.ikPub,
          base64Encode(aliceIdentity.getPublicKey().serialize()),
        );

        // Deliberately NOT completed: `provisioningComplete` is 10 per 15 min
        // per USER and this group already spends that budget (see
        // `secondDeviceOfAlice`). Cancel keeps the stage table clean.
        await alice.cancelProvisioning(provisioningId);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('(lxxvii) an explicit role:new open is still the classic ceremony: '
          'the hello side becomes the primary and the opener keeps the blob '
          'roles', () async {
        final n = E2eClient('linkRoleNew', baseUrl)..adoptAccountFrom(alice);
        await n.connectSocket();
        addTearDown(n.dispose);

        n.events.discard('provisioningHello');
        final opened = await n.openProvisioning(role: 'new');
        expect(opened['success'], isTrue, reason: '$opened');
        expect(opened.containsKey('deviceId'), isFalse);
        final provisioningId = opened['provisioningId'] as String;

        final ephP = generateLinkEphemeral();
        final ephPubP = base64Encode(linkEphemeralPublicBytes(ephP));
        final ack = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: ephPubP,
        );
        expect(ack['success'], isTrue, reason: '$ack');
        final relayed = await n.awaitProvisioningHelloRelay();
        expect(relayed['ephPubP'], ephPubP);
        expect(relayed['deviceId'], ack['deviceId']);

        // The role slots are the v1 ones, and the two DIFFERENT refusals are
        // what prove it without spending a `provisionDevice` slot: the hello
        // side fails the role gate, the opener gets past it to "no blob yet".
        final byPrimary = await alice.fetchProvisioningBlobAnswer(
          provisioningId,
        );
        expect(byPrimary['success'], isFalse);
        expect(byPrimary['error'], 'not_opener');
        final byOpener = await n.fetchProvisioningBlobAnswer(provisioningId);
        expect(byOpener['success'], isFalse);
        expect(
          byOpener['error'],
          'no_blob',
          reason: 'the opener IS the new device under role:new',
        );

        await alice.cancelProvisioning(provisioningId);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('concurrent double-link: two stages race one version slot; the '
          'loser re-signs v+2 against the SAME stage and lands; exactly one '
          'device per ceremony (falsification 20)', () async {
        final n1 = E2eClient('linkRace1', baseUrl)..adoptAccountFrom(alice);
        final n2 = E2eClient('linkRace2', baseUrl)..adoptAccountFrom(alice);
        await n1.connectSocket();
        await n2.connectSocket();
        addTearDown(n1.dispose);
        addTearDown(n2.dispose);

        // Open + hello both ceremonies.
        Future<(String, int, Uint8List, Uint8List)> openAndHello(
          E2eClient n,
        ) async {
          final ephN = generateLinkEphemeral();
          final opened = await n.openProvisioning();
          expect(opened['success'], isTrue, reason: '$opened');
          final provisioningId = opened['provisioningId'] as String;
          final ephP = generateLinkEphemeral();
          final ephPubP = linkEphemeralPublicBytes(ephP);
          final ack = await alice.provisioningHello(
            provisioningId: provisioningId,
            ephPubP: base64Encode(ephPubP),
          );
          expect(ack['success'], isTrue, reason: '$ack');
          final sdh = linkSharedSecret(
            theirEphPub: linkEphemeralPublicBytes(ephN),
            ownEphPriv: ephP.privateKey,
          );
          final transcript = linkTranscript(
            provisioningId: provisioningId,
            ephPubN: linkEphemeralPublicBytes(ephN),
            ephPubP: ephPubP,
          );
          return (provisioningId, ack['deviceId'] as int, sdh, transcript);
        }

        final (idA, deviceA, sdhA, transcriptA) = await openAndHello(n1);
        final (idB, deviceB, sdhB, transcriptB) = await openAndHello(n2);
        expect(deviceA, isNot(deviceB), reason: 'ids never collide');

        // Both staged against the SAME stored version → both sign v+1.
        final auth = await currentAuth();
        final versionBefore = auth['listVersion'] as int;
        Future<Map<String, dynamic>> stage(
          String provisioningId,
          int deviceId,
          Uint8List sdh,
          Uint8List transcript,
        ) async {
          final staged = await signAddedDevice(deviceId);
          final acked = await alice.provisionDevice({
            'provisioningId': provisioningId,
            'blob': base64Encode(
              sealLinkBlob(
                keys: deriveLinkBlobKeys(
                  sharedSecret: sdh,
                  transcript: transcript,
                ),
                payload: blobPayloadFor(deviceId, auth),
              ),
            ),
            'listCanonical': staged['listCanonical'],
            'listSignature': staged['listSignature'],
          });
          expect(acked['success'], isTrue, reason: '$acked');
          return staged;
        }

        await stage(idA, deviceA, sdhA, transcriptA);
        await stage(idB, deviceB, sdhB, transcriptB);

        // First complete wins the version slot.
        final wonA = await n1.provisioningComplete(idA);
        expect(wonA['success'], isTrue, reason: '$wonA');
        expect((await currentAuth())['listVersion'], versionBefore + 1);

        // Second complete LOSES on the version law — stage restored, not
        // burned (amendment (a)).
        final lostB = await n2.provisioningComplete(idB);
        expect(lostB['success'], isFalse);
        expect(lostB['error'], 'stale_version');

        // The primary re-signs v+2 against the SAME stage (a retried
        // provisionDevice overwrites the staged mutation and re-uses the
        // memoized id) and the retried complete lands.
        await stage(idB, deviceB, sdhB, transcriptB);
        final retriedB = await n2.provisioningComplete(idB);
        expect(retriedB['success'], isTrue, reason: '$retriedB');
        expect(retriedB['deviceId'], deviceB);

        // Exactly one device per ceremony: the final list carries BOTH new
        // ids, at exactly two committed versions past the start.
        final after = await currentAuth();
        expect(after['listVersion'], versionBefore + 2);
        final list = parseCanonicalDeviceList(
          base64Decode(after['listCanonical'] as String),
        );
        final ids = list.devices.map((d) => d.deviceId).toSet();
        expect(ids.contains(deviceA), isTrue);
        expect(ids.contains(deviceB), isTrue);
      }, timeout: const Timeout(Duration(minutes: 3)));

      // ---- T4: send fan-out + per-device delivery (§5.2/§5.3) ----
      //
      // These run LAST in the ceremony group on purpose: by now alice is
      // enrolled and has real linked devices in her signed list, which is the
      // substrate a fan-out send needs. Nested here to reuse `currentAuth`.

      test('amendment (x): a LEGACY single-ciphertext send to an enrolled '
          'account is refused with the signed list — never delivered to '
          'device 1 alone (I5)', () async {
        final auth = await currentAuth();
        final tempId = 'legacy-refused-$runTag';
        final ciphertext = await bob.encryptText(alice.userId, 'legacy shape');

        alice.events.discard('newMessage');
        bob.events.discard('deviceListStale');
        bob.socketService.socket!.emit('sendMessage', <String, dynamic>{
          'recipientId': alice.userId,
          'content': '[encrypted]',
          'encryptedContent': ciphertext,
          'tempId': tempId,
        });

        // The refusal carries everything needed to repair in ONE round trip.
        final refusal = await bob.awaitDeviceListStale(tempId);
        expect(refusal['success'], isFalse);
        expect(refusal['error'], 'device_list_stale');
        final lists = (refusal['lists'] as List).cast<Map<dynamic, dynamic>>();
        final aliceEntry = lists.firstWhere((e) => e['userId'] == alice.userId);
        expect(aliceEntry['version'], auth['listVersion']);
        expect(aliceEntry['listCanonical'], auth['listCanonical']);
        expect(aliceEntry['listSignature'], auth['listSignature']);
        final enrollment = aliceEntry['enrollment'] as Map;
        expect(enrollment['dakPub'], auth['dakPub']);
        expect(enrollment['enrollmentSig'], auth['enrollmentSig']);

        // Refused ATOMICALLY: nothing was delivered anywhere.
        await alice.events.none(
          'newMessage',
          within: const Duration(seconds: 2),
          reason: 'a refused legacy send delivers nothing',
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('falsification 5: a send addressed to a STALE list version is '
          'rejected atomically — zero envelopes written, nothing '
          'delivered', () async {
        final auth = await currentAuth();
        final staleVersion = (auth['listVersion'] as int) - 1;
        final tempId = 'stale-version-$runTag';
        final ciphertext = await bob.encryptText(alice.userId, 'stale send');

        alice.events.discard('newMessage');
        bob.events.discard('deviceListStale');
        bob.emitEnvelopeSend(
          alice.userId,
          tempId: tempId,
          envelopes: [
            {'userId': alice.userId, 'deviceId': 1, 'ciphertext': ciphertext},
          ],
          recipientListVersion: staleVersion,
        );

        final refusal = await bob.awaitDeviceListStale(tempId);
        expect(
          (refusal['lists'] as List).cast<Map<dynamic, dynamic>>().firstWhere(
            (e) => e['userId'] == alice.userId,
          )['version'],
          auth['listVersion'],
          reason: 'the CURRENT version is handed back for the retry',
        );
        await alice.events.none(
          'newMessage',
          within: const Duration(seconds: 2),
          reason: 'a stale send is refused before any write',
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('a fan-out send with the CURRENT version is accepted and each '
          'device is addressed exactly once (§5.3 device rooms)', () async {
        final auth = await currentAuth();
        final tempId = 'fanout-ok-$runTag';
        final ciphertext = await bob.encryptText(alice.userId, 'fan-out hello');

        alice.events.discard('newMessage');
        bob.emitEnvelopeSend(
          alice.userId,
          tempId: tempId,
          envelopes: [
            {'userId': alice.userId, 'deviceId': 1, 'ciphertext': ciphertext},
          ],
          sendToken: 'tok-fanout-$runTag',
          recipientListVersion: auth['listVersion'] as int,
        );

        // Device 1's socket receives ITS ciphertext, in its own device room.
        final delivered = await alice.awaitNewMessage(tempId);
        expect(delivered['encryptedContent'], ciphertext);
        expect(delivered['originDeviceId'], 1);
        // A recipient copy never carries the sender's private reconcile key,
        // and never claims there is no envelope for it.
        expect(delivered.containsKey('sendToken'), isFalse);
        expect(delivered['envelopeStatus'], isNull);
        // Exactly once — a duplicate would brick the session on decrypt.
        await alice.events.none(
          'newMessage',
          within: const Duration(seconds: 2),
          reason: 'one envelope per device, delivered once',
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('falsification 13: a linked device reads history and gets the '
          'none_for_device marker for rows that predate its link — never '
          'the foreign-ratchet legacy ciphertext', () async {
        // A fresh device of alice, linked AFTER every message above existed.
        final late = E2eClient('lateDevice', baseUrl)..adoptAccountFrom(alice);
        await late.connectSocket();
        addTearDown(late.dispose);

        final ephN = generateLinkEphemeral();
        final opened = await late.openProvisioning();
        final provisioningId = opened['provisioningId'] as String;
        final ephP = generateLinkEphemeral();
        final ack = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: base64Encode(linkEphemeralPublicBytes(ephP)),
        );
        final assignedId = ack['deviceId'] as int;
        final staged = await signAddedDevice(assignedId);
        final auth = await currentAuth();
        final transcript = linkTranscript(
          provisioningId: provisioningId,
          ephPubN: linkEphemeralPublicBytes(ephN),
          ephPubP: linkEphemeralPublicBytes(ephP),
        );
        final sdh = linkSharedSecret(
          theirEphPub: linkEphemeralPublicBytes(ephN),
          ownEphPriv: ephP.privateKey,
        );
        final sealed = sealLinkBlob(
          keys: deriveLinkBlobKeys(sharedSecret: sdh, transcript: transcript),
          payload: blobPayloadFor(assignedId, auth),
        );
        final acked = await alice.provisionDevice({
          'provisioningId': provisioningId,
          'blob': base64Encode(sealed),
          'listCanonical': staged['listCanonical'],
          'listSignature': staged['listSignature'],
        });
        expect(acked['success'], isTrue, reason: '$acked');
        final completed = await late.provisioningComplete(provisioningId);
        expect(completed['success'], isTrue, reason: '$completed');

        // Rebind: only now is this socket authenticated as the new device.
        late.socketService.disconnect();
        late.accessToken = completed['access_token'] as String;
        await late.connectSocket();

        late.events.discard('messageHistory');
        late.socketService.socket!.emit('getMessages', {
          'conversationId': conversationId,
        });
        final history =
            await late.events.next(
                  'messageHistory',
                  where: (p) =>
                      p is Map && p['conversationId'] == conversationId,
                  reason: 'late device history',
                )
                as Map;
        final rows = (history['messages'] as List).cast<Map<dynamic, dynamic>>();
        expect(rows, isNotEmpty, reason: 'the conversation has history');

        // Every E2E row predates this device's link, so every one of them is
        // marked — and NONE of them carries a ciphertext this device would
        // fail to decrypt across the whole pre-link history.
        final e2eRows = rows.where((r) => r['content'] == '[encrypted]');
        expect(e2eRows, isNotEmpty);
        for (final row in e2eRows) {
          expect(
            row['envelopeStatus'],
            'none_for_device',
            reason: 'row ${row['id']} predates this device',
          );
          expect(
            row['encryptedContent'],
            isNull,
            reason:
                'serving device 1 ciphertext here is the foreign-ratchet '
                'decrypt the §5.3 gate exists to prevent',
          );
        }
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('falsification 6: a send fans a SELF-SYNC envelope to the sender\'s '
          'own other device — its own ciphertext, no sendToken, no marker, and '
          'the origin device is never sent its own copy', () async {
        // A second device of ALICE, linked through the real ceremony. Alice is
        // the enrolled account here (the harness holds her DAK), so she is the
        // sender for this contract. Shared with falsification 24 because the
        // ceremony's completion budget is capped per user — see
        // [secondDeviceOfAlice].
        final (aliceDevice2, assignedId) = await secondDeviceOfAlice();

        // Alice's device 1 sends to bob AND to her own device 2. One ciphertext
        // per address: sharing one would brick the second decrypt, because
        // Signal consumes the message key. The self ciphertext is a synthetic
        // marker — this contract is about ROUTING (which device is handed
        // which bytes, and what metadata rides along), and the server treats
        // every ciphertext as opaque.
        final tempId = 'selfsync-$runTag';
        final forBob = await alice.encryptText(bob.userId, 'self-sync hello');
        final forOwnDevice = '3:selfsync-own-$runTag';
        final senderAuth = await currentAuth();

        bob.events.discard('newMessage');
        aliceDevice2.events.discard('newMessage');
        alice.events.discard('newMessage');
        alice.emitEnvelopeSend(
          bob.userId,
          tempId: tempId,
          envelopes: [
            {'userId': bob.userId, 'deviceId': 1, 'ciphertext': forBob},
            {
              'userId': alice.userId,
              'deviceId': assignedId,
              'ciphertext': forOwnDevice,
            },
          ],
          sendToken: 'tok-selfsync-$runTag',
          senderListVersion: senderAuth['listVersion'] as int,
        );

        // The sender's own OTHER device receives a real, device-addressed
        // ciphertext — this is the copy the receive-side law decrypts.
        final selfCopy = await aliceDevice2.awaitNewMessage(tempId);
        expect(selfCopy['encryptedContent'], forOwnDevice);
        expect(selfCopy['senderId'], alice.userId);
        expect(selfCopy['originDeviceId'], 1);
        expect(
          selfCopy.containsKey('sendToken'),
          isFalse,
          reason:
              'the reconcile key reaches ONLY the origin device — a device '
              'holding it could consume another device\'s pending record',
        );
        expect(
          selfCopy['envelopeStatus'],
          isNull,
          reason:
              'a self-sync row HAS an envelope; own_origin would tell this '
              'device to reconcile instead of decrypt',
        );
        // The recipient still gets exactly its own ciphertext.
        final peerCopy = await bob.awaitNewMessage(tempId);
        expect(peerCopy['encryptedContent'], forBob);
        // And the origin device is never handed its own copy: it could not
        // decrypt it, and trying would burn its only plaintext.
        await alice.events.none(
          'newMessage',
          within: const Duration(seconds: 2),
          reason: 'the origin device is excluded from its own fan-out',
        );
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('falsification 14: reusing a sendToken re-acks the SAME row and '
          'delivers nothing twice (spec §5.4 + amendment (ix))', () async {
        // Envelope-shaped, because amendment (x) refuses a legacy ciphertext
        // send whenever either party is enrolled — and alice is.
        final senderAuth = await currentAuth();
        final token = 'tok-lostack-$runTag';
        final ciphertext = await alice.encryptText(bob.userId, 'ack me once');

        Future<Map<String, dynamic>> sendWithSameToken(String tempId) async {
          alice.events.discard('messageSent');
          bob.events.discard('newMessage');
          alice.emitEnvelopeSend(
            bob.userId,
            tempId: tempId,
            envelopes: [
              {'userId': bob.userId, 'deviceId': 1, 'ciphertext': ciphertext},
            ],
            sendToken: token,
            senderListVersion: senderAuth['listVersion'] as int,
          );
          final ack =
              await alice.events.next(
                    'messageSent',
                    where: (p) => p is Map && p['tempId'] == tempId,
                    reason: 'ack for $tempId token=$token',
                  )
                  as Map;
          return ack.cast<String, dynamic>();
        }

        final first = await sendWithSameToken('lostack-a-$runTag');
        final rowId = first['id'] as int;
        expect(
          first['sendToken'],
          token,
          reason:
              'the token is echoed to its origin device — that echo IS the '
              'reconcile key for a row whose own copy carries no ciphertext',
        );
        expect(
          first['envelopeStatus'],
          'own_origin',
          reason: 'the origin device has no envelope of its own by design',
        );
        await bob.awaitNewMessage('lostack-a-$runTag');

        // The ack died on the way back, so the client retries with the SAME
        // token. The server must re-ack the committed row rather than commit a
        // second one: a duplicate row would be a second ciphertext for one
        // logical message, and Signal decrypt is not idempotent.
        final second = await sendWithSameToken('lostack-b-$runTag');
        expect(
          second['id'],
          rowId,
          reason: 'the same token must resolve to EXACTLY ONE row',
        );
        await bob.events.none(
          'newMessage',
          within: const Duration(seconds: 2),
          reason: 're-ack without re-fan: the recipient already has this row',
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('falsification 7 + §5.5: revoking a device kicks it, refuses its '
          'reconnect and its uploads, and no later message is addressed to '
          'it — while every other device keeps working', () async {
        // A real second device of ALICE through the real ceremony (the harness
        // holds her DAK, so she is the only account that can sign a mutation).
        final doomed = E2eClient('revokeTarget', baseUrl)
          ..adoptAccountFrom(alice);
        await doomed.connectSocket();
        addTearDown(doomed.dispose);

        final ephN = generateLinkEphemeral();
        final opened = await doomed.openProvisioning();
        final provisioningId = opened['provisioningId'] as String;
        final ephP = generateLinkEphemeral();
        final ack = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: base64Encode(linkEphemeralPublicBytes(ephP)),
        );
        final doomedId = ack['deviceId'] as int;
        final staged = await signAddedDevice(doomedId);
        final auth = await currentAuth();
        final transcript = linkTranscript(
          provisioningId: provisioningId,
          ephPubN: linkEphemeralPublicBytes(ephN),
          ephPubP: linkEphemeralPublicBytes(ephP),
        );
        final sdh = linkSharedSecret(
          theirEphPub: linkEphemeralPublicBytes(ephN),
          ownEphPriv: ephP.privateKey,
        );
        final acked = await alice.provisionDevice({
          'provisioningId': provisioningId,
          'blob': base64Encode(
            sealLinkBlob(
              keys: deriveLinkBlobKeys(
                sharedSecret: sdh,
                transcript: transcript,
              ),
              payload: blobPayloadFor(doomedId, auth),
            ),
          ),
          'listCanonical': staged['listCanonical'],
          'listSignature': staged['listSignature'],
        });
        expect(acked['success'], isTrue, reason: '$acked');
        final completed = await doomed.provisioningComplete(provisioningId);
        expect(completed['success'], isTrue, reason: '$completed');
        doomed.socketService.disconnect();
        doomed.accessToken = completed['access_token'] as String;
        await doomed.connectSocket();

        // It is a fully working device first: key material of its own, so a
        // fan-out to it is possible right up to the revocation.
        final deviceOne = await bob.fetchBundleFor(alice.userId, deviceId: 1);
        final identityKey = deviceOne['identityPublicKey'] as String;
        final live = await doomed.uploadDeviceKeyBundle(
          deviceId: doomedId,
          identityPublicKey: identityKey,
          registrationId: 8811,
        );
        expect(live['success'], isTrue, reason: '$live');

        // ---- the revocation itself ----
        final beforeAuth = await currentAuth();
        final beforeList = parseCanonicalDeviceList(
          base64Decode(beforeAuth['listCanonical'] as String),
        );
        final versionBefore = beforeAuth['listVersion'] as int;
        final revokingList = engine.signList(
          DeviceList(
            userId: alice.userId,
            version: versionBefore + 1,
            devices: [
              for (final d in beforeList.devices)
                if (d.deviceId == doomedId)
                  DeviceListEntry(
                    deviceId: d.deviceId,
                    platform: d.platform,
                    addedAtMs: d.addedAtMs,
                    name: d.name,
                    revokedAtMs: DateTime.now().millisecondsSinceEpoch,
                  )
                else
                  d,
            ],
          ),
        );

        // The caller here IS device 1, so asking to revoke device 1 is a
        // self-revoke — refused before anything else is even looked at
        // (amendment (xxi)). It is also the primary, and the primary is the
        // only DAK holder: revoking it would leave the account unable to sign
        // any future list version, with the §6.2 reset as the only way back.
        final selfRevoke = await alice.revokeDevice({
          'deviceId': 1,
          'listCanonical': revokingList['listCanonical'],
          'listSignature': revokingList['listSignature'],
        });
        expect(selfRevoke['success'], isFalse);
        expect(selfRevoke['error'], 'cannot_revoke_self', reason: '$selfRevoke');

        // `list_device_mismatch`, the other half of (xxi): the request and the
        // signed bytes must agree, or the teardown would cut off a device the
        // account's own signed list still calls LIVE — and peers follow the
        // list, so they would keep addressing envelopes to it.
        //
        // The payload is the account's CURRENT stored list, which is genuinely
        // DAK-signed and still shows `doomed` live. That is the point: an
        // honest signature over the wrong SET is exactly the case the rung
        // exists for, and it proves the refusal is not merely a signature
        // check wearing a different name.
        //
        // This reaches the rung with ONE live non-primary device, not two: the
        // second device the older note asked for is the PRIMARY CALLER, which
        // every enrolled account already has. It must run BEFORE the real
        // revocation below — afterwards `doomed` is revoked and `already_revoked`
        // (an earlier rung) would answer instead.
        final mismatch = await alice.revokeDevice({
          'deviceId': doomedId,
          'listCanonical': beforeAuth['listCanonical'],
          'listSignature': beforeAuth['listSignature'],
        });
        expect(mismatch['success'], isFalse);
        expect(
          mismatch['error'],
          'list_device_mismatch',
          reason: '$mismatch',
        );
        // Refused PRE-WRITE: the stored list did not move, and the very next
        // block revokes this same device successfully — so a refusal that had
        // leaked a partial teardown would break the proof that follows it.
        expect(
          (await currentAuth())['listCanonical'],
          beforeAuth['listCanonical'],
        );

        alice.events.discard('deviceListChanged');
        doomed.events.discard('deviceRevoked');
        final result = await alice.revokeDevice({
          'deviceId': doomedId,
          'listCanonical': revokingList['listCanonical'],
          'listSignature': revokingList['listSignature'],
        });
        expect(result['success'], isTrue, reason: '$result');
        expect(result['listVersion'], versionBefore + 1);

        // The kicked device is TOLD (amendment (xxvi)) and the account learns
        // the list moved.
        final notice = await doomed.events.next(
          'deviceRevoked',
          where: (p) => p is Map && p['deviceId'] == doomedId,
          reason: 'the revoked device must learn WHY its session ended',
        );
        expect((notice as Map)['userId'], alice.userId);
        final changed = await alice.events.next(
          'deviceListChanged',
          where: (p) => p is Map && p['listVersion'] == versionBefore + 1,
          reason: 'revocation broadcast',
        );
        expect((changed as Map)['userId'], alice.userId);

        // The stored list is byte-exactly what the primary signed.
        final afterAuth = await currentAuth();
        expect(afterAuth['listCanonical'], revokingList['listCanonical']);

        // A duplicate revocation is refused, not re-run.
        final again = await alice.revokeDevice({
          'deviceId': doomedId,
          'listCanonical': revokingList['listCanonical'],
          'listSignature': revokingList['listSignature'],
        });
        expect(again['success'], isFalse);
        expect(again['error'], anyOf('already_revoked', 'stale_version'));

        // ---- the session is gone, and stays gone ----
        // The still-valid access JWT buys nothing: the connect gate refuses it
        // and says why (amendments (xxii)/(xxvi)).
        doomed.socketService.disconnect();
        final refused = await doomed.connectExpectingRevoked();
        expect(refused['deviceId'], doomedId);

        // ---- falsification 7: no envelope for a revoked device ----
        // Addressing it is refused outright: the fan-out gate reads the same
        // `devices` row the revocation just stamped.
        alice.events.discard('error');
        alice.emitEnvelopeSend(
          bob.userId,
          tempId: 'revoked-target-$runTag',
          envelopes: [
            {
              'userId': bob.userId,
              'deviceId': 1,
              'ciphertext': await alice.encryptText(bob.userId, 'to bob'),
            },
            {
              'userId': alice.userId,
              'deviceId': doomedId,
              'ciphertext': '3:for-a-revoked-device-$runTag',
            },
          ],
          sendToken: 'tok-revoked-target-$runTag',
          senderListVersion: versionBefore + 1,
        );
        // Drained off `errors` so the end-of-run "no unexpected errors" check
        // stays meaningful (deliberate refusals must be claimed).
        await alice.events.takeError(
          'unknown_recipient_device',
          reason: 'a revoked device may not be addressed',
        );
        await bob.events.none(
          'newMessage',
          within: const Duration(seconds: 2),
          where: (p) => p is Map && p['tempId'] == 'revoked-target-$runTag',
          reason: 'the refusal is atomic — no row, no envelope for anyone',
        );

        // And a send that simply omits it SUCCEEDS — revoking one device must
        // never break the account's messaging.
        final tempId = 'after-revoke-$runTag';
        bob.events.discard('newMessage');
        alice.emitEnvelopeSend(
          bob.userId,
          tempId: tempId,
          envelopes: [
            {
              'userId': bob.userId,
              'deviceId': 1,
              'ciphertext': await alice.encryptText(
                bob.userId,
                'still working',
              ),
            },
          ],
          sendToken: 'tok-after-revoke-$runTag',
          senderListVersion: versionBefore + 1,
        );
        final delivered = await bob.awaitNewMessage(tempId);
        expect(delivered['senderId'], alice.userId);

        // ---- its key material is gone, and it cannot publish more ----
        // T3's `device_not_active` upload rejection: wire-unreachable until
        // revocation existed, reachable now. The upload rides a session the
        // gate refuses, so this asserts the durable teardown instead: the
        // revoked device's bundle no longer exists to serve.
        final gone = await bob.fetchBundleRawFor(
          alice.userId,
          deviceId: doomedId,
        );
        expect(
          gone['success'] == false || gone['registrationId'] == null,
          isTrue,
          reason:
              'the revoked device\'s key bundle was purged with it: $gone',
        );
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('falsification 24: an edit from a NON-ORIGIN own device re-fans every '
          'current device, INSERTS a row for one that had none, re-points '
          'originDeviceId at the editor, preserves the delivery projection and '
          'mints no sendToken (spec §5.7 + amendments (xxx)-(xxxiv))', () async {
        // The EDITING device: a real, non-primary device of alice, linked through
        // the ceremony and shared with falsification 6 (the ceremony's
        // completion budget is capped per user — see [secondDeviceOfAlice]).
        final (editor, editorDeviceId) = await secondDeviceOfAlice();

        // 1. Alice's device 1 sends. Note what it does NOT address: its own
        //    device 1 (it is the origin) — so device 1 has NO envelope for this
        //    row, which is exactly the placeholder case the edit must INSERT.
        final tempId = 'editrefan-$runTag';
        final forBob = await alice.encryptText(bob.userId, 'before the edit');
        final senderAuth = await currentAuth();
        bob.events.discard('newMessage');
        alice.emitEnvelopeSend(
          bob.userId,
          tempId: tempId,
          envelopes: [
            {'userId': bob.userId, 'deviceId': 1, 'ciphertext': forBob},
            {
              'userId': alice.userId,
              'deviceId': editorDeviceId,
              'ciphertext': '3:editrefan-self-$runTag',
            },
          ],
          sendToken: 'tok-editrefan-$runTag',
          senderListVersion: senderAuth['listVersion'] as int,
        );
        final delivered = await bob.awaitNewMessage(tempId);
        final messageId = delivered['id'] as int;

        // 2. Bob DELIVERS and READS it, which stamps his envelope and drives the
        //    row-level projection to READ. This is the state an edit must not
        //    destroy: an edit is not an un-delivery (durability finding F8).
        alice.events.discard('messageDelivered');
        bob.socketService.socket!.emit('messageDelivered', {
          'messageId': messageId,
        });
        await alice.events.next(
          'messageDelivered',
          where: (p) => p is Map && p['messageId'] == messageId,
          reason: 'delivery projection before the edit',
        );
        // The read projection rides the SAME `messageDelivered` event with a
        // READ status — there is no separate read event.
        alice.events.discard('messageDelivered');
        bob.socketService.socket!.emit('markConversationRead', {
          'conversationId': conversationId,
        });
        await alice.events.next(
          'messageDelivered',
          where: (p) =>
              p is Map &&
              p['messageId'] == messageId &&
              p['deliveryStatus'] == 'READ',
          reason: 'read projection before the edit',
        );

        // 3. The EDIT, issued from alice's device 2 — a device that did NOT send
        //    the row. Its ciphertexts are bound to ITS ratchet, so the server
        //    must re-point originDeviceId at it or every receiver would decrypt
        //    against device 1 and fail with a Bad-MAC (amendment (xxx)).
        // Synthetic ciphertexts, for the same reason falsification 6 uses them:
        // this contract is about ROUTING, ATTRIBUTION and STAMP PRESERVATION —
        // which device is handed which bytes, who the server says produced
        // them, and what survives the UPSERT. The server treats every
        // ciphertext as opaque, and the editing device holds no Signal state of
        // its own here (it adopted the account, it did not install keys).
        final editedForBob = '3:editrefan-bob-$runTag';
        final editedForOwnDevice1 = '3:editrefan-upgrade-$runTag';
        final editorAuth = await currentAuth();
        bob.events.discard('messageEdited');
        alice.events.discard('messageEdited');
        editor.events.discard('messageEdited');
        editor.emitEnvelopeEdit(
          messageId,
          envelopes: [
            {'userId': bob.userId, 'deviceId': 1, 'ciphertext': editedForBob},
            {
              'userId': alice.userId,
              'deviceId': 1,
              'ciphertext': editedForOwnDevice1,
            },
          ],
          recipientListVersion: null,
          senderListVersion: editorAuth['listVersion'] as int,
        );

        // The peer's device gets its OWN edited ciphertext, attributed to the
        // device that produced it.
        final peerEdit = await bob.awaitMessageEdited(messageId);
        expect(peerEdit['encryptedContent'], editedForBob);
        expect(
          peerEdit['originDeviceId'],
          editorDeviceId,
          reason:
              'the receiver keys its Signal session off this field, so an edit '
              'from a non-origin device MUST re-point it',
        );
        expect(
          peerEdit.containsKey('sendToken'),
          isFalse,
          reason: 'an edit never mints or consumes a sendToken (§5.4)',
        );

        // The sender's device 1 had NO envelope for this row (it was the origin
        // of the send). The edit INSERTS one: the placeholder upgrades, and the
        // upgrade is one-way.
        final upgraded = await alice.awaitMessageEdited(messageId);
        expect(
          upgraded['encryptedContent'],
          editedForOwnDevice1,
          reason:
              'a device with no prior envelope is addressed by the re-fan and '
              'upgrades its none_for_device placeholder',
        );

        // The EDITING device produced every ciphertext, so it holds the
        // plaintext and is handed none of them back.
        final echo = await editor.awaitMessageEdited(messageId);
        expect(echo['encryptedContent'], isNull);
        expect(echo['editedAt'], isNotNull);

        // 4. THE F8 ASSERTION. Re-read history as bob: his envelope was
        //    delivered AND read before the edit, and a content-only UPSERT must
        //    leave both stamps intact — so the row-level projection may not
        //    regress from READ. A full-row replace would zero them here.
        bob.events.discard('messageHistory');
        bob.socketService.socket!.emit('getMessages', {
          'conversationId': conversationId,
        });
        final history =
            await bob.events.next(
                  'messageHistory',
                  where: (p) =>
                      p is Map && p['conversationId'] == conversationId,
                  reason: 'bob re-reads history after the edit',
                )
                as Map;
        final row = (history['messages'] as List)
            .cast<Map<dynamic, dynamic>>()
            .firstWhere((m) => m['id'] == messageId);
        expect(
          row['encryptedContent'],
          editedForBob,
          reason:
              'the edit must be DURABLE: before T7 it lived only in the socket '
              'emit while the envelope kept the ORIGINAL ciphertext',
        );
        expect(
          row['deliveryStatus'],
          'READ',
          reason:
              'an edit is not an un-delivery — the §4 ROW projection never '
              'regresses on edit',
        );
        expect(row['editedAt'], isNotNull);
        // NOTE ON WHAT THIS DOES *NOT* PROVE. `deliveryStatus` is a
        // messages-ROW column, maintained by `updateDeliveryStatus`
        // independently of the per-device envelope stamps that
        // `stampEnvelope` writes — and `applyEdit` touches neither. So this
        // assertion would still pass if the UPSERT zeroed
        // `deliveredAt`/`readAt`. The wire has no read path for those columns,
        // so the content-only conflict clause is pinned by
        // `messages.service.spec.ts` ('UPSERTs the named envelopes
        // CONTENT-ONLY') and by a direct SQL check recorded in the T7 session
        // summary. Do not upgrade this comment into a claim.
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('a REAL self-sync envelope DECRYPTS on the sender\'s own second '
          'device — same account identity, its own per-device key material '
          '(spec §12 (xxxv), the decryptability half falsification 6 leaves '
          'open)', () async {
        // Falsification 6 proves ROUTING with a synthetic ciphertext, because
        // the server treats ciphertext as opaque. This proves the other half:
        // that the bytes routed there are bytes that device can actually open.
        final (device2, deviceTwoId) = await secondDeviceOfAlice();

        // ---- keystore isolation, and why it is needed ----
        // Both clients are the SAME account, and `EncryptionService` derives
        // every Signal storage key from `e2e_<userId>_`. The mock secure
        // storage is one process-wide map, so device 2 keying itself would
        // overwrite device 1's signed pre-key and OTPs — and `adopt` refuses
        // outright while device 1's identity record is present. So the two
        // keystores are separated in TIME: each device acts with its own map
        // installed, and the live map is re-snapshotted at every swap so no
        // side loses ratchet progress made since the last one.
        const storage = FlutterSecureStorage();
        final alicePrefix = 'e2e_${alice.userId}_';
        Future<Map<String, String>> snapshot() async =>
            Map<String, String>.from(await storage.readAll());
        void install(Map<String, String> world) {
          // ignore: invalid_use_of_visible_for_testing_member
          FlutterSecureStorage.setMockInitialValues(
            Map<String, String>.from(world),
          );
        }

        var deviceOneWorld = await snapshot();
        // Device 2 starts from the same world MINUS alice's own key material:
        // bob's rows stay so nothing else in the run is disturbed.
        var deviceTwoWorld = Map<String, String>.from(deviceOneWorld)
          ..removeWhere((key, _) => key.startsWith(alicePrefix));
        addTearDown(() => install(deviceOneWorld));

        // ---- device 2 becomes a real installation ----
        install(deviceTwoWorld);
        final auth = await currentAuth();
        // The production path a linked device takes: it ADOPTS the account's
        // shared identity key (§5.1 ships `ikPriv` in the sealed blob for
        // exactly this) and mints its OWN signed pre-key and one-time pre-keys.
        await device2.encryption.adoptProvisionedIdentity(
          userId: alice.userId,
          ikPubBase64: base64Encode(aliceIdentity.getPublicKey().serialize()),
          ikPrivBase64: base64Encode(aliceIdentity.getPrivateKey().serialize()),
          dakPubBase64: auth['dakPub'] as String,
        );
        final deviceTwoKeys = device2.encryption.getKeysForUpload();
        expect(
          deviceTwoKeys,
          isNotNull,
          reason: 'adopting must stage this device\'s own upload payload',
        );
        // Real material this time, not the opaque `dev<N>-spk-public`
        // placeholders the other tests use: `processPreKeyBundle` verifies the
        // signed pre-key signature, so a placeholder cannot build a session.
        // The socket rebound to deviceId=N at the end of the ceremony and the
        // server takes the device from the JWT, so these land on (alice, N).
        await device2.uploadKeyBundle(deviceTwoKeys!);
        await device2.uploadOneTimePreKeys(deviceTwoKeys, tagIdentityEpoch: true);
        deviceTwoWorld = await snapshot();

        // ---- device 1 sends a REAL self ciphertext ----
        install(deviceOneWorld);
        final bundle = await alice.fetchBundleFor(
          alice.userId,
          deviceId: deviceTwoId,
        );
        expect(
          bundle['registrationId'],
          deviceTwoKeys['keyBundle']['registrationId'],
          reason: 'the served bundle must be the one device 2 just published',
        );
        await alice.encryption.buildSession(
          alice.userId,
          bundle,
          deviceId: deviceTwoId,
         expectedIdentityBase64: null,);
        const plaintext = 'self-sync that really decrypts';
        final selfCiphertext = await alice.encryption.encrypt(
          alice.userId,
          jsonEncode(E2eEnvelope.build(plaintext)),
          deviceId: deviceTwoId,
        );
        expect(
          wireType(selfCiphertext),
          3,
          reason: 'a first message to a new device address is a PreKey message',
        );

        final tempId = 'selfdecrypt-$runTag';
        final forBob = await alice.encryptText(bob.userId, plaintext);
        final senderAuth = await currentAuth();
        // EventLog matches the first buffered payload satisfying its predicate,
        // and falsification 6 left a SYNTHETIC self copy in this device's
        // buffer. Without the discard this could "decrypt" those bytes instead.
        device2.events.discard('newMessage');
        bob.events.discard('newMessage');
        alice.emitEnvelopeSend(
          bob.userId,
          tempId: tempId,
          envelopes: [
            {'userId': bob.userId, 'deviceId': 1, 'ciphertext': forBob},
            {
              'userId': alice.userId,
              'deviceId': deviceTwoId,
              'ciphertext': selfCiphertext,
            },
          ],
          sendToken: 'tok-selfdecrypt-$runTag',
          senderListVersion: senderAuth['listVersion'] as int,
        );
        final selfCopy = await device2.awaitNewMessage(tempId);
        expect(selfCopy['encryptedContent'], selfCiphertext);
        expect(selfCopy['originDeviceId'], 1);
        deviceOneWorld = await snapshot();

        // ---- device 2 opens it ----
        install(deviceTwoWorld);
        // Decrypted as ORDINARY INBOUND against the ORIGIN device's session
        // (§12 (xi)/(xii)) — device 1 produced these bytes, so device 1 is the
        // address. Signal decrypt is not idempotent: exactly one attempt.
        final decrypted = await device2.encryption.decrypt(
          alice.userId,
          selfCopy['encryptedContent'] as String,
          deviceId: 1,
        );
        expect(E2eEnvelope.parse(decrypted).content, plaintext);

        // THE ANTI-VACUITY ASSERTION (§12 (xxxv)), and it is not decoration.
        // A Signal session decrypts whether or not the two parties' identity
        // keys are equal — libsignal_protocol_dart carries no self_session
        // concept and X3DH has no identity-key-equality branch. So everything
        // above would pass just as well for an unrelated account borrowing a
        // device id, which would prove nothing about SELF-sync. This is what
        // makes the device that decrypted genuinely alice's second device.
        expect(
          await device2.exportIdentityPair(),
          base64Encode(aliceIdentity.serialize()),
          reason:
              'device 2 must hold the ACCOUNT identity — otherwise this is an '
              'ordinary two-party decrypt wearing a self-sync label',
        );
        deviceTwoWorld = await snapshot();
        install(deviceOneWorld);
      }, timeout: const Timeout(Duration(minutes: 4)));

    });

    test('no unexpected socket errors surfaced during the run', () {
      expect(
        alice.events.errors,
        isEmpty,
        reason: 'alice received server error events',
      );
      expect(
        bob.events.errors,
        isEmpty,
        reason: 'bob received server error events',
      );
    });
  });
}
