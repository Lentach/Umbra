import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

/// A queue's auth key (design §4.3: one Ed25519 key per queue, never the seal
/// key). Stored as [bytes] = seed(32) ‖ publicKey(32), the libsodium/Go
/// layout, so loading a key never pays a scalar multiplication — a reconnect
/// re-signs `subscribe` for every queue this device holds.
class BoxAuthKey {
  BoxAuthKey._(this.bytes);

  /// Throws [ArgumentError] unless [bytes] is 64 long. Copies: the caller's
  /// buffer may be zeroed or reused.
  factory BoxAuthKey.fromBytes(List<int> bytes) {
    if (bytes.length != 64) {
      throw ArgumentError.value(bytes.length, 'bytes', 'must be 64');
    }
    return BoxAuthKey._(Uint8List.fromList(bytes));
  }

  final Uint8List bytes;

  Uint8List get seed => Uint8List.sublistView(bytes, 0, 32);
  Uint8List get publicKey => Uint8List.sublistView(bytes, 32);
}

/// The ONE signature the box verifies: pure Ed25519 (RFC 8032), checked by
/// node `crypto.verify` (`backend/src/box/box-signature.ts`). libsignal's
/// XEdDSA is a different scheme node cannot check. An interface so a WebCrypto
/// Ed25519 can replace the pure-Dart one without touching a caller;
/// [Ed25519BoxSigner] is the only production implementation.
abstract interface class BoxSigner {
  /// A fresh key from a secure random seed.
  BoxAuthKey mint();

  /// The 64-byte signature of [message] under [key].
  Uint8List sign(BoxAuthKey key, List<int> message);
}

class Ed25519BoxSigner implements BoxSigner {
  const Ed25519BoxSigner();

  @override
  BoxAuthKey mint() => BoxAuthKey.fromBytes(ed.generateKey().privateKey.bytes);

  @override
  Uint8List sign(BoxAuthKey key, List<int> message) => ed.sign(
    ed.PrivateKey(Uint8List.fromList(key.bytes)),
    Uint8List.fromList(message),
  );
}
