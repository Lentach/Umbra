import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'box_signer.dart';

BoxSigner platformBoxSigner() => WebCryptoBoxSigner();

/// RFC 8410 PKCS#8 wrapping of a raw 32-byte Ed25519 seed: this fixed header,
/// then the seed.
const List<int> _pkcs8SeedHeader = [
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, //
  0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
];

/// Ed25519 through the browser's WebCrypto (Chrome 137+, Firefox 129+,
/// Safari 17+): 256 signatures in ~17 ms where the pure-Dart signer compiled
/// to JS takes ~2 s (measured 2026-09-23, Chromium 153). Ed25519 is
/// deterministic, so both produce the same bytes.
///
/// A browser without Ed25519, or an insecure context (no `crypto.subtle`),
/// fails the first key import; from then on this session signs with
/// [_fallback], which still yields per signature.
class WebCryptoBoxSigner implements BoxSigner {
  WebCryptoBoxSigner({
    BoxSigner fallback = const Ed25519BoxSigner(yields: true),
  }) : _fallback = fallback;

  final BoxSigner _fallback;

  /// Imported keys by public key: a reconnect imports nothing twice.
  final Map<String, Future<web.CryptoKey?>> _keys = {};
  bool _unsupported = false;

  @override
  BoxAuthKey mint() => _fallback.mint();

  @override
  Future<Uint8List> sign(BoxAuthKey key, List<int> message) async {
    if (!_unsupported) {
      final cryptoKey = await _import(key);
      if (cryptoKey != null) {
        try {
          final signature = await web.window.crypto.subtle
              .sign(
                'Ed25519'.toJS,
                cryptoKey,
                Uint8List.fromList(message).toJS,
              )
              .toDart;
          return (signature! as JSArrayBuffer).toDart.asUint8List();
        } on Object {
          // An imported key that then fails to sign is not expected; the
          // pure-Dart signature is the same bytes, so use it for this one.
        }
      }
    }
    return _fallback.sign(key, message);
  }

  Future<web.CryptoKey?> _import(BoxAuthKey key) =>
      _keys.putIfAbsent(base64Url.encode(key.publicKey), () async {
        try {
          return await web.window.crypto.subtle
              .importKey(
                'pkcs8',
                Uint8List.fromList([..._pkcs8SeedHeader, ...key.seed]).toJS,
                'Ed25519'.toJS,
                false,
                ['sign'.toJS].toJS,
              )
              .toDart;
        } on Object {
          _unsupported = true;
          return null;
        }
      });
}
