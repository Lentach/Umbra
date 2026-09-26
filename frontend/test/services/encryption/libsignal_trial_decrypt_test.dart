import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// The vendored libsignal_protocol_dart (`frontend/third_party`, two
/// `UMBRA PATCH`es in 0.8.2's trial decrypt). A message sealed under an older
/// session state is read by trying the CURRENT state, then each archived
/// one. Upstream tried on a shallow copy, so the failed try advanced the real
/// current state (the next message on it failed `Bad Mac`), and it left the
/// archived original beside its promoted copy.
class _Party {
  _Party(this.name, this.address)
    : store = InMemorySignalProtocolStore(
        generateIdentityKeyPair(),
        generateRegistrationId(false),
      );

  final String name;
  final SignalProtocolAddress address;
  final InMemorySignalProtocolStore store;
  int _nextPreKey = 1;

  Future<PreKeyBundle> bundle() async {
    final identity = await store.getIdentityKeyPair();
    final preKey = generatePreKeys(_nextPreKey++, 1).single;
    final signed = generateSignedPreKey(identity, _nextPreKey++);
    await store.storePreKey(preKey.id, preKey);
    await store.storeSignedPreKey(signed.id, signed);
    return PreKeyBundle(
      await store.getLocalRegistrationId(),
      1,
      preKey.id,
      preKey.getKeyPair().publicKey,
      signed.id,
      signed.getKeyPair().publicKey,
      signed.signature,
      identity.getPublicKey(),
    );
  }

  SessionCipher cipherFor(_Party peer) =>
      SessionCipher.fromStore(store, peer.address);
}

Uint8List _text(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  test(
    'a message read from an ARCHIVED state leaves the current state as it '
    'was, keeps one copy of the state it was read from, and a replay of it '
    'is refused as a duplicate',
    () async {
      final alice = _Party('alice', const SignalProtocolAddress('alice', 1));
      final bob = _Party('bob', const SignalProtocolAddress('bob', 1));

      // S1: Alice starts, Bob reads and answers, Alice reads the answer.
      await SessionBuilder.fromSignalStore(
        alice.store,
        bob.address,
      ).processPreKeyBundle(await bob.bundle());
      final first = await alice.cipherFor(bob).encrypt(_text('a0'));
      await bob.cipherFor(alice).decrypt(
        PreKeySignalMessage(first.serialize()),
      );
      final answer = await bob.cipherFor(alice).encrypt(_text('b0'));
      await alice.cipherFor(bob).decryptFromSignal(
        SignalMessage.fromSerialized(answer.serialize()),
      );

      // Alice writes under S1; before Bob reads it, Bob re-keys (S2 current,
      // S1 archived).
      final late = await alice.cipherFor(bob).encrypt(_text('a1'));
      expect(late.getType(), CiphertextMessage.whisperType);
      await SessionBuilder.fromSignalStore(
        bob.store,
        alice.address,
      ).processPreKeyBundle(await alice.bundle());
      final before = await bob.store.loadSession(alice.address);
      final s2 = before.sessionState.aliceBaseKey;
      final s2Bytes = before.sessionState.structure.writeToBuffer();
      final s1 = before.previousSessionStates.first.aliceBaseKey;

      final lateMessage = SignalMessage.fromSerialized(late.serialize());
      expect(
        utf8.decode(
          await bob.cipherFor(alice).decryptFromSignal(lateMessage),
        ),
        'a1',
      );

      final after = await bob.store.loadSession(alice.address);
      final states = [after.sessionState, ...after.previousSessionStates];
      bool isS2(SessionState s) => _same(s.aliceBaseKey, s2);
      bool isS1(SessionState s) => _same(s.aliceBaseKey, s1);
      // Patch 1: the failed try on S2 did not move it.
      expect(states.where(isS2).single.structure.writeToBuffer(), s2Bytes);
      // Patch 2: S1 is promoted, and no stale copy of it is left archived.
      expect(isS1(after.sessionState), isTrue);
      expect(states.where(isS1), hasLength(1));

      await expectLater(
        bob.cipherFor(alice).decryptFromSignal(
          SignalMessage.fromSerialized(late.serialize()),
        ),
        throwsA(isA<DuplicateMessageException>()),
      );
    },
  );
}

bool _same(List<int> a, List<int> b) =>
    a.length == b.length && Iterable<int>.generate(a.length).every(
      (i) => a[i] == b[i],
    );
