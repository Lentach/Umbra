import 'dart:convert';
import 'dart:typed_data';

import 'queue_seal.dart';

/// Which Signal message a [BoxFrame] carries; the byte is libsignal's own
/// `CiphertextMessage` type, the `{type}` of `"{type}:{base64}"`.
enum BoxFrameKind {
  whisper(2),
  preKey(3);

  const BoxFrameKind(this.byte);

  final int byte;
}

/// The body a [QueueSeal] blob carries on a NORMAL queue (design §4.3,
/// owner decision 12, 2026-09-24):
///
///   body = u8 v=1 ‖ u8 kind ‖ u16be senderDeviceId ‖ raw Signal bytes
///
/// Binary, not JSON: base64 would spend a third of the 16 319-byte body.
/// No sender account: a normal queue is per peer, so the queue names it.
/// Kinds 0x10 and up are reserved for request-queue first contact (slice
/// (f), which adds the sender account) and decode to null until then.
class BoxFrame {
  const BoxFrame({
    required this.kind,
    required this.senderDeviceId,
    required this.signal,
  });

  static const int _version = 0x01;
  static const int _headerBytes = 4;

  /// The wire's device id range (`fetchPreKeyBundle`, wire.md).
  static const int _minDevice = 1;
  static const int _maxDevice = 100;

  /// The most Signal bytes one blob carries.
  static const int maxSignalBytes = QueueSeal.maxBodyBytes - _headerBytes;

  final BoxFrameKind kind;
  final int senderDeviceId;
  final Uint8List signal;

  /// What `EncryptionService.decrypt` reads.
  String get signalCiphertext => '${kind.byte}:${base64Encode(signal)}';

  /// The frame for `EncryptionService.encrypt`'s `"{type}:{base64}"` from
  /// [senderDeviceId]; null for a type that is not a Signal message or
  /// bytes that are not base64. Length is NOT checked here: a caller holding
  /// more than [maxSignalBytes] must refuse the send, never truncate it.
  static BoxFrame? fromSignalCiphertext(
    String ciphertext, {
    required int senderDeviceId,
  }) {
    final colon = ciphertext.indexOf(':');
    if (colon < 1) return null;
    final type = int.tryParse(ciphertext.substring(0, colon));
    final kind = BoxFrameKind.values.where((k) => k.byte == type);
    if (kind.isEmpty) return null;
    final Uint8List signal;
    try {
      signal = base64Decode(ciphertext.substring(colon + 1));
    } on FormatException {
      return null;
    }
    if (signal.isEmpty) return null;
    return BoxFrame(
      kind: kind.single,
      senderDeviceId: senderDeviceId,
      signal: signal,
    );
  }

  /// Throws [ArgumentError] for a device id outside 1..100 or more than
  /// [maxSignalBytes]: caller bugs, never runtime conditions.
  Uint8List encode() {
    if (senderDeviceId < _minDevice || senderDeviceId > _maxDevice) {
      throw ArgumentError.value(senderDeviceId, 'senderDeviceId');
    }
    if (signal.length > maxSignalBytes) {
      throw ArgumentError.value(signal.length, 'signal', 'over $maxSignalBytes');
    }
    return Uint8List(_headerBytes + signal.length)
      ..[0] = _version
      ..[1] = kind.byte
      ..[2] = (senderDeviceId >> 8) & 0xff
      ..[3] = senderDeviceId & 0xff
      ..setRange(_headerBytes, _headerBytes + signal.length, signal);
  }

  /// Null for anything but a version-1 Signal frame from a device in range
  /// carrying at least one Signal byte.
  static BoxFrame? decode(Uint8List body) {
    if (body.length <= _headerBytes || body[0] != _version) return null;
    final kind = BoxFrameKind.values.where((k) => k.byte == body[1]);
    if (kind.isEmpty) return null;
    final device = (body[2] << 8) | body[3];
    if (device < _minDevice || device > _maxDevice) return null;
    return BoxFrame(
      kind: kind.single,
      senderDeviceId: device,
      signal: Uint8List.fromList(Uint8List.sublistView(body, _headerBytes)),
    );
  }
}
