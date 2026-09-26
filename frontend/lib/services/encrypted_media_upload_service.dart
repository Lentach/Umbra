import 'dart:typed_data';

import 'api_service.dart';
import 'media_crypto_service.dart';

/// Result of encrypting media bytes and uploading the ciphertext blob.
class EncryptedMediaUpload {
  final String mediaUrl;
  final String keyBase64;
  final String ivBase64;
  final int? mediaDuration;

  const EncryptedMediaUpload({
    required this.mediaUrl,
    required this.keyBase64,
    required this.ivBase64,
    this.mediaDuration,
  });
}

/// Encrypts media bytes (AES-256-GCM) and uploads the ciphertext to the
/// backend media endpoint. Holds no provider state, so it can be unit-tested
/// with fake [MediaCryptoService] / [ApiService] dependencies.
class EncryptedMediaUploadService {
  final MediaCryptoService _crypto;
  final ApiService _api;

  EncryptedMediaUploadService({
    required ApiService api,
    MediaCryptoService? crypto,
  })  : _api = api,
        _crypto = crypto ?? MediaCryptoService();

  /// Encrypts [bytes] alone (fresh key and IV, refused past
  /// [MediaCryptoService.maxBytes]): a box attachment is uploaded through
  /// the box, never `/media/upload` (item 3 / media wiring, E17a).
  Future<EncryptedMedia> encrypt(Uint8List bytes) => _crypto.encrypt(bytes);

  /// Encrypts [bytes], invokes [onEncrypted] with the freshly minted key/iv
  /// (so callers can persist them into `_pendingSendContent` BEFORE the upload
  /// await — preserving the documented invariant), then uploads the ciphertext.
  Future<EncryptedMediaUpload> encryptAndUpload({
    required Uint8List bytes,
    required String token,
    required String mediaType,
    int? duration,
    int? expiresIn,
    String? fileName,
    void Function(String keyBase64, String ivBase64)? onEncrypted,
  }) async {
    final encrypted = await _crypto.encrypt(bytes);
    onEncrypted?.call(encrypted.keyBase64, encrypted.ivBase64);

    final responseData = await _api.uploadEncryptedMedia(
      token: token,
      encryptedBytes: encrypted.ciphertext,
      mediaType: mediaType,
      duration: duration,
      expiresIn: expiresIn,
      fileName: fileName,
    );

    return EncryptedMediaUpload(
      mediaUrl: responseData['mediaUrl'] as String,
      keyBase64: encrypted.keyBase64,
      ivBase64: encrypted.ivBase64,
      mediaDuration: (responseData['mediaDuration'] as num?)?.toInt(),
    );
  }
}
