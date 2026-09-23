import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import 'box_signer_stub.dart'
    if (dart.library.js_interop) 'box_signer_web.dart'
    as platform;

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
/// XEdDSA is a different scheme node cannot check.
///
/// Asynchronous because a reconnect signs `subscribe` for every queue this
/// device holds (up to 256 per chunk) and that must never hold the UI: the
/// pure-Dart signature compiled to JS costs ~8–9 ms, so 256 of them in one
/// go froze the web app for ~2 s (measured 2026-09-23, Chromium 153, -O4).
abstract interface class BoxSigner {
  /// A fresh key from a secure random seed.
  BoxAuthKey mint();

  /// The 64-byte signature of [message] under [key].
  Future<Uint8List> sign(BoxAuthKey key, List<int> message);
}

/// This platform's signer: the browser's own Ed25519 on the web (pure Dart
/// where the browser has none), pure Dart yielding per signature elsewhere.
/// One per process, so the web one imports each key once.
final BoxSigner boxSigner = platform.platformBoxSigner();

class Ed25519BoxSigner implements BoxSigner {
  /// [yields]: wait one event-loop turn before each signature, so a caller
  /// that starts a burst together (`Future.wait`) gets one signature per
  /// turn and the UI keeps drawing between them.
  const Ed25519BoxSigner({this.yields = false});

  final bool yields;

  @override
  BoxAuthKey mint() => BoxAuthKey.fromBytes(ed.generateKey().privateKey.bytes);

  @override
  Future<Uint8List> sign(BoxAuthKey key, List<int> message) async {
    if (yields) await Future<void>.delayed(Duration.zero);
    return ed.sign(
      ed.PrivateKey(Uint8List.fromList(key.bytes)),
      Uint8List.fromList(message),
    );
  }
}
