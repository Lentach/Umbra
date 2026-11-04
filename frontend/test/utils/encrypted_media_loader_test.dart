import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:fireplace/utils/encrypted_media_loader.dart';

class _FakeApi extends ApiService {
  _FakeApi(this._bytes) : super(baseUrl: 'http://test');
  final Uint8List _bytes;
  String? lastUrl;

  @override
  Future<Uint8List> fetchMediaBytes(String url) async {
    lastUrl = url;
    return _bytes;
  }
}

class _FakeCrypto extends MediaCryptoService {
  bool called = false;
  String? key;
  String? iv;

  @override
  Future<Uint8List> decrypt(Uint8List ciphertext, String keyB64, String ivB64) async {
    called = true;
    key = keyB64;
    iv = ivB64;
    return Uint8List.fromList(const [9, 9, 9]);
  }
}

void main() {
  group('loadDecryptedMediaBytes', () {
    test('no key/iv returns raw fetched bytes without decrypting', () async {
      final api = _FakeApi(Uint8List.fromList(const [1, 2, 3]));
      final crypto = _FakeCrypto();

      final out = await loadDecryptedMediaBytes(
        url: 'u',
        api: api,
        crypto: crypto,
      );

      expect(out, [1, 2, 3]);
      expect(crypto.called, isFalse);
      expect(api.lastUrl, 'u');
    });

    test('decrypts when both key and iv are present', () async {
      final api = _FakeApi(Uint8List.fromList(const [4, 5]));
      final crypto = _FakeCrypto();

      final out = await loadDecryptedMediaBytes(
        url: 'u',
        key: 'K',
        iv: 'IV',
        api: api,
        crypto: crypto,
      );

      expect(out, [9, 9, 9]);
      expect(crypto.called, isTrue);
      expect(crypto.key, 'K');
      expect(crypto.iv, 'IV');
    });

    test('key without iv returns raw bytes without decrypting', () async {
      final api = _FakeApi(Uint8List.fromList(const [1, 2, 3]));
      final crypto = _FakeCrypto();

      final out = await loadDecryptedMediaBytes(
        url: 'u',
        key: 'K',
        api: api,
        crypto: crypto,
      );

      expect(out, [1, 2, 3]);
      expect(crypto.called, isFalse);
    });

    test('iv without key returns raw bytes without decrypting', () async {
      final api = _FakeApi(Uint8List.fromList(const [1, 2, 3]));
      final crypto = _FakeCrypto();

      final out = await loadDecryptedMediaBytes(
        url: 'u',
        iv: 'IV',
        api: api,
        crypto: crypto,
      );

      expect(out, [1, 2, 3]);
      expect(crypto.called, isFalse);
    });

    test('throws when fetched media exceeds the size cap', () async {
      final api = _FakeApi(Uint8List(MediaCryptoService.maxBytes + 1));

      expect(
        () => loadDecryptedMediaBytes(url: 'u', api: api),
        throwsA(isA<Exception>()),
      );
    });

    test(
      'keyed media: the AES-GCM tag fits under the cap, one byte more does '
      'not',
      () async {
        // The sender gates the PLAINTEXT at maxBytes; the ciphertext it
        // uploads is 16 bytes longer. A receiver that compared the
        // ciphertext against maxBytes refused every clip in the last 16
        // bytes under the cap — sent fine, never played anywhere.
        final crypto = _FakeCrypto();
        final atTag = _FakeApi(Uint8List(MediaCryptoService.maxBytes + 16));
        final out = await loadDecryptedMediaBytes(
          url: 'u',
          key: 'k',
          iv: 'i',
          api: atTag,
          crypto: crypto,
        );
        expect(out, [9, 9, 9]);
        expect(crypto.called, isTrue);

        final overTag = _FakeApi(Uint8List(MediaCryptoService.maxBytes + 17));
        expect(
          () => loadDecryptedMediaBytes(
            url: 'u',
            key: 'k',
            iv: 'i',
            api: overTag,
            crypto: _FakeCrypto(),
          ),
          throwsA(isA<Exception>()),
        );
      },
    );
  });
}
