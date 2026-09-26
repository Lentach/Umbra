import 'dart:typed_data';

import '../config/app_config.dart';
import '../services/api_service.dart';
import '../services/box/box_media_url.dart';
import '../services/media_crypto_service.dart';

/// The unframed ciphertext of box attachment `box:<id>` (item 3 / media
/// wiring): this device's copy, else a download. Null when there is none.
/// `MessagingProvider.boxMediaCiphertext`.
typedef BoxCiphertextSource = Future<Uint8List?> Function(String url);

/// Fetch [url] with [token], enforce the media size cap, and AES-GCM decrypt
/// when both [key] and [iv] are present.
///
/// Extracted from the image / GIF / file message widgets, which each ran an
/// identical fetch + size-guard + optional-decrypt pipeline. This THROWS on any
/// failure (fetch error, oversize, decrypt failure); callers catch and render
/// their own existing failure UI (image -> error text, GIF -> broken-image
/// icon, file -> snackbar). [api]/[crypto] are injectable for testing.
///
/// A box attachment (`box:` url, E17a) comes from [box] instead — never
/// `/media`, never a Bearer token — and is always keyed; the cap applies to
/// its UNFRAMED ciphertext, so a 17 MiB file on the 32 MiB rung shows.
Future<Uint8List> loadDecryptedMediaBytes({
  required String url,
  required String token,
  String? key,
  String? iv,
  String? baseUrl,
  ApiService? api,
  MediaCryptoService? crypto,
  BoxCiphertextSource? box,
}) async {
  if (isBoxMediaUrl(url)) {
    if (box == null || key == null || iv == null) {
      throw StateError('Box media needs its source and key');
    }
    final ciphertext = await box(url);
    if (ciphertext == null) throw StateError('Box media unavailable');
    if (ciphertext.length > MediaCryptoService.maxCiphertextBytes) {
      throw Exception(
        'Media too large (${ciphertext.length} > '
        '${MediaCryptoService.maxCiphertextBytes})',
      );
    }
    return (crypto ?? MediaCryptoService()).decrypt(ciphertext, key, iv);
  }
  final service = api ?? ApiService(baseUrl: baseUrl ?? AppConfig.baseUrl);
  final raw = await service.fetchMediaBytes(url, token);
  final encrypted = key != null && iv != null;
  final cap = encrypted
      ? MediaCryptoService.maxCiphertextBytes
      : MediaCryptoService.maxBytes;
  if (raw.length > cap) {
    throw Exception('Media too large (${raw.length} > $cap)');
  }
  if (key != null && iv != null) {
    return (crypto ?? MediaCryptoService())
        .decrypt(Uint8List.fromList(raw), key, iv);
  }
  return Uint8List.fromList(raw);
}
