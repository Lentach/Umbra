import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/e2e_diag_log.dart';
import '../../utils/e2e_persistent_diag.dart';
import '../secure_kv.dart';
import 'content_key_manager.dart';
import 'content_key_wrap.dart';
import 'content_sealer.dart';
import 'sealed_sig_envelope.dart';
import 'sealed_web_signal_kv.dart';
import 'session_cross_context_lock.dart';

/// The four async operations every web Signal key-value backend exposes.
/// [WebSignalKvStore] is the historical plaintext behavior; the sealed store
/// and its fallback guard wrap it (docs/design/web-sig-sealing.md §3.1).
abstract class SigWebKv {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
  Future<Map<String, String>> readAll();
}

/// Platform-aware key-value storage for Signal Protocol keys.
///
/// **Web:** Uses ONLY SharedPreferences (localStorage). Historical reason: keys
/// vanished across tab closes. Uses SharedPreferencesAsync so Signal session
/// reads are not served from the legacy SharedPreferences in-memory cache after
/// another tab/client updates localStorage.
///
/// ⚠️ **The old rationale here — "flutter_secure_storage on web uses
/// IndexedDB+WebCrypto" — is FALSE, verified 2026-08-05 against the pinned
/// `flutter_secure_storage_web` 1.2.1 source.** That package uses
/// `window.localStorage` for everything and stores its AES-GCM master key
/// THERE TOO, raw and base64-encoded, under the `publicKey` option (default
/// literal `FlutterSecureStorage`): `generateKey(algorithm, true /* extractable
/// */, …)` → `exportKey("raw", …)` → `localStorage[key] = base64Encode(...)`
/// (`flutter_secure_storage_web.dart:110-116`); zero IndexedDB references in
/// the file. Consequences, both real: (1) moving Signal keys to
/// flutter_secure_storage on web would NOT protect them from a localStorage
/// read, because the unwrapping key is in the same store; (2) the same is true
/// of the B2a content sealing that already ships, and of B2b. Web at-rest
/// sealing is obfuscation against anyone who can read this origin's
/// localStorage — not encryption. Fixing it needs a NON-EXTRACTABLE `CryptoKey`
/// persisted in IndexedDB (or a passphrase-derived in-memory key), which 1.2.1
/// cannot provide.
///
/// **Mobile:** Uses flutter_secure_storage (Keychain on iOS, Keystore on Android)
/// which is hardware-backed and reliable.
class DualStorage {
  final FlutterSecureStorage _secure;
  final SharedPreferencesAsync? _asyncPrefsOverride;
  SharedPreferencesAsync? _asyncPrefsInstance;
  SharedPreferences? _prefs;
  WebSignalKvStore? _web;
  Future<SigWebKv>? _webOpen;

  /// Test seams for the web sealing path; production leaves them null and
  /// [_openWeb] builds the real sealer/key manager over [_secure].
  final ContentSealer? _sigSealerOverride;
  final ContentKeyManager? _sigKeysOverride;
  final SessionCrossContextLockRunner? _sigLockOverride;
  final bool _debugForceSealedWeb;

  DualStorage(
    this._secure, {
    SharedPreferencesAsync? asyncPrefs,
    ContentSealer? sigSealer,
    ContentKeyManager? sigKeys,
    SessionCrossContextLockRunner? sigLock,
    @visibleForTesting bool debugForceSealedWeb = false,
  }) : _asyncPrefsOverride = asyncPrefs,
       _sigSealerOverride = sigSealer,
       _sigKeysOverride = sigKeys,
       _sigLockOverride = sigLock,
       _debugForceSealedWeb = debugForceSealedWeb;

  /// Lazily built so construction never touches the async platform plugin on
  /// non-web (mobile/tests, where `kIsWeb` is false and the plugin is not
  /// registered) — eager construction threw "SharedPreferencesAsyncPlatform
  /// instance must be set" and broke every unit test that builds the store.
  SharedPreferencesAsync get _asyncPrefs =>
      _asyncPrefsInstance ??= _asyncPrefsOverride ?? SharedPreferencesAsync();

  Future<SharedPreferences> get _sharedPrefs async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Prefix for Signal keys in SharedPreferences to avoid collisions
  /// with other SharedPreferences data (e.g. decrypted message cache).
  static const String _spPrefix = 'sig_';

  /// Web-only key-value layer (localStorage). Built lazily; never touched on
  /// mobile. The legacy store is supplied through a provider so it is loaded
  /// only when the web path actually runs.
  WebSignalKvStore get _webStore => _web ??= WebSignalKvStore(
    _SharedPrefsAsyncKv(_asyncPrefs),
    () async => _SharedPrefsLegacyKv(await _sharedPrefs),
    _spPrefix,
  );

  bool get _useWeb => kIsWeb || _debugForceSealedWeb;

  /// The web backend for this session, memoized AS A FUTURE (concurrent first
  /// ops cannot race two stores; a failed open keeps rethrowing on every op —
  /// E2E down this session, retried next boot; a fallen-back session stays on
  /// the guarded plaintext store; never a mid-session backend flip).
  Future<SigWebKv> get _webKv => _webOpen ??= _openWeb();

  Future<SigWebKv> _openWeb() async {
    final raw = _webStore;
    try {
      final keys =
          _sigKeysOverride ??
          ContentKeyManager(
            FlutterSecureStorageKv(_secure),
            keyPrefix: ContentKeyManager.sigKeyPrefix,
            // Phase 2: the process-wide passcode vault. Null-safe by design —
            // with wrapping off it mints and reads raw keys exactly as before
            // (`ContentKeyWrap.isWrappingOn`).
            wrap: ContentKeyWrap.instance,
          );
      return await SealedWebSignalKv.open(
        inner: raw,
        keys: keys,
        sealer: _sigSealerOverride ?? AesGcmContentSealer(),
        lock: _sigLockOverride,
      );
    } on SigSealOpenUnavailable catch (e) {
      if (!e.fallbackLegal) {
        // Sealed rows exist (or their existence is unknowable): running a
        // plaintext store beside them is the rule-4 forbidden state, and an
        // absent-looking identity read could trigger regeneration. E2E stays
        // DOWN this session (docs/design/web-sig-sealing.md §3.4).
        E2ePersistentDiag.record('SIG_KEY_UNAVAILABLE', {'stage': e.stage});
        rethrow;
      }
      // Pre-first-seal world, proven by a successful zero-envelope probe:
      // plaintext is the status quo, loudly diagnosed, write-guarded against
      // a sibling engine sealing later.
      E2ePersistentDiag.record('SIG_STORE_FALLBACK', {'stage': e.stage});
      return FallbackWebSignalKv(raw);
    }
  }

  Future<void> write({required String key, required String value}) async {
    if (_useWeb) {
      await (await _webKv).write(key, value);
    } else {
      await _secure.write(key: key, value: value);
    }
  }

  Future<String?> read({required String key}) async {
    if (_useWeb) {
      return (await _webKv).read(key);
    } else {
      return _secure.read(key: key);
    }
  }

  Future<void> delete({required String key}) async {
    if (_useWeb) {
      await (await _webKv).delete(key);
    } else {
      await _secure.delete(key: key);
    }
  }

  Future<Map<String, String>> readAll() async {
    if (_useWeb) {
      return (await _webKv).readAll();
    } else {
      return _secure.readAll();
    }
  }

  void clearPrefsCache() {
    _prefs = null;
    _web = null;
    _webOpen = null;
  }

  /// Drops the web session's key material for a mid-session passcode re-lock:
  /// the open sealed store forgets its keys ([SealedWebSignalKv.revoke]) and
  /// the memo is cleared so the NEXT op re-opens — which, while the vault is
  /// locked, throws `SigSealOpenUnavailable('locked', fallbackLegal: false)`
  /// and keeps E2E down instead of degrading to plaintext.
  ///
  /// This is the ONE sanctioned exception to the "never a mid-session backend
  /// flip" rule on [_webKv]: the flip it guards against is sealed → plaintext
  /// behind the user's back, whereas this drops to NO backend at all, and the
  /// re-open decision is re-taken from scratch under the same rules.
  Future<void> revokeWebSession() async {
    final open = _webOpen;
    _webOpen = null;
    _web = null;
    if (open == null) return;
    try {
      final kv = await open;
      if (kv is SealedWebSignalKv) kv.revoke();
    } catch (_) {
      // A store that never opened has nothing to revoke.
    }
  }
}

/// Cache-free async key-value backend (reads straight through to the platform
/// store). Abstracted so [WebSignalKvStore] is unit-testable without a browser
/// or `kIsWeb`. Production impl wraps `SharedPreferencesAsync`.
abstract class AsyncKv {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
  Future<Map<String, Object?>> getAll();
}

/// Legacy (in-memory cached) key-value backend. `reload()` re-reads the backing
/// store before a read. Production impl wraps `SharedPreferences`.
abstract class LegacyKv {
  Future<void> reload();
  Iterable<String> keys();
  String? getString(String key);
  Future<void> remove(String key);
}

class _SharedPrefsAsyncKv implements AsyncKv {
  final SharedPreferencesAsync _p;
  _SharedPrefsAsyncKv(this._p);
  @override
  Future<String?> getString(String key) => _p.getString(key);
  @override
  Future<void> setString(String key, String value) => _p.setString(key, value);
  @override
  Future<void> remove(String key) => _p.remove(key);
  @override
  Future<Map<String, Object?>> getAll() => _p.getAll();
}

class _SharedPrefsLegacyKv implements LegacyKv {
  final SharedPreferences _p;
  _SharedPrefsLegacyKv(this._p);
  @override
  Future<void> reload() => _p.reload();
  @override
  Iterable<String> keys() => _p.getKeys();
  @override
  String? getString(String key) => _p.getString(key);
  @override
  Future<void> remove(String key) => _p.remove(key);
}

/// Web Signal key-value store backing [DualStorage] on `kIsWeb`.
///
/// `SharedPreferencesAsync` (cache-free localStorage) is the source of truth so
/// resumed/multi-tab clients always read the latest ratchet state. Keys written
/// by the legacy `SharedPreferences` API (a different localStorage namespace)
/// are drained into the async store by a **one-time, best-effort** migration on
/// first use:
///  - runs exactly once per instance ([_ensureMigrated] memoizes the future)
///    BEFORE any read/write proceeds, so it never races a concurrent write — no
///    lost update, no stale-session resurrection;
///  - per-key failures (e.g. localStorage quota) are swallowed and leave the
///    legacy copy intact, so a read can still fall back to it (no data loss, no
///    throw — a found key never becomes a decrypt failure);
///  - once every legacy `sig_` key is drained, [_legacyDrained] is set and
///    reads/deletes stop touching the legacy store, so steady-state negative
///    lookups never pay an O(n) `reload()`.
class WebSignalKvStore implements SigWebKv {
  final AsyncKv _async;
  final Future<LegacyKv> Function() _legacyProvider;
  final String _prefix;

  Future<void>? _migration;
  bool _legacyDrained = false;

  WebSignalKvStore(this._async, this._legacyProvider, this._prefix);

  /// Visible for testing: true once no legacy `sig_` keys remain as a fallback.
  bool get legacyDrained => _legacyDrained;

  Future<void> _ensureMigrated() => _migration ??= _migrate();

  Future<void> _migrate() async {
    try {
      final legacy = await _legacyProvider();
      await legacy.reload();
      final keys = legacy.keys().where((k) => k.startsWith(_prefix)).toList();
      var allDrained = true;
      for (final key in keys) {
        final value = legacy.getString(key);
        try {
          // Move into async only if async has no value — never clobber a newer
          // async write with a stale legacy copy.
          if (value != null && await _async.getString(key) == null) {
            await _async.setString(key, value);
          }
          await legacy.remove(key);
        } catch (_) {
          // Quota / platform error: keep the legacy copy so read() can serve
          // it; leave the fallback armed.
          allDrained = false;
        }
      }
      _legacyDrained = allDrained;
    } catch (_) {
      _legacyDrained = false;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    await _ensureMigrated();
    await _async.setString('$_prefix$key', value);
  }

  @override
  Future<String?> read(String key) async {
    await _ensureMigrated();
    final value = await _async.getString('$_prefix$key');
    if (value != null) return value;
    if (_legacyDrained) return null;
    // A legacy key survived migration (e.g. quota). Reload before reading so we
    // never serve a stale in-memory cache, then return it as-is — no write-back
    // (that could lose a concurrent write or throw under quota).
    final legacy = await _legacyProvider();
    await legacy.reload();
    return legacy.getString('$_prefix$key');
  }

  @override
  Future<void> delete(String key) async {
    await _ensureMigrated();
    await _async.remove('$_prefix$key');
    if (_legacyDrained) return;
    // Clear any legacy copy that survived migration so a later fallback read
    // cannot resurrect it.
    final legacy = await _legacyProvider();
    await legacy.reload();
    await legacy.remove('$_prefix$key');
  }

  @override
  Future<Map<String, String>> readAll() async {
    await _ensureMigrated();
    final result = <String, String>{};
    final asyncValues = await _async.getAll();
    for (final entry in asyncValues.entries) {
      if (entry.key.startsWith(_prefix) && entry.value is String) {
        result[entry.key.substring(_prefix.length)] = entry.value as String;
      }
    }
    if (!_legacyDrained) {
      final legacy = await _legacyProvider();
      await legacy.reload();
      for (final key in legacy.keys()) {
        if (key.startsWith(_prefix)) {
          final val = legacy.getString(key);
          if (val != null) {
            result.putIfAbsent(key.substring(_prefix.length), () => val);
          }
        }
      }
    }
    return result;
  }
}

/// Outcome of [SecureIdentityKeyStore.loadFromStorage].
enum IdentityLoadResult {
  /// A complete identity was restored.
  loaded,

  /// Nothing identity-shaped is stored. Genuine fresh install; safe to
  /// generate.
  absent,

  /// Identity material is present but INCOMPLETE. Regenerating here would mint
  /// a new identity and make every peer's history permanently undecryptable,
  /// so the caller must fail closed instead.
  partial,
}

/// Persistent IdentityKeyStore backed by DualStorage.
class SecureIdentityKeyStore extends IdentityKeyStore {
  final DualStorage _storage;
  final String _p;
  IdentityKeyPair? _identityKeyPair;
  int? _localRegistrationId;

  /// Fired when a peer presents an identity key DIFFERENT from the one already
  /// trusted for that address — a reinstall, a storage wipe, or a server
  /// swapping the bundle. Trust-on-first-use is unaffected (no callback for a
  /// peer we have never seen).
  void Function(SignalProtocolAddress address)? onIdentityChanged;

  SecureIdentityKeyStore(this._storage, this._p, {this.onIdentityChanged});

  /// Single-record identity. The pair and the registration id used to be two
  /// independent keys, so losing exactly ONE made [loadFromStorage] report a
  /// fresh install and the caller regenerated the identity — silent, total,
  /// unrecoverable history loss. One key cannot half-exist.
  String get _recordKey => '${_p}identity_record_v1';
  String get _legacyPairKey => '${_p}identity_key_pair';
  String get _legacyRegIdKey => '${_p}registration_id';

  /// Drops the in-RAM identity for a mid-session passcode re-lock. Storage is
  /// untouched; the next [loadFromStorage] re-reads it, which on a wrapped
  /// device requires the passcode.
  ///
  /// [getIdentityKeyPair] asserts non-null on purpose: after this the store
  /// must not be used until `EncryptionService.initialize` rebuilds it, and a
  /// null-return would let a caller treat "revoked" as "no identity" — the
  /// absence-as-truth inversion that mints a new identity.
  void forgetInMemoryIdentity() {
    _identityKeyPair = null;
    _localRegistrationId = null;
  }

  Future<void> initialize(
    IdentityKeyPair identityKeyPair,
    int registrationId,
  ) async {
    _identityKeyPair = identityKeyPair;
    _localRegistrationId = registrationId;
    // Atomic record FIRST: a crash after this point still loads cleanly.
    await _storage.write(
      key: _recordKey,
      value: jsonEncode(<String, dynamic>{
        'pair': base64Encode(identityKeyPair.serialize()),
        'registrationId': registrationId,
      }),
    );
    // Legacy mirror, so rolling back to an older bundle still finds an
    // identity. These two are never read while the record above exists.
    await _storage.write(
      key: _legacyPairKey,
      value: base64Encode(identityKeyPair.serialize()),
    );
    await _storage.write(
      key: _legacyRegIdKey,
      value: registrationId.toString(),
    );
  }

  /// Restore the identity, preferring the atomic record and falling back to the
  /// legacy two-key layout every existing install still has.
  ///
  /// A read that THROWS propagates — the caller must not treat a storage error
  /// as "no keys". Only a definitive absence returns [IdentityLoadResult.absent].
  Future<IdentityLoadResult> loadFromStorage() async {
    final raw = await _storage.read(key: _recordKey);
    if (raw != null) {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final pairB64 = decoded['pair'] as String?;
      final regId = decoded['registrationId'] as int?;
      if (pairB64 != null && regId != null) {
        _identityKeyPair = IdentityKeyPair.fromSerialized(
          base64Decode(pairB64),
        );
        _localRegistrationId = regId;
        return IdentityLoadResult.loaded;
      }
      // A record that exists but cannot be parsed is damage, not absence.
      return IdentityLoadResult.partial;
    }

    final pairB64 = await _storage.read(key: _legacyPairKey);
    final regIdStr = await _storage.read(key: _legacyRegIdKey);
    if (pairB64 == null && regIdStr == null) return IdentityLoadResult.absent;
    if (pairB64 == null || regIdStr == null) return IdentityLoadResult.partial;

    final regId = int.tryParse(regIdStr);
    if (regId == null) return IdentityLoadResult.partial;
    _identityKeyPair = IdentityKeyPair.fromSerialized(base64Decode(pairB64));
    _localRegistrationId = regId;

    // Best-effort upgrade to the atomic record. Purely additive: the legacy
    // keys stay, so a failure here costs nothing and is retried next boot.
    try {
      await _storage.write(
        key: _recordKey,
        value: jsonEncode(<String, dynamic>{
          'pair': pairB64,
          'registrationId': regId,
        }),
      );
    } catch (_) {}
    return IdentityLoadResult.loaded;
  }

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    return _identityKeyPair!;
  }

  @override
  Future<int> getLocalRegistrationId() async {
    return _localRegistrationId!;
  }

  String _trustedKey(SignalProtocolAddress address) =>
      '${_p}trusted_identity_${address.getName()}_${address.getDeviceId()}';

  /// The ACCOUNT-level pin (spec §12 amendment (xlvi)): the identity key this
  /// device has accepted for a peer ACCOUNT, independent of which of their
  /// devices presented it.
  ///
  /// §3 gives one identity key per account, shared to every linked device, so
  /// this is where the value always belonged. Keying the I7 anchor by
  /// `(peer, device 1)` was a category error that only became visible when
  /// §6.2 produced accounts with no device 1 — ids are never reused ((a)).
  String _accountKey(String name) => '${_p}account_identity_$name';

  /// Write-through memo of the trusted peer keys this engine has already read.
  ///
  /// libsignal calls [isTrustedIdentity] on EVERY encrypt and EVERY decrypt, and
  /// on web a single storage read enumerates the whole localStorage keyspace
  /// (`SharedPreferencesAsyncWeb.getString` filters its allowList only after
  /// materialising every key). Without this memo, change detection would cost
  /// one full enumeration per message. With it, steady state is a memory
  /// compare and — since the write below is now conditional — strictly cheaper
  /// than the unconditional write this code used to do per message.
  ///
  /// Engine-local by design: a sibling tab writing a peer key is not observed
  /// here, which can only cost a duplicate warning, never trust of a key this
  /// engine did not itself verify against storage on first contact.
  final Map<String, IdentityKey> _trustedMemo = {};

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
  ) async {
    if (identityKey == null) return false;
    final key = _trustedKey(address);
    final encoded = base64Encode(identityKey.serialize());
    await _storage.write(key: key, value: encoded);
    _trustedMemo[key] = identityKey;
    // The account pin is SET on first contact and never silently moved after
    // that. Advancing it on every accepted key would hand the anchor to any
    // single ciphertext: TOFU auto-accepts rotations, and the receive path has
    // no (xxxix) bundle check, so a colluding server could inject one message
    // from a device the peer's list legitimately names, carrying a divergent
    // identity, and the peer's REAL list would stop verifying — the same
    // fail-closed lockout (xlvi) exists to remove, and one that would not
    // self-heal because an unchanged key deliberately never re-writes.
    // A genuine account-level change goes through [promotePendingAccountIdentity],
    // which the human acknowledgement calls.
    final accountKey = _accountKey(address.getName());
    if (!_trustedMemo.containsKey(accountKey) &&
        await _storage.read(key: accountKey) == null) {
      await _storage.write(key: accountKey, value: encoded);
      _trustedMemo[accountKey] = identityKey;
    }
    return true;
  }

  /// The identity key accepted for a peer ACCOUNT, or null on first contact.
  ///
  /// Falls back to the legacy `(peer, device 1)` row and adopts it, so an
  /// install that predates (xlvi) keeps every anchor it had. Without that
  /// backfill an upgrade would fail-close every existing conversation at once
  /// — far worse than the defect being fixed.
  Future<IdentityKey?> getAccountIdentity(String name) async {
    final key = _accountKey(name);
    final memo = _trustedMemo[key];
    if (memo != null) return memo;
    final stored = await _storage.read(key: key);
    if (stored != null) {
      final identity = IdentityKey.fromBytes(base64Decode(stored), 0);
      _trustedMemo[key] = identity;
      return identity;
    }
    final legacy = await getIdentity(SignalProtocolAddress(name, 1));
    if (legacy == null) return null;
    await _storage.write(
      key: key,
      value: base64Encode(legacy.serialize()),
    );
    _trustedMemo[key] = legacy;
    return legacy;
  }

  /// Sets [name]'s ACCOUNT pin to [identityKey] when none is held, as a
  /// session's first contact would (metadata-privacy slice (f), E15e): a
  /// sibling that relays the server's search answer must be able to judge
  /// the peer's first PreKey frame BEFORE any session with it exists. Never
  /// moves a pin already set ([saveIdentity]'s rule). True when the pin now
  /// equals [identityKey].
  Future<bool> stageAccountIdentity(
    String name,
    IdentityKey identityKey,
  ) async {
    final held = await getAccountIdentity(name);
    if (held != null) return _sameIdentity(held, identityKey);
    final key = _accountKey(name);
    await _storage.write(key: key, value: encodedOf(identityKey));
    _trustedMemo[key] = identityKey;
    return true;
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async {
    if (identityKey == null) return false;
    // Auto-update: accept key rotation (e.g. peer reinstalled / storage
    // evicted). Consumer app — we don't verify fingerprints manually, so TOFU
    // always wins and the message keeps flowing.
    //
    // But a CHANGE is no longer silent. A peer's key changing means either a
    // reinstall or a server handing us a different bundle, and the second case
    // is indistinguishable from a machine-in-the-middle for everything sent
    // afterwards. The user gets told; only first contact stays quiet.
    final existing = await getIdentity(address);
    if (existing != null && _sameIdentity(existing, identityKey)) {
      // Unchanged: deliberately NO write. This runs per message.
      return true;
    }
    // First contact with this ADDRESS is not necessarily first contact with the
    // ACCOUNT, and that gap used to swallow the alarm entirely: a peer's §6.2
    // reset — or a server introducing a device under an identity of its own
    // choosing — arrives on a device id we have never seen, so the per-address
    // rule read it as first contact and said nothing (amendment (xlvi)).
    //
    // Resolved for EVERY address now, not only unseen ones (amendment (xlvii)
    // clause 4). The account anchor is the value a HUMAN accepted, so a
    // per-device row still holding an older key is not news. Without this the
    // explicit adoption (xlvii) clause 3 adds would re-raise the alarm on the
    // peer's very next message — training the user to dismiss the one surface
    // that detects a real takeover, which is the failure (xlvi) clause 2
    // already refused to accept in the other direction.
    final accountBefore = await getAccountIdentity(address.getName());
    final matchesAccount =
        accountBefore != null && _sameIdentity(accountBefore, identityKey);
    await saveIdentity(address, identityKey);
    if (!matchesAccount && (existing != null || accountBefore != null)) {
      // Hold the candidate rather than adopting it. The anchor moves only when
      // a human acknowledges the change, so a forged key can raise a VISIBLE
      // alarm but can never quietly become the thing the I7 chain trusts.
      //
      // PERSISTED, because the warning it accompanies is persisted too: the
      // user may well acknowledge after a restart, and an in-memory candidate
      // would leave that acknowledgement with nothing to promote — the peer
      // would stay unverifiable with no way left to say so.
      await _storage.write(
        key: _pendingKey(address.getName()),
        value: encodedOf(identityKey),
      );
      onIdentityChanged?.call(address);
    }
    return true;
  }

  static String encodedOf(IdentityKey key) => base64Encode(key.serialize());

  /// An identity seen for a peer ACCOUNT that differs from its pinned anchor,
  /// awaiting human acknowledgement (amendment (xlvi)).
  String _pendingKey(String name) => '${_p}pending_account_identity_$name';

  /// The user acknowledged [name]'s identity change, so the account anchor may
  /// now advance to the key that triggered it.
  ///
  /// Moving the anchor always costs an alarm the user actually saw. This was
  /// the ONLY way an established anchor moved until (xlvii) clause 3, which
  /// added [adoptAccountIdentity] for the peer this path cannot serve at all:
  /// one whose candidate was never recorded because the accept gate refused
  /// their row before Signal could look at it.
  ///
  /// **COMPARE-AND-SWAP on [expectedIdentityBase64].** The candidate slot is
  /// read twice by the ceremony — once to DISPLAY a fingerprint, once here to
  /// promote — and it has more than one unconditional writer ([saveIdentity]
  /// via `isTrustedIdentity`, and [stagePendingAccountIdentity] when the key
  /// came from the server). Promoting whatever happens to be stored at confirm
  /// time would therefore let a key change land BETWEEN display and
  /// confirmation, so the user compares fingerprint A out of band and pins
  /// key B — which is the (xlvii) clause 2 defect wearing a different hat.
  /// A caller that passes the exact identity it displayed gets an atomic
  /// promotion or a refusal, never a substitution.
  Future<bool> promotePendingAccountIdentity(
    String name, {
    String? expectedIdentityBase64,
  }) async {
    final pendingKey = _pendingKey(name);
    final stored = await _storage.read(key: pendingKey);
    if (stored == null) return false;
    if (expectedIdentityBase64 != null && stored != expectedIdentityBase64) {
      // The candidate moved under us. Refuse: the caller must re-display.
      return false;
    }
    final identity = IdentityKey.fromBytes(base64Decode(stored), 0);
    final key = _accountKey(name);
    await _storage.write(key: key, value: stored);
    _trustedMemo[key] = identity;
    await _storage.delete(key: pendingKey);
    return true;
  }

  /// The identity awaiting acknowledgement for [name], or null when none is
  /// held.
  ///
  /// Read by the verification UI so the user compares the key adoption will
  /// ACTUALLY pin (amendment (xlvii) clause 2). The dialog used to display the
  /// pinned anchor while the confirm button promoted this one, so the ceremony
  /// verified one number and adopted another.
  Future<IdentityKey?> pendingAccountIdentity(String name) async {
    final stored = await _storage.read(key: _pendingKey(name));
    if (stored == null) return null;
    return IdentityKey.fromBytes(base64Decode(stored), 0);
  }

  /// Stage [identity] as [name]'s pending candidate — a key SEEN for this
  /// account and awaiting human acceptance, exactly like one recorded by an
  /// inbound ciphertext.
  ///
  /// Used for a key the server served on request (amendment (xlvii) clause 3),
  /// so that every adoption promotes a candidate this device recorded. That
  /// keeps "the pinned key is the key the human was shown" a STRUCTURAL
  /// property rather than a convention held by one call site.
  ///
  /// Grants no trust whatsoever: the pending slot is read only by the display
  /// and by [promotePendingAccountIdentity], which needs a standing alarm and a
  /// human action.
  Future<void> stagePendingAccountIdentity(
    String name,
    IdentityKey identity,
  ) async {
    await _storage.write(
      key: _pendingKey(name),
      value: encodedOf(identity),
    );
  }

  /// The user compared [identity] against [name]'s own copy out of band and
  /// accepted it. Pins it as the account anchor.
  ///
  /// The escape hatch for a peer whose recovery path fail-closed before any
  /// candidate could be recorded (amendment (xlvii) clause 3): after a
  /// completed §6.2 reset the accept gate withholds the peer's row before
  /// Signal runs, so [promotePendingAccountIdentity] has nothing to promote and
  /// the peer stays permanently unreachable in BOTH directions.
  ///
  /// Only ever reached from an explicit human confirmation of a DISPLAYED
  /// fingerprint — never from a path that merely received bytes. The key is
  /// server-supplied and untrusted; the out-of-band comparison is the entire
  /// defence, exactly as it is on first contact (I7).
  ///
  /// **[expectedPendingBase64] is REQUIRED and clears the candidate slot only
  /// when the slot still holds exactly that value** (amendment (xlix) clause
  /// 2). This method used to delete the candidate unconditionally, which let a
  /// re-affirmation of the pinned key destroy a DIFFERENT key that had arrived
  /// under the open dialog — and, because the caller clears the persisted
  /// warning on success, destroy the only door back to this ceremony with it.
  /// Pass null to assert "no candidate was observed": a candidate that appeared
  /// since is then deliberately LEFT IN PLACE, because keeping evidence is the
  /// safe direction. The parameter is required rather than defaulted so no
  /// future caller can inherit the unguarded behaviour by omission.
  /// Returns whether the pending slot was EXACTLY as the caller expected
  /// ((lviii)). False means a candidate appeared or changed during this write,
  /// so the caller MUST NOT consume the warning that leads back here: the
  /// evidence survives, and without the warning the door to the ceremony does
  /// not. The anchor write always happens and is never rolled back — the
  /// re-affirmation path passes the already-pinned key, so it is idempotent.
  Future<bool> adoptAccountIdentity(
    String name,
    IdentityKey identity, {
    required String? expectedPendingBase64,
  }) async {
    final key = _accountKey(name);
    await _storage.write(key: key, value: encodedOf(identity));
    _trustedMemo[key] = identity;
    final pendingKey = _pendingKey(name);
    final stored = await _storage.read(key: pendingKey);
    if (expectedPendingBase64 == null) {
      // The caller asserted it observed NO candidate. This used to return
      // before reading, which is exactly the state where a candidate arriving
      // under the open dialog is invisible. Report it — and still never delete
      // a candidate we were not told about ((xlix) clause 2).
      return stored == null;
    }
    if (stored != expectedPendingBase64) return false;
    await _storage.delete(key: pendingKey);
    return true;
  }

  bool _sameIdentity(IdentityKey a, IdentityKey b) {
    final x = a.serialize();
    final y = b.serialize();
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final key = _trustedKey(address);
    final memo = _trustedMemo[key];
    if (memo != null) return memo;
    final stored = await _storage.read(key: key);
    if (stored == null) return null;
    final parsed = IdentityKey.fromBytes(base64Decode(stored), 0);
    _trustedMemo[key] = parsed;
    return parsed;
  }
}

/// Persistent PreKeyStore backed by DualStorage.
class SecurePreKeyStore extends PreKeyStore {
  final DualStorage _storage;
  final String _p;

  SecurePreKeyStore(this._storage, this._p);

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final data = await _storage.read(key: '${_p}pre_key_$preKeyId');
    if (data == null) {
      throw InvalidKeyIdException('No pre-key found for id: $preKeyId');
    }
    return PreKeyRecord.fromBuffer(base64Decode(data));
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    await _storage.write(
      key: '${_p}pre_key_$preKeyId',
      value: base64Encode(record.serialize()),
    );
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async {
    final data = await _storage.read(key: '${_p}pre_key_$preKeyId');
    return data != null;
  }

  @override
  Future<void> removePreKey(int preKeyId) async {
    await _storage.delete(key: '${_p}pre_key_$preKeyId');
  }
}

/// Persistent SignedPreKeyStore backed by DualStorage.
class SecureSignedPreKeyStore extends SignedPreKeyStore {
  final DualStorage _storage;
  final String _p;

  SecureSignedPreKeyStore(this._storage, this._p);

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final data = await _storage.read(
      key: '${_p}signed_pre_key_$signedPreKeyId',
    );
    if (data == null) {
      throw InvalidKeyIdException(
        'No signed pre-key found for id: $signedPreKeyId',
      );
    }
    return SignedPreKeyRecord.fromSerialized(base64Decode(data));
  }

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    await _storage.write(
      key: '${_p}signed_pre_key_$signedPreKeyId',
      value: base64Encode(record.serialize()),
    );
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    // We only use signedPreKeyId=0 in single-device model
    try {
      final record = await loadSignedPreKey(0);
      return [record];
    } catch (_) {
      return [];
    }
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    final data = await _storage.read(
      key: '${_p}signed_pre_key_$signedPreKeyId',
    );
    return data != null;
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    await _storage.delete(key: '${_p}signed_pre_key_$signedPreKeyId');
  }
}

/// Persistent SessionStore backed by DualStorage.
class SecureSessionStore extends SessionStore {
  final DualStorage _storage;
  final String _p;

  SecureSessionStore(this._storage, this._p);

  String _sessionKey(SignalProtocolAddress address) =>
      '${_p}session_${address.getName()}_${address.getDeviceId()}';

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final data = await _storage.read(key: _sessionKey(address));
    if (data == null) {
      return SessionRecord();
    }
    return SessionRecord.fromSerialized(base64Decode(data));
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    // Single-device model — only deviceId 1
    return [1];
  }

  @override
  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) async {
    try {
      await _storage.write(
        key: _sessionKey(address),
        value: base64Encode(record.serialize()),
      );
    } catch (e) {
      // TEMP storage-durability probe: a THROWN write (quota exceeded, private
      // mode, evicted origin) means the ratchet state never persisted — the
      // session will be absent on the next start. Rethrow: behaviour unchanged.
      // (An immediate read-back would NOT catch non-persistence: SharedPreferences
      // serves the in-memory value even when the localStorage flush silently
      // dropped. The cross-reload SESSION_INVENTORY is the real durability test.)
      E2eDiagLog.add('SESSION_STORE_WRITE_FAIL', {
        'peerId': address.getName(),
        'err': e.runtimeType.toString(),
      });
      rethrow;
    }
  }

  /// TEMP storage-durability probe: peer ids that currently have a persisted
  /// session on disk. Captured at every E2E init — a peer present one start and
  /// gone the next, with NO matching SESSION_STORE_DELETE in between, is storage
  /// eviction (not code). No key material is read, only the key names.
  Future<List<String>> inventoryPeerIds() async {
    final all = await _storage.readAll();
    final prefix = '${_p}session_';
    final ids = <String>[];
    for (final key in all.keys) {
      if (!key.startsWith(prefix)) continue;
      final rest = key.substring(prefix.length); // "<peerId>_<deviceId>"
      final cut = rest.lastIndexOf('_');
      ids.add(cut > 0 ? rest.substring(0, cut) : rest);
    }
    return ids;
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    final data = await _storage.read(key: _sessionKey(address));
    return data != null;
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    // TEMP storage-durability probe: log EVERY store-level delete (ours or
    // libsignal's). An inventory drop with no matching delete here ⇒ storage
    // loss; a drop WITH one ⇒ code deleted it.
    E2eDiagLog.add('SESSION_STORE_DELETE', {'peerId': address.getName()});
    await _storage.delete(key: _sessionKey(address));
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    // Delete session for device 1 (our only device)
    await _storage.delete(key: '${_p}session_${name}_1');
  }
}
