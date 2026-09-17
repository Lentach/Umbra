import 'dart:convert';

import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/reactions/reaction_key_lookup.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `K_react` has to survive a relaunch, and that is not a nicety: the server's
/// copy is a Signal-wrapped mailbox row, Signal decryption CONSUMES the message
/// key, so that row can be opened exactly once. The first draft of
/// `docs/design/reaction-privacy.md` claimed the key could live in RAM and be
/// re-pulled every launch — these tests are what that claim dies on
/// (falsification R7).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const uid = 42;
  const conversationId = 7;
  // Built, not literal: a 32-byte base64 constant in source reads as a real
  // key to gitleaks (and to a human skimming the file), and the pre-commit
  // scan is not something to argue with over a test fixture.
  final keyB64 = base64Encode(List<int>.generate(32, (i) => i));
  final rotatedB64 = base64Encode(List<int>.generate(32, (i) => 255 - i));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<EncryptionService> boot(int userId) async {
    final svc = EncryptionService();
    await svc.initialize(
      userId,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    return svc;
  }

  test('a saved key is still readable after a restart', () async {
    final first = await boot(uid);
    expect(
      await first.saveReactionKey(
        conversationId: conversationId,
        epoch: 3,
        keyB64: keyB64,
      ),
      isTrue,
      reason: 'the write is armed — an unverified write must report failure',
    );

    final restarted = await boot(uid);
    final loaded = await restarted.loadReactionKey(conversationId);

    expect(loaded, isA<ReactionKeyFound>());
    expect((loaded as ReactionKeyFound).epoch, 3);
    expect(loaded.keyB64, keyB64);
  });

  test('an unknown conversation is ABSENT, which is the only re-key licence', () async {
    final svc = await boot(uid);
    expect(await svc.loadReactionKey(999), isA<ReactionKeyAbsent>());
  });

  test('the key is scoped to the account that stored it', () async {
    final mine = await boot(uid);
    await mine.saveReactionKey(
      conversationId: conversationId,
      epoch: 1,
      keyB64: keyB64,
    );

    final other = await boot(99);
    expect(
      await other.loadReactionKey(conversationId),
      isA<ReactionKeyAbsent>(),
      reason:
          'reaction keys live in the per-user namespace, so a second account '
          'on the same device must not inherit them',
    );
  });

  test('a later epoch replaces the stored key', () async {
    final svc = await boot(uid);
    await svc.saveReactionKey(
      conversationId: conversationId,
      epoch: 1,
      keyB64: keyB64,
    );
    final rotated = rotatedB64;
    await svc.saveReactionKey(
      conversationId: conversationId,
      epoch: 2,
      keyB64: rotated,
    );

    final loaded = await svc.loadReactionKey(conversationId) as ReactionKeyFound;
    expect(loaded.epoch, 2);
    expect(loaded.keyB64, rotated);
  });

  test('account deletion takes the reaction keys with it', () async {
    final svc = await boot(uid);
    await svc.saveReactionKey(
      conversationId: conversationId,
      epoch: 1,
      keyB64: keyB64,
    );

    await svc.clearAllKeys();
    await svc.initialize(
      uid,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );

    expect(
      await svc.loadReactionKey(conversationId),
      isA<ReactionKeyAbsent>(),
      reason:
          'a key that outlived the identity it belonged to would be residue '
          'the next account on this device could not use but could read',
    );
  });

  test('a LOCKED vault is unavailable, never absent', () async {
    final svc = await boot(uid);
    await svc.saveReactionKey(
      conversationId: conversationId,
      epoch: 1,
      keyB64: keyB64,
    );
    // The web content store rethrows on a locked passcode vault instead of
    // falling back. Reading that as "no key" would let the caller re-key at
    // epoch + 1 and orphan every existing chip for both participants — for a
    // key that is sitting right there, readable the moment the user unlocks.
    svc.debugSetContentKv(_LockedContentKv());

    final verdict = await svc.loadReactionKey(conversationId);

    expect(verdict, isA<ReactionKeyUnavailable>());
    expect((verdict as ReactionKeyUnavailable).reason, 'locked');
    expect(
      verdict,
      isNot(isA<ReactionKeyAbsent>()),
      reason: 'absence is the ONLY state that may authorise a re-key',
    );
  });

  test('an unknown store failure is unavailable, never absent', () async {
    final svc = await boot(uid);
    svc.debugSetContentKv(_ThrowingContentKv());

    final verdict = await svc.loadReactionKey(conversationId);

    expect(verdict, isA<ReactionKeyUnavailable>());
  });
}

/// Mirrors the web store's locked behaviour: rethrow, never fall back.
class _LockedContentKv implements ContentKv {
  @override
  String? getString(String key) =>
      throw const ContentStoreUnavailable('web-locked', locked: true);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw const ContentStoreUnavailable('web-locked', locked: true);
}

class _ThrowingContentKv implements ContentKv {
  @override
  String? getString(String key) => throw StateError('store is on fire');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('store is on fire');
}
