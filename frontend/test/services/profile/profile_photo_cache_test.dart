import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/services/box/box_media_store.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/profile/profile_photo_cache.dart';
import 'package:fireplace/services/profile/profile_photo_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../support/profile_photo_fakes.dart';

/// A store that counts its reads and can be made to fail or to wait.
class _WatchedStore extends MemoryBoxMediaStore {
  int gets = 0;
  bool broken = false;
  Completer<void>? gate;

  @override
  Future<Uint8List?> get(int userId, Uint8List id) async {
    gets++;
    await gate?.future;
    if (broken) throw StateError('disk');
    return super.get(userId, id);
  }
}

/// The reference number [n] of a photo handed to the cache without a
/// download: a distinct media id per [n].
ProfilePhotoRef _refAt(int n) => ProfilePhotoRef(
  rev: 1,
  mediaId: boxB64(Uint8List(32)..[0] = n >> 8..[1] = n & 0xFF),
  key: base64.encode(List.filled(32, 5)),
  iv: base64.encode(List.filled(12, 6)),
);

void main() {
  late TagMediaCrypto crypto;
  late TagMediaCrypto sender;
  late ProfilePhotoCache cache;
  late int told;
  final plain = fakeJpeg(1);

  setUp(() {
    crypto = TagMediaCrypto();
    sender = TagMediaCrypto();
    cache = ProfilePhotoCache(crypto: crypto);
    told = 0;
    cache.addListener(() => told++);
  });

  tearDown(() => cache.dispose());

  Future<({ProfilePhotoRef ref, Uint8List ciphertext})> sealed({
    Uint8List? file,
    int idFill = 1,
  }) => sealPhoto(sender, file ?? plain, idFill: idFill);

  group('ingest: a downloaded file becomes a photo only if it passes', () {
    test('a file that authenticates under the key is held and shown',
        () async {
      final s = await sealed();
      expect(await cache.ingest(s.ref, s.ciphertext), isTrue);
      expect(cache.bytesFor(s.ref), plain);
      expect(told, 1);
    });

    test('a file under a key it was not sealed with is refused, and never '
        'shown', () async {
      final s = await sealed();
      final other = await sealed(file: fakeJpeg(2), idFill: 2);
      // The reference names this id but carries the OTHER file's key.
      final lying = ProfilePhotoRef(
        rev: 1,
        mediaId: s.ref.mediaId!,
        key: other.ref.key!,
        iv: other.ref.iv!,
      );
      expect(await cache.ingest(lying, s.ciphertext), isFalse);
      expect(cache.bytesFor(lying), isNull);
      expect(told, 0);
    });

    test('a ciphertext with a flipped byte in its tag is refused', () async {
      final s = await sealed();
      final tampered = Uint8List.fromList(s.ciphertext)
        ..[s.ciphertext.length - 1] ^= 0x01;
      expect(await cache.ingest(s.ref, tampered), isFalse);
      expect(cache.bytesFor(s.ref), isNull);
    });

    test('a file that decrypts to something that is no JPEG is refused',
        () async {
      final png = Uint8List.fromList(
        img.encodePng(img.Image(width: 8, height: 8)),
      );
      var fill = 1;
      for (final notAPhoto in [
        png,
        Uint8List.fromList('<html>hi</html>'.codeUnits),
        Uint8List(0),
      ]) {
        final s = await sealed(file: notAPhoto, idFill: fill++);
        expect(await cache.ingest(s.ref, s.ciphertext), isFalse);
        expect(cache.bytesFor(s.ref), isNull);
      }
      expect(told, 0);
    });

    test('a JPEG that claims more than 1024 px a side is refused: it never '
        'reaches the decoder', () async {
      final bomb = await sealed(file: jpegHeader(5000, 5000));
      expect(await cache.ingest(bomb.ref, bomb.ciphertext), isFalse);
      expect(cache.bytesFor(bomb.ref), isNull);
      final edge = await sealed(file: jpegHeader(1024, 1024), idFill: 2);
      expect(await cache.ingest(edge.ref, edge.ciphertext), isTrue);
    });

    test('a ciphertext over the 256 KiB rung is refused UNOPENED', () async {
      final s = await sealed();
      final big = Uint8List(ProfilePhotoCodec.kMaxCiphertextBytes + 1);
      expect(await cache.ingest(s.ref, big), isFalse);
      expect(crypto.decrypts, 0);
      expect(cache.bytesFor(s.ref), isNull);
    });

    test('exactly 256 KiB of ciphertext is opened', () async {
      final head = jpegHeader(100, 100);
      final big = jpegHeader(
        100,
        100,
        tail: List.filled(
          ProfilePhotoCodec.kMaxCiphertextBytes - 16 - head.length,
          7,
        ),
      );
      final s = await sealed(file: big);
      expect(s.ciphertext.length, ProfilePhotoCodec.kMaxCiphertextBytes);
      expect(await cache.ingest(s.ref, s.ciphertext), isTrue);
    });

    test('a cleared reference names no file: false, nothing opened', () async {
      final s = await sealed();
      expect(
        await cache.ingest(const ProfilePhotoRef.cleared(3), s.ciphertext),
        isFalse,
      );
      expect(crypto.decrypts, 0);
    });

    test('a photo already held is not opened again', () async {
      final s = await sealed();
      await cache.ingest(s.ref, s.ciphertext);
      expect(await cache.ingest(s.ref, s.ciphertext), isTrue);
      expect(crypto.decrypts, 1);
      expect(told, 1);
    });
  });

  group('bytesFor', () {
    test('a cleared or absent reference shows nothing and asks nobody',
        () async {
      final store = _WatchedStore();
      cache.bind(store: store, userId: 1);
      expect(cache.bytesFor(null), isNull);
      expect(cache.bytesFor(const ProfilePhotoRef.cleared(4)), isNull);
      await pumpEventQueue();
      expect(store.gets, 0);
      expect(told, 0);
    });

    test('a photo not shown yet is read from the device store in the '
        'background, then the widgets are told', () async {
      final s = await sealed();
      final store = _WatchedStore();
      await store.put(1, s.ref.mediaIdBytes!, s.ciphertext);
      cache.bind(store: store, userId: 1);

      expect(cache.bytesFor(s.ref), isNull, reason: 'never blocks a frame');
      expect(told, 0);
      await pumpEventQueue();
      expect(told, 1);
      expect(cache.bytesFor(s.ref), plain);
    });

    test('the store is asked ONCE for a file it does not have; a download '
        'that lands later is shown', () async {
      final s = await sealed();
      final store = _WatchedStore();
      cache.bind(store: store, userId: 1);

      for (var i = 0; i < 5; i++) {
        expect(cache.bytesFor(s.ref), isNull);
        await pumpEventQueue();
      }
      expect(store.gets, 1);
      expect(told, 0);

      await cache.ingest(s.ref, s.ciphertext);
      expect(cache.bytesFor(s.ref), plain);
    });

    test('a stored file that is no sound photo is never shown nor read '
        'again', () async {
      final s = await sealed(file: Uint8List.fromList([1, 2, 3, 4, 5, 6]));
      final store = _WatchedStore();
      await store.put(1, s.ref.mediaIdBytes!, s.ciphertext);
      cache.bind(store: store, userId: 1);

      for (var i = 0; i < 3; i++) {
        expect(cache.bytesFor(s.ref), isNull);
        await pumpEventQueue();
      }
      expect(store.gets, 1);
      expect(told, 0);
    });

    test('a store that fails is "not here", never an error out of a frame',
        () async {
      final s = await sealed();
      final store = _WatchedStore()..broken = true;
      cache.bind(store: store, userId: 1);
      expect(cache.bytesFor(s.ref), isNull);
      await pumpEventQueue();
      expect(cache.bytesFor(s.ref), isNull);
      expect(told, 0);
    });

    test('a cache bound to no store shows only what it was handed',
        () async {
      final s = await sealed();
      expect(cache.bytesFor(s.ref), isNull);
      await pumpEventQueue();
      await cache.ingest(s.ref, s.ciphertext);
      expect(cache.bytesFor(s.ref), plain);
    });

    test('a read that finishes after the account changed shows nothing of '
        'the old one', () async {
      final s = await sealed();
      final store = _WatchedStore();
      await store.put(1, s.ref.mediaIdBytes!, s.ciphertext);
      final gate = store.gate = Completer<void>();
      cache.bind(store: store, userId: 1);
      expect(cache.bytesFor(s.ref), isNull);

      cache.bind(store: _WatchedStore(), userId: 2);
      gate.complete();
      await pumpEventQueue();

      expect(cache.bytesFor(s.ref), isNull);
      expect(told, 0);
    });
  });

  group('remember: a photo this device just made', () {
    test('is held without a decrypt, and shown', () {
      final ref = _refAt(3);
      expect(cache.remember(ref, plain), isTrue);
      expect(cache.bytesFor(ref), plain);
      expect(crypto.decrypts, 0);
      expect(told, 1);
    });

    test('a cleared reference, or a file that is no sound photo, is refused',
        () {
      final ref = _refAt(3);
      expect(cache.remember(const ProfilePhotoRef.cleared(2), plain), isFalse);
      expect(cache.remember(ref, Uint8List.fromList([1, 2, 3, 4, 5])), isFalse);
      expect(cache.remember(ref, jpegHeader(4000, 10)), isFalse);
      expect(cache.bytesFor(ref), isNull);
      expect(told, 0);
    });
  });

  group('forget', () {
    test('drops the decrypted photo and tells the widgets', () async {
      final s = await sealed();
      await cache.ingest(s.ref, s.ciphertext);
      told = 0;
      cache.forget(s.ref.mediaId);
      expect(told, 1);
      expect(cache.bytesFor(s.ref), isNull);
    });

    test('forgetting what is not held, or nothing, is quiet', () {
      cache.forget('nope');
      cache.forget(null);
      expect(told, 0);
    });

    test('a forgotten photo is read again from the store when asked for, '
        'not stuck as "not here"', () async {
      final s = await sealed();
      final store = _WatchedStore();
      cache.bind(store: store, userId: 1);
      expect(cache.bytesFor(s.ref), isNull);
      await pumpEventQueue();
      expect(store.gets, 1);

      cache.forget(s.ref.mediaId);
      await store.put(1, s.ref.mediaIdBytes!, s.ciphertext);
      expect(cache.bytesFor(s.ref), isNull);
      await pumpEventQueue();
      expect(store.gets, 2);
      expect(cache.bytesFor(s.ref), plain);
    });
  });

  group('the size cap', () {
    test('the oldest photo goes first once more than 256 are held', () {
      for (var n = 0; n <= ProfilePhotoCache.maxEntries; n++) {
        expect(cache.remember(_refAt(n), fakeJpeg(n)), isTrue);
      }
      expect(cache.bytesFor(_refAt(0)), isNull, reason: 'the oldest is gone');
      expect(cache.bytesFor(_refAt(1)), isNotNull);
      expect(cache.bytesFor(_refAt(ProfilePhotoCache.maxEntries)), isNotNull);
    });

    test('a photo shown again counts as the newest, not the oldest', () {
      for (var n = 0; n < ProfilePhotoCache.maxEntries; n++) {
        cache.remember(_refAt(n), fakeJpeg(n));
      }
      cache.remember(_refAt(0), fakeJpeg()); // the oldest, made again
      cache.remember(_refAt(ProfilePhotoCache.maxEntries), fakeJpeg(9));
      expect(cache.bytesFor(_refAt(0)), isNotNull);
      expect(cache.bytesFor(_refAt(1)), isNull, reason: 'now the oldest');
    });
  });

  group('bind / unbind', () {
    test('another account starts empty; the same account keeps its photos',
        () async {
      final s = await sealed();
      cache.bind(store: _WatchedStore(), userId: 1);
      await cache.ingest(s.ref, s.ciphertext);

      cache.bind(store: _WatchedStore(), userId: 1);
      expect(cache.bytesFor(s.ref), plain, reason: 'a reconnect, same user');

      told = 0;
      cache.bind(store: _WatchedStore(), userId: 2);
      expect(cache.bytesFor(s.ref), isNull);
      expect(told, 1);
    });

    test('unbind forgets everything and stops reading a store', () async {
      final s = await sealed();
      final store = _WatchedStore();
      await store.put(1, s.ref.mediaIdBytes!, s.ciphertext);
      cache.bind(store: store, userId: 1);
      await cache.ingest(s.ref, s.ciphertext);
      expect(cache.bytesFor(s.ref), plain);

      cache.unbind();
      expect(cache.bytesFor(s.ref), isNull);
      await pumpEventQueue();
      expect(store.gets, 0, reason: 'no store to read after sign-out');
      expect(cache.bytesFor(s.ref), isNull);
    });

    test('what was refused for one account is asked again for the next',
        () async {
      final s = await sealed();
      final first = _WatchedStore();
      await first.put(1, s.ref.mediaIdBytes!, Uint8List(3)); // not a file
      cache.bind(store: first, userId: 1);
      expect(cache.bytesFor(s.ref), isNull);
      await pumpEventQueue();
      expect(cache.bytesFor(s.ref), isNull);

      final second = _WatchedStore();
      await second.put(2, s.ref.mediaIdBytes!, s.ciphertext);
      cache.bind(store: second, userId: 2);
      expect(cache.bytesFor(s.ref), isNull);
      await pumpEventQueue();
      expect(cache.bytesFor(s.ref), plain);
    });
  });
}
