import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../device_link/link_crypto.dart' show hkdfSha256;
import '../encryption/content_sealer.dart';
import 'box_wire.dart';

/// A queue's X25519 seal key pair, raw 32-byte halves. Minted by the queue's
/// owner at `createQueue`; the private half never leaves the device, the
/// public half travels to the peer beside the sid, inside E2E.
class QueueSealKeyPair {
  const QueueSealKeyPair({required this.privateKey, required this.publicKey});

  final Uint8List privateKey;
  final Uint8List publicKey;
}

/// The outer layer of every box blob (design §4.3): an ECIES seal to the
/// queue's seal key, padded to exactly [kBoxBlobBytes].
///
///   key  = HKDF-SHA256(X25519(eph, sealPub),
///            info = "umbra.box.seal.v1" 0x00 ‖ ephPub ‖ sealPub, 32)
///   blob = 0x01 ‖ ephPub(32) ‖ IV(12) ‖ AES-256-GCM(frame) ‖ tag(16)
///   frame = uint32be(len) ‖ body ‖ zeros, exactly [frameBytes] long
///
/// A fresh ephemeral per blob, so the key never repeats and two seals of the
/// same body share no byte. Binding both public keys into the KDF means a
/// blob sealed to one queue opens under no other. The seal target is the
/// QUEUE's key, never the account identity key: linked devices share the
/// identity, so a revoked device could otherwise open every seal forever.
/// No outer forward secrecy (the Signal ratchet inside carries it).
///
/// HKDF is `link_crypto`'s (salt = 32 zero bytes); X25519 is libsignal's
/// `Curve`, the same construction as the link ceremony. The AEAD is a
/// [ContentSealer] seam — production [AesGcmContentSealer]; a test injects a
/// pure-Dart GCM because webcrypto cannot load under `flutter test` here.
class QueueSeal {
  QueueSeal({ContentSealer? cipher})
    : _cipher = cipher ?? AesGcmContentSealer();

  final ContentSealer _cipher;

  static const int _version = 0x01;
  static const int _keyBytes = 32;
  static const int _ivBytes = 12;
  static const int _tagBytes = 16;
  static const int _headerBytes = 1 + _keyBytes;

  /// The sealed frame: everything the blob does not spend on header, IV, tag.
  static const int frameBytes =
      kBoxBlobBytes - _headerBytes - _ivBytes - _tagBytes;

  /// The longest body one blob carries.
  static const int maxBodyBytes = frameBytes - 4;

  static final Uint8List _info = ascii.encode('umbra.box.seal.v1\x00');

  static QueueSealKeyPair mintKeyPair() {
    final pair = Curve.generateKeyPair();
    return QueueSealKeyPair(
      privateKey: Uint8List.fromList(
        (pair.privateKey as DjbECPrivateKey).privateKey,
      ),
      publicKey: Uint8List.fromList((pair.publicKey as DjbECPublicKey).publicKey),
    );
  }

  /// [body] sealed to [sealPub] as one [kBoxBlobBytes] blob, or null when the
  /// key agreement or the cipher refused — a low-order [sealPub] from a
  /// hostile peer included (callers treat null as a failed send, never as
  /// empty). Throws [ArgumentError] for a body over [maxBodyBytes] or a key
  /// that is not 32 bytes: those are caller bugs, not runtime conditions.
  Future<Uint8List?> seal(Uint8List sealPub, Uint8List body) async {
    if (sealPub.length != _keyBytes) {
      throw ArgumentError.value(sealPub.length, 'sealPub', 'must be 32 bytes');
    }
    if (body.length > maxBodyBytes) {
      throw ArgumentError.value(body.length, 'body', 'over $maxBodyBytes');
    }
    final eph = Curve.generateKeyPair();
    final ephPub = Uint8List.fromList((eph.publicKey as DjbECPublicKey).publicKey);
    final Uint8List shared;
    try {
      shared = Curve.calculateAgreement(
        DjbECPublicKey(Uint8List.fromList(sealPub)),
        eph.privateKey,
      );
    } on Object {
      return null;
    }
    final key = _deriveKey(shared, ephPub, sealPub);
    final sealed = await _cipher.seal(key, _frame(body));
    if (sealed == null || sealed.length != _ivBytes + frameBytes + _tagBytes) {
      return null;
    }
    return Uint8List(kBoxBlobBytes)
      ..[0] = _version
      ..setRange(1, _headerBytes, ephPub)
      ..setRange(_headerBytes, kBoxBlobBytes, sealed);
  }

  /// The body of [blob] if it was sealed to this key pair; null for anything
  /// else — another queue's blob, a tampered byte, a wrong size or version.
  Future<Uint8List?> open(
    Uint8List sealPriv,
    Uint8List sealPub,
    Uint8List blob,
  ) async {
    if (blob.length != kBoxBlobBytes || blob[0] != _version) return null;
    if (sealPriv.length != _keyBytes || sealPub.length != _keyBytes) {
      return null;
    }
    final ephPub = Uint8List.fromList(blob.sublist(1, _headerBytes));
    final Uint8List shared;
    try {
      shared = Curve.calculateAgreement(
        DjbECPublicKey(Uint8List.fromList(ephPub)),
        DjbECPrivateKey(Uint8List.fromList(sealPriv)),
      );
    } on Object {
      return null;
    }
    final key = _deriveKey(shared, ephPub, sealPub);
    final frame = await _cipher.unseal(
      key,
      Uint8List.sublistView(blob, _headerBytes),
    );
    if (frame == null || frame.length != frameBytes) return null;
    final length =
        (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3];
    if (length > maxBodyBytes) return null;
    return Uint8List.fromList(Uint8List.sublistView(frame, 4, 4 + length));
  }

  /// The AEAD key. A low-order point never gets here: libsignal's X25519
  /// (`x25519` 0.1.1) THROWS on an all-zero output — RFC 7748 §6.1's check —
  /// and both callers turn that into null, so no blob is ever keyed to a
  /// value anyone could compute from the public key alone.
  static Uint8List _deriveKey(
    Uint8List shared,
    Uint8List ephPub,
    Uint8List sealPub,
  ) => hkdfSha256(
    ikm: shared,
    info: Uint8List.fromList([..._info, ...ephPub, ...sealPub]),
    length: 32,
  );

  /// `uint32be(length) ‖ body ‖ zeros`, exactly [frameBytes] — the contact
  /// backup's framing (`contact_backup.dart`), to one fixed size.
  static Uint8List _frame(Uint8List body) => Uint8List(frameBytes)
    ..[0] = (body.length >> 24) & 0xff
    ..[1] = (body.length >> 16) & 0xff
    ..[2] = (body.length >> 8) & 0xff
    ..[3] = body.length & 0xff
    ..setRange(4, 4 + body.length, body);
}
