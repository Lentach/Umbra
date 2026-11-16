import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/utils/media_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../support/media_metadata_fixtures.dart';

const _jpegSecrets = [
  'SECRET-EXIF-MODEL',
  'SECRET-GPS',
  'SECRET-XMP',
  'SECRET-IPTC',
  'SECRET-COMMENT',
  'SECRET-MPF',
  'SECRET-TAIL',
];

void _expectNoSecret(Uint8List bytes, Iterable<String> secrets) {
  for (final secret in secrets) {
    expect(containsAscii(bytes, secret), isFalse, reason: secret);
  }
}

List<int> _pixels(img.Image? decoded) => decoded!.getBytes();

void main() {
  group('a photo (JPEG)', () {
    test(
      'loses Exif, GPS, XMP, IPTC, comments, MPF and the image after EOI, '
      'keeps its ICC profile, and decodes to the same pixels',
      () {
        final original = jpegWithCameraMetadata();
        expect(containsAscii(original, 'SECRET-GPS'), isTrue);

        final out = scrubImageMetadata(original);

        _expectNoSecret(out.bytes, _jpegSecrets);
        expect(containsAscii(out.bytes, 'KEEP-ICC'), isTrue);
        expect(out.scrubbed, greaterThan(0));
        expect(
          _pixels(img.decodeJpg(out.bytes)),
          _pixels(img.decodeJpg(original)),
        );
      },
    );

    test('keeps a turned photo turned: the orientation survives alone', () {
      final out = scrubImageMetadata(jpegWithCameraMetadata());

      final exif = img.decodeJpgExif(out.bytes)!;
      expect(exif.imageIfd.orientation, 6);
      expect(exif.gpsIfd.isEmpty, isTrue);
    });

    test('an upright photo keeps no Exif at all', () {
      final out = scrubImageMetadata(jpegWithCameraMetadata(orientation: 1));

      expect(img.decodeJpgExif(out.bytes)?.imageIfd.orientation, isNull);
      _expectNoSecret(out.bytes, _jpegSecrets);
    });

    test('a JPEG cut short is left as it was', () {
      final whole = jpegWithCameraMetadata();
      final cut = Uint8List.sublistView(whole, 0, 40);

      final out = scrubImageMetadata(cut);
      expect(out.scrubbed, 0);
      expect(out.bytes, cut);
    });
  });

  test(
    'a PNG loses its text, Exif and time chunks and what follows IEND, and '
    'decodes to the same pixels',
    () {
      final original = pngWithMetadata();

      final out = scrubImageMetadata(original);

      _expectNoSecret(out.bytes, const [
        'SECRET-PNG-TEXT',
        'SECRET-PNG-EXIF',
        'SECRET-PNG-TAIL',
      ]);
      expect(containsAscii(out.bytes, 'tIME'), isFalse);
      expect(
        _pixels(img.decodePng(out.bytes)),
        _pixels(img.decodePng(original)),
      );
    },
  );

  test(
    'a WebP loses its EXIF and XMP chunks and their VP8X flags; the RIFF '
    'size matches and every other chunk is untouched',
    () {
      final out = scrubImageMetadata(webpWithMetadata());

      _expectNoSecret(out.bytes, const ['SECRET-WEBP-EXIF', 'SECRET-WEBP-XMP']);
      final data = ByteData.sublistView(out.bytes);
      expect(data.getUint32(4, Endian.little), out.bytes.length - 8);
      expect(out.bytes[20], 0x10, reason: 'only the alpha flag is left');
      expect(containsAscii(out.bytes, 'KEEP-ICC'), isTrue);
      expect(containsAscii(out.bytes, 'VP8L'), isTrue);
      // VP8L's odd payload keeps its pad byte: the file ends right after it.
      expect(out.bytes.sublist(out.bytes.length - 6), [1, 2, 3, 4, 5, 0]);
    },
  );

  test('a GIF or anything unknown is left as it was', () {
    final gif = Uint8List.fromList([...ascii.encode('GIF89a'), 1, 2, 3]);
    final out = scrubImageMetadata(gif);
    expect(out.scrubbed, 0);
    expect(identical(out.bytes, gif), isTrue);
  });

  group('a video (MP4/MOV)', () {
    test(
      'loses the location, Apple keys, track names and XMP, and keeps its '
      'exact size and every other byte',
      () {
        final original = mp4WithLocation();
        final video = Uint8List.fromList(original);

        final scrubbed = scrubVideoMetadataInPlace(video);

        expect(scrubbed, greaterThan(0));
        expect(video.length, original.length);
        _expectNoSecret(video, const [
          'SECRET+52.2297',
          'SECRET-APPLE',
          'SECRET-TRACK-NAME',
          'SECRET-MP4-XMP',
        ]);
        var changed = 0;
        for (var i = 0; i < video.length; i++) {
          if (video[i] != original[i]) changed++;
        }
        // Only the zeroed payloads and the four renamed type fields moved.
        expect(changed, lessThanOrEqualTo(scrubbed + 4 * 4));
        expect(containsAscii(video, 'free'), isTrue);
        expect(
          video.sublist(video.length - fixtureMdat.length),
          fixtureMdat,
          reason: 'the samples are untouched',
        );
        expect(containsAscii(video, 'mvhd'), isTrue);
        expect(containsAscii(video, 'tkhd'), isTrue);
        expect(containsAscii(video, 'mdia'), isTrue);
      },
    );

    test('a box that runs past its parent leaves the whole file untouched', () {
      final original = mp4WithLocation();
      // moov's size now claims one byte more than the file holds.
      final moovAt = ByteData.sublistView(original).getUint32(0);
      final video = Uint8List.fromList(original);
      ByteData.sublistView(video).setUint32(moovAt, original.length);

      final before = Uint8List.fromList(video);
      expect(scrubVideoMetadataInPlace(video), 0);
      expect(video, before);
    });

    test('a WebM (not ISO BMFF) is left as it was', () {
      final webm = Uint8List.fromList([0x1a, 0x45, 0xdf, 0xa3, 0, 0, 0, 0, 1]);
      expect(scrubVideoMetadataInPlace(webm), 0);
    });
  });
}
