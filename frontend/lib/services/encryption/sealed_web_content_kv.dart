import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../../utils/e2e_diag_log.dart';
import '../../utils/e2e_persistent_diag.dart';
import '../plaintext_record_codec.dart';
import 'content_key_manager.dart';
import 'content_kv.dart';
import 'content_sealer.dart';
import 'sealed_web_envelope.dart';
import 'session_cross_context_lock.dart';

/// The sealed web backend of the [ContentKv] seam
/// (`docs/design/web-content-sealing.md`).
///
/// Values of the three plaintext-bearing key families — `_decrypted_`,
/// `_decrypt_raw_v1_`, `_pendsend_v1_` — are AES-256-GCM envelopes
/// ([SealedWebEnvelope]) over the SAME SharedPreferences/localStorage backing
/// store `PrefsContentKv` uses; every other key (control records: retired set,
/// ledger, purge backlog, markers, diag) passes through verbatim, because
/// control records are precisely what must stay readable after a key loss.
///
/// ## The three rules that must never regress
///
///  * **A seal/unseal failure reads as UNDETERMINED, never absent.** The
///    ledger gate retires permanently on `recordExists == false`, and
///    `recordExists` decides presence on raw bytes before any decode — so an
///    unsealable row is served AS ITS RAW ENVELOPE STRING (present but
///    undecodable), and [authoritativeSnapshot] is TOTAL: it never returns a
///    non-throwing null, never omits a backing-store key, and propagates an
///    enumeration failure as a throw so `recordExists`'s own catch answers
///    null.
///  * **Proven key loss is only provable inside the open lock.** This seam is
///    multi-engine by contract; without serialization, an engine whose
///    inventory snapshot predates a peer's mint would misread rows sealed
///    under the fresh kid as key loss and retire readable history. The whole
///    open-time critical section (inventory → mint/arm → row scan → retire
///    fold) runs under [lockName]; mid-session unknown kids are NEVER
///    retired — they render present-but-unreadable until the next locked
///    open.
///  * **The drain never overwrites unverified.** Migration replaces a legacy
///    plaintext value in place, so the envelope is round-trip-verified IN RAM
///    before the destructive write; the post-write read-back is byte equality
///    only and can no longer lose data.
class SealedWebContentKv implements ContentKv {
  SealedWebContentKv._(this._prefs, this._keys, this._sealer, this._lock);

  /// Cross-context Web Lock serializing mint and the proven-loss fold. Its
  /// own name: it touches no SessionRecord and no ledger, so it must not
  /// reuse those locks.
  static const String lockName = 'fireplace-e2e-content-keys';

  /// Device-wide active-kid marker. OUTSIDE the `e2e_<uid>_` namespace so
  /// `clearAllKeys` (logout/account deletion) cannot sweep it — the store is
  /// shared across accounts on the device, like the Android meta row.
  static const String activeKidKey = 'fp_content_active_kid_v1';

  /// `contact_v1_` (the client-owned contact list, `services/contacts/`) is
  /// sealed like the message families: the contact graph is the metadata the
  /// whole design exists to keep off the server, so it must not sit in clear
  /// localStorage either. It carries no message id, so [_retireIdKey] never
  /// matches it and a lost-kid contact row is served as its raw envelope
  /// (present, undecodable) — `ContactStore` counts it and moves on.
  /// `boxreq_v1` (this device's box request queue, `ContactStore
  /// .requestQueueKey`) holds the queue's private auth + seal halves; a
  /// lost-kid row reads undecodable and `ContactStore` replaces it.
  /// `boxin_v1_` (the box delivery journal, `contact_store_inbox.dart`) holds
  /// Signal ciphertext beside the peer it came from.
  static final RegExp _familyKey = RegExp(
    r'^e2e_\d+_(decrypted_|decrypt_raw_v1_|pendsend_v1_|contact_v1_|boxreq_v1|boxin_v1_)',
  );
  static final RegExp _retireIdKey = RegExp(
    r'^e2e_(\d+)_(?:decrypted_|decrypt_raw_v1_)(\d+)$',
  );
  static final RegExp _decryptedKey = RegExp(r'^e2e_\d+_decrypted_\d+$');

  /// Whether [key] belongs to a family whose value this store seals.
  static bool isSealedFamilyKey(String key) => _familyKey.hasMatch(key);

  final SharedPreferences _prefs;
  final ContentKeyManager _keys;
  final ContentSealer _sealer;
  final SessionCrossContextLockRunner _lock;

  /// Plaintext (or raw envelope, when unsealable) per sealed-family key.
  final Map<String, String> _view = <String, String>{};

  /// envelope string → plaintext. Envelopes are unique (fresh random IV per
  /// seal), so this makes [reload]/[authoritativeSnapshot] re-unseal only
  /// strings never seen before. Pruned to the live envelope set on every
  /// rebuild so a long-lived PWA session cannot accumulate one plaintext
  /// entry per envelope ever observed.
  final Map<String, String> _unsealMemo = <String, String>{};

  /// Sealing keys as of the last successful inventory. Refreshed at most once
  /// per rebuild/snapshot when an unknown kid appears (another engine minted
  /// mid-session).
  Map<String, Uint8List> _knownKeys = <String, Uint8List>{};

  /// Nullable, not `late`: [revoke] must be able to DROP the reference. The
  /// sealer memoizes its imported `AesGcmSecretKey` in an `Expando` keyed on
  /// this exact object, so a surviving reference keeps a usable key alive in
  /// RAM even after the bytes are zeroed.
  String? _activeKid;
  Uint8List? _activeKey;

  /// Set by [revoke].
  bool _revoked = false;

  /// Legacy plaintext rows of the sealed families awaiting the drain.
  final Set<String> _legacyResidue = <String>{};

  Future<void>? _drainFuture;

  /// Opens and ARMS the store, or throws [ContentStoreUnavailable] with the
  /// failing stage — the caller falls back to [PrefsContentKv] for the
  /// session and records the stage in diagnostics.
  static Future<SealedWebContentKv> open({
    required SharedPreferences prefs,
    required ContentKeyManager keys,
    required ContentSealer sealer,
    SessionCrossContextLockRunner? lock,
  }) async {
    final store = SealedWebContentKv._(
      prefs,
      keys,
      sealer,
      lock ?? runSessionCrossContextLocked,
    );
    await store._lock(lockName, store._openLocked);
    if (store._legacyResidue.isNotEmpty) {
      unawaited(store._drainLegacy());
    }
    return store;
  }

  /// Forgets every key AND every decrypted row this store holds, so a
  /// mid-session passcode re-lock is a real revocation rather than a UI
  /// barrier (`frontend/CLAUDE.md` §10a).
  ///
  /// This store is the one that matters most: `_view` holds the PLAINTEXT of
  /// every sealed row it has read this session, and `_unsealMemo` holds one
  /// plaintext per envelope string. Dropping the keys without dropping those
  /// two would leave the message bodies in RAM.
  ///
  /// Storage is untouched — the sealed rows become present-but-undecodable,
  /// which is exactly the state the three rules above already define, so
  /// `recordExists` still answers TRUE and nothing gets retired as lost. The
  /// only behaviour change is that sealed WRITES are refused
  /// ([setString] returns false) instead of sealing under a dropped key.
  ///
  /// One honest limit: rows still awaiting the legacy drain are cleartext ON
  /// DISK, so revocation cannot make them unreadable. It stops the drain
  /// rather than re-sealing them under a key that no longer exists.
  void revoke() {
    if (_revoked) return;
    _revoked = true;
    for (final key in _knownKeys.values) {
      key.fillRange(0, key.length, 0);
    }
    _knownKeys = <String, Uint8List>{};
    _activeKey = null;
    _activeKid = null;
    _view.clear();
    _unsealMemo.clear();
    _legacyResidue.clear();
  }

  Future<void> _openLocked() async {
    final openedAt = DateTime.now();
    // Fresh view: another engine can have written since this engine's
    // snapshot was taken, and the proven-loss fold below must see every row.
    if (kIsWeb) await _prefs.reload();

    final inventory = await _keys.inventory();
    if (inventory == null) {
      // Enumeration itself failed. Change NOTHING: a transient secure-storage
      // hiccup misread as "keys gone" would retire the whole history.
      throw const ContentStoreUnavailable('inventory');
    }
    if (inventory.lockedKeyCount > 0) {
      // Passcode-wrapped keys are present but cannot be opened. Unlike a
      // genuinely unavailable store this must NOT degrade to the plaintext
      // backend (see `ContentStoreUnavailable.locked`) — nor may the fold
      // below run, because every sealed row would look key-less and get
      // retired as proven loss.
      throw const ContentStoreUnavailable('locked', locked: true);
    }
    _knownKeys = Map<String, Uint8List>.of(inventory.keys);

    final sealedRows = <String, SealedWebEnvelope>{};
    final plainRows = <String>[];
    for (final key in _prefs.getKeys()) {
      if (!isSealedFamilyKey(key)) continue;
      final value = _prefs.getString(key);
      if (value == null) continue;
      final env = SealedWebEnvelope.tryParse(value);
      if (env != null) {
        sealedRows[key] = env;
      } else {
        plainRows.add(key);
      }
    }

    if (_knownKeys.isEmpty && sealedRows.isNotEmpty) {
      // Sealed rows exist but the enumeration held no content key at all: a
      // genuinely wiped secure store also wiped the Signal identity, which
      // has its own failure path. Unavailable-not-wiped, same as Android.
      throw const ContentStoreUnavailable('empty-enumeration');
    }

    await _armActiveKid();

    // Unseal pass. Kids missing from the successfully enumerated inventory
    // are PROVEN loss — provable only here, inside the lock: any kid observed
    // in a row was armed (written + read back) before that row was written,
    // and this inventory was taken after acquiring the lock.
    var unreadable = 0;
    var lostRows = 0;
    final lostKids = <String>{};
    final lostByUid = <int, Set<int>>{};
    final unreadableUids = <int>{};
    for (final entry in sealedRows.entries) {
      final env = entry.value;
      final raw = _knownKeys[env.kid];
      if (raw == null) {
        lostKids.add(env.kid);
        lostRows++;
        final m = _retireIdKey.firstMatch(entry.key);
        if (m != null) {
          lostByUid
              .putIfAbsent(int.parse(m.group(1)!), () => <int>{})
              .add(int.parse(m.group(2)!));
        }
        _view[entry.key] = _prefs.getString(entry.key)!;
        continue;
      }
      final plain = await _unsealToString(raw, env);
      if (plain == null) {
        // Key present, bytes refuse: corruption/tamper. Present-but-
        // unreadable, NEVER absent and NEVER retired.
        unreadable++;
        final m = _retireIdKey.firstMatch(entry.key);
        if (m != null) unreadableUids.add(int.parse(m.group(1)!));
        _view[entry.key] = _prefs.getString(entry.key)!;
      } else {
        _view[entry.key] = plain;
        _unsealMemo[env.encode()] = plain;
      }
    }

    // Legacy plaintext rows: served verbatim (read-both) until the drain
    // seals them. Correctness never depends on the drain finishing. Seeded
    // BEFORE the retirement fold so the readable-sibling check below sees
    // every source the runtime gate would.
    for (final key in plainRows) {
      _view[key] = _prefs.getString(key)!;
      _legacyResidue.add(key);
    }

    // Retired rows are never deleted — the key may come back. And an id is
    // only retired when NO readable source survives: the runtime gate
    // (messaging_provider.decrypt) retires on `recordExists == false &&
    // rawReplayExists == false`, so the open-time fold must be no more
    // aggressive — a decrypted_ row lost with kid K1 while the same id's
    // decrypt_raw_v1_ row is readable under a surviving K2 (or as legacy
    // plaintext) is still SERVABLE, and retiring it would over-destroy
    // (review finding D2).
    for (final entry in lostByUid.entries) {
      final uid = entry.key;
      final ids = entry.value
          .where(
            (id) =>
                !_readableInView('e2e_${uid}_decrypted_$id') &&
                !_readableInView('e2e_${uid}_decrypt_raw_v1_$id'),
          )
          .toSet();
      if (ids.isNotEmpty) await _foldRetired(uid, ids);
    }
    if (lostKids.isNotEmpty) {
      // The kid VALUES are the forensically useful part of a key-loss dump;
      // bounded so a pathological store cannot bloat the durable log.
      E2ePersistentDiag.record('CONTENT_KEY_LOST', {
        'kids': (lostKids.take(8).toList()..sort()).join(','),
        'rows': lostRows,
        'accounts': lostByUid.length,
      });
    }
    if (unreadable > 0) {
      // Deduped by construction: recorded at most once per open, aggregate.
      // Same field shape as the Android store's event.
      E2ePersistentDiag.record('CONTENT_RECORDS_UNREADABLE', {
        'rows': unreadable,
        'accounts': unreadableUids.length,
      });
    }

    E2eDiagLog.add('WEB_SEAL_OPEN', {
      'sealed': sealedRows.length,
      'legacy': plainRows.length,
      'unreadable': unreadable,
      'lostRows': lostRows,
      'ms': DateTime.now().difference(openedAt).inMilliseconds,
    });
  }

  /// Picks or mints the active kid, ARMED: a minted key counts only after it
  /// is read back out of a FRESH secure-storage enumeration.
  Future<void> _armActiveKid() async {
    final marker = _prefs.getString(activeKidKey);
    var kid = (marker != null && _knownKeys.containsKey(marker))
        ? marker
        : null;
    if (kid == null && _knownKeys.isNotEmpty) {
      // Marker lost/stale but keys survive: any inventory key seals fine.
      // Deterministic pick so concurrent engines converge.
      kid = (_knownKeys.keys.toList()..sort()).last;
    }
    if (kid == null) {
      final minted = await _keys.mintContentKey();
      if (minted == null) throw const ContentStoreUnavailable('mint');
      final raw = (await _keys.inventory())?.keys[minted];
      if (raw == null) throw const ContentStoreUnavailable('arm');
      _knownKeys[minted] = raw;
      kid = minted;
    }
    if (marker != kid && !await _prefs.setString(activeKidKey, kid)) {
      throw const ContentStoreUnavailable('meta');
    }
    _activeKid = kid;
    _activeKey = _knownKeys[kid]!;
  }

  /// Merge [ids] into the persisted retired-id set for [uid], mirroring
  /// `EncryptionService.markRetired` exactly (bounded, highest ids kept).
  Future<void> _foldRetired(int uid, Set<int> ids) async {
    const cap = 5000;
    final key = 'e2e_${uid}_retired_v1';
    final existing = <int>{};
    final raw = _prefs.getString(key);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) existing.addAll(decoded.whereType<int>());
      } catch (_) {}
    }
    final sorted = (existing..addAll(ids)).toList()..sort();
    final kept = sorted.length > cap
        ? sorted.sublist(sorted.length - cap)
        : sorted;
    await _prefs.setString(key, jsonEncode(kept));
  }

  Future<String?> _unsealToString(Uint8List raw, SealedWebEnvelope env) async {
    final plain = await _sealer.unseal(raw, env.bytes);
    if (plain == null) return null;
    try {
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  /// Resolves the sealing key for [kid], refreshing the inventory AT MOST
  /// once per pass when an unknown kid appears (another engine minted after
  /// this engine's open). A kid still unknown after the refresh is served
  /// present-but-unreadable — mid-session skew NEVER retires.
  Future<Uint8List?> _keyForKid(String kid, _InventoryRefresh refresh) async {
    // Revoked: never resolve a key again, and never pay the enumeration to
    // learn what the locked vault would answer anyway (`lockedKeyCount > 0`
    // with an empty key map). Rows stay present-but-undecodable.
    if (_revoked) return null;
    final known = _knownKeys[kid];
    if (known != null) return known;
    if (refresh.spent) return null;
    refresh.spent = true;
    final inventory = await _keys.inventory();
    if (inventory == null) return null;
    _knownKeys = Map<String, Uint8List>.of(inventory.keys);
    return _knownKeys[kid];
  }

  // ── ContentKv ─────────────────────────────────────────────────────────────

  @override
  Future<void> reload() async {
    if (kIsWeb) await _prefs.reload();
    final refresh = _InventoryRefresh();
    final liveEnvelopes = <String>{};
    final liveKeys = <String>{};
    for (final key in _prefs.getKeys()) {
      if (!isSealedFamilyKey(key)) continue;
      liveKeys.add(key);
      final value = _prefs.getString(key);
      if (value == null) continue;
      final env = SealedWebEnvelope.tryParse(value);
      if (env == null) {
        // Legacy plaintext (read-both) — e.g. written by a fallback session
        // in another engine. Serve verbatim and queue for the drain.
        _view[key] = value;
        if (_legacyResidue.add(key) && _drainFuture == null) {
          unawaited(_drainLegacy());
        }
        continue;
      }
      liveEnvelopes.add(value);
      final memo = _unsealMemo[value];
      if (memo != null) {
        _view[key] = memo;
        continue;
      }
      final raw = await _keyForKid(env.kid, refresh);
      final plain = raw == null ? null : await _unsealToString(raw, env);
      if (plain == null) {
        _view[key] = value;
      } else {
        _view[key] = plain;
        _unsealMemo[value] = plain;
      }
    }
    // Rows removed by another engine leave the view; the memo is pruned to
    // the live envelope set (fresh IVs make every write a new envelope).
    _view.removeWhere((key, _) => !liveKeys.contains(key));
    _legacyResidue.removeWhere((key) => !liveKeys.contains(key));
    _unsealMemo.removeWhere((env, _) => !liveEnvelopes.contains(env));
  }

  /// TOTAL by contract (design §3.1): never a non-throwing null, never an
  /// omitted key; enumeration failure PROPAGATES so `recordExists`'s catch
  /// answers null (undetermined) instead of a stale-view false (absent →
  /// permanent retirement).
  @override
  Future<Map<String, Object>?> authoritativeSnapshot() async {
    final raw = await SharedPreferencesStorePlatform.instance.getAll();
    final refresh = _InventoryRefresh();
    final out = <String, Object>{};
    for (final entry in raw.entries) {
      final key = entry.key.startsWith(PrefsContentKv.storePrefix)
          ? entry.key.substring(PrefsContentKv.storePrefix.length)
          : entry.key;
      var value = entry.value;
      if (value is String && isSealedFamilyKey(key)) {
        final env = SealedWebEnvelope.tryParse(value);
        if (env != null) {
          final memo = _unsealMemo[value];
          if (memo != null) {
            value = memo;
          } else {
            final keyBytes = await _keyForKid(env.kid, refresh);
            final plain = keyBytes == null
                ? null
                : await _unsealToString(keyBytes, env);
            if (plain != null) {
              _unsealMemo[value] = plain;
              value = plain;
            }
            // plain == null: keep the raw envelope — present, undecodable.
          }
        }
      }
      out[key] = value;
    }
    return out;
  }

  @override
  String? getString(String key) {
    if (!isSealedFamilyKey(key)) return _prefs.getString(key);
    final held = _view[key];
    if (held != null) return held;
    // Not in the view (e.g. landed cross-engine since the last reload): the
    // raw value is still PRESENT — serve plaintext verbatim, or the envelope
    // string for a sealed row (present-but-unreadable until the next
    // reload unseals it). Never null for a key that exists.
    final raw = _prefs.getString(key);
    if (raw == null) return null;
    return _unsealMemo[raw] ?? raw;
  }

  /// A view entry that is actual plaintext (unsealed or legacy) — a raw
  /// envelope held only for presence does not count as readable.
  bool _readableInView(String key) {
    final value = _view[key];
    return value != null && !SealedWebEnvelope.isEnvelope(value);
  }

  @override
  int? getInt(String key) => _prefs.getInt(key);

  @override
  bool containsKey(String key) => _prefs.containsKey(key);

  @override
  Set<String> getKeys() => _prefs.getKeys();

  @override
  Future<bool> setString(String key, String value) async {
    if (!isSealedFamilyKey(key)) return _prefs.setString(key, value);
    // Capture kid AND key bytes together before any await (Android gate 1):
    // a future rotation flipping the active kid mid-seal must never label a
    // row with a key that did not encrypt it.
    final kid = _activeKid;
    final keyBytes = _activeKey;
    // Revoked mid-session (passcode re-lock): a REFUSED write, exactly like a
    // refused seal. Writing plaintext here would put the message body in
    // cleartext localStorage while the app is locked.
    if (kid == null || keyBytes == null) return false;
    final sealed = await _sealer.seal(
      keyBytes,
      Uint8List.fromList(utf8.encode(value)),
    );
    // Null from the sealer is a REFUSED write, never empty content.
    if (sealed == null) return false;
    final envelope = SealedWebEnvelope(
      kid: kid,
      cid: _cidFor(key, value),
      bytes: sealed,
    ).encode();
    final committed = await _prefs.setString(key, envelope);
    if (committed) {
      _view[key] = value;
      _unsealMemo[envelope] = value;
      _legacyResidue.remove(key);
    }
    return committed;
  }

  @override
  Future<bool> setInt(String key, int value) => _prefs.setInt(key, value);

  @override
  Future<bool> remove(String key) async {
    final removed = await _prefs.remove(key);
    if (removed) {
      _view.remove(key);
      _legacyResidue.remove(key);
    }
    return removed;
  }

  /// The envelope's cleartext conversation id — erasure completeness: a
  /// session that cannot unseal this row must still be able to select it for
  /// a user-requested conversation deletion. Only the `_decrypted_` family
  /// carries one; pre-`_cid` legacy values seal with `-`, matching their
  /// documented unmatchability.
  int? _cidFor(String key, String value) {
    if (!_decryptedKey.hasMatch(key)) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        final cid = decoded[PlaintextRecordCodec.conversationIdKey];
        if (cid is int) return cid;
      }
    } catch (_) {}
    return null;
  }

  // ── Legacy drain ──────────────────────────────────────────────────────────

  /// Test/lifecycle hook: runs (or joins) a full drain pass.
  @visibleForTesting
  Future<void> debugDrainNow() => _drainFuture ?? _drainLegacy();

  @visibleForTesting
  String get debugActiveKid => _activeKid!;

  @visibleForTesting
  bool get debugRevoked => _revoked;

  @visibleForTesting
  Set<String> get debugLegacyResidue => Set.unmodifiable(_legacyResidue);

  Future<void> _drainLegacy() {
    final inFlight = _drainFuture;
    if (inFlight != null) return inFlight;
    return _drainFuture = _runDrain().whenComplete(() => _drainFuture = null);
  }

  Future<void> _runDrain() async {
    const batchSize = 32;
    var sealedCount = 0;
    final keys = _legacyResidue.toList();
    for (var start = 0; start < keys.length; start += batchSize) {
      final batch = keys.sublist(
        start,
        start + batchSize > keys.length ? keys.length : start + batchSize,
      );
      // Under the open lock: the drain re-seals under the active kid and must
      // not interleave with another engine's mint/fold (or future rotation).
      final ok = await _lock(lockName, () async {
        for (final key in batch) {
          final sealedOne = await _drainOne(key);
          if (sealedOne == null) return false; // abort: retry next session
          if (sealedOne) sealedCount++;
        }
        return true;
      });
      if (!ok) {
        E2eDiagLog.add('WEB_SEAL_DRAIN_ABORT', {'sealed': sealedCount});
        return;
      }
      // Yield so a foreground burst (history decrypt pass) is not competing
      // with the migration.
      await Future<void>.delayed(Duration.zero);
    }
    if (_legacyResidue.isEmpty && sealedCount > 0) {
      E2ePersistentDiag.record('WEB_SEAL_DRAIN_DONE', {'sealed': sealedCount});
    } else {
      E2eDiagLog.add('WEB_SEAL_DRAIN_PASS', {
        'sealed': sealedCount,
        'residue': _legacyResidue.length,
      });
    }
  }

  /// Seals one legacy row IN PLACE. Returns true when sealed, false when the
  /// row needed no work, null when the drain must abort for this session.
  ///
  /// Order is load-bearing (design §3.4, review finding H1): with in-place
  /// replacement there is exactly ONE value under the key at all times, so
  /// the envelope is round-trip-verified in RAM BEFORE the destructive write.
  /// A post-write failure can no longer lose data — the read-back is byte
  /// equality against what was just proven readable.
  Future<bool?> _drainOne(String key) async {
    final raw = _prefs.getString(key);
    if (raw == null || SealedWebEnvelope.isEnvelope(raw)) {
      _legacyResidue.remove(key);
      return false;
    }
    final kid = _activeKid;
    final keyBytes = _activeKey;
    // Revoked mid-drain: abort rather than replace the only copy of this row
    // with an envelope no key can open.
    if (kid == null || keyBytes == null) return null;
    final plainBytes = Uint8List.fromList(utf8.encode(raw));
    final sealed = await _sealer.seal(keyBytes, plainBytes);
    if (sealed == null) return null;
    // Verify BEFORE overwrite: the envelope must round-trip to the exact
    // plaintext while the plaintext still exists.
    final back = await _sealer.unseal(keyBytes, sealed);
    if (back == null || !listEquals(back, plainBytes)) return null;
    // Compare-and-set (review finding D1): the seal/unseal awaits yielded to
    // the foreground. An edit may have replaced this value (a stale
    // write-back would destroy the newer plaintext — the `_sessionTails`
    // lost-update shape) or a purge may have removed it (a write-back would
    // RESURRECT plaintext the user asked destroyed). No await between this
    // read and the write, so the check is atomic in-isolate.
    final current = _prefs.getString(key);
    if (current != raw) {
      if (current == null || SealedWebEnvelope.isEnvelope(current)) {
        // Removed, or already sealed by the foreground write: nothing left
        // for the drain to do.
        _legacyResidue.remove(key);
      }
      return false;
    }
    final envelope = SealedWebEnvelope(
      kid: kid,
      cid: _cidFor(key, raw),
      bytes: sealed,
    ).encode();
    if (!await _prefs.setString(key, envelope)) return null;
    if (_prefs.getString(key) != envelope) return null;
    _view[key] = raw;
    _unsealMemo[envelope] = raw;
    _legacyResidue.remove(key);
    return true;
  }
}

/// One-shot inventory-refresh budget per rebuild/snapshot pass: a pass that
/// meets ten rows under one unknown kid must not pay ten enumerations.
class _InventoryRefresh {
  bool spent = false;
}
