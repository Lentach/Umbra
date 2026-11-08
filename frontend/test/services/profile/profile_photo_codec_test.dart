import 'dart:math';
import 'dart:typed_data';

import 'package:fireplace/services/profile/profile_photo_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../support/profile_photo_fakes.dart';

/// A real encoder's JPEG of a [width] x [height] flat image.
Uint8List realJpeg(int width, int height) => Uint8List.fromList(
  img.encodeJpg(
    img.Image(width: width, height: height)..clear(img.ColorRgb8(30, 120, 200)),
  ),
);

void main() {
  group('isSound: a received file is vouched for before anything decodes it',
      () {
    test('a JPEG within the accepted size is sound, baseline or progressive',
        () {
      for (final marker in [0xC0, 0xC1, 0xC2]) {
        expect(
          ProfilePhotoCodec.isSound(jpegHeader(256, 256, marker: marker)),
          isTrue,
          reason: 'SOF 0x${marker.toRadixString(16)}',
        );
      }
      expect(ProfilePhotoCodec.isSound(jpegHeader(1, 1)), isTrue);
      expect(ProfilePhotoCodec.isSound(jpegHeader(256, 171)), isTrue);
    });

    test('the accepted side is 1024 inclusive, width and height alike', () {
      expect(ProfilePhotoCodec.isSound(jpegHeader(1024, 1024)), isTrue);
      expect(ProfilePhotoCodec.isSound(jpegHeader(1024, 17)), isTrue);
      expect(ProfilePhotoCodec.isSound(jpegHeader(17, 1024)), isTrue);
      expect(ProfilePhotoCodec.isSound(jpegHeader(1025, 17)), isFalse);
      expect(ProfilePhotoCodec.isSound(jpegHeader(17, 1025)), isFalse);
      expect(ProfilePhotoCodec.isSound(jpegHeader(1025, 1025)), isFalse);
    });

    test('a header that claims a decompression bomb is not sound', () {
      expect(ProfilePhotoCodec.isSound(jpegHeader(65535, 65535)), isFalse);
      expect(ProfilePhotoCodec.isSound(jpegHeader(60000, 60000)), isFalse);
      expect(ProfilePhotoCodec.isSound(jpegHeader(65535, 1)), isFalse);
    });

    test('a zero side is not sound', () {
      expect(ProfilePhotoCodec.isSound(jpegHeader(0, 256)), isFalse);
      expect(ProfilePhotoCodec.isSound(jpegHeader(256, 0)), isFalse);
      expect(ProfilePhotoCodec.isSound(jpegHeader(0, 0)), isFalse);
    });

    test('fill bytes and restart markers before the frame are walked over',
        () {
      expect(
        ProfilePhotoCodec.isSound(
          jpegHeader(200, 100, prefix: [0xFF, 0xFF, 0xFF, 0xD0, 0xFF, 0x01]),
        ),
        isTrue,
      );
    });

    test('only a frame marker states a size: a table that merely follows '
        'is not one', () {
      final bytes = Uint8List.fromList([
        0xFF, 0xD8, //
        0xFF, 0xC4, 0x00, 0x05, 1, 2, 3, // DHT
        0xFF, 0xC8, 0x00, 0x04, 1, 2, // JPG extension
        0xFF, 0xCC, 0x00, 0x04, 1, 2, // DAC
      ]);
      expect(ProfilePhotoCodec.isSound(bytes), isFalse);
      // …and a DHT between SOI and the frame does not hide a frame's size.
      final dhtFirst = Uint8List.fromList([
        0xFF, 0xD8, //
        0xFF, 0xC4, 0x00, 0x05, 1, 2, 3,
        ...jpegHeader(5000, 5000).sublist(2),
      ]);
      expect(ProfilePhotoCodec.isSound(dhtFirst), isFalse);
      // The same walk, a small frame behind the same table: sound — so the
      // refusal above is the frame's size, not the table that precedes it.
      final smallAfterDht = Uint8List.fromList([
        0xFF, 0xD8, //
        0xFF, 0xC4, 0x00, 0x05, 1, 2, 3,
        ...jpegHeader(64, 64).sublist(2),
      ]);
      expect(ProfilePhotoCodec.isSound(smallAfterDht), isTrue);
    });

    test("a real encoder's JPEG is sound; the same one too wide is not", () {
      expect(ProfilePhotoCodec.isSound(realJpeg(40, 30)), isTrue);
      expect(ProfilePhotoCodec.isSound(realJpeg(256, 256)), isTrue);
      expect(ProfilePhotoCodec.isSound(realJpeg(1024, 4)), isTrue);
      expect(ProfilePhotoCodec.isSound(realJpeg(1030, 4)), isFalse);
    });

    test('bytes that are no JPEG are not sound', () {
      final png = Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));
      final gif = Uint8List.fromList(
        img.encodeGif(img.Image(width: 8, height: 8)),
      );
      for (final bytes in [
        Uint8List(0),
        Uint8List(1),
        Uint8List.fromList([0xFF]),
        Uint8List.fromList([0xFF, 0xD8]),
        Uint8List.fromList([0xFF, 0xD8, 0xFF]),
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
        Uint8List(256),
        Uint8List.fromList(List.filled(64, 0xFF)),
        png,
        gif,
        Uint8List.fromList('<html>not a photo</html>'.codeUnits),
      ]) {
        expect(ProfilePhotoCodec.isSound(bytes), isFalse, reason: '$bytes');
      }
    });

    test('the SOI alone, or another first byte, is not enough', () {
      final good = jpegHeader(256, 256);
      expect(ProfilePhotoCodec.isSound(good), isTrue);
      expect(
        ProfilePhotoCodec.isSound(Uint8List.fromList([0xFE, ...good.skip(1)])),
        isFalse,
      );
      expect(
        ProfilePhotoCodec.isSound(Uint8List.fromList([0xFF, 0xD9, ...good.skip(2)])),
        isFalse,
      );
    });

    test('a header cut before it states the size is not sound, at any cut',
        () {
      final good = jpegHeader(256, 256);
      // The header is vouched for by the size it states, read from the
      // markers: the frame header's last 4 bytes (the sizes) must be in.
      // The rest of the file is the decoder's to refuse.
      const sizeEndsBeforeEnd = 4;
      for (var cut = 0; cut < good.length - sizeEndsBeforeEnd; cut++) {
        expect(
          ProfilePhotoCodec.isSound(Uint8List.sublistView(good, 0, cut)),
          isFalse,
          reason: 'cut at $cut of ${good.length}',
        );
      }
      expect(ProfilePhotoCodec.isSound(good), isTrue);
    });

    test('a segment whose length runs past the file, or says less than its '
        'own length bytes, ends the walk', () {
      expect(
        ProfilePhotoCodec.isSound(
          Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xFF, 1, 2, 3, 4]),
        ),
        isFalse,
      );
      for (final length in [0, 1]) {
        expect(
          ProfilePhotoCodec.isSound(
            Uint8List.fromList([
              0xFF, 0xD8, 0xFF, 0xE0, 0x00, length, //
              ...jpegHeader(8, 8).skip(2),
            ]),
          ),
          isFalse,
          reason: 'length $length',
        );
      }
    });

    test('a stream that never reaches a frame header ends, whatever it holds',
        () {
      // SOS before any SOF: entropy data is not a marker.
      expect(
        ProfilePhotoCodec.isSound(
          Uint8List.fromList([
            0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x04, 1, 2, 0x12, 0x34, 0x56, 0x78, //
            ...jpegHeader(8, 8).skip(2),
          ]),
        ),
        isFalse,
      );
    });

    test('arbitrary hostile bytes behind a SOI never throw or hang', () {
      final random = Random(138);
      for (var n = 0; n < 500; n++) {
        final bytes = Uint8List.fromList([
          0xFF,
          0xD8,
          for (var i = 0; i < 1 + random.nextInt(300); i++)
            random.nextInt(4) == 0 ? 0xFF : random.nextInt(256),
        ]);
        // Whatever it answers, it answers: a thrown RangeError would lose
        // the friend's whole frame.
        expect(() => ProfilePhotoCodec.isSound(bytes), returnsNormally);
      }
    });
  });

  group('scale: what this device sends', () {
    // dart:ui's codec needs the real engine: `runAsync` lets it finish.
    Future<Uint8List?> scaled(WidgetTester tester, Uint8List picked) async =>
        tester.runAsync<Uint8List?>(() => ProfilePhotoCodec.scale(picked));

    testWidgets('a large photo comes out a sound JPEG within 256 px, aspect '
        'kept', (tester) async {
      final big = Uint8List.fromList(
        img.encodePng(
          img.Image(width: 900, height: 600)
            ..clear(img.ColorRgb8(200, 30, 60)),
        ),
      );
      final out = await scaled(tester, big);

      expect(out, isNotNull);
      expect(ProfilePhotoCodec.isSound(out!), isTrue);
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, 256);
      expect(decoded.height, 171); // 600 * 256 / 900, rounded
      expect(out.length, lessThan(ProfilePhotoCodec.kMaxCiphertextBytes));
    });

    testWidgets('a tall photo is bounded by its height', (tester) async {
      final tall = Uint8List.fromList(
        img.encodePng(img.Image(width: 300, height: 1200)),
      );
      final decoded = img.decodeJpg((await scaled(tester, tall))!)!;
      expect(decoded.height, 256);
      expect(decoded.width, 64);
    });

    testWidgets('a small photo is never scaled UP', (tester) async {
      final small = Uint8List.fromList(
        img.encodePng(img.Image(width: 40, height: 30)),
      );
      final decoded = img.decodeJpg((await scaled(tester, small))!)!;
      expect(decoded.width, 40);
      expect(decoded.height, 30);
    });

    testWidgets('a JPEG picked from the gallery is accepted as input',
        (tester) async {
      final out = await scaled(tester, realJpeg(800, 800));
      expect(out, isNotNull);
      final decoded = img.decodeJpg(out!)!;
      expect([decoded.width, decoded.height], [256, 256]);
    });

    testWidgets('transparency is flattened on white, never black',
        (tester) async {
      final clear = Uint8List.fromList(
        img.encodePng(
          img.Image(width: 64, height: 64, numChannels: 4)
            ..clear(img.ColorRgba8(0, 0, 0, 0)),
        ),
      );
      final decoded = img.decodeJpg((await scaled(tester, clear))!)!;
      final pixel = decoded.getPixel(32, 32);
      expect(pixel.r, greaterThan(240));
      expect(pixel.g, greaterThan(240));
      expect(pixel.b, greaterThan(240));
    });

    testWidgets('bytes that are no image are null, not an exception',
        (tester) async {
      expect(await scaled(tester, Uint8List(0)), isNull);
      expect(await scaled(tester, Uint8List.fromList(List.filled(200, 7))), isNull);
      expect(
        await scaled(tester, Uint8List.fromList('not an image'.codeUnits)),
        isNull,
      );
    });
  });
}
