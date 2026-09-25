import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The box wire, client half (`docs/contracts/wire.md` "The box"; server
/// `backend/src/box/box-wire.ts` + `box-signature.ts`). The signed bytes are
/// byte-exact with the server's: `test/services/box/box_wire_test.dart` pins
/// them to vectors the server's own code produced.

/// Every `send`/`msg` blob is exactly this long (I5).
const int kBoxBlobBytes = 16384;

/// Most entries one `subscribe` frame may carry.
const int kBoxSubscribeMax = 256;

const int kBoxRidBytes = 32;
const int kBoxSidBytes = 32;
const int kBoxNidBytes = 16;
const int kBoxMsgIdBytes = 16;
const int kBoxCodeBytes = 16;
const int kBoxMediaIdBytes = 32;
const int kBoxAuthPubBytes = 32;
const int kBoxSigBytes = 64;

/// The only body sizes `POST /box/media` accepts (I5): pad to one of these.
/// The 32 MiB top rung keeps today's 20 MiB plaintext file sendable once
/// padded.
const List<int> kBoxMediaLadder = [
  4 * 1024,
  16 * 1024,
  64 * 1024,
  256 * 1024,
  1024 * 1024,
  4 * 1024 * 1024,
  16 * 1024 * 1024,
  32 * 1024 * 1024,
];

enum QueueKind { normal, request }

enum NotifierPlatform { fcm, webpush }

enum NotifierState { challenged, active }

enum BoxState {
  /// No connection, or the last one dropped.
  offline,

  /// A connection is up (or being set up) and the subscribe set is not yet
  /// re-signed over it.
  connecting,

  /// Every subscribe chunk for this connection has answered.
  ready,
}

/// A refusal the box (or its media route) answered. Server codes plus the two
/// HTTP-only answers of the media route.
enum BoxCode {
  invalidPayload('invalid_payload'),
  authFailed('auth_failed'),
  queueFull('queue_full'),
  quotaExceeded('quota_exceeded'),
  rateLimited('rate_limited'),
  internal('internal'),
  badSize('bad_size'),
  notFound('not_found');

  const BoxCode(this.wire);

  final String wire;

  /// An unknown code is read as [internal]: a refusal we cannot name is
  /// still a refusal, never an answer.
  static BoxCode parse(Object? wire) => values.firstWhere(
    (c) => c.wire == wire,
    orElse: () => internal,
  );
}

/// Why a call has no answer. None of these is a refusal: a `send` that timed
/// out may still have been stored, so the caller retries and the E2E message
/// id dedups (PR2.1).
enum BoxUnknownReason {
  /// Not connected: nothing was emitted.
  offline,

  /// Emitted, no answer within the client's timeout.
  timeout,

  /// Emitted, then the connection closed before the answer.
  disconnected,

  /// An answer arrived that this client cannot read.
  malformed,
}

sealed class BoxResult<T> {
  const BoxResult();
}

final class BoxOk<T> extends BoxResult<T> {
  const BoxOk(this.value);

  final T value;
}

final class BoxRefused<T> extends BoxResult<T> {
  const BoxRefused(this.code, {this.retryAfter});

  final BoxCode code;
  final Duration? retryAfter;
}

final class BoxUnknown<T> extends BoxResult<T> {
  const BoxUnknown(this.reason);

  final BoxUnknownReason reason;
}

/// What `createQueue` answers.
class QueueAddress {
  const QueueAddress({required this.rid, required this.sid, required this.nid});

  final Uint8List rid;
  final Uint8List sid;
  final Uint8List nid;
}

/// One `msg` push.
class BoxDelivery {
  const BoxDelivery({required this.rid, required this.id, required this.blob});

  final Uint8List rid;
  final Uint8List id;
  final Uint8List blob;
}

/// A rid the box refused on `subscribe`: deleted, reaped, or never ours.
class BoxRefusal {
  const BoxRefusal({required this.rid, required this.code});

  final Uint8List rid;
  final BoxCode code;
}

/// What `POST /box/media` answers.
class BoxMediaRef {
  const BoxMediaRef({
    required this.id,
    required this.bucket,
    required this.expiresAt,
  });

  final Uint8List id;
  final String bucket;
  final DateTime expiresAt;
}

/// The ONE spelling the box accepts: base64url, no padding.
String boxB64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

final RegExp _b64UrlChars = RegExp(r'^[A-Za-z0-9_-]+$');

/// The bytes of [value] when it is the canonical unpadded base64url spelling
/// of exactly [length] bytes; otherwise null (the server's `decodeFixedB64`).
/// The regex bars padding and the standard alphabet; the one other
/// non-canonical spelling — non-zero spare bits in the last character — is
/// a [FormatException] from Dart's decoder itself.
Uint8List? boxB64Decode(Object? value, int length) {
  if (value is! String) return null;
  if (value.length != (length * 4 + 2) ~/ 3) return null;
  if (!_b64UrlChars.hasMatch(value)) return null;
  try {
    final bytes = base64Url.decode(base64Url.normalize(value));
    return bytes.length == length ? bytes : null;
  } on FormatException {
    return null;
  }
}

enum BoxSignedVerb { createQueue, subscribe, ack, deleteQueue, registerNotifier }

final Uint8List _domain = ascii.encode('umbra.box.v1\x00');

/// `"umbra.box.v1" 0x00 ‖ verb 0x00 ‖ u8(len sockId) ‖ utf8(sockId) ‖ F`.
///
/// [sockId] is the socket.io id of the `/box` NAMESPACE socket the command
/// goes out on — the server binds every signature to it, so a signature is
/// dead once that connection closes.
Uint8List boxSignedMessage(
  BoxSignedVerb verb,
  String sockId,
  List<int> fields,
) {
  final sock = utf8.encode(sockId);
  if (sock.length > 255) {
    throw ArgumentError.value(sockId, 'sockId', 'longer than a u8 prefix');
  }
  return Uint8List.fromList([
    ..._domain,
    ...ascii.encode(verb.name),
    0x00,
    sock.length,
    ...sock,
    ...fields,
  ]);
}

/// F for `createQueue`: the kind byte, then the key being proven.
Uint8List createQueueFields(QueueKind kind, List<int> authPub) =>
    Uint8List.fromList([
      if (kind == QueueKind.normal) 0x01 else 0x02,
      ...authPub,
    ]);

/// F for `ack`: rid ‖ message id.
Uint8List ackFields(List<int> rid, List<int> id) =>
    Uint8List.fromList([...rid, ...id]);

/// F for `registerNotifier` step 1: nid ‖ 0x01 ‖ SHA-256(platform 0x00 token).
Uint8List notifierChallengeFields(
  List<int> nid,
  NotifierPlatform platform,
  String token,
) => Uint8List.fromList([
  ...nid,
  0x01,
  ...sha256.convert(utf8.encode('${platform.name}\x00$token')).bytes,
]);

/// F for `registerNotifier` step 2: nid ‖ 0x02 ‖ the code the push delivered.
Uint8List notifierActivateFields(List<int> nid, List<int> code) =>
    Uint8List.fromList([...nid, 0x02, ...code]);
