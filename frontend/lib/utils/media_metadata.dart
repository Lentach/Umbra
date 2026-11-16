import 'dart:convert';
import 'dart:typed_data';

/// Camera metadata scrubbing before a photo or video is sealed (plan A2): a
/// phone camera writes where and when a picture was taken, the device model
/// and a thumbnail into the file, and the friend would get all of it.
///
/// Both scrubbers are LOSSLESS — no pixel is decoded or re-encoded:
///  * a photo (JPEG, PNG, WebP) is rebuilt without its metadata segments or
///    chunks; a JPEG keeps only its orientation, so it still shows upright;
///  * a video (MP4/MOV) keeps its exact size, because its sample tables hold
///    absolute file offsets: each metadata box is zeroed and renamed `free`.
///
/// A file in any other format (GIF, HEIC, WebM, …), or one these parsers do
/// not understand, is left as it was, and `scrubbed` is then 0.
typedef MediaScrub = ({Uint8List bytes, int scrubbed});

/// [image] without its metadata; see the library comment.
MediaScrub scrubImageMetadata(Uint8List image) {
  try {
    if (_isJpeg(image)) return _scrubJpeg(image);
    if (_isPng(image)) return _scrubPng(image);
    if (_isWebp(image)) return _scrubWebp(image);
  } on _Malformed {
    // Left as it was, like an unknown format.
  }
  return (bytes: image, scrubbed: 0);
}

/// Zeroes the metadata boxes of an MP4/MOV [video] IN PLACE and renames them
/// `free`; the number of bytes zeroed. Nothing is touched unless the whole
/// box tree parses first.
int scrubVideoMetadataInPlace(Uint8List video) {
  try {
    if (!_isIsoBmff(video)) return 0;
    final targets = <({int start, int header, int end})>[];
    _findMetadataBoxes(video, 0, video.length, 0, targets);
    var scrubbed = 0;
    for (final box in targets) {
      video
        ..setRange(box.start + 4, box.start + 8, _free)
        ..fillRange(box.start + box.header, box.end, 0);
      scrubbed += box.end - box.start - box.header;
    }
    return scrubbed;
  } on _Malformed {
    return 0;
  }
}

class _Malformed implements Exception {
  const _Malformed();
}

int _u16be(Uint8List b, int at) => (b[at] << 8) | b[at + 1];

int _u32be(Uint8List b, int at) =>
    ByteData.sublistView(b).getUint32(at);

int _u32le(Uint8List b, int at) =>
    ByteData.sublistView(b).getUint32(at, Endian.little);

bool _startsWith(Uint8List b, int at, List<int> prefix) {
  if (at + prefix.length > b.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (b[at + i] != prefix[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------- JPEG

bool _isJpeg(Uint8List b) => b.length > 3 && b[0] == 0xff && b[1] == 0xd8;

final List<int> _exifId = ascii.encode('Exif\x00\x00');
final List<int> _iccId = ascii.encode('ICC_PROFILE\x00');

/// Rebuilds a JPEG from SOI to EOI without APP1 (Exif, XMP), APP3–APP13,
/// APP15, COM, non-ICC APP2 (MPF) and anything after EOI (the extra images
/// an MPF index points at). The orientation is carried over in a minimal
/// Exif segment of its own.
MediaScrub _scrubJpeg(Uint8List b) {
  final kept = BytesBuilder(copy: false);
  var scrubbed = 0;
  int? orientation;
  var headerDone = false;
  final header = <Uint8List>[];
  var pos = 2;
  void keep(Uint8List segment) =>
      headerDone ? kept.add(segment) : header.add(segment);
  while (true) {
    if (pos >= b.length || b[pos] != 0xff) throw const _Malformed();
    while (pos < b.length && b[pos] == 0xff) {
      pos++;
    }
    if (pos >= b.length) throw const _Malformed();
    final marker = b[pos++];
    if (marker == 0xd9) {
      scrubbed += b.length - pos;
      break;
    }
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      keep(Uint8List.fromList([0xff, marker]));
      continue;
    }
    if (pos + 2 > b.length) throw const _Malformed();
    final length = _u16be(b, pos);
    final end = pos + length;
    if (length < 2 || end > b.length) throw const _Malformed();
    final payloadAt = pos + 2;
    final drop = switch (marker) {
      0xe1 => true,
      0xe2 => !_startsWith(b, payloadAt, _iccId),
      0xee => false,
      >= 0xe3 && <= 0xef => true,
      0xfe => true,
      _ => false,
    };
    if (marker == 0xe1 && _startsWith(b, payloadAt, _exifId)) {
      orientation ??= _exifOrientation(Uint8List.sublistView(b, payloadAt, end));
    }
    if (drop) {
      scrubbed += length + 2;
    } else {
      keep(Uint8List.sublistView(b, pos - 2, end));
    }
    pos = end;
    if (marker == 0xda) {
      headerDone = true;
      pos = _endOfScan(b, pos);
      kept.add(Uint8List.sublistView(b, end, pos));
    }
  }
  final out = BytesBuilder(copy: false)..add(const [0xff, 0xd8]);
  var i = 0;
  // JFIF readers expect APP0 first; the orientation follows it.
  if (header.isNotEmpty && header.first[1] == 0xe0) out.add(header[i++]);
  if (orientation != null && orientation != 1) {
    out.add(_orientationSegment(orientation));
  }
  for (; i < header.length; i++) {
    out.add(header[i]);
  }
  out
    ..add(kept.takeBytes())
    ..add(const [0xff, 0xd9]);
  return (bytes: out.takeBytes(), scrubbed: scrubbed);
}

/// The first marker after a scan's entropy-coded data, which starts at
/// [from]: `FF 00` is a stuffed byte, `FF D0`–`FF D7` a restart, `FF FF`
/// fill.
int _endOfScan(Uint8List b, int from) {
  var i = from;
  while (i + 1 < b.length) {
    if (b[i] != 0xff) {
      i++;
      continue;
    }
    final next = b[i + 1];
    if (next == 0x00 || (next >= 0xd0 && next <= 0xd7) || next == 0xff) {
      i += next == 0xff ? 1 : 2;
      continue;
    }
    return i;
  }
  throw const _Malformed();
}

/// Tag 0x0112 of IFD0 in an `Exif\0\0` APP1 payload, when it is a valid
/// orientation (1–8).
int? _exifOrientation(Uint8List payload) {
  if (payload.length < 6 + 8) return null;
  final tiff = Uint8List.sublistView(payload, 6);
  final Endian endian;
  if (tiff[0] == 0x49 && tiff[1] == 0x49) {
    endian = Endian.little;
  } else if (tiff[0] == 0x4d && tiff[1] == 0x4d) {
    endian = Endian.big;
  } else {
    return null;
  }
  final data = ByteData.sublistView(tiff);
  if (data.getUint16(2, endian) != 42) return null;
  final ifd = data.getUint32(4, endian);
  if (ifd + 2 > tiff.length) return null;
  final count = data.getUint16(ifd, endian);
  for (var n = 0; n < count; n++) {
    final entry = ifd + 2 + 12 * n;
    if (entry + 12 > tiff.length) return null;
    if (data.getUint16(entry, endian) != 0x0112) continue;
    if (data.getUint16(entry + 2, endian) != 3) return null;
    final value = data.getUint16(entry + 8, endian);
    return value >= 1 && value <= 8 ? value : null;
  }
  return null;
}

/// `FF E1` + an Exif payload holding one IFD0 entry: Orientation.
Uint8List _orientationSegment(int orientation) {
  const payloadBytes = 6 + 8 + 2 + 12 + 4;
  final segment = Uint8List(4 + payloadBytes);
  final data = ByteData.sublistView(segment)
    ..setUint16(0, 0xffe1)
    ..setUint16(2, 2 + payloadBytes);
  segment.setRange(4, 10, _exifId);
  data
    ..setUint16(10, 0x4d4d) // "MM", big-endian TIFF
    ..setUint16(12, 42)
    ..setUint32(14, 8) // IFD0 right after the header
    ..setUint16(18, 1) // one entry
    ..setUint16(20, 0x0112)
    ..setUint16(22, 3) // SHORT
    ..setUint32(24, 1)
    ..setUint16(28, orientation)
    ..setUint32(32, 0); // no IFD1, so no thumbnail
  return segment;
}

// ---------------------------------------------------------------- PNG

const List<int> _pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

bool _isPng(Uint8List b) => _startsWith(b, 0, _pngSignature);

const Set<String> _pngMetadataChunks = {'eXIf', 'tEXt', 'zTXt', 'iTXt', 'tIME'};

/// Drops the PNG's text, Exif and time chunks, and anything after IEND.
MediaScrub _scrubPng(Uint8List b) {
  final out = BytesBuilder(copy: false)..add(_pngSignature);
  var scrubbed = 0;
  var pos = _pngSignature.length;
  while (true) {
    if (pos + 12 > b.length) throw const _Malformed();
    final end = pos + 12 + _u32be(b, pos);
    if (end > b.length) throw const _Malformed();
    final type = ascii.decode(b.sublist(pos + 4, pos + 8), allowInvalid: true);
    if (_pngMetadataChunks.contains(type)) {
      scrubbed += end - pos;
    } else {
      out.add(Uint8List.sublistView(b, pos, end));
    }
    pos = end;
    if (type == 'IEND') {
      scrubbed += b.length - pos;
      return (bytes: out.takeBytes(), scrubbed: scrubbed);
    }
  }
}

// ---------------------------------------------------------------- WebP

bool _isWebp(Uint8List b) =>
    _startsWith(b, 0, ascii.encode('RIFF')) &&
    _startsWith(b, 8, ascii.encode('WEBP'));

/// Drops the WebP's `EXIF` and `XMP ` chunks, clears their VP8X flags and
/// rewrites the RIFF size.
MediaScrub _scrubWebp(Uint8List b) {
  final riffEnd = 8 + _u32le(b, 4);
  if (riffEnd > b.length) throw const _Malformed();
  final out = BytesBuilder(copy: false)..add(Uint8List(12));
  var scrubbed = b.length - riffEnd;
  var pos = 12;
  while (pos < riffEnd) {
    if (pos + 8 > riffEnd) throw const _Malformed();
    final size = _u32le(b, pos + 4);
    final end = pos + 8 + size + (size.isOdd ? 1 : 0);
    if (end > riffEnd) throw const _Malformed();
    final fourcc = ascii.decode(b.sublist(pos, pos + 4), allowInvalid: true);
    if (fourcc == 'EXIF' || fourcc == 'XMP ') {
      scrubbed += end - pos;
    } else if (fourcc == 'VP8X' && size >= 1) {
      final chunk = Uint8List.fromList(b.sublist(pos, end));
      chunk[8] &= ~0x0c; // the EXIF (0x08) and XMP (0x04) flags
      out.add(chunk);
    } else {
      out.add(Uint8List.sublistView(b, pos, end));
    }
    pos = end;
  }
  final bytes = out.takeBytes()..setRange(0, 12, b);
  ByteData.sublistView(bytes).setUint32(4, bytes.length - 8, Endian.little);
  return (bytes: bytes, scrubbed: scrubbed);
}

// ---------------------------------------------------------------- MP4/MOV

final List<int> _free = ascii.encode('free');

const Set<String> _bmffTopLevel = {'ftyp', 'moov', 'mdat', 'free', 'skip', 'wide'};

/// The XMP `uuid` box (Adobe's extended type).
const List<int> _xmpUuid = [
  0xbe, 0x7a, 0xcf, 0xcb, 0x97, 0xa9, 0x42, 0xe8, //
  0x9c, 0x71, 0x99, 0x94, 0x91, 0xe3, 0xaf, 0xac,
];

bool _isIsoBmff(Uint8List b) =>
    b.length >= 8 &&
    _bmffTopLevel.contains(
      ascii.decode(b.sublist(4, 8), allowInvalid: true),
    );

/// Collects every `udta`, `meta` and XMP `uuid` box at the top level, in
/// `moov` and in each `trak`; throws [_Malformed] on any box that does not
/// fit its parent.
void _findMetadataBoxes(
  Uint8List b,
  int start,
  int end,
  int depth,
  List<({int start, int header, int end})> targets,
) {
  var pos = start;
  while (pos + 8 <= end) {
    var size = _u32be(b, pos);
    var header = 8;
    if (size == 1) {
      if (pos + 16 > end) throw const _Malformed();
      final data = ByteData.sublistView(b);
      size = data.getUint32(pos + 8) * 0x100000000 + data.getUint32(pos + 12);
      header = 16;
    } else if (size == 0) {
      size = end - pos;
    }
    if (size < header || pos + size > end) throw const _Malformed();
    final type = ascii.decode(b.sublist(pos + 4, pos + 8), allowInvalid: true);
    final boxEnd = pos + size;
    final isXmp =
        type == 'uuid' &&
        size >= header + 16 &&
        _startsWith(b, pos + header, _xmpUuid);
    if (type == 'udta' || type == 'meta' || isXmp) {
      targets.add((start: pos, header: header, end: boxEnd));
    } else if ((type == 'moov' && depth == 0) ||
        (type == 'trak' && depth == 1)) {
      _findMetadataBoxes(b, pos + header, boxEnd, depth + 1, targets);
    }
    pos = boxEnd;
  }
  if (pos != end) throw const _Malformed();
}
