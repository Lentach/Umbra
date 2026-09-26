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

/// The body a [QueueSeal] blob carries (design §4.3, owner decision 12,
/// 2026-09-24). On a NORMAL queue:
///
///   body = u8 v=1 ‖ u8 kind ‖ u16be senderDeviceId ‖ raw Signal bytes
///
/// Binary, not JSON: base64 would spend a third of the 16 319-byte body.
/// No sender account: a normal queue is per peer, so the queue names it.
///
/// On a REQUEST queue the queue names nobody, so the frame does — the
/// ACCOUNT-BEARING kinds, the Signal kind with bit 0x10 set (0x12 whisper,
/// 0x13 PreKey):
///
///   body = u8 v=1 ‖ u8 kind|0x10 ‖ u16be senderDeviceId ‖ u32be senderUserId
///          ‖ raw Signal bytes
///
/// The claim is only a hint for which Signal session to try: the decrypt
/// under that account's session is what authenticates it. Every other kind
/// from 0x10 up stays reserved and decodes to null.
class BoxFrame {
  const BoxFrame({
    required this.kind,
    required this.senderDeviceId,
    required this.signal,
    this.senderUserId,
  });

  static const int _version = 0x01;
  static const int _headerBytes = 4;
  static const int _accountBytes = 4;
  static const int _accountBit = 0x10;

  /// The wire's device id range (`fetchPreKeyBundle`, wire.md).
  static const int _minDevice = 1;
  static const int _maxDevice = 100;
  static const int _maxAccount = 0xffffffff;

  /// The most Signal bytes one blob carries (a normal-queue frame; an
  /// account-bearing one carries four fewer).
  static const int maxSignalBytes = QueueSeal.maxBodyBytes - _headerBytes;

  final BoxFrameKind kind;
  final int senderDeviceId;

  /// The sender's account; null on a normal-queue frame.
  final int? senderUserId;
  final Uint8List signal;

  /// What `EncryptionService.decrypt` reads.
  String get signalCiphertext => '${kind.byte}:${base64Encode(signal)}';

  /// The frame for `EncryptionService.encrypt`'s `"{type}:{base64}"` from
  /// [senderDeviceId] (of [senderUserId], for a request queue); null for a
  /// type that is not a Signal message or bytes that are not base64. Length
  /// is NOT checked here: a caller holding more than [maxSignalBytes] must
  /// refuse the send, never truncate it.
  static BoxFrame? fromSignalCiphertext(
    String ciphertext, {
    required int senderDeviceId,
    int? senderUserId,
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
      senderUserId: senderUserId,
      signal: signal,
    );
  }

  /// Throws [ArgumentError] for a device id outside 1..100, an account
  /// outside 1..2^32-1 or more Signal bytes than the frame holds: caller
  /// bugs, never runtime conditions.
  Uint8List encode() {
    if (senderDeviceId < _minDevice || senderDeviceId > _maxDevice) {
      throw ArgumentError.value(senderDeviceId, 'senderDeviceId');
    }
    final account = senderUserId;
    if (account != null && (account < 1 || account > _maxAccount)) {
      throw ArgumentError.value(account, 'senderUserId');
    }
    final header = account == null ? _headerBytes : _headerBytes + _accountBytes;
    final max = QueueSeal.maxBodyBytes - header;
    if (signal.length > max) {
      throw ArgumentError.value(signal.length, 'signal', 'over $max');
    }
    final body = Uint8List(header + signal.length)
      ..[0] = _version
      ..[1] = account == null ? kind.byte : kind.byte | _accountBit
      ..[2] = (senderDeviceId >> 8) & 0xff
      ..[3] = senderDeviceId & 0xff
      ..setRange(header, header + signal.length, signal);
    if (account != null) {
      ByteData.sublistView(body).setUint32(_headerBytes, account);
    }
    return body;
  }

  /// Null for anything but a version-1 Signal frame from a device in range
  /// (and, account-bearing, an account ≥ 1) carrying at least one Signal
  /// byte.
  static BoxFrame? decode(Uint8List body) {
    if (body.length <= _headerBytes || body[0] != _version) return null;
    final bearing = (body[1] & _accountBit) != 0 && body[1] < 2 * _accountBit;
    final byte = bearing ? body[1] & ~_accountBit : body[1];
    final kind = BoxFrameKind.values.where((k) => k.byte == byte);
    if (kind.isEmpty) return null;
    final device = (body[2] << 8) | body[3];
    if (device < _minDevice || device > _maxDevice) return null;
    final header = bearing ? _headerBytes + _accountBytes : _headerBytes;
    if (body.length <= header) return null;
    final account = bearing
        ? ByteData.sublistView(body).getUint32(_headerBytes)
        : null;
    if (account == 0) return null;
    return BoxFrame(
      kind: kind.single,
      senderDeviceId: device,
      senderUserId: account,
      signal: Uint8List.fromList(Uint8List.sublistView(body, header)),
    );
  }
}
