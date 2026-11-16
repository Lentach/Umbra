import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Camera-style files carrying metadata a friend must never receive (plan
/// A2). Each secret is an ASCII marker: finding it in the scrubbed bytes
/// means that metadata survived.

/// A 4×2 picture with distinct pixels, so a re-encode or a shifted scan
/// would show in a pixel compare.
img.Image fixturePicture() {
  final picture = img.Image(width: 4, height: 2);
  for (var y = 0; y < 2; y++) {
    for (var x = 0; x < 4; x++) {
      picture.setPixelRgb(x, y, x * 60, y * 120, 200 - x * 40);
    }
  }
  return picture;
}

bool containsAscii(Uint8List haystack, String needle) {
  final n = ascii.encode(needle);
  outer:
  for (var i = 0; i + n.length <= haystack.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

Uint8List _jpegSegment(int marker, List<int> payload) {
  final out = Uint8List(4 + payload.length);
  ByteData.sublistView(out)
    ..setUint16(0, 0xff00 | marker)
    ..setUint16(2, payload.length + 2);
  out.setRange(4, out.length, payload);
  return out;
}

/// `Exif\0\0` + a little-endian TIFF whose IFD0 holds [orientation], an
/// ImageDescription and a GPS IFD with a latitude reference string.
List<int> _exifPayload(int orientation) {
  final b = BytesBuilder();
  final tiff = ByteData(256);
  var o = 0;
  void u16(int v) {
    tiff.setUint16(o, v, Endian.little);
    o += 2;
  }

  void u32(int v) {
    tiff.setUint32(o, v, Endian.little);
    o += 4;
  }

  const description = 'SECRET-EXIF-MODEL\x00';
  const gps = 'SECRET-GPS-52.2297N\x00';
  // Header.
  tiff
    ..setUint8(0, 0x49)
    ..setUint8(1, 0x49);
  o = 2;
  u16(42);
  u32(8);
  // IFD0: 3 entries at 8; data after it.
  const ifd0 = 8;
  const ifd0Size = 2 + 3 * 12 + 4;
  const descAt = ifd0 + ifd0Size;
  const gpsIfd = descAt + description.length;
  const gpsAt = gpsIfd + 2 + 12 + 4;
  u16(3);
  u16(0x010e); // ImageDescription
  u16(2);
  u32(description.length);
  u32(descAt);
  u16(0x0112); // Orientation
  u16(3);
  u32(1);
  u16(orientation);
  u16(0);
  u16(0x8825); // GPS IFD pointer
  u16(4);
  u32(1);
  u32(gpsIfd);
  u32(0);
  final bytes = tiff.buffer.asUint8List()
    ..setRange(descAt, descAt + description.length, ascii.encode(description));
  o = gpsIfd;
  u16(1);
  u16(0x0002); // GPSLatitude, stored as text here: only its bytes matter
  u16(2);
  u32(gps.length);
  u32(gpsAt);
  u32(0);
  bytes.setRange(gpsAt, gpsAt + gps.length, ascii.encode(gps));
  b
    ..add(ascii.encode('Exif\x00\x00'))
    ..add(bytes.sublist(0, gpsAt + gps.length));
  return b.takeBytes();
}

/// [fixturePicture] as a baseline JPEG with what a phone camera adds: Exif
/// (orientation, model, GPS), XMP, IPTC (APP13), a comment, an MPF APP2, an
/// ICC profile APP2 (kept), and a second image after EOI.
Uint8List jpegWithCameraMetadata({int orientation = 6}) {
  final plain = img.encodeJpg(fixturePicture(), quality: 99);
  final b = BytesBuilder()
    ..add(plain.sublist(0, 2))
    ..add(_jpegSegment(0xe1, _exifPayload(orientation)))
    ..add(
      _jpegSegment(0xe1, [
        ...ascii.encode('http://ns.adobe.com/xap/1.0/\x00'),
        ...ascii.encode('<x:xmpmeta>SECRET-XMP-LOCATION</x:xmpmeta>'),
      ]),
    )
    ..add(_jpegSegment(0xed, ascii.encode('Photoshop 3.0\x00SECRET-IPTC')))
    ..add(_jpegSegment(0xfe, ascii.encode('SECRET-COMMENT')))
    ..add(_jpegSegment(0xe2, ascii.encode('MPF\x00SECRET-MPF-INDEX')))
    ..add(_jpegSegment(0xe2, ascii.encode('ICC_PROFILE\x00\x01\x01KEEP-ICC')))
    ..add(plain.sublist(2))
    ..add([0xff, 0xd8, 0xff, 0xfe, 0x00, 0x0e])
    ..add(ascii.encode('SECRET-TAIL!'))
    ..add([0xff, 0xd9]);
  return b.takeBytes();
}

Uint8List _pngChunk(String type, List<int> data) {
  final out = Uint8List(12 + data.length);
  ByteData.sublistView(out).setUint32(0, data.length);
  out
    ..setRange(4, 8, ascii.encode(type))
    ..setRange(8, 8 + data.length, data);
  // The CRC is left zero: only these dropped chunks carry a bad one.
  return out;
}

/// [fixturePicture] as a PNG with text, Exif and time chunks before IEND and
/// bytes after it.
Uint8List pngWithMetadata() {
  final plain = img.encodePng(fixturePicture());
  final iend = plain.length - 12;
  return (BytesBuilder()
        ..add(plain.sublist(0, iend))
        ..add(_pngChunk('tEXt', ascii.encode('Comment\x00SECRET-PNG-TEXT')))
        ..add(_pngChunk('eXIf', ascii.encode('MM\x00*SECRET-PNG-EXIF')))
        ..add(_pngChunk('tIME', [7, 234, 11, 16, 12, 0, 0]))
        ..add(plain.sublist(iend))
        ..add(ascii.encode('SECRET-PNG-TAIL')))
      .takeBytes();
}

Uint8List _riffChunk(String fourcc, List<int> data) {
  final out = Uint8List(8 + data.length + (data.length.isOdd ? 1 : 0))
    ..setRange(0, 4, ascii.encode(fourcc))
    ..setRange(8, 8 + data.length, data);
  ByteData.sublistView(out).setUint32(4, data.length, Endian.little);
  return out;
}

/// A WebP container (its image chunk is opaque bytes here: only the
/// container is under test) with EXIF and XMP chunks and their VP8X flags.
Uint8List webpWithMetadata() {
  final body = BytesBuilder()
    ..add(ascii.encode('WEBP'))
    ..add(_riffChunk('VP8X', [0x0c | 0x10, 0, 0, 0, 3, 0, 0, 1, 0, 0]))
    ..add(_riffChunk('ICCP', ascii.encode('KEEP-ICC')))
    ..add(_riffChunk('VP8L', [1, 2, 3, 4, 5]))
    ..add(_riffChunk('EXIF', ascii.encode('SECRET-WEBP-EXIF')))
    ..add(_riffChunk('XMP ', ascii.encode('SECRET-WEBP-XMP')));
  final chunks = body.takeBytes();
  final out = Uint8List(8 + chunks.length)
    ..setRange(0, 4, ascii.encode('RIFF'))
    ..setRange(8, 8 + chunks.length, chunks);
  ByteData.sublistView(out).setUint32(4, chunks.length, Endian.little);
  return out;
}

Uint8List _box(String type, List<int> payload) {
  final out = Uint8List(8 + payload.length);
  ByteData.sublistView(out).setUint32(0, out.length);
  out
    ..setRange(4, 8, latin1.encode(type))
    ..setRange(8, out.length, payload);
  return out;
}

const List<int> fixtureXmpUuid = [
  0xbe, 0x7a, 0xcf, 0xcb, 0x97, 0xa9, 0x42, 0xe8, //
  0x9c, 0x71, 0x99, 0x94, 0x91, 0xe3, 0xaf, 0xac,
];

/// The `mdat` payload of [mp4WithLocation], for a byte compare.
final Uint8List fixtureMdat = Uint8List.fromList(
  List.generate(64, (i) => (i * 7) % 256),
);

/// An MP4 shaped like a phone recording: location in `moov/udta/©xyz` (the
/// Android muxer), Apple keys in `moov/meta`, a track `udta`, an XMP `uuid`
/// box, and an `mdat` written with a 64-bit size.
Uint8List mp4WithLocation() {
  final trak = _box('trak', [
    ..._box('tkhd', List.filled(20, 0x11)),
    ..._box('udta', ascii.encode('SECRET-TRACK-NAME')),
    ..._box('mdia', List.filled(24, 0x22)),
  ]);
  final moov = _box('moov', [
    ..._box('mvhd', List.filled(32, 0x33)),
    ..._box('udta', [
      ..._box('\u00a9xyz', ascii.encode('SECRET+52.2297+021.0122/')),
    ]),
    ..._box('meta', ascii.encode('com.apple.quicktime.location.ISO6709 SECRET-APPLE')),
    ...trak,
  ]);
  final mdat = Uint8List(16 + fixtureMdat.length);
  ByteData.sublistView(mdat)
    ..setUint32(0, 1)
    ..setUint32(8, 0)
    ..setUint32(12, mdat.length);
  mdat
    ..setRange(4, 8, ascii.encode('mdat'))
    ..setRange(16, mdat.length, fixtureMdat);
  return (BytesBuilder()
        ..add(_box('ftyp', ascii.encode('isom\x00\x00\x02\x00isomiso2mp41')))
        ..add(moov)
        ..add(_box('uuid', [...fixtureXmpUuid, ...ascii.encode('SECRET-MP4-XMP')]))
        ..add(mdat))
      .takeBytes();
}
