import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../utils/e2e_persistent_diag.dart';
import '../../utils/message_ids.dart';
import '../contacts/contact_record.dart';
import '../encryption/content_kv.dart';
import '../plaintext_record_codec.dart';
import 'backup_file_out_stub.dart'
    if (dart.library.io) 'backup_file_out_io.dart'
    show emitBackupFile;
import 'history_backup.dart';

/// How much a backup carries, or restored.
typedef HistoryBackupCounts = ({int records, int contacts});

/// A message's wire identity: `(_wsid, _wid)` (`PlaintextRecordCodec`).
typedef _Wire = ({int senderId, String wireId});

/// Export and import of the user-held history backup (PR2.3).
///
/// Scope, and why it is exactly this: the two families a restore can
/// legitimately write back.
///  * `e2e_<uid>_decrypted_*` and `e2e_<uid>_decrypt_raw_v1_*` — the
///    decrypted plaintext of consumed-ratchet messages. Nothing else on
///    earth can regenerate these; the ciphertext they came from is
///    undecryptable a second time.
///  * `e2e_<uid>_contact_v1_*` — the contact graph, included so ONE file is
///    a whole restore even for an account that never had a server backup.
///
/// Deliberately NOT included: Signal key material and the identity. Those
/// have their own phrase-sealed backup ((lxxviii)) with its own ceremony, and
/// a second copy of the identity in a user-managed file is a key-escrow
/// hazard this app does not take on.
class HistoryBackupService {
  HistoryBackupService({
    required Future<ContentKv> Function() open,
    HistoryBackupCodec? codec,
    Future<void> Function(Uint8List bytes, String filename)? emit,
    Future<int?> Function(int count)? allocateLocalIds,
    Future<bool Function(({int senderId, String wireId}) wire)> Function()?
    tombstones,
    void Function()? onImported,
  }) : _open = open,
       _codec = codec ?? HistoryBackupCodec(),
       _emit = emit ?? emitBackupFile,
       _allocateLocalIds = allocateLocalIds,
       _tombstones = tombstones,
       _onImported = onImported;

  final Future<ContentKv> Function() _open;
  final HistoryBackupCodec _codec;

  /// The box's local-id allocator (`ContactStore.allocateLocalIds`: the
  /// first of `count` consecutive ids): every local id the file names is
  /// re-issued from it, so an imported message never shares an id with one
  /// this device already holds, and the box's next id lands past it. Null,
  /// or answering null (a closed store), means a file naming local ids
  /// cannot be imported now.
  final Future<int?> Function(int count)? _allocateLocalIds;

  /// The messages deleted for everyone on this device, read ONCE per import
  /// (`EncryptionService.boxTombstoneSnapshot`): their file copies stay out.
  final Future<bool Function(_Wire wire)> Function()? _tombstones;

  /// Told once rows were written behind the store's back — the owner of the
  /// wire-id cache (`EncryptionService.forgetWireClaims`) must rescan.
  final void Function()? _onImported;

  /// Hands the finished file to the platform — a share sheet on native, a
  /// browser download on web. Injectable because the VM test host has
  /// neither, and the export logic (what goes in, what stays out) is what
  /// needs covering, not the channel.
  final Future<void> Function(Uint8List bytes, String filename) _emit;

  /// Web is EXPORT-ONLY (owner's plan). Not a capability gap — `file_picker`
  /// reads files there fine — but a deliberate scope line: the native build
  /// is the one whose store can be destroyed in a way the server cannot
  /// repair, and an import path is a write path into the plaintext cache
  /// that deserves the device's at-rest guarantees behind it.
  static bool get importSupported => !kIsWeb;

  static String recordPrefix(int userId) => 'e2e_${userId}_decrypted_';
  static String rawRecordPrefix(int userId) => 'e2e_${userId}_decrypt_raw_v1_';
  static String contactPrefix(int userId) => 'e2e_${userId}_contact_v1_';

  /// The share-sheet filename. It carries NO account identifier: the file
  /// leaves the device through Drive/Gmail/Downloads sync, where the name is
  /// cleartext even though the payload is not, and the server-assigned
  /// `userId` is exactly the metadata this phase removes elsewhere. The id
  /// still rides INSIDE the sealed payload, which is what `importBytes`
  /// checks — the name was never load-bearing.
  static String filenameFor(DateTime at) {
    final stamp = at.toIso8601String().substring(0, 10);
    return 'umbra-backup-$stamp.$kHistoryBackupFileExtension';
  }

  /// Seals everything this device holds for [userId] and hands the file to
  /// the platform. Returns what went in.
  ///
  /// An EMPTY backup is still produced and still shared: "you have nothing
  /// stored locally" is a fact the user is entitled to discover by looking at
  /// the file, and refusing would make the button look broken on a fresh
  /// device.
  Future<HistoryBackupCounts> exportAndShare({
    required int userId,
    required String passphrase,
  }) async {
    final kv = await _open();
    final rows = await _readAll(kv);
    final records = <String, String>{};
    final contacts = <String, String>{};
    final recordPre = recordPrefix(userId);
    final rawPre = rawRecordPrefix(userId);
    final contactPre = contactPrefix(userId);
    for (final entry in rows.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value is! String) continue;
      if (key.startsWith(contactPre)) {
        contacts[key] = value;
      } else if (key.startsWith(recordPre) || key.startsWith(rawPre)) {
        records[key] = value;
      }
    }
    final bytes = await _codec.seal(
      HistoryBackupPayload(
        userId: userId,
        records: records,
        contacts: contacts,
      ),
      passphrase,
    );
    await _emit(bytes, filenameFor(DateTime.now()));
    E2ePersistentDiag.record('HISTORY_BACKUP_EXPORTED', {
      'records': records.length,
      'contacts': contacts.length,
    });
    return (records: records.length, contacts: contacts.length);
  }

  /// Asks the user for a file and writes its rows back.
  ///
  /// UPGRADE-ONLY: a key the device already holds is left alone. The local
  /// copy is at least as new as the backup by construction, and a decrypted
  /// record is one-shot — overwriting a live one with an older snapshot is
  /// the one mistake here that cannot be undone.
  ///
  /// A box message's LOCAL id (decision 14) is this device's name for it,
  /// not the message's: after a storage loss the box hands the same ids out
  /// again, so a file id can name a different live message. Every local id
  /// the file names is therefore re-issued ([_mapLocalIds]); a message the
  /// device already holds by its wire id is not written a second time.
  ///
  /// Throws [StateError] when the picker was cancelled, so the surface can
  /// stay silent instead of reporting a failure the user caused on purpose.
  Future<HistoryBackupCounts> pickAndImport({
    required int userId,
    required String passphrase,
  }) async {
    if (!importSupported) throw StateError('import_unsupported');
    final picked = await FilePicker.pickFiles(withData: true);
    final bytes = picked?.files.singleOrNull?.bytes;
    if (bytes == null) throw StateError('cancelled');
    return importBytes(userId: userId, bytes: bytes, passphrase: passphrase);
  }

  /// [pickAndImport] without the picker — the seam the tests and the
  /// storage-loss screen drive.
  Future<HistoryBackupCounts> importBytes({
    required int userId,
    required Uint8List bytes,
    required String passphrase,
  }) async {
    final payload = await _codec.open(bytes, passphrase);
    if (payload.userId != userId) throw HistoryBackupForeignAccount();

    final kv = await _open();
    final live = await _readAll(kv);
    // EXACTLY the two prefixes `exportAndShare` produces — never the rest of
    // the `e2e_<uid>_` namespace. Signal key material, the identity and the
    // passcode verifier live there too and are out of scope by contract; the
    // device this path targets has a store that was just destroyed, so
    // `live` is empty and nothing else would stop a crafted file from
    // planting them.
    final recordPre = recordPrefix(userId);
    final rawPre = rawRecordPrefix(userId);
    final contactPre = contactPrefix(userId);
    final rows = {
      for (final MapEntry(:key, :value) in payload.records.entries)
        if (key.startsWith(recordPre) || key.startsWith(rawPre)) key: value,
    };
    final contactRows = {
      for (final MapEntry(:key, :value) in payload.contacts.entries)
        if (key.startsWith(contactPre) && !live.containsKey(key)) key: value,
    };
    // Every id is issued BEFORE the first write: a refused allocation leaves
    // the store exactly as it was.
    final ids = await _mapLocalIds(
      rows: rows,
      contactRows: contactRows,
      live: live,
      recordPre: recordPre,
      rawPre: rawPre,
    );

    var records = 0;
    var contacts = 0;
    for (final MapEntry(:key, :value) in rows.entries) {
      final prefix = key.startsWith(recordPre) ? recordPre : rawPre;
      final local = _localIdOf(key, prefix);
      if (local != null && ids.skip.contains(local)) continue;
      final target = local == null ? key : '$prefix${ids.to[local]}';
      if (live.containsKey(target)) continue;
      final row = prefix == recordPre ? _withReplyMoved(value, ids.to) : value;
      if (await kv.setString(target, row)) records++;
    }
    for (final MapEntry(:key, :value) in contactRows.entries) {
      if (await kv.setString(key, _withKeptMoved(value, ids.to))) contacts++;
    }
    if (records > 0) _onImported?.call();
    E2ePersistentDiag.record('HISTORY_BACKUP_IMPORTED', {
      'records': records,
      'contacts': contacts,
      'reissued': ids.reissued,
    });
    return (records: records, contacts: contacts);
  }

  /// Where each LOCAL id the file names lands on this device.
  ///
  /// `skip`: a file message this device already holds — the same `(_wsid,
  /// _wid)` stamp on any live record, or, unstamped, a byte-identical live
  /// record — is not written again (a second import of the same file, a
  /// message the box re-delivered); nor is one deleted for everyone here
  /// ([_tombstones]). `to`: the id every reference is rewritten to — the
  /// held message's own id when exactly one record holds it, else a FRESH
  /// id from the box's allocator, in file order, all in one block.
  ///
  /// Fresh even where the old id is free right now: the box can journal a
  /// delivery under it before this import writes, and a pending journal row
  /// owns its id before any record exists. The allocator bumps its counter
  /// under the store's lock, so nothing else is ever handed these ids.
  Future<({Map<int, int> to, Set<int> skip, int reissued})> _mapLocalIds({
    required Map<String, String> rows,
    required Map<String, String> contactRows,
    required Map<String, Object?> live,
    required String recordPre,
    required String rawPre,
  }) async {
    final liveWires = <_Wire, Set<int>>{};
    final liveBodies = <String, Set<int>>{};
    for (final MapEntry(:key, :value) in live.entries) {
      if (value is! String || !key.startsWith(recordPre)) continue;
      final id = int.tryParse(key.substring(recordPre.length));
      if (id == null) continue;
      final wire = _wireOf(_decode(value));
      if (wire != null) (liveWires[wire] ??= <int>{}).add(id);
      if (isLocalMessageId(id)) (liveBodies[value] ??= <int>{}).add(id);
    }

    final tombstoned = await _tombstones?.call() ?? ((_) => false);

    final to = <int, int>{};
    final skip = <int>{};
    final named = <int>{};
    void name(Object? id) {
      if (id is int && isLocalMessageId(id)) named.add(id);
    }

    for (final MapEntry(:key, :value) in rows.entries) {
      if (key.startsWith(rawPre)) {
        name(_localIdOf(key, rawPre));
        continue;
      }
      final local = _localIdOf(key, recordPre);
      final record = _decode(value);
      if (local != null) {
        final wire = _wireOf(record);
        final holders = wire != null ? liveWires[wire] : liveBodies[value];
        if (holders != null && holders.isNotEmpty) {
          skip.add(local);
          if (holders.length == 1) to[local] = holders.single;
        } else if (wire != null && tombstoned(wire)) {
          skip.add(local);
        }
        name(local);
      }
      if (local == null || !skip.contains(local)) {
        if (record?['replyTo'] case {'id': final Object? quoted}) name(quoted);
      }
    }
    for (final value in contactRows.values) {
      for (final kept in _keptOf(_decode(value))) {
        if (kept case {'lid': final Object? lid}) name(lid);
      }
    }

    final fresh = [
      for (final id in named.toList()..sort())
        if (!to.containsKey(id)) id,
    ];
    if (fresh.isNotEmpty) {
      final first = await _allocateLocalIds?.call(fresh.length);
      if (first == null) throw HistoryBackupLocalIdsUnavailable();
      for (final (i, id) in fresh.indexed) {
        to[id] = first + i;
      }
    }
    return (to: to, skip: skip, reissued: fresh.length);
  }

  static int? _localIdOf(String key, String prefix) {
    if (!key.startsWith(prefix)) return null;
    final id = int.tryParse(key.substring(prefix.length));
    return id != null && isLocalMessageId(id) ? id : null;
  }

  static Map<String, dynamic>? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static _Wire? _wireOf(Map<String, dynamic>? record) => switch (record) {
    {
      PlaintextRecordCodec.wireIdKey: final String wireId,
      PlaintextRecordCodec.wireSenderKey: final int senderId,
    } =>
      (senderId: senderId, wireId: wireId),
    _ => null,
  };

  static List<Object?> _keptOf(Map<String, dynamic>? contact) =>
      switch (contact) {
        {'box': {ContactBoxOrigin.keptKey: final List<Object?> kept}} => kept,
        _ => const [],
      };

  /// [raw] with its quote's local id moved per [to]; verbatim otherwise.
  static String _withReplyMoved(String raw, Map<int, int> to) {
    final record = _decode(raw);
    if (record?['replyTo'] case final Map<String, dynamic> quote) {
      if (to[quote['id']] case final int moved) {
        quote['id'] = moved;
        return jsonEncode(record);
      }
    }
    return raw;
  }

  /// [raw] with its kept requests' replay ids (`lid`) moved per [to].
  static String _withKeptMoved(String raw, Map<int, int> to) {
    final contact = _decode(raw);
    var moved = false;
    for (final kept in _keptOf(contact)) {
      if (kept is Map<String, dynamic>) {
        if (to[kept['lid']] case final int lid) {
          kept['lid'] = lid;
          moved = true;
        }
      }
    }
    return moved ? jsonEncode(contact) : raw;
  }

  /// Ground truth where the backend has a stale-able read view (web), the
  /// loaded view elsewhere — the same rule `ContactStore` follows, and for
  /// the same reason: an export that MISSES a row silently ships an
  /// incomplete backup, and an import that misses one overwrites a live
  /// record it believed absent.
  static Future<Map<String, Object?>> _readAll(ContentKv kv) async {
    final snapshot = await kv.authoritativeSnapshot();
    if (snapshot != null) return snapshot;
    return {for (final key in kv.getKeys()) key: kv.getString(key)};
  }
}

/// The file names box messages by LOCAL id, and no allocator answered (the
/// contact store is closed or was never wired). Thrown before anything is
/// written: importing them under their old ids could overwrite or shadow a
/// message this device received since. Retry once the store is open.
class HistoryBackupLocalIdsUnavailable implements Exception {
  @override
  String toString() => 'HistoryBackupLocalIdsUnavailable';
}
