import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../utils/e2e_persistent_diag.dart';
import '../encryption/content_kv.dart';
import 'backup_file_out_stub.dart'
    if (dart.library.io) 'backup_file_out_io.dart'
    show emitBackupFile;
import 'history_backup.dart';

/// How much a backup carries, or restored.
typedef HistoryBackupCounts = ({int records, int contacts});

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
  }) : _open = open,
       _codec = codec ?? HistoryBackupCodec(),
       _emit = emit ?? emitBackupFile;

  final Future<ContentKv> Function() _open;
  final HistoryBackupCodec _codec;

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

  static String filenameFor(int userId, DateTime at) {
    final stamp = at.toIso8601String().substring(0, 10);
    return 'umbra-$userId-$stamp.$kHistoryBackupFileExtension';
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
    await _emit(bytes, filenameFor(userId, DateTime.now()));
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
    final existing = (await _readAll(kv)).keys.toSet();
    var records = 0;
    var contacts = 0;
    // EXACTLY the two prefixes `exportAndShare` produces — never the rest of
    // the `e2e_<uid>_` namespace. Signal key material, the identity and the
    // passcode verifier live there too and are out of scope by contract; the
    // device this path targets has a store that was just destroyed, so
    // `existing` is empty and nothing else would stop a crafted file from
    // planting them.
    final recordPre = recordPrefix(userId);
    final rawPre = rawRecordPrefix(userId);
    for (final entry in payload.records.entries) {
      if (existing.contains(entry.key)) continue;
      if (!entry.key.startsWith(recordPre) && !entry.key.startsWith(rawPre)) {
        continue;
      }
      if (await kv.setString(entry.key, entry.value)) records++;
    }
    for (final entry in payload.contacts.entries) {
      if (existing.contains(entry.key)) continue;
      if (!entry.key.startsWith(contactPrefix(userId))) continue;
      if (await kv.setString(entry.key, entry.value)) contacts++;
    }
    E2ePersistentDiag.record('HISTORY_BACKUP_IMPORTED', {
      'records': records,
      'contacts': contacts,
    });
    return (records: records, contacts: contacts);
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
