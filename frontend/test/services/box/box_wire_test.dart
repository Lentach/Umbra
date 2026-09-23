import 'dart:async';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:fireplace/services/box/box_signer.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:flutter_test/flutter_test.dart';

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _seq(int start, int length) =>
    Uint8List.fromList(List.generate(length, (i) => start + i));

/// Vectors the SERVER produced, 2026-09-23: `backend/dist/box/box-signature.js`
/// built the messages and node `crypto.sign(null, m, ed25519Key)` signed them,
/// for seed 00..1f and socket id `Xk3_bQ9-ZtLpA0c1AAAB`. Ed25519 is
/// deterministic, so equal signatures prove this client signs what the
/// server's `crypto.verify` accepts.
const _sockId = 'Xk3_bQ9-ZtLpA0c1AAAB';
const _pub =
    '03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8';
const _vectors = <String, ({String msg, String sig})>{
  'createQueue': (
    msg:
        '756d6272612e626f782e76310063726561746551756575650014586b335f6251392d5a744c7041306331414141420103a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8',
    sig:
        '5e18f68104712dbd9e2f05b9d9dec76ee128bcba1f7190de975b8db8ceb694bf5450bc4fcd929f9641a82d0b59a3057a0947e4b35f1cba291716f7150f43d804',
  ),
  'subscribe': (
    msg:
        '756d6272612e626f782e7631007375627363726962650014586b335f6251392d5a744c704130633141414142404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f',
    sig:
        'cff23a635197dc366da46f17c36eeaa2b7b06a8184af5879ab9c4b4143da0e7b72b7df3eb6f8ce53043883221b11aaac77eced2fd61a94730af8bc4ba2ec9000',
  ),
  'ack': (
    msg:
        '756d6272612e626f782e76310061636b0014586b335f6251392d5a744c704130633141414142404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5fa0a1a2a3a4a5a6a7a8a9aaabacadaeaf',
    sig:
        '64f4c3f6410642f89c7934adf5a6337ddc61987d0ce77364b4695b11ba392386a37716a64afc39605d0afd7a6179b259fdac8d5b37f640d9bdce971b397fef0d',
  ),
  'registerNotifier': (
    msg:
        '756d6272612e626f782e76310072656769737465724e6f7469666965720014586b335f6251392d5a744c704130633141414142101112131415161718191a1b1c1d1e1f01d505814daf9b6ae6658e8aa37b8e6181502f42586962fd1d01806b4a18d369f2',
    sig:
        '2f4e01db3d9df1770e9698bd759ac68c3496638faee7ffee52338b767afdeffeea0c056b10e6f6cd9517ed651434c58ace9ca16a8f94039bd8b4404864bd5809',
  ),
};

void main() {
  group('signed bytes match the server byte for byte', () {
    final key = BoxAuthKey.fromBytes(ed.newKeyFromSeed(_seq(0, 32)).bytes);
    final rid = _seq(0x40, 32);
    const signer = Ed25519BoxSigner();

    test('the key a seed derives is the one node derived', () {
      expect(_toHex(key.publicKey), _pub);
    });

    final built = <String, Uint8List>{
      'createQueue': boxSignedMessage(
        BoxSignedVerb.createQueue,
        _sockId,
        createQueueFields(QueueKind.normal, key.publicKey),
      ),
      'subscribe': boxSignedMessage(BoxSignedVerb.subscribe, _sockId, rid),
      'ack': boxSignedMessage(
        BoxSignedVerb.ack,
        _sockId,
        ackFields(rid, _seq(0xa0, 16)),
      ),
      'registerNotifier': boxSignedMessage(
        BoxSignedVerb.registerNotifier,
        _sockId,
        notifierChallengeFields(
          _seq(0x10, 16),
          NotifierPlatform.fcm,
          'tok:en_1',
        ),
      ),
    };

    for (final entry in _vectors.entries) {
      test('${entry.key}: message and signature', () async {
        final message = built[entry.key]!;
        expect(_toHex(message), entry.value.msg);
        expect(_toHex(await signer.sign(key, message)), entry.value.sig);
      });
    }

    test(
      'the platform signer takes one event-loop turn per signature, one '
      'signature at a time, and still signs the same bytes',
      () async {
        // A reconnect starts up to 256 signatures at once. Back to back on
        // the UI thread they froze the web app for ~2.6 s; with every turn
        // queued up front they held each later timer until the last one.
        var completed = 0;
        final burst = Future.wait([
          for (var i = 0; i < 3; i++)
            boxSigner.sign(key, built['subscribe']!).then((signature) {
              completed++;
              return signature;
            }),
        ]);
        int? completedWhenLaterWorkRan;
        Timer.run(() => completedWhenLaterWorkRan = completed);
        final signatures = await burst;
        expect(completedWhenLaterWorkRan, lessThan(signatures.length));
        expect(
          signatures.map(_toHex),
          everyElement(_vectors['subscribe']!.sig),
        );
      },
    );
  });

  group('boxB64Decode accepts only the canonical fixed-length spelling', () {
    final bytes = _seq(1, 16);
    final canonical = boxB64(bytes);

    test('the canonical spelling decodes', () {
      expect(canonical.contains('='), isFalse);
      expect(boxB64Decode(canonical, 16), bytes);
    });

    test('padded, wrong-length, standard-alphabet and non-canonical fail', () {
      expect(boxB64Decode('$canonical==', 16), isNull);
      expect(boxB64Decode(canonical, 17), isNull);
      final urlSafe = boxB64(_seq(250, 16));
      expect(urlSafe, matches(RegExp('[-_]')));
      expect(
        boxB64Decode(urlSafe.replaceAll('-', '+').replaceAll('_', '/'), 16),
        isNull,
      );
      // Right length and alphabet, but the last char sets spare bits: a
      // lenient decoder reads the same 16 bytes from it; the box does not.
      expect(canonical.endsWith('A'), isTrue);
      final sloppy = '${canonical.substring(0, canonical.length - 1)}B';
      expect(boxB64Decode(sloppy, 16), isNull);
      expect(boxB64Decode(12, 16), isNull);
    });
  });
}
