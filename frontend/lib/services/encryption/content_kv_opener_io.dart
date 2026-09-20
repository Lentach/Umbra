import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/e2e_persistent_diag.dart';
import '../backup/storage_loss.dart';
import '../secure_kv.dart';
import 'audio_reseal.dart';
import 'content_db.dart';
import 'content_key_manager.dart';
import 'content_kv.dart';
import 'native_content_store.dart';

Future<ContentKv>? _memo;

/// Native build of the opener. Android gets the encrypted store; everything
/// else (desktop dev hosts, the flutter_test VM — `Platform` here is the HOST
/// OS, not `defaultTargetPlatform`) keeps the legacy prefs backend.
///
/// ONLY the Android path is memoized (as a Future, so concurrent first calls
/// cannot race two encrypted stores into existence; and a session that fell
/// back to prefs stays on prefs — flip-flopping backends mid-session would
/// split the read view). The prefs path deliberately returns a FRESH wrapper
/// per call: that is the historical per-service-instance behavior, and the
/// flutter_test VM depends on it — a process-wide memo would pin the first
/// test's mock SharedPreferences under every later test.
Future<ContentKv> openPlatformContentKv() {
  if (!Platform.isAndroid) return PrefsContentKv.open();
  return _memo ??= _open();
}

/// Native counterpart of the web revocation seam, required because both
/// openers are behind one conditional import.
///
/// It only drops the memo. There is nothing to revoke: key wrapping is web
/// only (owner ruling 2026-09-04 — on Android the same material is already
/// Keystore-backed behind `FLAG_SECURE`, and wrapping it there would turn a
/// Keystore fault into permanent history loss), so a native store's keys are
/// readable again the instant it re-opens. Closing the SQLCipher handle here
/// would therefore buy nothing and risk tearing a live write in half.
/// `EncryptionService.revokeForPasscodeLock` never calls this off-web.
Future<void> revokePlatformContentKv() async {
  _memo = null;
}

/// Whether `ContactStore` may keep the contact graph in [kv]. On Android
/// only the SQLCipher store qualifies: the prefs fallback the message cache
/// tolerates for one session is cleartext XML, and a contact list there is
/// exactly the metadata this store exists to keep off disk in the clear. Off
/// Android (desktop dev hosts, the flutter_test VM) prefs is the only
/// backend and stays acceptable. Lives behind the conditional import because
/// naming [NativeContentStore] from web code would pull drift into the build.
bool contactStoreAccepts(ContentKv kv) =>
    !Platform.isAndroid || kv is NativeContentStore;

Future<ContentKv> _open() async {
  var stage = 'unknown';
  try {
    final legacy = await SharedPreferences.getInstance();
    // SAME instance/options as the Signal keys (DualStorage): the content
    // keys must live and die with the identity, never alone.
    final keys = ContentKeyManager(
      const FlutterSecureStorageKv(
        FlutterSecureStorage(webOptions: WebOptions(dbName: 'FireplaceE2E')),
      ),
    );
    stage = 'db-key';
    final dbKey = await keys.dbKeyHex();
    if (dbKey == null) throw const ContentStoreUnavailable('db-key');
    stage = 'db-open';
    final db = await _openDb(dbKey);
    try {
      stage = 'store';
      final store = await NativeContentStore.open(
        db: db,
        keys: keys,
        legacyPrefs: legacy,
        audioResealer: resealAudioCacheFiles,
      );
      return store;
    } on ContentStoreUnavailable catch (e) {
      stage = e.stage;
      await db.close();
      rethrow;
    } catch (_) {
      await db.close();
      rethrow;
    }
  } catch (_) {
    // Fallback = the pre-Phase-2 behavior, loudly diagnosed. Deliberately NOT
    // an unencrypted database: prefs is the known status quo, and the diag
    // rate is what tells us whether this path ever fires in the field.
    E2ePersistentDiag.record('CONTENT_STORE_FALLBACK', {'stage': stage});
    return PrefsContentKv.open();
  }
}

/// Opens the SQLCipher DB, recreating the file ONCE when it cannot be opened
/// with a key that was FRESHLY minted this call — i.e. secure storage was
/// provably enumerated and genuinely held no DB key, so the surviving file is
/// ciphertext nobody can ever read again (and the Signal identity in the same
/// store is gone with it). Recreating trades an unreadable file for a working
/// store; refusing would push every future session onto the plaintext prefs
/// fallback forever.
///
/// With a PRE-EXISTING key the failure is NOT evidence of loss (corruption,
/// transient I/O), so the file is left untouched and the session falls back.
Future<DriftRecordDb> _openDb(DbKeyResult dbKey) async {
  try {
    return await DriftRecordDb.open(dbKeyHex: dbKey.hex);
  } catch (_) {
    if (!dbKey.freshlyMinted) rethrow;
    final deleted = await DriftRecordDb.deleteDatabaseFiles();
    if (!deleted) rethrow;
    E2ePersistentDiag.record('CONTENT_DB_RECREATED', {});
    // The contact list lived in that file too (`ContactStore`). PR2.4's
    // server-held backup brings that half back on its own at the next
    // login; the decrypted message history has no server copy and can only
    // come back from a PR2.3 file, which is what the loss screen offers.
    E2ePersistentDiag.record('CONTACTS_DESTROYED', {'stage': 'db-recreate'});
    StorageLoss.record('db-recreate');
    return DriftRecordDb.open(dbKeyHex: dbKey.hex);
  }
}
