import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/box/queue_seal.dart';
import 'package:fireplace/services/device_link/link_crypto.dart' show hkdfSha256;
import 'package:flutter_test/flutter_test.dart';

import '../../support/box_fakes.dart';

Uint8List _body(int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 7 + 3) & 0xff));

void main() {
  final seal = QueueSeal(cipher: PointyGcmSealer());
  final queue = QueueSeal.mintKeyPair();

  test('a blob is exactly 16384 bytes whatever it carries, and opens', () async {
    for (final length in [0, 1, 500, QueueSeal.maxBodyBytes]) {
      final body = _body(length);
      final blob = (await seal.seal(queue.publicKey, body))!;
      expect(blob, hasLength(kBoxBlobBytes));
      expect(await seal.open(queue.privateKey, queue.publicKey, blob), body);
    }
  });

  test('a body one byte over the frame is a caller bug', () {
    expect(
      () => seal.seal(queue.publicKey, _body(QueueSeal.maxBodyBytes + 1)),
      throwsArgumentError,
    );
  });

  test('two seals of one body share no bytes past the version', () async {
    final body = _body(64);
    final a = (await seal.seal(queue.publicKey, body))!;
    final b = (await seal.seal(queue.publicKey, body))!;
    expect(a[0], b[0]);
    expect(a.sublist(1, 33), isNot(b.sublist(1, 33)), reason: 'fresh eph');
    expect(a.sublist(33), isNot(b.sublist(33)));
  });

  test('a blob sealed to one queue opens under no other', () async {
    final other = QueueSeal.mintKeyPair();
    final blob = (await seal.seal(queue.publicKey, _body(10)))!;
    expect(await seal.open(other.privateKey, other.publicKey, blob), isNull);
    // The right private key under a claimed public key that is not its own:
    // the KDF binds the recipient's key, so this fails too.
    expect(await seal.open(queue.privateKey, other.publicKey, blob), isNull);
  });

  test('any flipped byte — header, IV, body, padding or tag — refuses', () async {
    final blob = (await seal.seal(queue.publicKey, _body(10)))!;
    for (final at in [0, 1, 32, 33, 45, 60, 9000, kBoxBlobBytes - 1]) {
      final bent = Uint8List.fromList(blob)..[at] ^= 0x01;
      expect(
        await seal.open(queue.privateKey, queue.publicKey, bent),
        isNull,
        reason: 'byte $at',
      );
    }
    expect(
      await seal.open(queue.privateKey, queue.publicKey, blob.sublist(1)),
      isNull,
    );
  });

  test(
    'a low-order ephemeral is refused: its key is one ANYONE can compute',
    () async {
      // X25519 with the all-zero point outputs 32 zero bytes for every private
      // key, so a forger who knows only the PUBLIC seal key derives the same
      // AEAD key the recipient would. Build exactly that blob.
      final zeroEph = Uint8List(32);
      final key = hkdfSha256(
        ikm: Uint8List(32),
        info: Uint8List.fromList([
          ...ascii.encode('umbra.box.seal.v1\x00'),
          ...zeroEph,
          ...queue.publicKey,
        ]),
        length: 32,
      );
      final frame = Uint8List(QueueSeal.frameBytes)
        ..[3] = 5
        ..setRange(4, 9, ascii.encode('forged'.substring(0, 5)));
      final sealed = (await PointyGcmSealer().seal(key, frame))!;
      final forged = Uint8List.fromList([0x01, ...zeroEph, ...sealed]);
      expect(forged, hasLength(kBoxBlobBytes));
      expect(
        await seal.open(queue.privateKey, queue.publicKey, forged),
        isNull,
      );
    },
  );

  test('a low-order seal key from a hostile peer fails the send, not the app', () async {
    expect(await seal.seal(Uint8List(32), _body(10)), isNull);
  });
}
