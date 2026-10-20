import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/e2e_persistent_diag.dart';
import 'content_key_manager.dart';
import 'content_sealer.dart';
import 'sealed_audio_codec.dart';
import 'content_kv.dart';
import 'record_db.dart';

/// Re-seals every non-DB artifact (today: the decrypted voice-note cache)
/// that is sealed under any of [retiringKeys], using [newKid]/[newKey].
///
/// Returns whether EVERYTHING is provably off the retiring keys. A `false`
/// aborts the rotation before any key is destroyed — destroying a key while
/// an audio file still needs it would silently brick that voice note.
typedef AudioResealer =
    Future<bool> Function(
      Map<String, Uint8List> retiringKeys,
      String newKid,
      Uint8List newKey,
    );

/// The encrypted native backend of the [ContentKv] seam.
///
/// Layout: rows live in a SQLCipher database (file-level encryption, DB key in
/// secure storage, never rotated); the payloads of the three plaintext-bearing
/// key families are ADDITIONALLY sealed per record under a rotating content
/// key. Control records — purge backlog, retired ids, retention stamps, diag —
/// stay cleartext inside the encrypted file, because they are precisely what
/// must remain readable after a content-key loss.
///
/// ## Armed-gate
/// Nothing is sealed until the content key has been persisted AND read back
/// from a fresh secure-storage read ([ContentKeyManager]). When any part of
/// arming fails, [NativeContentStore.open] THROWS and the caller runs the
/// session on the legacy prefs backend instead — an unarmed device keeps
/// writing the old way (recoverable) rather than sealing under a key that may
/// not exist tomorrow (not recoverable).
///
/// ## Key loss
/// Detected EAGERLY at open, before any decrypt can run: rows whose `kid` is
/// absent from a successfully enumerated key inventory have their message ids
/// folded into the persisted retired-id set, so the very first history pass
/// renders "no longer stored" instead of live-decrypting a consumed ciphertext
/// into a permanent "[Decryption failed]". Three hard rules, each protecting
/// against a catastrophic misreading:
///  * an inventory that could not be enumerated retires NOTHING (transient
///    Keystore unavailability must never be read as key loss);
///  * an empty enumeration on a store that has an active kid is treated as
///    storage-unavailable, not wiped — a genuinely wiped secure store also
///    means a wiped Signal identity, which has its own failure path;
///  * unreadable rows are RETIRED, never deleted: the bytes stay, and a later
///    launch where the key reappears serves them again.
///
/// ## Shredding
/// Removing a sealed record deletes its row AND stamps a durable rotation
/// obligation (`shred_gen` != `shred_done_gen`). The batched rotation re-seals
/// every survivor under a fresh key and destroys the old ones; freelist/WAL
/// residue of purged records is then ciphertext under a destroyed key. Purge
/// stays instant; the honest claim is "removed instantly, shredded within
/// minutes" — never "shredded before the purge returns", which would put an
/// O(all records) re-seal on every per-message delete.
class NativeContentStore implements ContentKv {
  NativeContentStore._({
    required RecordDb db,
    required ContentKeyManager keys,
    required SharedPreferences legacyPrefs,
    required AudioResealer audioResealer,
    required ContentSealer sealer,
    required Duration rotationDebounce,
    required Duration rotationDeadline,
  }) : _db = db,
       _keys = keys,
       _legacy = legacyPrefs,
       _audioResealer = audioResealer,
       _sealer = sealer,
       _rotationDebounce = rotationDebounce,
       _rotationDeadline = rotationDeadline;

  final RecordDb _db;
  final ContentKeyManager _keys;
  final SharedPreferences _legacy;
  final AudioResealer _audioResealer;
  final ContentSealer _sealer;
  final Duration _rotationDebounce;
  final Duration _rotationDeadline;

  /// The read view: every live record, already unsealed. Same design as the
  /// SharedPreferences plugin cache this store replaces — sync reads are part
  /// of the [ContentKv] contract, and the plaintext of the loaded history was
  /// always resident in the process under the old backend too.
  final Map<String, Object> _view = <String, Object>{};

  /// Keys that may still exist in legacy SharedPreferences. Drained in
  /// batches; whatever a kill leaves behind is re-seeded and re-drained next
  /// open (at-least-once, same discipline as the purge backlog).
  final Set<String> _legacyResidue = <String>{};

  String _activeKid = '';
  final Map<String, Uint8List> _rawKeys = {};

  int _shredGen = 0;
  int _shredDoneGen = 0;
  bool _rotating = false;
  bool _closed = false;

  /// Sealed writes currently between capturing a content key and committing
  /// their row. A rotation MUST NOT destroy a key while one is in flight.
  int _sealedWrites = 0;
  Completer<void>? _sealedIdle;
  Timer? _debounce;
  Timer? _deadline;


  static const String _metaActiveKid = 'active_kid';
  static const String _metaShredGen = 'shred_gen';
  static const String _metaShredDoneGen = 'shred_done_gen';

  /// The four plaintext-bearing families (the fourth: box messages that did
  /// not go out, decision 104). Everything else under `e2e_` is control data
  /// and stays cleartext-in-encrypted-DB (see class doc).
  static bool isSealedKey(String k) =>
      k.startsWith('e2e_') &&
      (k.contains('_decrypted_') ||
          k.contains('_decrypt_raw_v1_') ||
          k.contains('_pendsend_v1_') ||
          k.contains('_boxunsent_v1_'));

  static final RegExp _idBearingKey = RegExp(
    r'^e2e_(\d+)_(?:decrypted|decrypt_raw_v1)_(\d+)$',
  );

  /// Opens and ARMS the store, or throws [ContentStoreUnavailable] with the
  /// failing stage — the caller falls back to the legacy prefs backend for
  /// this session and records the stage in diagnostics.
  static Future<NativeContentStore> open({
    required RecordDb db,
    required ContentKeyManager keys,
    required SharedPreferences legacyPrefs,
    required AudioResealer audioResealer,
    ContentSealer? sealer,
    Duration rotationDebounce = const Duration(seconds: 20),
    Duration rotationDeadline = const Duration(minutes: 3),
  }) async {
    final store = NativeContentStore._(
      db: db,
      keys: keys,
      legacyPrefs: legacyPrefs,
      audioResealer: audioResealer,
      sealer: sealer ?? AesGcmContentSealer(),
      rotationDebounce: rotationDebounce,
      rotationDeadline: rotationDeadline,
    );
    await store._open();
    instance = store;
    return store;
  }

  Future<void> _open() async {
    final inventory = await _keys.inventory();
    if (inventory == null) {
      throw const ContentStoreUnavailable('inventory');
    }

    final metaKid = await _db.getMeta(_metaActiveKid);
    var lostActiveKey = false;
    if (metaKid == null) {
      // Fresh store: mint and arm before anything can be sealed.
      final armed = await _mintAndArm();
      _activeKid = armed.kid;
      _rawKeys[armed.kid] = armed.raw;
    } else if (inventory.keys.containsKey(metaKid)) {
      _activeKid = metaKid;
      _rawKeys.addAll(inventory.keys);
    } else if (inventory.keys.isEmpty && inventory.otherEntryCount == 0) {
      // The store has history under a key, and secure storage answered with
      // NOTHING — not even the Signal keys that share it. That is storage
      // unavailability, not evidence of loss; retiring on it would destroy
      // the readability of the whole history over a hiccup.
      throw const ContentStoreUnavailable('empty-enumeration');
    } else {
      // Enumeration worked, other entries exist, our key is gone: genuine
      // content-key loss. Budgeted, not denied: mint a fresh key so NEW
      // records seal, and let the row scan below retire what died.
      lostActiveKey = true;
      final armed = await _mintAndArm();
      _activeKid = armed.kid;
      _rawKeys
        ..addAll(inventory.keys)
        ..[armed.kid] = armed.raw;
    }

    _shredGen = int.tryParse(await _db.getMeta(_metaShredGen) ?? '') ?? 0;
    // Absent done-marker defaults to ZERO, not to the current gen: a store
    // that stamped an obligation and died before its first rotation would
    // otherwise reopen "clean" and silently lose the shred it owes.
    _shredDoneGen =
        int.tryParse(await _db.getMeta(_metaShredDoneGen) ?? '') ?? 0;

    // Build the read view, detecting unreadable rows as we go.
    final rows = await _db.loadAll();
    final unreadableByUid = <int, Set<int>>{};
    var unreadableRows = 0;
    for (final row in rows) {
      if (row.intValue != null) {
        _view[row.k] = row.intValue!;
        continue;
      }
      if (row.kid == null) {
        if (row.text != null) _view[row.k] = row.text!;
        continue;
      }
      final sealed = row.sealed;
      if (sealed == null) continue;
      final raw = _rawKeys[row.kid];
      String? plain;
      if (raw != null) {
        plain = await _unseal(row.kid!, raw, sealed);
      }
      if (plain == null) {
        // Missing key or failed authentication: retired, never deleted (the
        // bytes may become readable again if the key reappears).
        unreadableRows++;
        final m = _idBearingKey.firstMatch(row.k);
        if (m != null) {
          unreadableByUid
              .putIfAbsent(int.parse(m.group(1)!), () => <int>{})
              .add(int.parse(m.group(2)!));
        }
        continue;
      }
      _view[row.k] = plain;
    }

    if (unreadableRows > 0) {
      for (final entry in unreadableByUid.entries) {
        await _foldRetired(entry.key, entry.value);
      }
      E2ePersistentDiag.record(lostActiveKey ? 'CONTENT_KEY_LOST' : 'CONTENT_RECORDS_UNREADABLE', {
        'rows': unreadableRows,
        'accounts': unreadableByUid.length,
      });
    } else if (lostActiveKey) {
      // The key died but no sealed rows existed — still worth a field signal.
      E2ePersistentDiag.record('CONTENT_KEY_LOST', {'rows': 0, 'accounts': 0});
    }

    // Legacy seed: records still in SharedPreferences (pre-Phase-2 installs,
    // or a drain interrupted by a kill). DB wins on conflict — a legacy value
    // can only be equal or staler than what a later build wrote to the DB.
    try {
      for (final k in _legacy.getKeys()) {
        if (!k.startsWith('e2e_')) continue;
        // The persistent diag store is a StringList owned by
        // E2ePersistentDiag, which must stay writable BEFORE this store
        // opens (it records the fallback path itself). It holds failure
        // classes and peer ids, never message content; deliberately left on
        // prefs and out of the drain.
        if (k == E2ePersistentDiag.storageKey) continue;
        final v = _legacy.get(k);
        // Only claim keys whose value this store can actually carry. A type
        // we cannot migrate must never enter the residue set — the drain
        // deletes what it believes it migrated, and "delete without carry"
        // on an unexpected type would be silent data destruction.
        if (v is! String && v is! int) continue;
        _legacyResidue.add(k);
        if (_view.containsKey(k)) continue;
        _view[k] = v as Object;
      }
    } catch (_) {
      // Unreadable legacy prefs: nothing to migrate this session.
    }

    if (_legacyResidue.isNotEmpty) {
      unawaited(_drainLegacy());
    }
    if (_shredGen != _shredDoneGen) {
      _scheduleRotation();
    }
  }

  /// Mint a content key, ARM it, and record it as the active kid.
  ///
  /// Arming means the key was READ BACK out of secure storage by a fresh
  /// enumeration — never assumed from a write that reported success. Throws
  /// [ContentStoreUnavailable] naming the stage that failed; open turns that
  /// into a prefs-fallback session, rotation turns it into a retry.
  Future<({String kid, Uint8List raw})> _mintAndArm() async {
    final kid = await _keys.mintContentKey();
    if (kid == null) throw const ContentStoreUnavailable('mint');
    final raw = (await _keys.inventory())?.keys[kid];
    if (raw == null) throw const ContentStoreUnavailable('arm');
    if (!await _db.setMeta(_metaActiveKid, kid)) {
      throw const ContentStoreUnavailable('meta');
    }
    return (kid: kid, raw: raw);
  }

  /// Merge [ids] into the persisted retired-id set for [uid], mirroring
  /// `EncryptionService.markRetired` exactly (bounded, highest ids kept).
  Future<void> _foldRetired(int uid, Set<int> ids) async {
    const cap = 5000;
    final key = 'e2e_${uid}_retired_v1';
    final existing = <int>{};
    final raw = _view[key];
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) existing.addAll(decoded.whereType<int>());
      } catch (_) {}
    } else {
      // Not in the DB yet — the legacy prefs copy (not yet seeded at this
      // point in _open) may hold it.
      try {
        final legacyRaw = _legacy.getString(key);
        if (legacyRaw != null) {
          final decoded = jsonDecode(legacyRaw);
          if (decoded is List) existing.addAll(decoded.whereType<int>());
        }
      } catch (_) {}
    }
    final merged = existing..addAll(ids);
    final sorted = merged.toList()..sort();
    final kept = sorted.length > cap ? sorted.sublist(sorted.length - cap) : sorted;
    final encoded = jsonEncode(kept);
    if (await _db.put(RecordRow(k: key, text: encoded))) {
      _view[key] = encoded;
    }
  }

  // ── ContentKv ────────────────────────────────────────────────────────────

  @override
  Future<void> reload() async {
    // Single process on native; the view is authoritative.
  }

  @override
  Future<Map<String, Object>?> authoritativeSnapshot() async {
    // Null means "[getString] is already ground truth". Single process, and
    // nothing ever clears [_view] — `reload()` above is a no-op — so the
    // clobber window the prefs backend has cannot exist here. Returning a copy
    // instead would make every record read allocate the whole view for nothing.
    return null;
  }

  @override
  String? getString(String key) {
    final v = _view[key];
    return v is String ? v : null;
  }

  @override
  int? getInt(String key) {
    final v = _view[key];
    return v is int ? v : null;
  }

  @override
  bool containsKey(String key) => _view.containsKey(key);

  @override
  Set<String> getKeys() => Set.of(_view.keys);

  @override
  Future<bool> setString(String key, String value) async {
    if (!isSealedKey(key)) {
      if (!await _db.put(RecordRow(k: key, text: value))) return false;
      _view[key] = value;
      _noteLegacyResidue(key);
      return true;
    }
    _sealedWrites++;
    try {
      // Kid and key bytes are captured TOGETHER, before the await. A rotation
      // flipping `_activeKid` mid-seal must never make this row claim a key
      // that did not encrypt it: the reseal pass finds rows BY kid, so a
      // mislabelled row is invisible to it and dies with its real key.
      final kid = _activeKid;
      final raw = _rawKeys[kid];
      if (raw == null) return false;
      final sealed = await _sealWith(raw, value);
      if (sealed == null) return false;
      if (!await _db.put(RecordRow(k: key, kid: kid, sealed: sealed))) {
        return false;
      }
    } finally {
      _sealedWrites--;
      if (_sealedWrites == 0) {
        _sealedIdle?.complete();
        _sealedIdle = null;
      }
    }
    _view[key] = value;
    _noteLegacyResidue(key);
    return true;
  }

  @override
  Future<bool> setInt(String key, int value) async {
    if (!await _db.put(RecordRow(k: key, intValue: value))) return false;
    _view[key] = value;
    _noteLegacyResidue(key);
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    final wasSealedRecord = isSealedKey(key) && _view.containsKey(key);
    if (!await _db.delete(key)) return false;
    var legacyOk = true;
    try {
      if (_legacy.containsKey(key)) {
        legacyOk = await _legacy.remove(key);
        if (legacyOk) _legacyResidue.remove(key);
      }
    } catch (_) {
      legacyOk = false;
    }
    // The commit gate covers BOTH copies: reporting a removal while the
    // legacy XML still holds the value would be claiming a destruction that
    // did not happen.
    if (!legacyOk) return false;
    _view.remove(key);
    if (wasSealedRecord) {
      await _stampShred();
      _scheduleRotation();
    }
    return true;
  }

  // ── Legacy drain ─────────────────────────────────────────────────────────

  void _noteLegacyResidue(String key) {
    try {
      if (_legacy.containsKey(key)) {
        _legacyResidue.add(key);
        if (_drainDone) unawaited(_drainLegacy());
      }
    } catch (_) {}
  }

  bool _drainDone = false;
  Future<void>? _drainFuture;

  /// Test/lifecycle hook: runs (or joins) a full drain pass and completes
  /// when it does.
  @visibleForTesting
  Future<void> debugDrainNow() => _drainFuture ?? _drainLegacy();

  /// Migrate/clean legacy SharedPreferences keys in small commit-gated
  /// batches. Incremental and resumable BY CONSTRUCTION: the only state is
  /// which keys still exist in the prefs file, so a kill at any point simply
  /// leaves the remainder for the next launch. Never lazy-on-read — the
  /// oldest records are exactly the ones retention destroys first, and their
  /// residue must not outlive everything else (rationale in
  /// `plaintext_record_codec.dart`).
  Future<void> _drainLegacy() {
    final inFlight = _drainFuture;
    if (inFlight != null) return inFlight;
    if (_closed) return Future.value();
    return _drainFuture = _runDrain().whenComplete(() => _drainFuture = null);
  }

  Future<void> _runDrain() async {
    _drainDone = false;
    const batchSize = 32;
    var batch = <String>[];
    for (final key in _legacyResidue.toList()) {
      if (_closed) return;
      batch.add(key);
      if (batch.length >= batchSize) {
        await _drainBatch(batch);
        batch = <String>[];
        // Yield so a foreground burst (history decrypt pass) is not
        // competing with the migration for the platform channel.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    if (batch.isNotEmpty) await _drainBatch(batch);
    _drainDone = true;
  }

  Future<void> _drainBatch(List<String> keys) async {
    for (final key in keys) {
      try {
        if (!_legacy.containsKey(key)) {
          _legacyResidue.remove(key);
          continue;
        }
        final v = _view[key];
        var persisted = true;
        if (v is String) {
          persisted = await setString(key, v);
        } else if (v is int) {
          persisted = await setInt(key, v);
        }
        // v == null: the record was removed from the store after seeding;
        // the prefs copy is pure residue.
        if (!persisted) continue; // retry next drain
        if (await _legacy.remove(key)) {
          _legacyResidue.remove(key);
        }
      } catch (_) {
        // Key stays in residue; next drain retries.
      }
    }
    // File-level residue in the old XML after the keys are gone is
    // best-effort territory (the platform rewrites the file on its own
    // schedule); documented honestly rather than promised away.
  }

  // ── Sealing ──────────────────────────────────────────────────────────────

  Future<Uint8List?> _sealWith(Uint8List raw, String value) =>
      _sealer.seal(raw, Uint8List.fromList(utf8.encode(value)));

  /// Round-trips a probe under [raw] to tell the two meanings of a refused
  /// unseal apart: a healthy cipher rejecting bytes that are not what we
  /// sealed (evidence of corruption) versus the cipher itself failing —
  /// webcrypto/BoringSSL can throw under memory pressure, and rotation runs
  /// from the app-background hook, exactly when the OS is reclaiming.
  Future<bool> _cipherHealthy(Uint8List raw) async {
    final probe = Uint8List.fromList(const [0x66, 0x70, 0x61, 0x65]);
    final sealed = await _sealer.seal(raw, probe);
    if (sealed == null) return false;
    final back = await _sealer.unseal(raw, sealed);
    return back != null && listEquals(back, probe);
  }

  /// Resolves once no sealed write is mid-flight; false when they do not
  /// settle promptly — a stuck platform channel must DEFER the shred, never
  /// let it proceed unproven.
  Future<bool> _sealedWritesIdle() {
    if (_sealedWrites == 0) return Future.value(true);
    final waiter = _sealedIdle ??= Completer<void>();
    return waiter.future
        .then((_) => true)
        .timeout(const Duration(seconds: 10), onTimeout: () => false);
  }

  Future<String?> _unseal(String kid, Uint8List raw, Uint8List sealed) async {
    final plain = await _sealer.unseal(raw, sealed);
    if (plain == null) return null;
    try {
      return utf8.decode(plain);
    } catch (_) {
      // Authenticated bytes that are not UTF-8: not a record we wrote.
      return null;
    }
  }

  // ── Rotation ─────────────────────────────────────────────────────────────

  bool get rotationPending => _shredGen != _shredDoneGen;

  Future<void> _stampShred() async {
    _shredGen++;
    if (!await _db.setMeta(_metaShredGen, '$_shredGen')) {
      // The row is gone but the durable obligation is not recorded. The purge
      // itself must not fail on this; make the gap visible instead.
      E2ePersistentDiag.record('ROTATION_STAMP_FAILED', {'phase': 'shred'});
    }
  }

  void _scheduleRotation() {
    if (_closed || !rotationPending) return;
    _debounce?.cancel();
    _debounce = Timer(_rotationDebounce, () => unawaited(rotateNow()));
    _deadline ??= Timer(_rotationDeadline, () => unawaited(rotateNow()));
  }

  /// Runs one full rotation if one is owed. Public for the app-background
  /// hook and tests; safe to call at any time.
  ///
  /// One rotation in flight at most. Purges arriving mid-rotation bump
  /// `shred_gen`, so completion of THIS rotation does not clear the pending
  /// flag and the next cycle folds them in — never a queue of overlapping
  /// rotations.
  Future<void> rotateNow() async {
    if (_rotating || _closed || !rotationPending) return;
    _rotating = true;
    _debounce?.cancel();
    _deadline?.cancel();
    _debounce = null;
    _deadline = null;
    try {
      final g0 = _shredGen;

      final inventory = await _keys.inventory();
      if (inventory == null) return _retryLater('inventory');

      final ({String kid, Uint8List raw}) armed;
      try {
        armed = await _mintAndArm();
      } on ContentStoreUnavailable catch (e) {
        return _retryLater(e.stage);
      }
      final newKid = armed.kid;
      final newRaw = armed.raw;

      final retiring = Map<String, Uint8List>.of(_rawKeys)
        ..addAll(inventory.keys)
        ..remove(newKid);
      _activeKid = newKid;
      _rawKeys[newKid] = newRaw;

      // Writes that captured a retiring key before the flip above are still
      // in flight; every write STARTED after it seals under `newKid`. Waiting
      // here is what makes "nothing live is left under a retiring key"
      // provable — without it a record could commit under a key this pass
      // already drained, and the destroy below would take it along.
      if (!await _sealedWritesIdle()) return _retryLater('quiesce');

      // Re-seal survivors, oldest keys first, in bounded all-or-nothing
      // batches. An abort at any point leaves a resumable state: rows still
      // carry their old kid and the pending stamp is untouched.
      final skipped = <String>{};
      final corruptByUid = <int, Set<int>>{};
      for (final entry in retiring.entries) {
        while (true) {
          final rows = await _db.rowsByKid(entry.key, 64);
          final pending = rows.where((r) => !skipped.contains(r.k)).toList();
          if (pending.isEmpty) break;
          final resealed = <RecordRow>[];
          for (final row in pending) {
            final sealed = row.sealed;
            final plain = sealed == null
                ? null
                : await _unseal(entry.key, entry.value, sealed);
            if (plain == null) {
              // A refused unseal is AMBIGUOUS. Only a cipher that still
              // round-trips a probe makes it evidence of corruption; a cipher
              // that just failed would otherwise cost this row its key while
              // the same bytes read fine minutes ago at open.
              if (!await _cipherHealthy(entry.value)) {
                return _retryLater('cipher');
              }
              skipped.add(row.k);
              final m = _idBearingKey.firstMatch(row.k);
              if (m != null) {
                corruptByUid
                    .putIfAbsent(int.parse(m.group(1)!), () => <int>{})
                    .add(int.parse(m.group(2)!));
              }
              continue;
            }
            final newSealed = await _sealWith(newRaw, plain);
            if (newSealed == null) return _retryLater('reseal');
            resealed.add(RecordRow(k: row.k, kid: newKid, sealed: newSealed));
          }
          if (resealed.isNotEmpty && !await _db.putMany(resealed)) {
            return _retryLater('commit');
          }
        }
      }

      // Non-DB artifacts sealed under retiring keys (voice-note files).
      if (retiring.isNotEmpty &&
          !await _audioResealer(retiring, newKid, newRaw)) {
        return _retryLater('audio');
      }

      // Last gate before the irreversible step: prove no readable row is
      // still filed under a retiring key. Anything that landed between the
      // reseal pass and here defers the shred to the next cycle rather than
      // being destroyed by it.
      if (!await _sealedWritesIdle()) return _retryLater('quiesce');
      for (final kid in retiring.keys) {
        final left = await _db.rowsByKid(kid, 64);
        if (left.any((r) => !skipped.contains(r.k))) {
          return _retryLater('late-rows');
        }
      }

      // Only now is nothing live left under the old keys: destroy them. THIS
      // is the shred — residue everywhere (freelist, WAL, replaced files)
      // becomes ciphertext under keys that no longer exist.
      var allDestroyed = true;
      for (final kid in retiring.keys) {
        if (await _keys.destroyContentKey(kid)) {
          _rawKeys.remove(kid);
        } else {
          allDestroyed = false;
        }
      }
      if (!allDestroyed) return _retryLater('destroy');

      // Provably corrupt rows have no key at all now: retire their ids so
      // history renders "no longer stored" in THIS session instead of
      // live-decrypting a consumed ciphertext into a terminal failure.
      for (final entry in corruptByUid.entries) {
        await _foldRetired(entry.key, entry.value);
      }
      if (skipped.isNotEmpty) {
        E2ePersistentDiag.record('ROTATION_SKIPPED_ROWS', {
          'rows': skipped.length,
        });
      }

      await _db.vacuumHint();

      _shredDoneGen = g0;
      if (!await _db.setMeta(_metaShredDoneGen, '$g0')) {
        // Memory says done, disk does not: the next open re-runs one rotation,
        // which is idempotent — but the field should know the stamp is
        // unreliable on this device.
        E2ePersistentDiag.record('ROTATION_STAMP_FAILED', {'phase': 'done'});
      }
      if (rotationPending) {
        // Purges folded in mid-rotation; owe another cycle.
        _scheduleRotation();
      }
    } finally {
      _rotating = false;
    }
  }

  void _retryLater(String stage) {
    E2ePersistentDiag.record('ROTATION_RETRY', {'stage': stage});
    if (!_closed) {
      _deadline?.cancel();
      _deadline = Timer(_rotationDeadline, () => unawaited(rotateNow()));
    }
  }

  /// The live store of this process, or null (web, fallback session, not yet
  /// opened). The audio cache and the app-background hook reach it here; the
  /// record path never does — it goes through the [ContentKv] seam.
  static NativeContentStore? instance;

  /// Seal decrypted voice-note bytes under the ACTIVE content key, or null
  /// when sealing is unavailable (caller then writes plaintext — the same
  /// honest fallback as the record path, and the file still dies with its
  /// message purge; it just has no shred story until sealed).
  Future<Uint8List?> sealAudioBytes(Uint8List plain) {
    final raw = _rawKeys[_activeKid];
    if (raw == null) return Future.value();
    return SealedAudioCodec.seal(
      kid: _activeKid,
      keyBytes: raw,
      plaintext: plain,
    ).then<Uint8List?>((b) => b, onError: (_) => null);
  }

  /// Unseal a cached voice-note file, or null when [bytes] is sealed under a
  /// key this device no longer holds (caller re-downloads: the message record
  /// still carries the only mediaKey/mediaIv, so the cache is re-derivable —
  /// unlike message plaintext).
  Future<Uint8List?> unsealAudioBytes(Uint8List bytes) async {
    final kid = SealedAudioCodec.kidOf(bytes);
    if (kid == null) return null;
    final raw = _rawKeys[kid];
    if (raw == null) return null;
    return SealedAudioCodec.unseal(bytes: bytes, keyBytes: raw);
  }

  /// App moving to background: last chance this process may get. Fires the
  /// owed rotation immediately instead of waiting out the debounce.
  Future<void> onAppBackground() => rotateNow();

  Future<void> close() async {
    _closed = true;
    if (identical(instance, this)) instance = null;
    _debounce?.cancel();
    _deadline?.cancel();
    await _db.close();
  }

  @visibleForTesting
  bool get debugDrainDone => _drainDone && _legacyResidue.isEmpty;

  @visibleForTesting
  String get debugActiveKid => _activeKid;
}

