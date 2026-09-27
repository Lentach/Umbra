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
/// under that account's session is what authenticates it.
///
/// A friend's handoff on a request queue may also carry the sender
/// account's device list OUTSIDE Signal — the LIST-BEARING kinds, the
/// account-bearing kind with 0x20 set too (0x32 whisper, 0x33 PreKey;
/// metadata-privacy slice (e), decision 50, E50b):
///
///   body = u8 v=1 ‖ u8 kind|0x30 ‖ u16be senderDeviceId ‖ u32be senderUserId
///          ‖ u16be len ‖ len bytes of the list JSON ‖ raw Signal bytes
///
/// Outside Signal because it must be judged before Signal sees the frame:
/// the list is DAK-signed, so the seal is all it needs. Every other kind
/// from 0x10 up stays reserved and decodes to null.
class BoxFrame {
  const BoxFrame({
    required this.kind,
    required this.senderDeviceId,
    required this.signal,
    this.senderUserId,
    this.carriedList,
  });

  static const int _version = 0x01;
  static const int _headerBytes = 4;
  static const int _accountBytes = 4;
  static const int _lengthBytes = 2;
  static const int _accountBit = 0x10;
  static const int _listBit = 0x20;

  /// The wire's device id range (`fetchPreKeyBundle`, wire.md).
  static const int _minDevice = 1;
  static const int _maxDevice = 100;
  static const int _maxAccount = 0xffffffff;

  /// The most Signal bytes one blob carries (a normal-queue frame; an
  /// account-bearing one carries four fewer).
  static const int maxSignalBytes = QueueSeal.maxBodyBytes - _headerBytes;

  /// Whether [list] (the JSON of an authorization record) fits beside
  /// [signalBytes] Signal bytes in one list-bearing frame.
  static bool carriedListFits(String list, int signalBytes) {
    final length = utf8.encode(list).length;
    return length > 0 &&
        length <= 0xffff &&
        _headerBytes + _accountBytes + _lengthBytes + length + signalBytes <=
            QueueSeal.maxBodyBytes;
  }

  final BoxFrameKind kind;
  final int senderDeviceId;

  /// The sender's account; null on a normal-queue frame.
  final int? senderUserId;
  final Uint8List signal;

  /// The sender account's device list, as the JSON of its authorization
  /// record, on a list-bearing frame; null on every other frame. Unchecked
  /// here: only its adoption can say what it is worth.
  final String? carriedList;

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
  /// outside 1..2^32-1, a list on a frame without an account, an empty or
  /// over-long list, or more bytes than the frame holds: caller bugs, never
  /// runtime conditions.
  Uint8List encode() {
    if (senderDeviceId < _minDevice || senderDeviceId > _maxDevice) {
      throw ArgumentError.value(senderDeviceId, 'senderDeviceId');
    }
    final account = senderUserId;
    if (account != null && (account < 1 || account > _maxAccount)) {
      throw ArgumentError.value(account, 'senderUserId');
    }
    final list = carriedList == null ? null : utf8.encode(carriedList!);
    if (list != null &&
        (account == null || list.isEmpty || list.length > 0xffff)) {
      throw ArgumentError.value(carriedList, 'carriedList');
    }
    final header =
        _headerBytes +
        (account == null ? 0 : _accountBytes) +
        (list == null ? 0 : _lengthBytes + list.length);
    final max = QueueSeal.maxBodyBytes - header;
    if (signal.length > max) {
      throw ArgumentError.value(signal.length, 'signal', 'over $max');
    }
    final body = Uint8List(header + signal.length)
      ..[0] = _version
      ..[1] =
          kind.byte |
          (account == null ? 0 : _accountBit) |
          (list == null ? 0 : _listBit)
      ..[2] = (senderDeviceId >> 8) & 0xff
      ..[3] = senderDeviceId & 0xff
      ..setRange(header, header + signal.length, signal);
    if (account != null) {
      ByteData.sublistView(body).setUint32(_headerBytes, account);
    }
    if (list != null) {
      const at = _headerBytes + _accountBytes;
      ByteData.sublistView(body).setUint16(at, list.length);
      body.setRange(at + _lengthBytes, at + _lengthBytes + list.length, list);
    }
    return body;
  }

  /// Null for anything but a version-1 Signal frame from a device in range
  /// (and, account-bearing, an account ≥ 1; list-bearing, a list of at
  /// least one byte that is UTF-8) carrying at least one Signal byte.
  static BoxFrame? decode(Uint8List body) {
    if (body.length <= _headerBytes || body[0] != _version) return null;
    final flags = body[1] & 0xf0;
    final bearing = flags == _accountBit || flags == _accountBit | _listBit;
    final listed = flags == _accountBit | _listBit;
    if (flags != 0 && !bearing) return null;
    final byte = body[1] & 0x0f;
    final kind = BoxFrameKind.values.where((k) => k.byte == byte);
    if (kind.isEmpty) return null;
    final device = (body[2] << 8) | body[3];
    if (device < _minDevice || device > _maxDevice) return null;
    var header = bearing ? _headerBytes + _accountBytes : _headerBytes;
    if (body.length <= header) return null;
    final account = bearing
        ? ByteData.sublistView(body).getUint32(_headerBytes)
        : null;
    if (account == 0) return null;
    String? list;
    if (listed) {
      if (body.length < header + _lengthBytes) return null;
      final length = ByteData.sublistView(body).getUint16(header);
      header += _lengthBytes;
      if (length == 0 || body.length <= header + length) return null;
      try {
        list = utf8.decode(Uint8List.sublistView(body, header, header + length));
      } on FormatException {
        return null;
      }
      header += length;
    }
    return BoxFrame(
      kind: kind.single,
      senderDeviceId: device,
      senderUserId: account,
      signal: Uint8List.fromList(Uint8List.sublistView(body, header)),
      carriedList: list,
    );
  }
}
