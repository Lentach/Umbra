import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/e2e_envelope.dart';
import '../../utils/message_ids.dart';
import '../backup/history_backup.dart';
import '../backup/history_backup_service.dart';
import '../encryption_service.dart' show WireKey;
import '../media_crypto_service.dart';
import '../plaintext_record_codec.dart';
import 'box_wire.dart';

/// How often a device on the box stamps that it is (decision 102): the
/// absence a later connect measures is never off by more than this.
const Duration kCatchUpHeartbeat = Duration(minutes: 2);

/// A gap between two stamps longer than this is an absence worth a
/// catch-up. Five heartbeats: a stamp missed to a slow tick or a throttled
/// background tab never reads as one, while any real absence (an app
/// closed, a device off) does. The box keeps the queues meanwhile, so a
/// false positive costs one request and one deduplicated blob, nothing
/// more.
const Duration kCatchUpAbsence = Duration(minutes: 10);

/// How far before the last stamp a catch-up asks from: the heartbeat's own
/// slack plus the sender clocks a record's send time comes from (clamped to
/// the receiver's, never later). Overlap is free — the import dedups by
/// `(sender, wire id)`.
const Duration kCatchUpMargin = Duration(minutes: 10);

/// The furthest back a catch-up reaches (decision 102: "at most 30 d").
const Duration kCatchUpReach = Duration(days: 30);

/// The most plaintext one catch-up blob carries: the payload JSON, newest
/// records first, older ones left out past it. One MiB holds the whole
/// plaintext store (it is capped at 2 000 records, ~0.4 KiB each); the
/// sealed body (+16 B tag, +4 B length) stays on the 1 MiB rung, and the
/// download stays small enough to run on the reader's chain.
const int kCatchUpMaxBytes = 1024 * 1024 - 64;

/// This device's presence stamp (decision 102): when it was last on the
/// box (`at`) and the catch-up still owed from an absence no sibling took
/// yet (`owed`, its `since`).
typedef BoxCatchUpMark = ({DateTime? at, DateTime? owed});

/// What a `sync_resp` points at: the box media blob, its AES-256-GCM key
/// and IV (standard base64), the `since` it answers and the records in it.
typedef BoxCatchUpResponse = ({
  String media,
  String key,
  String iv,
  DateTime since,
  int count,
});

/// One record a catch-up blob carries: the id the RESPONDER holds it
/// under, its plaintext record as that device's store keeps it, and its
/// wire identity.
typedef BoxCatchUpRecord = ({
  int id,
  Map<String, dynamic> record,
  WireKey wire,
});

/// When an absence ends, the `since` a catch-up asks from: [lastOnline]
/// less [kCatchUpMargin], never before [now] less [kCatchUpReach]. Null
/// when there was no absence — no stamp yet (a fresh install has nothing
/// to catch up on from a sibling it was just linked to), a gap of at most
/// [kCatchUpAbsence], or a stamp in the future (the clock moved back).
DateTime? catchUpSince({required DateTime? lastOnline, required DateTime now}) {
  if (lastOnline == null) return null;
  final gap = now.difference(lastOnline);
  if (gap.isNegative || gap <= kCatchUpAbsence) return null;
  return catchUpFloor(lastOnline.subtract(kCatchUpMargin), now);
}

/// [since], never before [now] less [kCatchUpReach].
DateTime catchUpFloor(DateTime since, DateTime now) {
  final floor = now.subtract(kCatchUpReach);
  return since.isBefore(floor) ? floor : since;
}

/// The siblings to ask, in order: only those in [addressed] (a self-queue
/// to send into), the most recently heard first ([lastHeard], decision
/// 103), then the rest by device id — the lowest live id is the primary
/// (`devices_screen.dart`), so the primary leads them.
List<int> catchUpResponders({
  required Iterable<int> siblings,
  required Set<int> addressed,
  DateTime? Function(int device)? lastHeard,
}) {
  final heard = <(int, DateTime)>[];
  final rest = <int>[];
  for (final device in siblings) {
    if (!addressed.contains(device)) continue;
    final at = lastHeard?.call(device);
    if (at == null) {
      rest.add(device);
    } else {
      heard.add((device, at));
    }
  }
  heard.sort((a, b) => b.$2.compareTo(a.$2));
  rest.sort();
  return [for (final (device, _) in heard) device, ...rest];
}

/// The wire identity a plaintext record is stamped with; null without one.
WireKey? catchUpWireOf(Map<String, dynamic> record) => switch (record) {
  {
    PlaintextRecordCodec.wireIdKey: final String wireId,
    PlaintextRecordCodec.wireSenderKey: final int senderId,
  } =>
    (senderId: senderId, wireId: wireId),
  _ => null,
};

/// The box message records a catch-up from [since] carries, as the history
/// file names them (`HistoryBackupService.recordPrefix` + local id → the
/// record's JSON): local ids only, sent at or after [since], stamped with a
/// wire id (the importer dedups by it), not deleted for everyone
/// ([tombstoned]), not past their destruction stamp at [now], and [usable]
/// (real plaintext). Newest first until [maxBytes] of payload.
Map<String, String> catchUpRecords({
  required int userId,
  required Map<int, Map<String, dynamic>> records,
  required DateTime since,
  required DateTime now,
  required bool Function(WireKey wire) tombstoned,
  required bool Function(int id, Map<String, dynamic> record) usable,
  int maxBytes = kCatchUpMaxBytes,
}) {
  final sinceMs = since.millisecondsSinceEpoch;
  final nowMs = now.millisecondsSinceEpoch;
  final picked = <(int, int, Map<String, dynamic>)>[];
  for (final MapEntry(key: id, value: record) in records.entries) {
    if (!isLocalMessageId(id)) continue;
    final sentMs = record[PlaintextRecordCodec.createdAtKey];
    if (sentMs is! int || sentMs < sinceMs) continue;
    final expiresMs = record[PlaintextRecordCodec.expiresAtKey];
    if (expiresMs is int && expiresMs <= nowMs) continue;
    final wire = catchUpWireOf(record);
    if (wire == null || tombstoned(wire) || !usable(id, record)) continue;
    picked.add((id, sentMs, record));
  }
  picked.sort((a, b) => b.$2.compareTo(a.$2));
  final prefix = HistoryBackupService.recordPrefix(userId);
  // The payload's own frame (`v`, `domain`, `userId`, the two maps).
  var bytes = 128;
  final out = <String, String>{};
  for (final (id, _, record) in picked) {
    final key = '$prefix$id';
    final value = jsonEncode(record);
    // As the payload JSON spells it: both quoted, the value escaped.
    final cost = key.length + utf8.encode(jsonEncode(value)).length + 4;
    if (bytes + cost > maxBytes) break;
    bytes += cost;
    out[key] = value;
  }
  return out;
}

/// The bytes of a catch-up blob before encryption: the history file's
/// payload (PR2.3, `HistoryBackupPayload`) with the records alone.
Uint8List encodeCatchUpPayload(int userId, Map<String, String> records) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(
          HistoryBackupPayload(
            userId: userId,
            records: records,
            contacts: const {},
          ).toJson(),
        ),
      ),
    );

/// The records of a decrypted catch-up blob for [userId], oldest first:
/// each under a LOCAL id in this account's record family and stamped with
/// a wire id. Null when the blob is not a payload of this account.
List<BoxCatchUpRecord>? decodeCatchUpPayload(int userId, Uint8List bytes) {
  final HistoryBackupPayload payload;
  try {
    payload = HistoryBackupPayload.fromJson(jsonDecode(utf8.decode(bytes)));
  } on Object {
    return null;
  }
  if (payload.userId != userId) return null;
  final prefix = HistoryBackupService.recordPrefix(userId);
  final out = <(BoxCatchUpRecord, int)>[];
  for (final MapEntry(:key, :value) in payload.records.entries) {
    if (!key.startsWith(prefix)) continue;
    final id = int.tryParse(key.substring(prefix.length));
    if (id == null || !isLocalMessageId(id)) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, dynamic>) continue;
    final wire = catchUpWireOf(decoded);
    final sentMs = decoded[PlaintextRecordCodec.createdAtKey];
    if (wire == null || sentMs is! int) continue;
    out.add(((id: id, record: decoded, wire: wire), sentMs));
  }
  out.sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final (record, _) in out) record];
}

/// The catch-up frames own devices send each other (decision 102): inside
/// Signal, quiet, through the receiver's self-queue only.
abstract final class BoxCatchUpEnvelope {
  static const String _keySince = 'since';
  static const String _keyCount = 'count';
  static const String _keyMedia = 'boxMedia';
  static const String _keyMediaKey = 'mediaKey';
  static const String _keyMediaIv = 'mediaIv';

  /// `DateTime`'s range in ms, as every `ts` is bounded.
  static const int _maxEpochMs = 8640000000000000;

  /// `{t: 'sync_req', since}`: send me the box messages since [since].
  static Map<String, dynamic> request(DateTime since) => {
    't': E2eEnvelope.typeSyncRequest,
    _keySince: since.millisecondsSinceEpoch,
  };

  /// The `since` a `sync_req` asks from; null when it is not one or the
  /// time is not sound.
  static DateTime? parseRequest(String json) {
    if (_object(json) case {
      't': E2eEnvelope.typeSyncRequest,
      _keySince: final int since,
    } when _isEpochMs(since)) {
      return DateTime.fromMillisecondsSinceEpoch(since, isUtc: true);
    }
    return null;
  }

  /// `{t: 'sync_resp', since, count, boxMedia, mediaKey, mediaIv}`: the
  /// blob answering a `sync_req` from [since].
  static Map<String, dynamic> response({
    required String media,
    required String key,
    required String iv,
    required DateTime since,
    required int count,
  }) => {
    't': E2eEnvelope.typeSyncResponse,
    _keySince: since.millisecondsSinceEpoch,
    _keyCount: count,
    _keyMedia: media,
    _keyMediaKey: key,
    _keyMediaIv: iv,
  };

  /// The blob a `sync_resp` points at; null when it is not one or any
  /// field is not sound (a 32-byte box media id, a 32-byte key, a 12-byte
  /// IV, a positive count).
  static BoxCatchUpResponse? parseResponse(String json) {
    if (_object(json)
        case {
          't': E2eEnvelope.typeSyncResponse,
          _keySince: final int since,
          _keyCount: final int count,
          _keyMedia: final String media,
          _keyMediaKey: final String key,
          _keyMediaIv: final String iv,
        }
        when _isEpochMs(since) &&
            count > 0 &&
            boxB64Decode(media, kBoxMediaIdBytes) != null &&
            _base64Length(key) == 32 &&
            _base64Length(iv) == 12) {
      return (
        media: media,
        key: key,
        iv: iv,
        since: DateTime.fromMillisecondsSinceEpoch(since, isUtc: true),
        count: count,
      );
    }
    return null;
  }

  static bool _isEpochMs(int ms) => ms > 0 && ms <= _maxEpochMs;

  static int? _base64Length(String value) {
    try {
      return base64.decode(value).length;
    } on FormatException {
      return null;
    }
  }

  static Map<String, dynamic>? _object(String json) {
    try {
      final decoded = jsonDecode(json);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}

/// This device's catch-up state (decision 102): the persisted presence
/// stamp, the heartbeat that keeps it fresh while on the box, and the
/// AES-256-GCM a blob is sealed with (the attachment crypto, injectable
/// because webcrypto does not load under `flutter test`).
class BoxCatchUp {
  BoxCatchUp({MediaCryptoService? crypto})
    : crypto = crypto ?? MediaCryptoService();

  final MediaCryptoService crypto;

  Timer? _heartbeat;
  bool _ticking = false;

  /// When this device last answered each sibling's request: one blob per
  /// sibling per [kCatchUpAbsence], whatever a sibling asks.
  final Map<int, DateTime> _answered = {};
  final Set<String> _imported = {};

  /// The SharedPreferences row of [userId]'s stamp: `{at, owed?}` in ms.
  /// Device-local; no backup carries it.
  static String markKey(int userId) => 'e2e_${userId}_boxsync_v1';

  Future<BoxCatchUpMark> load(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(markKey(userId));
    if (raw == null) return (at: null, owed: null);
    try {
      if (jsonDecode(raw) case final Map<String, dynamic> row) {
        return (at: _time(row['at']), owed: _time(row['owed']));
      }
    } on FormatException {
      // An unreadable stamp is no stamp.
    }
    return (at: null, owed: null);
  }

  Future<void> save(int userId, BoxCatchUpMark mark) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      markKey(userId),
      jsonEncode({
        'at': ?mark.at?.millisecondsSinceEpoch,
        'owed': ?mark.owed?.millisecondsSinceEpoch,
      }),
    );
  }

  static DateTime? _time(Object? ms) => ms is int && ms > 0
      ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
      : null;

  /// Starts the heartbeat calling [tick] every [kCatchUpHeartbeat], once.
  void keepBeating(void Function() tick) {
    _heartbeat ??= Timer.periodic(kCatchUpHeartbeat, (_) => tick());
  }

  /// One tick at a time: true when this caller may run one now.
  bool claimTick() {
    if (_ticking) return false;
    return _ticking = true;
  }

  void endTick() => _ticking = false;

  /// Whether [device]'s request may be answered at [now] (and records it).
  bool mayAnswer(int device, DateTime now) {
    final last = _answered[device];
    if (last != null && now.difference(last) < kCatchUpAbsence) return false;
    _answered[device] = now;
    return true;
  }

  /// Whether the blob [media] (its box id) was imported in this process: a
  /// re-delivered `sync_resp` is not downloaded again. Another blob of the
  /// same records is still deduped record by record.
  bool imported(String media) => _imported.contains(media);

  void markImported(String media) => _imported.add(media);

  /// Logout or teardown: the heartbeat stops, the answers and imports are
  /// forgotten.
  void reset() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _answered.clear();
    _imported.clear();
  }
}
