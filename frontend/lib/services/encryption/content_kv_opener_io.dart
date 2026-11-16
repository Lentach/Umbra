import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

/// The stage [openEncryptedContentKv] last recorded as unavailable, cleared
/// by a successful open. Every store touch retries the open, so without it
/// one failing launch wrote ~7 durable entries into the 80-entry ring.
String? _unavailableRecorded;

/// Native build of the opener. Android gets the encrypted store; everything
/// else (desktop dev hosts, the flutter_test VM — `Platform` here is the HOST
/// OS, not `defaultTargetPlatform`) keeps the legacy prefs backend.
///
/// On Android it FAILS CLOSED (hardening plan A3): a store that will not open
/// throws [ContentStoreUnavailable], never a plaintext SharedPreferences
/// stand-in, so nothing this session reads or writes lands in cleartext XML.
/// Callers surface it (`ConnectionProvider.contactStoreFailed`) and the next
/// touch opens again.
///
/// The prefs path deliberately returns a FRESH wrapper per call: that is the
/// historical per-service-instance behavior, and the flutter_test VM depends
/// on it — a process-wide memo would pin the first test's mock
/// SharedPreferences under every later test.
Future<ContentKv> openPlatformContentKv() {
  if (!Platform.isAndroid) return PrefsContentKv.open();
  return openMemoized(openEncryptedContentKv);
}

/// [open], memoized as a Future so concurrent first calls cannot race two
/// encrypted stores into existence. A FAILED open is dropped, so the next
/// call opens again: kept, a Keystore hiccup at launch would refuse the store
/// for the whole process.
@visibleForTesting
Future<ContentKv> openMemoized(Future<ContentKv> Function() open) async {
  final opening = _memo ??= open();
  try {
    return await opening;
  } on Object {
    if (identical(_memo, opening)) _memo = null;
    rethrow;
  }
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

/// Whether `ContactStore` may keep the contact graph in [kv]. On a real
/// PHONE only the SQLCipher store qualifies: prefs is cleartext XML, and a
/// contact list there is exactly the metadata this store exists to keep off
/// disk in the clear. The Android opener never answers prefs any more (A3);
/// this stays as the second lock on the same door.
/// Off-device (desktop dev hosts, the flutter_test VM) prefs is the only
/// backend and stays acceptable. Lives behind the conditional import because
/// naming [NativeContentStore] from web code would pull drift into the build.
///
/// iOS is named explicitly even though it does not ship yet (G2 review T2,
/// 2026-09-21): an `isAndroid`-only test FAILS OPEN, so the first iOS build
/// would have written the graph into cleartext prefs on any opener fault —
/// silently, on the one platform the plan lists as unverified.
bool contactStoreAccepts(ContentKv kv) =>
    (!Platform.isAndroid && !Platform.isIOS) || kv is NativeContentStore;

/// The Android open chain: DB key, SQLCipher file, armed store. Throws
/// [ContentStoreUnavailable] naming the stage that failed.
@visibleForTesting
Future<ContentKv> openEncryptedContentKv() async {
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
      _unavailableRecorded = null;
      // Once per launch (the open is memoized): voice notes an older build
      // cached in the clear get sealed under the key just armed (A5).
      unawaited(sealPlainAudioCacheFiles(store.sealAudioBytes));
      return store;
    } on ContentStoreUnavailable catch (e) {
      stage = e.stage;
      await db.close();
      rethrow;
    } on Object {
      await db.close();
      rethrow;
    }
  } on Object {
    // Deliberately NOT a plaintext fallback (the pre-A3 behavior) and never
    // an unencrypted database: the session runs without its store until an
    // open succeeds. The diag rate says how often this fires in the field;
    // a stage is recorded once until an open succeeds.
    if (stage != _unavailableRecorded) {
      _unavailableRecorded = stage;
      E2ePersistentDiag.record('CONTENT_STORE_UNAVAILABLE', {'stage': stage});
    }
    throw ContentStoreUnavailable(stage);
  }
}

/// Opens the SQLCipher DB, recreating the file ONCE when it cannot be opened
/// with a key that was FRESHLY minted this call — i.e. secure storage was
/// provably enumerated and genuinely held no DB key, so the surviving file is
/// ciphertext nobody can ever read again (and the Signal identity in the same
/// store is gone with it). Recreating trades an unreadable file for a working
/// store; refusing would leave every future session without a store.
///
/// With a PRE-EXISTING key the failure is NOT evidence of loss (corruption,
/// transient I/O), so the file is left untouched and the open fails.
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
