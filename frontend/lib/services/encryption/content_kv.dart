import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// The storage seam under [EncryptionService]'s plaintext-record machinery.
///
/// Every persisted plaintext artifact — decrypted records, the raw replay
/// cache, pending-send records, the purge backlog, retention stamps, the
/// retired-id set — historically went through raw [SharedPreferences]. That
/// backend is being replaced on native (encrypted DB, issue #105 M4) WITHOUT
/// touching the semantics above it: commit-gated removals, the durable purge
/// backlog, two-phase expiry, reconcile, retention, the LRU — all of it was
/// paid for in the field and survives unchanged. So this interface mirrors the
/// exact [SharedPreferences] surface those code paths use, shape for shape:
///
///  * READS ARE SYNCHRONOUS against a loaded view. [SharedPreferences] serves
///    reads from its in-memory cache; the native store loads its records once
///    at open and serves reads the same way. Callers may loop `getString` over
///    thousands of keys without paying a round trip each.
///  * WRITES RETURN THE COMMIT RESULT. `setString`/`remove` answering `false`
///    is load-bearing: a dropped write is how a decrypted message later
///    re-decrypts, hits DuplicateMessage and bricks to a permanent
///    "[Decryption failed]" (see `saveDecryptedContent`). An implementation
///    must never report success for a write it cannot prove committed.
///  * [reload] is the cross-context coherence point. On web, another PWA
///    engine may have written plaintext this engine has not seen; serving a
///    stale snapshot there means a cache miss on a consumed ciphertext. On
///    native there is one process, so it is a no-op.
abstract class ContentKv {
  /// Refresh the read view from the backing store where another context can
  /// have written to it. Web-only concern; a no-op elsewhere.
  Future<void> reload();

  /// A snapshot of the BACKING STORE keyed exactly like [getString], or null
  /// when this backend's read view cannot go stale and [getString] is already
  /// authoritative.
  ///
  /// WHY THIS EXISTS. [reload] on the prefs backend refills its in-memory cache
  /// from a snapshot taken across an await; a write landing inside that window
  /// survives in the store but is DROPPED from the cache. For a plaintext
  /// record that false miss is not "no plaintext" — the caller re-decrypts a
  /// ciphertext whose Signal ratchet key was consumed at first decrypt, hits
  /// DuplicateMessage, and the row becomes a permanent "[Decryption failed]"
  /// while its only readable copy is still on disk. That shipped as the
  /// 2026-07-29 incident.
  ///
  /// Locking cannot close it: the Signal session stores reload the same
  /// underlying singleton throughout decrypt. So the record readers ask the
  /// backend for ground truth instead, and each backend decides what that
  /// means — which is why this lives here and not in `EncryptionService`.
  ///
  /// Implementations MUST return keys in the same namespace [getString] takes,
  /// with any storage-level prefix already stripped.
  Future<Map<String, Object>?> authoritativeSnapshot();

  String? getString(String key);

  int? getInt(String key);

  bool containsKey(String key);

  /// Every key currently in the store. Prefix scans over this set are how all
  /// sweeps enumerate records; implementations must return the complete live
  /// key set, not a filtered view.
  Set<String> getKeys();

  /// Returns whether the value durably committed. Implementations retry
  /// nothing themselves — the callers own their retry policy.
  Future<bool> setString(String key, String value);

  Future<bool> setInt(String key, int value);

  /// Returns whether the removal durably committed. Removing an absent key
  /// succeeds ([SharedPreferences] semantics — callers distinguish presence
  /// via [containsKey] BEFORE removing, see `removeDecryptedContent`).
  Future<bool> remove(String key);
}

/// [SharedPreferences]-backed [ContentKv]: the historical behavior, verbatim.
///
/// This is the ONLY backend on web (localStorage writes are synchronous in JS
/// and survive tab close, which is why the records live there and not in
/// IndexedDB) and the fallback on native when the encrypted store cannot open
/// or arm — per the armed-gate rule, an unarmed device keeps writing the
/// legacy way rather than risk sealing records under a key that never
/// persisted.
class PrefsContentKv implements ContentKv {
  PrefsContentKv(this._prefs);

  static Future<PrefsContentKv> open() async =>
      PrefsContentKv(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  /// Web-only, same rule as the previous inline `_reloadPrefsForCrossContext`:
  /// on web `reload()` is a full localStorage enumeration (measured 65-77 ms
  /// per 50-row pass when called per row), so callers pay it once per pass —
  /// and on native the plugin cache is authoritative within the process.
  @override
  Future<void> reload() async {
    if (kIsWeb) await _prefs.reload();
  }

  /// Web only. `reload()` already pays for exactly this enumeration, so ground
  /// truth costs nothing extra there. Off web nothing clears the cache, so the
  /// answer is null and callers keep the free synchronous read.
  ///
  /// Strips the backend prefix so callers never learn it. Hardcoded because the
  /// package exposes [SharedPreferences.setPrefix] but no getter, and this app
  /// never changes it; pinned by test so a package change fails loudly instead
  /// of silently answering null for every record. Shared with the sealed web
  /// backend, which strips the same prefix from the same platform store.
  static const String storePrefix = 'flutter.';

  /// Forces the web branch under `flutter test`, which runs on the Dart VM with
  /// [kIsWeb] false and this backend selected. Without it the reload-race suite
  /// would exercise the cache path — precisely the one it exists to prove
  /// broken — and pass while proving nothing.
  @visibleForTesting
  static bool debugForceAuthoritative = false;

  @override
  Future<Map<String, Object>?> authoritativeSnapshot() async {
    if (!kIsWeb && !debugForceAuthoritative) return null;
    final raw = await SharedPreferencesStorePlatform.instance.getAll();
    return <String, Object>{
      for (final entry in raw.entries)
        (entry.key.startsWith(storePrefix)
                ? entry.key.substring(storePrefix.length)
                : entry.key):
            entry.value,
    };
  }

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  int? getInt(String key) => _prefs.getInt(key);

  @override
  bool containsKey(String key) => _prefs.containsKey(key);

  @override
  Set<String> getKeys() => _prefs.getKeys();

  @override
  Future<bool> setString(String key, String value) =>
      _prefs.setString(key, value);

  @override
  Future<bool> setInt(String key, int value) => _prefs.setInt(key, value);

  @override
  Future<bool> remove(String key) => _prefs.remove(key);
}

/// Thrown by a sealed-store opener (`NativeContentStore.open` on Android,
/// `SealedWebContentKv.open` on web) when the store cannot be safely armed.
/// The stage names the first check that failed; the caller records it. The
/// web falls back to the legacy prefs backend for the session; Android fails
/// closed (hardening A3). Lives here, not in
/// the native store, so the web opener can use it without pulling the
/// drift/SQLCipher backend into a web build.
class ContentStoreUnavailable implements Exception {
  const ContentStoreUnavailable(this.stage, {this.locked = false});

  final String stage;

  /// True when the store could not be armed because passcode-wrapped keys are
  /// present but LOCKED. The caller must NOT fall back to the plaintext
  /// backend in that case: the decrypted-message cache would be written in
  /// cleartext while the app is still locked, which inverts the whole point
  /// of wrapping. Fail closed and wait for the unlock instead.
  final bool locked;

  @override
  String toString() =>
      'ContentStoreUnavailable($stage${locked ? ', locked' : ''})';
}
