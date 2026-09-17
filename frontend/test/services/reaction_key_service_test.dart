import 'dart:async';
import 'dart:convert';

import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/reactions/reaction_key_lookup.dart';
import 'package:fireplace/services/reactions/reaction_key_service.dart';
import 'package:fireplace/services/reactions/reaction_token_codec.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every failure path here is a decision about whether to RE-KEY, and a re-key
/// advances the server-assigned epoch, which permanently orphans every chip
/// written under the old one — for both participants' other devices. So the
/// tests that matter are the ones proving the service does NOT create a key.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const uid = 5;
  const conversationId = 11;
  const peerUserId = 6;
  final key = base64Encode(List<int>.generate(32, (i) => i + 1));

  late List<String> events;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    events = <String>[];
  });

  Future<EncryptionService> boot() async {
    final svc = EncryptionService();
    await svc.initialize(
      uid,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    return svc;
  }

  ReactionKeyService build(
    EncryptionService store, {
    // FutureOr: a case that inspects the store AT the moment of the round
    // trip (persist-before-publish) has to await; the rest stay synchronous.
    required FutureOr<Map<String, dynamic>?> Function(String, Map<String, dynamic>)
    answer,
    List<ReactionKeyTarget> targets = const [
      (userId: peerUserId, deviceId: 1),
    ],
    Future<String> Function(int, int, String)? decryptFrom,
  }) => ReactionKeyService(
    store: store,
    request: (event, payload) async {
      events.add(event);
      return await answer(event, payload);
    },
    resolveTargets: (_) async => targets,
    encryptFor: (u, d, plaintext) async => 'ct:$u:$d:$plaintext',
    decryptFrom:
        decryptFrom ??
        (senderUserId, senderDeviceId, ciphertext) async =>
            throw StateError('not expected'),
  );

  test('a locked store creates NOTHING and touches no socket', () async {
    final store = await boot();
    await store.saveReactionKey(
      conversationId: conversationId,
      epoch: 1,
      keyB64: key,
    );
    store.debugSetContentKvOpener(
      () async => throw const ContentStoreUnavailable('web-locked', locked: true),
    );
    final svc = build(store, answer: (_, _) => fail('must not ask the server'));

    final result = await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
      mayCreate: true,
    );

    expect(result.codec, isNull);
    expect(result.failure, ReactionKeyFailure.unavailable);
    expect(
      events,
      isEmpty,
      reason:
          'the key may be sitting in the vault, readable the moment it '
          'unlocks — creating a new epoch over it orphans every chip',
    );
  });

  test('a local key short-circuits: no fetch, no upload', () async {
    final store = await boot();
    await store.saveReactionKey(
      conversationId: conversationId,
      epoch: 2,
      keyB64: key,
    );
    final svc = build(store, answer: (_, _) => fail('must not ask the server'));

    final result = await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
    );

    expect(result.codec, isNotNull);
    expect(events, isEmpty);
  });

  test('an absent local key is PULLED from the mailbox and persisted', () async {
    final store = await boot();
    final svc = build(
      store,
      answer: (event, _) => event == 'fetchReactionKey'
          ? {
              'conversationId': conversationId,
              'epoch': 4,
              'senderUserId': peerUserId,
              'senderDeviceId': 2,
              'ciphertext': 'wrapped',
            }
          : fail('must not upload when a row exists'),
      decryptFrom: (senderUserId, senderDeviceId, ciphertext) async {
        expect(senderUserId, peerUserId);
        expect(senderDeviceId, 2, reason: 'the SERVER says which device wrapped it');
        expect(ciphertext, 'wrapped');
        return key;
      },
    );

    final result = await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
    );

    expect(result.codec, isNotNull);
    expect(events, ['fetchReactionKey']);
    // Persisted, because that wrap can never be opened a second time.
    final reloaded = await store.loadReactionKey(conversationId);
    expect(reloaded, isA<ReactionKeyFound>());
    expect((reloaded as ReactionKeyFound).epoch, 4);
  });

  test('a row this device cannot open does NOT re-key', () async {
    final store = await boot();
    final svc = build(
      store,
      answer: (event, _) => event == 'fetchReactionKey'
          ? {
              'epoch': 3,
              'senderUserId': peerUserId,
              'senderDeviceId': 1,
              'ciphertext': 'spent',
            }
          : fail('a spent wrap must not trigger an upload'),
      decryptFrom: (_, _, _) async => throw StateError('DuplicateMessage'),
    );

    final result = await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
      mayCreate: true,
    );

    expect(result.failure, ReactionKeyFailure.undecryptable);
    expect(events, ['fetchReactionKey']);
  });

  test('a render path never creates a key, even with no row anywhere', () async {
    final store = await boot();
    final svc = build(
      store,
      answer: (event, _) => event == 'fetchReactionKey'
          ? {'epoch': 0, 'ciphertext': null}
          : fail('mayCreate: false must not upload'),
    );

    final result = await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
    );

    expect(result.failure, ReactionKeyFailure.noKeyYet);
  });

  test('creating a key seals one envelope per target and proposes epoch+1', () async {
    final store = await boot();
    final uploads = <Map<String, dynamic>>[];
    final svc = build(
      store,
      targets: const [
        (userId: peerUserId, deviceId: 1),
        (userId: peerUserId, deviceId: 3),
        (userId: uid, deviceId: 2),
      ],
      answer: (event, payload) {
        if (event == 'fetchReactionKey') return {'epoch': 0, 'ciphertext': null};
        uploads.add(payload);
        return {'success': true, 'epoch': 1};
      },
    );

    final result = await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
      mayCreate: true,
    );

    expect(result.codec, isNotNull);
    expect(uploads, hasLength(1));
    expect(uploads.single['epoch'], 1);
    final envelopes = (uploads.single['envelopes'] as List)
        .cast<Map<String, dynamic>>();
    expect(
      envelopes.map((e) => '${e['userId']}:${e['deviceId']}'),
      ['$peerUserId:1', '$peerUserId:3', '$uid:2'],
      reason: "the sender's OTHER devices must be sealed to as well",
    );
    expect(await store.loadReactionKey(conversationId), isA<ReactionKeyFound>());
  });

  test('losing the epoch race PULLS the winner instead of retrying', () async {
    final store = await boot();
    var fetches = 0;
    final svc = build(
      store,
      answer: (event, _) {
        if (event == 'fetchReactionKey') {
          fetches++;
          // First fetch: nothing yet. After the refusal: the winner's row.
          return fetches == 1
              ? {'epoch': 0, 'ciphertext': null}
              : {
                  'epoch': 1,
                  'senderUserId': peerUserId,
                  'senderDeviceId': 1,
                  'ciphertext': 'winner',
                };
        }
        return {'success': false, 'error': 'stale_epoch', 'epoch': 1};
      },
      decryptFrom: (_, _, _) async => key,
    );

    final result = await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
      mayCreate: true,
    );

    expect(
      result.codec,
      isNotNull,
      reason:
          "the loser must adopt the winner's key — retrying with its own "
          'would leave tokens nobody else can read (falsification R3)',
    );
    final stored = await store.loadReactionKey(conversationId);
    expect((stored as ReactionKeyFound).epoch, 1);
  });

  test('a refused upload leaves NO local key', () async {
    final store = await boot();
    final svc = build(
      store,
      answer: (event, _) => event == 'fetchReactionKey'
          ? {'epoch': 0, 'ciphertext': null}
          : {'success': false, 'error': 'unauthorized'},
    );

    final result = await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
      mayCreate: true,
    );

    expect(result.failure, ReactionKeyFailure.refused);
    expect(
      await store.loadReactionKey(conversationId),
      isA<ReactionKeyAbsent>(),
      reason:
          'a key the server rejected must not be used to blind tokens the '
          'peer can never resolve',
    );
  });

  test('a PULLED key whose store write fails reports unavailable, not undecryptable', () async {
    final store = await boot();
    var fetches = 0;
    // The decrypt below SPENDS the Signal message key, so if the write is lost
    // the plaintext exists only in this process. Reporting `undecryptable`
    // would be terminal — the next launch re-pulls the same row, hits
    // DuplicateMessage and answers undecryptable for good, chips orphaned with
    // no way back. `unavailable` keeps the caller retrying.
    final svc = build(
      store,
      answer: (event, _) {
        if (event != 'fetchReactionKey') fail('must not upload');
        fetches++;
        return {
          'epoch': 6,
          'senderUserId': peerUserId,
          'senderDeviceId': 1,
          'ciphertext': 'wrapped',
        };
      },
      decryptFrom: (_, _, _) async => key,
    );
    // A store that reads ABSENT and silently loses the write: the local lookup
    // still says "no key" (so the pull runs), and the armed read-back after
    // saving finds nothing.
    store.debugSetContentKv(_WriteLosingContentKv());

    final result = await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
      mayCreate: true,
    );

    expect(result.codec, isNull);
    expect(
      result.failure,
      ReactionKeyFailure.unavailable,
      reason: 'undecryptable here would be a permanent, unrecoverable verdict',
    );
    expect(fetches, 1, reason: 'and it must not have created a replacement key');
  });

  test('creating costs ONE fetch, not two', () async {
    final store = await boot();
    final svc = build(
      store,
      // Epoch 0: the only epoch at which creating is allowed at all.
      answer: (event, _) => event == 'fetchReactionKey'
          ? {'epoch': 0, 'ciphertext': null}
          : {'success': true, 'epoch': 1},
    );

    await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
      mayCreate: true,
    );

    expect(
      events,
      ['fetchReactionKey', 'uploadReactionKey'],
      reason:
          'the fetch that proved there is no row already reported the epoch; '
          'asking again was a wasted round trip on every first reaction',
    );
  });

  test('a device linked after distribution is never allowed to re-key', () async {
    // The conversation is at epoch 2 and the server has no row for THIS
    // device: it was linked after the key went out. Minting here would
    // advance the epoch and blank every existing chip for the devices that
    // can still read the messages those chips sit on (owner ruling
    // 2026-09-17). This device waits for a same-epoch top-up instead.
    final store = await boot();
    final svc = build(
      store,
      answer: (event, _) => event == 'fetchReactionKey'
          ? {'epoch': 2, 'ciphertext': null}
          : {'success': true, 'epoch': 3},
    );

    final result = await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
      mayCreate: true,
    );

    expect(result.codec, isNull);
    expect(result.failure, ReactionKeyFailure.noKeyYet);
    expect(
      events,
      ['fetchReactionKey'],
      reason: 'no upload: the epoch must not move',
    );
  });

  test('a created key is STORED before it is published', () async {
    // The upload is what advances the server's epoch, and the fan-out never
    // addresses this device — so there is no mailbox row to recover from. If
    // the key were published first, a lost ack would leave the server serving
    // an epoch whose only plaintext copy died with the call, and the epoch-0
    // rule would then refuse to re-key it. Forever.
    final store = await boot();
    String? storedAtUploadTime;
    final svc = build(
      store,
      answer: (event, _) async {
        if (event == 'uploadReactionKey') {
          final held = await store.loadReactionKey(conversationId);
          storedAtUploadTime = held is ReactionKeyFound ? held.keyB64 : null;
          return {'success': true, 'epoch': 1};
        }
        return {'epoch': 0, 'ciphertext': null};
      },
    );

    final result = await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
      mayCreate: true,
    );

    expect(result.codec, isNotNull);
    expect(
      storedAtUploadTime,
      isNotNull,
      reason: 'the key must already be on disk when the upload goes out',
    );
  });

  test('a REFUSED upload leaves no key behind', () async {
    // The other half of persist-before-publish: a key the server rejected must
    // not survive locally, or `loadReactionKey` answers Found on every later
    // launch and the real key is never pulled — the same permanent blindness,
    // arrived at from the opposite direction.
    final store = await boot();
    final svc = build(
      store,
      answer: (event, _) => event == 'fetchReactionKey'
          ? {'epoch': 0, 'ciphertext': null}
          : {'success': false, 'error': 'rate_limited'},
    );

    final result = await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
      mayCreate: true,
    );

    expect(result.failure, ReactionKeyFailure.refused);
    expect(await store.loadReactionKey(conversationId), isA<ReactionKeyAbsent>());
  });

  test('the generated key is 32 bytes and conversation-specific', () async {
    final store = await boot();
    final captured = <String>[];
    final svc = build(
      store,
      answer: (event, payload) {
        if (event == 'fetchReactionKey') return {'epoch': 0, 'ciphertext': null};
        final env =
            (payload['envelopes'] as List).first as Map<String, dynamic>;
        captured.add(env['ciphertext']! as String);
        return {'success': true, 'epoch': 1};
      },
    );

    await svc.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
      mayCreate: true,
    );

    // encryptFor stringifies the plaintext, so the wrapped key is inspectable.
    final wrapped = captured.single.split(':').last;
    expect(base64Decode(wrapped), hasLength(ReactionTokenCodec.keyBytes));
  });
}

/// Reads as empty and drops every write, so the armed read-back in
/// `saveReactionKey` reports failure without any exception being thrown —
/// which is exactly the shape that makes a SPENT wrap unrecoverable if the
/// caller mistakes it for "undecryptable".
class _WriteLosingContentKv implements ContentKv {
  @override
  String? getString(String key) => null;

  /// An EMPTY authoritative view: the write was accepted and then lost.
  /// Reaction-key reads go through this snapshot (a stale cache deciding
  /// "absent" is what spends the mailbox row), so a fake that cannot answer
  /// it would fail the read for the wrong reason.
  @override
  Future<Map<String, Object>?> authoritativeSnapshot() async =>
      const <String, Object>{};

  @override
  Future<bool> setString(String key, String value) async => true;

  @override
  Set<String> getKeys() => const <String>{};

  @override
  Future<void> reload() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
