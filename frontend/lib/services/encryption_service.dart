import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'encryption/content_kv.dart';
import 'encryption/sealed_web_content_kv.dart';
import 'encryption/sealed_web_envelope.dart';
import 'encryption/content_kv_opener_stub.dart'
    if (dart.library.io) 'encryption/content_kv_opener_io.dart';

import '../utils/e2e_diag_log.dart';
import '../utils/e2e_persistent_diag.dart';
import 'plaintext_record_codec.dart';
import 'encryption/signal_stores.dart';
import 'device_link/identity_backup.dart';
import 'passcode_wrap_hook.dart';
import 'encryption/session_cross_context_lock.dart';
import 'reactions/reaction_key_lookup.dart';

/// Thrown by [EncryptionService.initialize] when identity material is present
/// but incomplete.
///
/// Initialization fails CLOSED here on purpose: regenerating would mint a new
/// identity and make every peer's history permanently undecryptable, while
/// refusing leaves the surviving bytes on disk where they may still be
/// recoverable. Because that also means E2E never comes up, this is a distinct
/// type — callers must surface it and offer the §5.1 link (or the §6.2 reset)
/// as the way back in, NOT treat it as a transient init failure. There is no
/// consented "start fresh" (amendment (lxxi)): a device that lost its keys
/// re-enters the account through the primary, never by minting on its own.
class E2eIdentityIncompleteException implements Exception {
  const E2eIdentityIncompleteException();

  @override
  String toString() =>
      'E2eIdentityIncompleteException: identity material is incomplete; '
      'refusing to regenerate without explicit consent';
}

/// Thrown when a missing local identity cannot be checked against the server.
///
/// This is intentionally distinct from [E2eIdentityIncompleteException]:
/// UNKNOWN is transient and must retry on the next connection, while an
/// incomplete identity needs the user's explicit destructive consent.
class E2eIdentityCheckUnavailableException implements Exception {
  const E2eIdentityCheckUnavailableException();

  @override
  String toString() =>
      'E2eIdentityCheckUnavailableException: unable to verify whether '
      'the missing identity is a fresh install';
}

/// The server's answer to the (lxxi)/(lxxiii) identity guard: whether the
/// account already published a key bundle for this login's device, and
/// whether the registration lock is armed (an `account_authorizations` row
/// exists). `linkingEnabled` defaults to true because an ABSENT field (older
/// server) must fail closed to the gating behaviour, never to a mint the
/// server would refuse.
class ServerIdentityGuard {
  const ServerIdentityGuard({required this.exists, this.linkingEnabled = true});

  final bool exists;
  final bool linkingEnabled;
}

/// Thrown when a served pre-key bundle carries an identity key that is NOT the
/// account's (spec §3, enforced per §12 amendment (xxxix)).
///
/// Every device of an account shares one identity key. A bundle that disagrees
/// with the key we already trust for that account did not come from the
/// account: either the server is compromised and is offering its own key for a
/// device the signed list legitimately names, or the account's key changed
/// without the device-list chain reflecting it. Both are machine-in-the-middle
/// until proven otherwise, so the session is refused rather than built.
///
/// Distinct from the same-address rotation warning: THAT is a key changing
/// where one was already known and is surfaced as an alarm the user can read.
/// This is a key that is wrong on arrival, on an address that has none.
class AccountIdentityMismatch implements Exception {
  const AccountIdentityMismatch({required this.userId, required this.deviceId});

  final int userId;
  final int deviceId;

  @override
  String toString() =>
      'AccountIdentityMismatch: the bundle served for userId=$userId '
      'deviceId=$deviceId carries an identity key that is not the account\'s';
}

class EncryptionService {
  EncryptionService({
    int decryptedContentCacheLimit = 2000,
    SessionCrossContextLockRunner? sessionCrossContextLock,
  }) : _decryptedContentCacheLimit = decryptedContentCacheLimit,
       _sessionCrossContextLock =
           sessionCrossContextLock ?? runSessionCrossContextLocked;

  /// Batch size for replenishment (preKeysLow). Server threshold is 10.
  static const int _preKeyBatchSize = 100;

  /// Smaller initial batch for fresh install — faster startup, preKeysLow replenishes when low.
  static const int _initialPreKeyBatchSize = 20;
  static const int _deviceId = 1;

  /// DualStorage: platform-branched Signal-key storage (see
  /// encryption/signal_stores.dart). On web, keys live ONLY in
  /// SharedPreferences/localStorage — historically because keys vanished across
  /// tab closes. NOTE: the old claim that flutter_secure_storage on web is
  /// "IndexedDB+WebCrypto" is FALSE (1.2.1 is localStorage, master key
  /// included) — full note in signal_stores.dart. On mobile, ONLY
  /// flutter_secure_storage (Keychain/Keystore).
  DualStorage _storage = DualStorage(
    FlutterSecureStorage(webOptions: const WebOptions(dbName: 'FireplaceE2E')),
  );

  /// Test-only seam mirroring [debugSetContentKv]: pin the Signal key-value
  /// backend (e.g. a throwing fake proving the residue/prekey enumeration
  /// hardenings — B2b design review R1/R3). Call BEFORE [initialize]; the
  /// stores built there capture the reference.
  @visibleForTesting
  void debugSetDualStorage(DualStorage storage) {
    _storage = storage;
  }

  late SecureIdentityKeyStore _identityStore;
  late SecurePreKeyStore _preKeyStore;
  late SecureSignedPreKeyStore _signedPreKeyStore;
  late SecureSessionStore _sessionStore;

  /// The session store handed to SessionCipher/SessionBuilder. Same object as
  /// [_sessionStore] in production; race probes wrap it via
  /// [debugWrapSessionStore] to gate storeSession deterministically.
  late SessionStore _cipherSessionStore;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  int? _userId;

  /// The account every storage key on this instance is namespaced under, or
  /// null before [initialize]. Exposed so a long-running pass can confirm the
  /// account did not change underneath it before destroying anything.
  int? get activeUserId => _userId;

  /// The plaintext-record store behind every cache/purge/retention path here.
  /// [ContentKv] mirrors the SharedPreferences surface exactly; see its doc
  /// for what each backend guarantees. Kept behind the historical
  /// `_sharedPrefs` name so the call sites below read unchanged.
  ///
  /// The opener is platform-selected (encrypted store on Android, legacy
  /// prefs everywhere else incl. tests) and memoized AS A FUTURE: two
  /// concurrent first touches must not race two backends into existence.
  ContentKv? _prefs;
  Future<ContentKv>? _prefsOpening;
  ///
  /// A REJECTED opening is NOT memoized. On web a locked passcode vault makes
  /// the opener rethrow instead of falling back (`frontend/docs/e2e-invariants.md`
  /// — falling back there would write the plaintext cache while the app is
  /// still locked), and caching that rejected future made the failure last the
  /// whole PROCESS: every later read rethrew locked even after the user
  /// unlocked, so nothing recovered without a relaunch. The race guarantee is
  /// unchanged — concurrent first touches still share ONE opening; only a
  /// failed one is dropped so the next touch can retry.
  Future<ContentKv> get _sharedPrefs async {
    final cached = _prefs;
    if (cached != null) return cached;
    final opening = _prefsOpening ??= (_kvOpener ?? openPlatformContentKv)();
    try {
      return _prefs = await opening;
    } catch (_) {
      if (_prefsOpening == opening) _prefsOpening = null;
      rethrow;
    }
  }

  Future<void> _reloadPrefsForCrossContext(ContentKv prefs) => prefs.reload();

  /// Test-only seam: pin the content-store backend (e.g. a SealedWebContentKv
  /// over mocked prefs). Production selection stays with the platform opener.
  @visibleForTesting
  void debugSetContentKv(ContentKv kv) {
    _prefs = kv;
    _prefsOpening = Future.value(kv);
  }

  /// Test-only seam for the OPENER, not the opened store.
  ///
  /// [debugSetContentKv] above pins a store and therefore cannot exercise the
  /// open path at all. This one exists so the "a locked open must not poison
  /// the process" behaviour above has a test: a fake that throws first and
  /// succeeds second.
  @visibleForTesting
  void debugSetContentKvOpener(Future<ContentKv> Function()? opener) {
    _kvOpener = opener;
    _prefs = null;
    _prefsOpening = null;
  }

  Future<ContentKv> Function()? _kvOpener;

  /// Ground truth for a record read, or null when [ContentKv.getString] is
  /// already authoritative on this backend.
  ///
  /// WHY IT EXISTS — do not "simplify" the readers below back onto the cache.
  /// The prefs backend's `reload()` refills its in-memory cache from a snapshot
  /// taken across an await, so a write landing in that window survives in the
  /// store but is DROPPED from the cache. For a plaintext record that miss is
  /// not "no plaintext": the caller re-decrypts a ciphertext whose Signal
  /// ratchet key was consumed at first decrypt, hits DuplicateMessage, and the
  /// row becomes a permanent "[Decryption failed]" while its only readable copy
  /// is still on disk. That shipped as the 2026-07-29 incident. The
  /// read-modify-write in [saveDecryptedContent] reads the same null and can
  /// then write a narrower record — including the "[Decryption failed]" label —
  /// OVER real plaintext, which is unrecoverable loss.
  ///
  /// A lock in this class could not close it: the Signal session stores reload
  /// the SAME underlying singleton throughout decrypt, concurrently with these
  /// writes.
  ///
  /// Which backends answer, and what it costs, is [ContentKv]'s business —
  /// asking it here is what keeps this class free of backend detail. The prefs
  /// backend answers only on web (where `reload()` already paid for the same
  /// enumeration); the native encrypted store answers null because its view
  /// cannot be clobbered.
  Future<Map<String, Object>?> _authoritativeSnapshot() async =>
      (await _sharedPrefs).authoritativeSnapshot();

  /// The raw record at [key]. A null [snapshot] means the backend's own read is
  /// ground truth. A null RESULT means the record is GENUINELY absent.
  String? _rawRecord(
    Map<String, Object>? snapshot,
    ContentKv prefs,
    String key,
  ) {
    if (snapshot == null) return prefs.getString(key);
    final value = snapshot[key];
    return value is String ? value : null;
  }

  /// Record keys under [prefix], from whichever view is authoritative.
  Iterable<String> _recordKeys(
    Map<String, Object>? snapshot,
    ContentKv prefs,
    String prefix,
  ) => (snapshot?.keys ?? prefs.getKeys()).where((k) => k.startsWith(prefix));

  final int _decryptedContentCacheLimit;
  final SessionCrossContextLockRunner _sessionCrossContextLock;

  /// Per-session dedupe for the non-authoritative `PLAINTEXT_SCAN_SKIPPED`
  /// durable: a fallback-to-prefs session sweeping over sealed envelopes
  /// would otherwise record it once per sweep and evict real evidence from
  /// the cap-80 durable log. See `_messageIdsMatching`.
  bool _scanSkippedDiagRecorded = false;

  /// Test-only seam: wrap the session store used by SessionCipher /
  /// SessionBuilder (e.g. to hold a storeSession mid-flight and force a
  /// lost-update interleave). Diagnostics ([sessionInventoryPeerIds]) keep
  /// reading the real [_sessionStore].
  @visibleForTesting
  void debugWrapSessionStore(SessionStore Function(SessionStore inner) wrap) {
    _cipherSessionStore = wrap(_cipherSessionStore);
  }

  /// True if keys were just generated and need to be uploaded to the server.
  bool needsKeyUpload = false;

  /// Public key data to upload to the server (set after key generation).
  Map<String, dynamic>? _keysForUpload;

  /// True only between a §5.1 [adoptProvisionedIdentity] and its ceremony's
  /// settlement — the sole state in which [discardProvisionedIdentity] may
  /// destroy key material (T3 review invariant lock).
  bool _provisionalIdentityAdopted = false;

  /// True once [initialize] refused to start because the server already holds
  /// a bundle for this login's device while local identity material is missing
  /// or incomplete. The way forward is the §5.1 link or the §6.2 reset; nothing
  /// in this service mints over an enrolled identity (amendment (lxxi)).
  bool identityIncomplete = false;

  /// Peers whose identity key changed under us, surfaced so the UI can warn
  /// instead of silently trusting the new key.
  ///
  /// PERSISTED (`e2e_<uid>_peer_identity_changed_v1`) and cleared ONLY by
  /// [acknowledgePeerIdentity], i.e. by the user saying "I verified this".
  /// It used to be session-only, so the single warning this product has for a
  /// possible machine-in-the-middle vanished on the next PWA reopen — a user
  /// who was not looking at that chat never learned it happened. Best-effort by
  /// design: a failed read means the warning does not survive a restart (the
  /// pre-2026-08-05 behaviour), never that a change is invented.
  final Set<int> _peersWithChangedIdentity = <int>{};
  Set<int> get peersWithChangedIdentity =>
      Set.unmodifiable(_peersWithChangedIdentity);

  /// Peers whose session build was REFUSED by the (xxxix)/(lv) account-anchor
  /// gate this run. In-memory ONLY: a standing refusal re-fires on the next
  /// build attempt, and the fail-closed state it names is already durable
  /// (the anchor and the warning set). While it holds a peer, the red pill
  /// renders REGARDLESS of the (lxxix) demotion setting — a refusal is the
  /// one shape with no message flow and therefore no other visible door.
  /// Cleared by a successful [acknowledgePeerIdentity].
  final Set<int> _peersRefusedIdentity = <int>{};
  Set<int> get peersRefusedIdentity =>
      Set.unmodifiable(_peersRefusedIdentity);

  static const int _identityChangedCap = 200;

  String _identityChangedKey(int userId) =>
      'e2e_${userId}_peer_identity_changed_v1';

  /// Called when a peer's identity key changes. Set by the provider.
  void Function(int peerId)? onPeerIdentityChanged;

  /// Amendment (lxxix): whether the user opted back into manual key-change
  /// confirmation. Injected from `SettingsProvider` via the provider wiring;
  /// the default matches the spec default (warnings DEMOTED).
  bool Function() keyChangeWarnings = () => false;

  /// One-shot muted timeline notes (amendment (lxxix)): peerId → ISO-8601
  /// instant of the auto-acknowledged identity change. Persisted per user
  /// (`e2e_<uid>_peer_key_change_notes_v1`) so the muted line survives a
  /// reload (falsification F12). Insertion-ordered and capped by recency,
  /// same eviction style as [_peersWithChangedIdentity].
  final Map<int, String> _peerKeyChangeNotes = <int, String>{};
  Map<int, String> get peerKeyChangeNotes =>
      Map.unmodifiable(_peerKeyChangeNotes);

  String _keyChangeNotesKey(int userId) =>
      'e2e_${userId}_peer_key_change_notes_v1';

  /// The (lxxix) demotion, shared by both detection paths (server event and
  /// local libsignal). With warnings OFF: record the muted one-shot note, then
  /// auto-acknowledge through [acknowledgePeerIdentity] — the SAME
  /// compare-and-swap the manual ceremony uses, so the anchor advances only to
  /// a key this device recorded. With warnings ON this is a no-op and today's
  /// manual-confirmation surface is unchanged.
  Future<void> _demoteKeyChangeIfMuted(int peerId) async {
    if (keyChangeWarnings()) return;
    // Re-insert so a repeat change moves the note to the newest end.
    _peerKeyChangeNotes.remove(peerId);
    _peerKeyChangeNotes[peerId] = DateTime.now().toUtc().toIso8601String();
    await _persistKeyChangeNotes();
    // A bare acknowledge promotes the staged candidate (the local-detection
    // path stages it before firing). When nothing is staged — the plain
    // server-event shape — nothing advances and nothing is pinned, so the peer
    // STAYS in `_peersWithChangedIdentity`.
    //
    // That case no longer hides: since 2026-09-13 `chat_detail_screen` renders
    // the actionable pill for any peer still in that set, because a
    // non-advanced anchor makes `buildSession` fail closed and blocks every
    // send to them. The muted note below is written either way, but the screen
    // only shows it when the pill is absent — i.e. only for a change that
    // actually WAS absorbed. Do not re-gate the pill on the warnings setting:
    // that setting picks how an absorbed change is announced, not whether a
    // chat that cannot send says so.
    await acknowledgePeerIdentity(peerId);
    onPeerIdentityChanged?.call(peerId);
  }

  Future<void> _persistKeyChangeNotes() async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      final entries = _peerKeyChangeNotes.entries.toList();
      final kept = entries.length > _identityChangedCap
          ? entries.sublist(entries.length - _identityChangedCap)
          : entries;
      await prefs.setString(
        _keyChangeNotesKey(userId),
        jsonEncode([
          for (final e in kept) {'peerId': e.key, 'occurredAt': e.value},
        ]),
      );
    } catch (_) {}
  }

  Future<void> _loadKeyChangeNotes(int userId) async {
    try {
      final prefs = await _sharedPrefs;
      final raw = prefs.getString(_keyChangeNotesKey(userId));
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final peerId = entry['peerId'];
        final occurredAt = entry['occurredAt'];
        // The writer is `toIso8601String()`; anything else is corrupt storage
        // and is dropped HERE, so the screen's "is anything newer?" question
        // never meets a value it cannot order ((lxxxiv)).
        if (peerId is! int || occurredAt is! String) continue;
        if (DateTime.tryParse(occurredAt) == null) continue;
        _peerKeyChangeNotes[peerId] = occurredAt;
      }
    } catch (_) {}
  }

  // --- Reaction keys (D10, docs/design/reaction-privacy.md) ---------------
  //
  // K_react is the per-conversation HMAC key that blinds reaction emoji from
  // the server. It rides the SAME at-rest path as every other record here
  // (the `ContentKv` seam: SQLCipher on Android, sealed store on web, prefs on
  // desktop/test) rather than minting its own key family — same custody as the
  // plaintext cache, one place to reason about.
  //
  // It MUST persist, and the reason is the same one that forces a local
  // plaintext record store: the server's copy is a Signal-wrapped mailbox row,
  // and Signal decryption CONSUMES the message key, so that row opens exactly
  // once. A device that kept the key in RAM only would be unable to read its
  // own conversation's chips after a relaunch (design §3, falsification R7).
  String _reactionKeyPrefix(int userId) => 'e2e_${userId}_rkey_v1_';

  String _reactionKeyRecordKey(int userId, int conversationId) =>
      '${_reactionKeyPrefix(userId)}$conversationId';

  /// Stores [keyB64] as this device's `K_react` for [conversationId].
  ///
  /// ARMED, like every other key in this app: the write is verified by a
  /// read-back before the caller is told it succeeded, because a key the
  /// sender believes is stored but is not would blind reactions this device can
  /// never read again.
  Future<bool> saveReactionKey({
    required int conversationId,
    required int epoch,
    required String keyB64,
  }) async {
    final userId = _userId;
    if (userId == null) return false;
    try {
      final prefs = await _sharedPrefs;
      final key = _reactionKeyRecordKey(userId, conversationId);
      await prefs.setString(key, jsonEncode({'e': epoch, 'k': keyB64}));
      // Read back through the AUTHORITATIVE snapshot, like every other
      // durable record here. The per-engine cache can miss a write that
      // landed, and a false "not stored" on this path is destructive: the
      // caller treats it as a lost key while the server already serves the
      // epoch (the 2026-07-29 incident, same mechanism).
      final readBack = _rawRecord(await _authoritativeSnapshot(), prefs, key);
      if (readBack == null) return false;
      final decoded = jsonDecode(readBack);
      return decoded is Map && decoded['e'] == epoch && decoded['k'] == keyB64;
    } on Object catch (_) {
      return false;
    }
  }

  /// Forgets this device's `K_react` for [conversationId].
  ///
  /// Used when a key was stored optimistically and the server then refused to
  /// publish it: keeping it would mint tokens no other device agrees with,
  /// and — worse — make `loadReactionKey` answer `Found`, so the real key
  /// would never be pulled.
  Future<void> dropReactionKey(int conversationId) async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      await prefs.remove(_reactionKeyRecordKey(userId, conversationId));
    } on Object catch (_) {
      // Best effort: a surviving record is re-validated on the next read and
      // a failed removal must not fail the caller's recovery path.
    }
  }

  /// This device's `K_react` for [conversationId], as a THREE-state answer.
  ///
  /// The three states exist because the recovery they feed is destructive.
  /// "I cannot open my mailbox row" is supposed to let a participant re-key at
  /// `epoch + 1`, and that permanently orphans every existing chip for BOTH
  /// participants' other devices — so it may fire ONLY on a proven absence.
  /// A locked passcode vault makes the content store RETHROW
  /// `ContentStoreUnavailable(locked: true)` rather than fall back
  /// (`frontend/docs/e2e-invariants.md`, and the passcode-lock doc records that
  /// locked deliberately outranks the "no keys" probe because conflating
  /// absent-with-locked destroyed data once already). Collapsing that into
  /// `null` would re-key a device whose key is sitting right there, unreadable
  /// for the next few seconds.
  Future<ReactionKeyLookup> loadReactionKey(int conversationId) async {
    final userId = _userId;
    if (userId == null) return const ReactionKeyUnavailable('unbound-user');
    try {
      final prefs = await _sharedPrefs;
      // The AUTHORITATIVE snapshot, not the per-engine cache. This read
      // decides ABSENCE, and absence is the one verdict that spends the
      // Signal mailbox row (or, at epoch 0, mints a new key). A stale cache
      // that has dropped a landed write would therefore destroy the key
      // rather than merely miss it — the 2026-07-29 mechanism, with no
      // second copy to recover from.
      final raw = _rawRecord(
        await _authoritativeSnapshot(),
        prefs,
        _reactionKeyRecordKey(userId, conversationId),
      );
      // `_rawRecord` returning null now means GENUINELY absent, which is the
      // one state that may authorise a re-key.
      if (raw == null) return const ReactionKeyAbsent();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const ReactionKeyUnavailable('corrupt');
      final epoch = decoded['e'];
      final keyB64 = decoded['k'];
      // A half record is corrupt storage, NOT an absence: re-keying over it
      // would throw away a key that may still be recoverable.
      if (epoch is! int || keyB64 is! String || keyB64.isEmpty) {
        return const ReactionKeyUnavailable('corrupt');
      }
      return ReactionKeyFound(epoch: epoch, keyB64: keyB64);
    } on ContentStoreUnavailable catch (e) {
      return ReactionKeyUnavailable(e.locked ? 'locked' : e.stage);
    } on Object catch (e) {
      // Unknown failure is NOT absence. Fail toward "leave it alone".
      return ReactionKeyUnavailable(e.runtimeType.toString());
    }
  }

  /// (lxxxiv): the timeline moved past [peerId]'s muted note recorded at
  /// [occurredAt]. Forget it durably, so a later open of that chat does not
  /// re-render the line while history is still loading (an empty timeline
  /// cannot out-date it). Compare-and-remove: the screen decides in `build`
  /// and calls after the frame, and `_demoteKeyChangeIfMuted` can write a
  /// FRESH instant in between — that note was never superseded and must
  /// survive. Same discipline as the identity-anchor CAS above.
  Future<void> dismissPeerKeyChangeNote(
    int peerId, {
    required String occurredAt,
  }) async {
    if (_peerKeyChangeNotes[peerId] != occurredAt) return;
    _peerKeyChangeNotes.remove(peerId);
    await _persistKeyChangeNotes();
    onPeerIdentityChanged?.call(peerId);
  }

  /// The user compared [peerId]'s fingerprint out of band and accepted it.
  /// Returns whether the account anchor actually advanced.
  ///
  /// It is also the ONLY thing that advances the I7 account anchor
  /// (amendment (xlvi)). A peer who completes a §6.2 reset presents a new
  /// account identity, and their re-enrolled device list cannot verify until
  /// this device accepts it — but accepting it silently would let one injected
  /// ciphertext move the anchor and lock the peer out instead. Tying the two
  /// together means the anchor never moves without an alarm the user saw.
  ///
  /// [adoptIdentityBase64] is the key the UI actually DISPLAYED for comparison.
  /// When present it wins outright over any stored candidate (amendment
  /// (xlvii) clause 2): promoting a candidate the user was never shown is how
  /// the ceremony came to verify one number and adopt another. When absent this
  /// falls back to promoting the stored candidate, which is what a locally
  /// detected change leaves behind.
  ///
  /// **The warning is cleared ONLY if the anchor advanced** (amendment (xlvii)
  /// clause 1). It used to be dropped first and unconditionally, so a peer with
  /// no candidate — every peer who completed §6.2, because the accept gate
  /// withholds their row before Signal can record one — lost the single
  /// persisted notice of a real event and got nothing repaired in exchange.
  Future<bool> acknowledgePeerIdentity(
    int peerId, {
    String? adoptIdentityBase64,
  }) async {
    if (!_peersWithChangedIdentity.contains(peerId)) return false;
    final name = peerId.toString();
    final supplied = adoptIdentityBase64;
    final bool advanced;
    final String source;
    if (supplied != null && supplied.isNotEmpty) {
      // ONLY a key this device already recorded may be pinned, and ONLY if it
      // is STILL the recorded one. The candidate slot is read once to display a
      // fingerprint and again to promote, and it has several unconditional
      // writers, so a plain "check then promote" would let the candidate move
      // in between — the user compares A out of band and pins B, which is the
      // clause 2 defect wearing a different hat. The compare-and-swap makes it
      // atomic: the promotion takes the displayed bytes or refuses.
      final promoted = await _identityStore.promotePendingAccountIdentity(
        name,
        expectedIdentityBase64: supplied,
      );
      if (promoted) {
        advanced = true;
        source = 'displayed_candidate';
      } else {
        // The CAS refused, and it refuses for two materially different reasons
        // that MUST NOT be conflated (amendment (xlix)): either nothing is
        // staged, or something DIFFERENT is staged. Read the slot before
        // considering a re-affirmation, because [adoptAccountIdentity] drops
        // the candidate and the caller below consumes the warning — so taking
        // the re-affirmation first would destroy the only record of a key that
        // arrived under the open dialog AND the sole door back to this
        // ceremony. A malicious server reaches exactly that state by serving
        // the HONEST key (so the out-of-band comparison succeeds) and
        // injecting a ciphertext of its own while the user reads the number
        // aloud; the user's CORRECT confirmation would otherwise be the
        // instrument that erases the evidence.
        final pending = await _identityStore.pendingAccountIdentity(name);
        final pendingBase64 = pending == null
            ? null
            : base64Encode(pending.serialize());
        if (pendingBase64 != null && pendingBase64 != supplied) {
          E2ePersistentDiag.record('PEER_IDENTITY_ADOPT_REFUSED', {
            'peerId': peerId,
            'reason': 'candidate_changed_since_display',
          });
          return false;
        }
        // Nothing staged (or the slot already holds exactly what was
        // confirmed): the one remaining value a human may legitimately
        // confirm is the key already pinned — a re-affirmation that advances
        // nothing but resolves the warning.
        final pinned = await _identityStore.getAccountIdentity(name);
        if (pinned != null && base64Encode(pinned.serialize()) == supplied) {
          // (lviii) The slot was read BEFORE this write, so a candidate can
          // still arrive during it. The store reports whether its guard held;
          // if it did not, the warning MUST stand — the evidence survives, and
          // without the warning the door back to this ceremony does not.
          final guardHeld = await _identityStore.adoptAccountIdentity(
            name,
            pinned,
            expectedPendingBase64: pendingBase64,
          );
          if (!guardHeld) {
            E2ePersistentDiag.record('PEER_IDENTITY_ADOPT_REFUSED', {
              'peerId': peerId,
              'reason': 'candidate_changed_since_display',
            });
            return false;
          }
          advanced = true;
          source = 'reaffirmed_pin';
        } else {
          // An unrecorded key: what the user compared is not what would be
          // pinned, so nothing is pinned and the warning stands. The caller
          // must re-display before asking again.
          E2ePersistentDiag.record('PEER_IDENTITY_ADOPT_REFUSED', {
            'peerId': peerId,
            'reason': 'unrecorded_key',
          });
          return false;
        }
      }
    } else {
      advanced = await _identityStore.promotePendingAccountIdentity(name);
      source = 'pending_candidate';
    }
    E2ePersistentDiag.record('PEER_IDENTITY_ACKNOWLEDGED', {
      'peerId': peerId,
      'anchorAdvanced': advanced,
      'source': source,
    });
    if (!advanced) return false;
    _peersWithChangedIdentity.remove(peerId);
    _peersRefusedIdentity.remove(peerId);
    await _persistIdentityChanged();
    onPeerIdentityChanged?.call(peerId);
    return true;
  }

  /// Server-corroborated peer identity change (Phase 0a `peerIdentityChanged`
  /// WS event): the peer's key bundle was REPLACED server-side. Feeds the SAME
  /// state and persistence as the local libsignal detection — one warning
  /// surface, cleared only by [acknowledgePeerIdentity]. Usually a legitimate
  /// new device/browser sign-in on the peer's side, so callers must not word
  /// it as an attack.
  Future<void> recordPeerIdentityChangedFromServer(
    int peerId, {
    String source = 'server_event',
  }) async {
    // (xlviii) clause 2. The userId on this event is whatever the server says,
    // and nothing here used to check it. A peer this device holds NO account
    // anchor for has no identity to have CHANGED — there is nothing to compare
    // in the ceremony and nothing to repair — so recording one is pure noise
    // that competes for the capped persisted set. ~200 forged ids were enough
    // to evict a genuine warning across a restart, and since (xlvii) that
    // warning is the SOLE door to recovery: the flood deleted the repair path
    // for a peer the server had itself broken.
    if (!await _hasPinnedAccountIdentity(peerId)) {
      E2ePersistentDiag.record('PEER_IDENTITY_CHANGED_IGNORED', {
        'peerId': peerId,
        'reason': 'no_local_anchor',
      });
      return;
    }
    final fresh = _peersWithChangedIdentity.add(peerId);
    // (lxxxiv): with warnings OFF the muted demotion below acknowledges
    // without a staged candidate, so the anchor does not advance and the peer
    // STAYS in this set. Returning here on a repeat would drop every later
    // server-reported change for that peer — the "new device or browser"
    // line would fire once per peer, ever. With warnings ON the standing pill
    // already says it, and the repeat is the duplicate it always was.
    if (!fresh && keyChangeWarnings()) return;
    E2ePersistentDiag.record('PEER_IDENTITY_CHANGED', {
      'peerId': peerId,
      'source': source,
      if (!fresh) 'repeat': true,
    });
    if (fresh) {
      onPeerIdentityChanged?.call(peerId);
      await _persistIdentityChanged();
    }
    await _demoteKeyChangeIfMuted(peerId);
  }

  /// A session build was REFUSED because the served identity did not match the
  /// account's anchor ((xxxix)/(lv)). Stages the offered key as the pending
  /// candidate and raises the identity surface, so the refusal is visible and
  /// the out-of-band ceremony can repair it.
  ///
  /// Deliberately NOT routed through [recordPeerIdentityChangedFromServer]:
  /// that method's (xlviii) clause 2 guard drops any peer whose
  /// `getAccountIdentity` is null, which is precisely the shape this path hits
  /// when the anchor was resolved from a per-device row instead. Reusing it
  /// would discard the alarm on the exact path (lv) exists to light up. The
  /// guard filters ids a SERVER asserted with no local anchor; here an anchor
  /// is what produced the refusal, so its condition is already known true.
  ///
  /// Staging grants no trust: the pending slot is read only by the fingerprint
  /// display and by an explicit human confirmation.
  Future<void> _recordAccountIdentityRefusal(
    int peerId,
    IdentityKey offered,
  ) async {
    try {
      // (lxiii) Only when the slot is EMPTY, matching (xlvii) clause 3's guard
      // and for its stated reason: the slot is the evidence a human will
      // compare. Staging unconditionally overwrote a candidate recorded from a
      // REAL inbound ciphertext with a key the server just served — the
      // "candidate moves under the open dialog" shape (xlix) clause 2 and
      // (lviii) preserve, reached from the writer side. It also handed a
      // hostile server a durable ceremony DoS: vary the served key on every
      // fetch and every confirmation loses its compare-and-swap, so the warning
      // never clears and the only door out of the (lvi) refusal stays shut.
      final name = peerId.toString();
      final existing = await _identityStore.pendingAccountIdentity(name);
      if (existing == null) {
        await _identityStore.stagePendingAccountIdentity(name, offered);
      }
    } catch (e) {
      // A failed staging must not swallow the refusal or the alarm: the banner
      // is worth more than the candidate, and (xlvii) clause 3's ceremony
      // re-stages a served key when it finds a standing warning with no offer.
      debugPrint('[EncryptionService] stage pending identity failed: $e');
    }
    // (lxxix) CORRECTION: this path is NOT demoted. Auto-adopting a key the
    // anchor just refused would convert a live MITM refusal into silent trust
    // — exactly what the gate exists to prevent. Instead the refusal always
    // raises the PILL surface (in-memory; a refusal re-fires on the next
    // build attempt), so the muted default still has a visible door: the
    // ceremony, whose successful acknowledgement clears this set.
    if (_peersRefusedIdentity.add(peerId)) {
      onPeerIdentityChanged?.call(peerId);
    }
    if (!_peersWithChangedIdentity.add(peerId)) return;
    E2ePersistentDiag.record('PEER_IDENTITY_CHANGED', {
      'peerId': peerId,
      'source': 'account_identity_mismatch',
    });
    onPeerIdentityChanged?.call(peerId);
    await _persistIdentityChanged();
  }

  /// Whether this device holds a pinned ACCOUNT identity for [peerId].
  ///
  /// Uncertainty answers YES on purpose: losing a genuine identity warning is
  /// far worse than recording a spurious one, so an unready store or a storage
  /// error must not become a silent filter on safety notices.
  Future<bool> _hasPinnedAccountIdentity(int peerId) async {
    if (!_initialized) return true;
    try {
      final pinned = await _identityStore.getAccountIdentity(peerId.toString());
      return pinned != null;
    } catch (_) {
      return true;
    }
  }

  // ---------- Own-identity-replaced alarm (Phase 0a, spec §6.0) ----------

  /// ISO-8601 instant of the last server-reported replacement of THIS
  /// account's key bundle by ANOTHER session (`ownIdentityReplaced` WS event
  /// or `identity_changed` push). Null when none pending. Persisted per user
  /// until explicitly dismissed — the alarm must survive a restart.
  String? _ownIdentityReplacedAt;
  String? get ownIdentityReplacedAt => _ownIdentityReplacedAt;

  /// Fired when the own-identity-replaced state changes. Set by the provider.
  void Function()? onOwnIdentityReplaced;

  String _ownIdentityReplacedKey(int userId) =>
      'e2e_${userId}_own_identity_replaced_v1';

  /// Watermark of the newest replacement the user already dismissed.
  ///
  /// Needed because the server now reports the last replacement at connect
  /// time (so a session that was offline when it happened still learns about
  /// it). Without this, every reconnect would resurrect an alarm the user
  /// already acknowledged; with it, only a replacement NEWER than the
  /// dismissed one can raise the banner again.
  String? _ownIdentityReplacedSeenAt;

  String _ownIdentityReplacedSeenKey(int userId) =>
      'e2e_${userId}_own_identity_replaced_seen_v1';

  /// One-shot: THIS device published a new identity and the server has not yet
  /// reported it back. Amendment (li) clause 2 — replaces a device-clock
  /// watermark, because that clock was compared against SERVER stamps and a
  /// fast clock silently suppressed every genuine replacement for the skew.
  bool _ownPublishUnacknowledged = false;

  String _ownPublishUnackKey(int userId) =>
      'e2e_${userId}_own_publish_unacked_v1';

  /// How far ahead of us a server instant may legitimately sit. Generous on
  /// purpose: this bounds ABSURDITY (a `9999-…` suppressor), not clock skew.
  static const Duration _maxServerInstantSkew = Duration(days: 1);

  /// Amendment (li) clause 1. Parses a server-supplied instant and returns the
  /// CANONICAL UTC form, or null when the value cannot be trusted to order.
  ///
  /// Every downstream comparison of these values is a STRING compare, which is
  /// sound only for a canonical representation — so canonicalising here is what
  /// makes that soundness structural instead of an assumption in a comment.
  static String? normalizeServerInstant(String? raw) {
    if (raw == null) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    final utc = parsed.toUtc();
    if (utc.isAfter(DateTime.now().toUtc().add(_maxServerInstantSkew))) {
      return null;
    }
    return utc.toIso8601String();
  }

  Future<void> recordOwnIdentityReplaced(String occurredAt) async {
    _ownIdentityReplacedAt = occurredAt;
    E2ePersistentDiag.record('OWN_IDENTITY_REPLACED', {
      'occurredAt': occurredAt,
    });
    // UI first, persistence after: the alarm must reach the user even when
    // the write fails (same rule as the peer warning above).
    onOwnIdentityReplaced?.call();
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      await prefs.setString(_ownIdentityReplacedKey(userId), occurredAt);
    } catch (_) {}
  }

  /// Connect-time hydration from the server's durable audit row (Phase 0b).
  ///
  /// Ignores anything the user already dismissed, and anything not newer than
  /// what is already showing, so reconnect churn cannot re-raise a handled
  /// alarm. The comparison is a string compare, which is sound because every
  /// value that reaches here has been through [normalizeServerInstant] — the
  /// assumption a comment used to assert, now enforced ((li) clause 1).
  ///
  /// [replacedTo] is the audit row's NEW identity key ((lxxx) clause 5). When
  /// it equals the key THIS device publishes, the row describes a change that
  /// ended at the identity we already hold — nothing is pending, so it is not
  /// reported. A row ending at any OTHER key still alarms, which is what keeps
  /// this exactly as strong as before: republishing this identity needs its
  /// private half, and a §6.1 rotation or §6.2 ceremony by anyone else lands
  /// on a different key. Deliberately NOT the one-shot
  /// [markOwnIdentityPublished] flag: an account with no audit row sends no
  /// instant, the early return below fires before the flag is consumed, and a
  /// flag left armed in prefs would eat the next genuine replacement.
  Future<void> recordOwnIdentityReplacedFromServer(
    String occurredAt, {
    String? replacedTo,
  }) async {
    // Defence in depth: the provider normalizes, and so do we. An unorderable
    // instant is IGNORED on this path — hydration exists only to order a past
    // event against the watermark, and a server that withholds the field
    // entirely already achieves this, so ignoring grants it nothing new.
    final normalized = normalizeServerInstant(occurredAt);
    if (normalized == null) return;

    if (replacedTo != null && replacedTo.isNotEmpty) {
      // Unknown own key (not initialized yet) falls THROUGH to reporting:
      // silence must never be the fail-open answer for an alarm.
      final own = await _ownPublishedIdentityBase64();
      if (own != null && own == replacedTo) {
        E2ePersistentDiag.record('OWN_IDENTITY_REPLACED_IS_SELF', {});
        // (lxxxi) clause 2: the SAME row may already be showing — it was
        // reported by the connect that preceded the restore, when this
        // install held no identity to compare against. It just proved to be
        // ours, so retract it. Only an alarm for THIS instant: the server
        // reports the latest row, and an alarm for an earlier instant was
        // raised by a different row that is still somebody else's.
        if (_ownIdentityReplacedAt == normalized) {
          await dismissOwnIdentityReplaced();
        }
        return;
      }
    }

    // Amendment (li) clause 2: the report of OUR OWN republish, consumed once.
    if (_ownPublishUnacknowledged) {
      await _clearOwnPublishUnacknowledged();
      return;
    }
    final seen = _ownIdentityReplacedSeenAt;
    if (seen != null && normalized.compareTo(seen) <= 0) return;
    final current = _ownIdentityReplacedAt;
    if (current != null && normalized.compareTo(current) <= 0) return;
    await recordOwnIdentityReplaced(normalized);
  }

  /// This device's published identity public key, base64, or null when the
  /// keys are not loaded (or unreadable). Only ever used to recognise our OWN
  /// key in an audit row ((lxxx) clause 5), so a null answer is safe: the
  /// caller then reports the row rather than suppressing it.
  Future<String?> _ownPublishedIdentityBase64() async {
    if (!_initialized) return null;
    try {
      final keyPair = await _identityStore.getIdentityKeyPair();
      return base64Encode(keyPair.getPublicKey().serialize());
    } catch (_) {
      return null;
    }
  }

  /// Records that THIS device published a new identity, so the connect-time
  /// hydration does not report that replacement back as a warning.
  ///
  /// Without it a user who just completed a reset ceremony and re-published
  /// their keys is told, on their very next connect, that "another sign-in"
  /// replaced them — an alarm about the recovery they just performed, on a
  /// fresh install that has no dismissal watermark to suppress it.
  ///
  /// A ONE-SHOT flag, not a time window ((li) clause 2). The old form wrote a
  /// DEVICE-clock watermark ten minutes ahead and compared it against
  /// SERVER-stamped instants, so a fast device clock silently suppressed every
  /// genuine replacement for the whole skew. The blind spot is now exactly one
  /// report instead of ten minutes of them, and it involves no clock at all —
  /// and an unauthorized replacement still cannot reach it, because the §6.1
  /// registration lock refuses one that is neither signed nor spending a
  /// ceremony.
  Future<void> markOwnIdentityPublished() async {
    _ownPublishUnacknowledged = true;
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      await prefs.setInt(_ownPublishUnackKey(userId), 1);
    } catch (_) {}
  }

  Future<void> _clearOwnPublishUnacknowledged() async {
    _ownPublishUnacknowledged = false;
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      await prefs.remove(_ownPublishUnackKey(userId));
    } catch (_) {}
  }

  Future<void> dismissOwnIdentityReplaced() async {
    final dismissed = _ownIdentityReplacedAt;
    if (dismissed == null) return;
    _ownIdentityReplacedAt = null;
    _ownIdentityReplacedSeenAt = dismissed;
    E2ePersistentDiag.record('OWN_IDENTITY_REPLACED_DISMISSED', {});
    onOwnIdentityReplaced?.call();
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      await prefs.remove(_ownIdentityReplacedKey(userId));
      await prefs.setString(_ownIdentityReplacedSeenKey(userId), dismissed);
    } catch (_) {}
  }

  Future<void> _loadOwnIdentityReplaced(int userId) async {
    try {
      final prefs = await _sharedPrefs;
      _ownIdentityReplacedAt = prefs.getString(_ownIdentityReplacedKey(userId));
      _ownIdentityReplacedSeenAt = prefs.getString(
        _ownIdentityReplacedSeenKey(userId),
      );
      // (li) clause 2: the flag must survive a restart, because a fresh
      // install right after a recovery is exactly when the false alarm fired.
      _ownPublishUnacknowledged =
          (prefs.getInt(_ownPublishUnackKey(userId)) ?? 0) == 1;
    } catch (_) {}
  }

  Future<void> _persistIdentityChanged() async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      // Bounded degradation (an old warning drops off) beats an unbounded key
      // competing with the Signal session records for quota — but the eviction
      // MUST be by recency, not by id (xlviii clause 2). This used to sort the
      // ids and keep the tail, i.e. the 200 numerically HIGHEST, which drops
      // the LOWEST id: merely the oldest account, and therefore the likeliest
      // to be a real long-standing contact. `_peersWithChangedIdentity` is a
      // LinkedHashSet, so iteration order IS insertion order and the tail is
      // the most recently warned.
      final ordered = _peersWithChangedIdentity.toList();
      final kept = ordered.length > _identityChangedCap
          ? ordered.sublist(ordered.length - _identityChangedCap)
          : ordered;
      await prefs.setString(_identityChangedKey(userId), jsonEncode(kept));
    } catch (_) {}
  }

  Future<void> _loadIdentityChanged(int userId) async {
    try {
      final prefs = await _sharedPrefs;
      await _reloadPrefsForCrossContext(prefs);
      final raw = prefs.getString(_identityChangedKey(userId));
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _peersWithChangedIdentity.addAll(decoded.whereType<int>());
    } catch (_) {}
  }

  // ---------- Persisted session-rebuild intent (amendment (xlviii) clause 1) --

  /// Addresses whose Signal session must be rebuilt before the next send,
  /// as `peerId:deviceId`.
  ///
  /// Persisted because the reason it gets set is persisted. A confirmed
  /// (xlvii) recovery advances the account anchor AND clears the identity
  /// warning — both durable — while the intent to rebuild the sessions that
  /// the old key poisoned used to live only in provider memory. Killing the
  /// app in between therefore left a peer whose anchor said "resolved", whose
  /// warning was gone, and whose session was still keyed to the identity the
  /// user had just replaced: the next send silently encrypted to a key the
  /// peer no longer holds, destroying a message that had one copy.
  ///
  /// Insertion-ordered and capped like the warning set: bounded degradation
  /// beats an unbounded key competing with the session records for quota.
  final Set<String> _pendingSessionRebuilds = <String>{};

  static const int _sessionRebuildCap = 200;

  String _sessionRebuildKey(int userId) => 'e2e_${userId}_session_rebuild_v1';

  static String _rebuildEntry(int peerId, int deviceId) => '$peerId:$deviceId';

  /// Every persisted rebuild intent, as `(peerId, deviceId)` pairs.
  Set<(int, int)> get pendingSessionRebuilds {
    final out = <(int, int)>{};
    for (final entry in _pendingSessionRebuilds) {
      final parts = entry.split(':');
      if (parts.length != 2) continue;
      final peerId = int.tryParse(parts[0]);
      final deviceId = int.tryParse(parts[1]);
      if (peerId == null || deviceId == null) continue;
      out.add((peerId, deviceId));
    }
    return out;
  }

  /// Durably record that [addresses] of [peerId] need a session rebuild.
  ///
  /// Called BEFORE the anchor advances, on purpose (clause 1): a kill between
  /// the two MUST leave a redundant rebuild rather than a cleared warning over
  /// a poisoned session. A redundant rebuild costs one pre-key fetch and one
  /// one-time pre-key; the other ordering costs a message.
  Future<void> recordSessionRebuilds(
    int peerId,
    Iterable<int> addresses,
  ) async {
    var added = false;
    for (final deviceId in addresses) {
      if (_pendingSessionRebuilds.add(_rebuildEntry(peerId, deviceId))) {
        added = true;
      }
    }
    if (!added) return;
    await _persistSessionRebuilds();
  }

  /// Drop the persisted intent for one address, once a rebuild really happened.
  Future<void> clearSessionRebuild(int peerId, int deviceId) async {
    if (!_pendingSessionRebuilds.remove(_rebuildEntry(peerId, deviceId))) {
      return;
    }
    await _persistSessionRebuilds();
  }

  /// Drop every persisted intent for [peerId] — the acknowledgement was
  /// refused, so nothing advanced and nothing is poisoned.
  Future<void> clearSessionRebuildsFor(int peerId) async {
    final prefix = '$peerId:';
    final before = _pendingSessionRebuilds.length;
    _pendingSessionRebuilds.removeWhere((e) => e.startsWith(prefix));
    if (_pendingSessionRebuilds.length == before) return;
    await _persistSessionRebuilds();
  }

  Future<void> _persistSessionRebuilds() async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      final ordered = _pendingSessionRebuilds.toList();
      final kept = ordered.length > _sessionRebuildCap
          ? ordered.sublist(ordered.length - _sessionRebuildCap)
          : ordered;
      await prefs.setString(_sessionRebuildKey(userId), jsonEncode(kept));
    } catch (_) {}
  }

  Future<void> _loadSessionRebuilds(int userId) async {
    try {
      final prefs = await _sharedPrefs;
      final raw = prefs.getString(_sessionRebuildKey(userId));
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _pendingSessionRebuilds.addAll(decoded.whereType<String>());
    } catch (_) {}
  }

  // ---------- Persisted device-list rollback pins (xlviii clause 3) ----------

  /// Highest device-list version ever verified per PEER userId.
  ///
  /// The floor the (xix) rollback refusal reads. Persisted because a process
  /// restart is a stronger cache invalidation than the one the pin was already
  /// designed to survive: while it lived only in memory, every app launch let a
  /// server re-serve an older validly-signed list — including one that
  /// re-admits a device the peer had revoked.
  final Map<int, int> _deviceListPins = {};

  /// Pins recorded by this and previous processes, for seeding the cache.
  Map<int, int> get deviceListPins => Map.unmodifiable(_deviceListPins);

  String _deviceListPinsKey(int userId) => 'e2e_${userId}_devicelist_pins_v1';

  /// Durably record that [peerId]'s list verified at [version]. Monotonic: a
  /// lower version never lowers the floor.
  ///
  /// The WRITE deliberately does not throw ((lvii)). This serialises the ENTIRE
  /// map on every advance, so a transient failure is repaired by the next
  /// successful advance; and [DeviceListCache.onPinAdvanced] is a `void`
  /// callback reached from inside verification, where throwing would turn a
  /// storage hiccup into a failed verification. It records a diagnostic instead,
  /// because the failure used to be entirely invisible.
  Future<void> recordDeviceListPin(int peerId, int version) async {
    final held = _deviceListPins[peerId];
    if (held != null && version <= held) return;
    _deviceListPins[peerId] = version;
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      await prefs.setString(
        _deviceListPinsKey(userId),
        jsonEncode(_deviceListPins.map((k, v) => MapEntry(k.toString(), v))),
      );
    } catch (e) {
      E2ePersistentDiag.record('DEVICELIST_PIN_WRITE_FAILED', {
        'peerId': peerId,
        'version': version,
        'error': e.toString(),
      });
    }
  }

  /// Restore the rollback floors recorded by previous processes.
  ///
  /// FAILS CLOSED ((lvii)): a storage or decode error PROPAGATES out of
  /// [initialize]. This used to swallow everything, which made a read failure
  /// indistinguishable from "never pinned" — and an empty floor is not neutral.
  /// [DeviceListCache.adopt] refuses a `not enrolled` answer only when a pin
  /// exists, and compares against the pin otherwise, so a silently empty floor
  /// lets a server re-serve an older validly-signed list — including one that
  /// re-admits a revoked device. That is the window (xix) refuses.
  ///
  /// This is the rule the identity load twenty lines below already states: a
  /// storage error must never be read as an absence. A loud, retryable init
  /// failure beats a permanent, undetectable downgrade.
  ///
  /// A missing key is a GENUINE absence and stays silent: a device that never
  /// pinned anything has no floor to lose.
  Future<void> _loadDeviceListPins(int userId) async {
    final prefs = await _sharedPrefs;
    final raw = prefs.getString(_deviceListPinsKey(userId));
    if (raw == null) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      E2ePersistentDiag.record('DEVICELIST_PIN_LOAD_FAILED', {
        'userId': userId,
        'error': e.toString(),
      });
      rethrow;
    }
    if (decoded is! Map) {
      E2ePersistentDiag.record('DEVICELIST_PIN_LOAD_FAILED', {
        'userId': userId,
        'error': 'stored pins are not a map',
      });
      throw StateError('device-list pins for $userId are malformed');
    }
    decoded.forEach((key, value) {
      final peerId = int.tryParse(key.toString());
      if (peerId == null || value is! int) {
        // One unusable entry is one lost floor, not a lost store, so it must be
        // visible without denying every other peer its pin.
        E2ePersistentDiag.record('DEVICELIST_PIN_ENTRY_SKIPPED', {
          'userId': userId,
          'key': key.toString(),
        });
        return;
      }
      final held = _deviceListPins[peerId];
      if (held == null || value > held) _deviceListPins[peerId] = value;
    });
  }

  /// Construct the four Signal stores for prefix [p].
  ///
  /// Single place on purpose: the identity store carries the
  /// peer-identity-change callback, and a second construction site that forgot
  /// it would silently disable the MITM/re-key warning.
  void _buildStores(String p) {
    _identityStore = SecureIdentityKeyStore(
      _storage,
      p,
      onIdentityChanged: (address) {
        final peerId = int.tryParse(address.getName());
        if (peerId == null) return;
        if (!_peersWithChangedIdentity.add(peerId)) return;
        E2ePersistentDiag.record('PEER_IDENTITY_CHANGED', {'peerId': peerId});
        // Fire the UI first, persist after: the warning must reach the user
        // even if the write fails, and this callback is not awaited by the
        // Signal path (it runs inside isTrustedIdentity).
        onPeerIdentityChanged?.call(peerId);
        _persistIdentityChanged();
        // (lxxix): not awaited — this callback runs inside isTrustedIdentity
        // on the Signal path, same reasoning as the persist above.
        _demoteKeyChangeIfMuted(peerId);
      },
    );
    _preKeyStore = SecurePreKeyStore(_storage, p);
    _signedPreKeyStore = SecureSignedPreKeyStore(_storage, p);
    _sessionStore = SecureSessionStore(_storage, p);
    _cipherSessionStore = _sessionStore;
  }

  /// Initialize the encryption service for the given user. Loads keys from
  /// secure storage or generates new ones if this is a fresh install.
  Future<void> initialize(
    int userId, {
    Future<ServerIdentityGuard?> Function()? checkServerIdentity,
  }) async {
    // (lxxxiv) rider: this service is a process singleton reused across
    // logins, and the loaders below ADD to these collections. Left standing,
    // account A's peer notes and pills render in B's chats, A's rebuild
    // intents (A's sessions) drive B's sends, and A's device-list pins get
    // re-persisted under B's key (B's floor must come from B's own storage;
    // the loader below restores it). Cleared only when the account
    // CHANGES — a same-user re-run (passcode re-lock → unlock) must keep the
    // unpersisted refusals.
    if (_userId != userId) {
      _peersWithChangedIdentity.clear();
      _peerKeyChangeNotes.clear();
      _peersRefusedIdentity.clear();
      _pendingSessionRebuilds.clear();
      _deviceListPins.clear();
    }
    _userId = userId;
    final p = 'e2e_${userId}_'; // per-user storage key prefix

    _buildStores(p);
    // Restore warnings the user has not acknowledged yet, before any session
    // work can add to the set.
    await _loadIdentityChanged(userId);
    await _loadKeyChangeNotes(userId);
    await _loadOwnIdentityReplaced(userId);
    // Rebuild intents outlive the process that recorded them (clause 1): a
    // recovery confirmed just before the app died must still repair its
    // sessions on the next launch.
    await _loadSessionRebuilds(userId);
    // Rollback floors from previous launches (clause 3), before any device list
    // can be adopted against an empty floor.
    await _loadDeviceListPins(userId);

    // A THROWING read propagates: a storage error must never be read as "no
    // keys". Only a definitive outcome reaches the server-backed guard.
    final load = await _identityStore.loadFromStorage();
    if (load == IdentityLoadResult.loaded) {
      debugPrint('[EncryptionService] Loaded existing keys from storage');
      // A non-null _keysForUpload means THIS process minted key material
      // that may not have reached the server yet — above all the §5.1
      // adopt path, whose init previously failed (keyless) so the
      // provider re-enters here after the ceremony. Dropping the flag
      // would strand the minted signed-prekey/OTPs unpublished until a
      // preKeysLow bounce.
      needsKeyUpload = _keysForUpload != null;
      _initialized = true;
      return;
    }

    // No usable identity: a damaged record, an identity gone while sessions
    // or prekeys survive, or a truly empty store. None of these is evidence
    // of a fresh install on its own — the same shapes come from a storage
    // wipe and from a second-device login — so the server decides (lxxi).
    // It answers for this login's device, which resolves to the live
    // primary, so "no bundle" means the account never published an identity
    // (or a completed §6.2 reset is waiting to be spent by our upload).
    final residue =
        load == IdentityLoadResult.partial || await _hasPriorInstallResidue(p);
    ServerIdentityGuard? guard;
    try {
      guard = await checkServerIdentity?.call();
    } catch (_) {
      // A failed check is UNKNOWN, never evidence of a fresh install.
    }

    if (guard == null) {
      E2ePersistentDiag.record('IDENTITY_GUARD_UNKNOWN', {'userId': userId});
      throw const E2eIdentityCheckUnavailableException();
    }
    if (guard.exists && guard.linkingEnabled) {
      E2ePersistentDiag.record(
        residue ? 'IDENTITY_INCOMPLETE' : 'IDENTITY_GUARD_SERVER_BUNDLE_EXISTS',
        {'userId': userId},
      );
      debugPrint(
        '[EncryptionService] Identity incomplete — refusing to regenerate',
      );
      identityIncomplete = true;
      throw const E2eIdentityIncompleteException();
    }

    if (residue) {
      // Signal material without a published identity is leftover from an
      // install whose upload never landed. No peer holds a session against
      // it, so it protects nothing — and leaving it would strand the new
      // identity against ratchets no peer can follow. Which is why the
      // discard must be PROVEN, not attempted: if enumeration fails, nothing
      // may be minted over rows we could not see. Defer to the next boot,
      // exactly as an UNKNOWN server answer does (§5.11 R1).
      if (!await _wipeSignalMaterial(p)) {
        E2ePersistentDiag.record('IDENTITY_RESIDUE_DISCARD_DEFERRED', {
          'userId': userId,
        });
        throw const E2eIdentityCheckUnavailableException();
      }
      E2ePersistentDiag.record('IDENTITY_RESIDUE_DISCARDED', {'userId': userId});
      _buildStores(p);
      // Warnings about peers and rebuild intents were recorded against the
      // discarded material; both name nothing now.
      _peersWithChangedIdentity.clear();
      await _persistIdentityChanged();
      _pendingSessionRebuilds.clear();
      await _persistSessionRebuilds();
    }
    if (guard.exists) {
      // (lxxiii) clause 2: the account has a bundle but never enrolled a DAK,
      // so the server accepts an 'unlocked' replacement — mint instead of
      // gating. The residue (if any) was discarded PROVEN above; the previous
      // identity's peers get the §6.0 "identity changed" alarm on upload.
      E2ePersistentDiag.record('IDENTITY_GUARD_UNLOCKED_REMINT', {
        'userId': userId,
      });
    }
    // DURABLE on purpose: this is the one branch that mints a new Signal
    // identity, and until 2026-09-04 it left only a debugPrint, so a
    // misclassification could be inferred in the field solely from the
    // peer identity-change cascade it caused hours later. Every guard
    // above records its refusal; the action itself has to record too.
    E2ePersistentDiag.record('IDENTITY_MINTED', {
      'userId': userId,
      'reason': guard.exists
          ? 'server-bundle-unlocked-remint'
          : 'absent-no-residue-server-says-none',
    });
    debugPrint('[EncryptionService] Generating new keys (fresh install)');
    await _generateKeys();
    needsKeyUpload = true;
    _initialized = true;
  }

  /// True when storage still holds Signal material from a previous install of
  /// this account — sessions, prekeys, or the prekey counter. Identity absent
  /// while these survive is partial loss, not a fresh install: whether the
  /// residue protects anything is the server's call (lxxi), never inferred.
  ///
  /// Only consulted after [SecureIdentityKeyStore.loadFromStorage] returned
  /// `absent`. A throwing `readAll` is INCONCLUSIVE — and inconclusive now
  /// reads as RESIDUE-PRESENT (fail closed; B2b design review R1). The old
  /// `catch → false` bias was written for a plaintext world where `readAll`
  /// practically never threw and biasing true would brick fresh installs;
  /// with the web sig store sealed, an enumeration transient coinciding with
  /// lost identity rows would have this guard wave `_generateKeys()` through
  /// — a NEW identity minted over surviving sealed sessions, the permanent
  /// silent loss this method exists to block. Cost of the new bias: a genuine
  /// fresh install under a storage transient sees the incomplete-identity
  /// surface once and retries next boot — recoverable, unlike regeneration.
  Future<bool> _hasPriorInstallResidue(String prefix) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final all = await _storage.readAll();
        for (final key in all.keys) {
          if (!key.startsWith(prefix)) continue;
          final suffix = key.substring(prefix.length);
          if (suffix.startsWith('session_') ||
              suffix.startsWith('pre_key_') ||
              suffix.startsWith('signed_pre_key_') ||
              suffix == 'next_pre_key_id') {
            return true;
          }
        }
        return false;
      } catch (_) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }
    E2ePersistentDiag.record('IDENTITY_RESIDUE_UNKNOWN', {'prefix': prefix});
    return true;
  }

  /// Deletes every Signal-material key under [p] — identity, sessions,
  /// pre-keys, signed pre-keys, peer trust — leaving the content store and
  /// non-Signal records untouched. Shared by the (lxxi) never-published
  /// residue discard and the (lxv) stale-material disposal.
  ///
  /// Returns whether the wipe is PROVEN complete: the store was listed AND
  /// every Signal-material row under [p] was deleted. `false` means at least
  /// one row may still exist. The (lxv) caller ignores that (it immediately
  /// overwrites the identity slot; a partial wipe beats none); the (lxxi)
  /// caller MUST NOT mint over a row it could not see or could not remove.
  Future<bool> _wipeSignalMaterial(String p) async {
    final Map<String, String> all;
    try {
      all = await _storage.readAll();
    } catch (_) {
      return false;
    }
    var deletedAll = true;
    for (final key in all.keys.toList()) {
      if (!key.startsWith(p)) continue;
      final suffix = key.substring(p.length);
      final isSignalMaterial =
          suffix.startsWith('session_') ||
          suffix.startsWith('pre_key_') ||
          suffix.startsWith('signed_pre_key_') ||
          suffix.startsWith('trusted_identity_') ||
          suffix.startsWith('identity_') ||
          suffix == 'registration_id' ||
          suffix == 'next_pre_key_id';
      if (isSignalMaterial) {
        try {
          await _storage.delete(key: key);
        } catch (_) {
          // Keep going — every row that CAN go should — but report it.
          deletedAll = false;
        }
      }
    }
    return deletedAll;
  }

  /// §5.1 provisioning adopt (Phase 2 T3, spec §12 item (ii)): install the
  /// account identity the primary transported in the ceremony blob, on a
  /// device that has NO identity of its own.
  ///
  /// Discipline (frontend/CLAUDE.md §5): the identity record is ONE atomic
  /// write of the ADOPTED pair plus a locally-minted registrationId — never
  /// regenerated, and storage is untouched until every input has parsed.
  /// Signed pre-key and one-time pre-keys are minted into the local stores
  /// but NOT uploaded — the upload rides the existing OTP-gate path after
  /// the session rebinds to the assigned deviceId (amendment (b)).
  ///
  /// Amendment (lxv): [disposeStaleMaterial] authorizes wiping an EXISTING
  /// identity before adopting. Passed ONLY by the ceremony when this install
  /// is in the (lxiv) device-material-mismatch state — material stamped for a
  /// device the account has revoked. The SAS confirmation plus authenticated
  /// blob is the user's consent; the content store (sealed history) is
  /// untouched, so the §5.5 "messages stay" promise holds.
  Future<void> adoptProvisionedIdentity({
    required int userId,
    required String ikPubBase64,
    required String ikPrivBase64,
    required String dakPubBase64,
    bool disposeStaleMaterial = false,
  }) async {
    // Invariant lock (T3 review NOTE): adopting over a device that already
    // holds ANY identity would silently orphan every session keyed to it —
    // the UI gates this flow on identityIncomplete, but the service must
    // refuse on its own too. Both record shapes checked (atomic + legacy).
    // Amendment (lxv) carves out exactly ONE exception: a ceremony-authorized
    // disposal of (lxiv)-mismatched stale material.
    final existingPrefix = 'e2e_${userId}_';
    final holdsIdentity =
        await _storage.read(key: '${existingPrefix}identity_record_v1') !=
            null ||
        await _storage.read(key: '${existingPrefix}identity_key_pair') != null;
    if (holdsIdentity && !disposeStaleMaterial) {
      throw StateError(
        'adoptProvisionedIdentity: device already holds an identity',
      );
    }
    // Parse EVERYTHING first: a malformed blob must fail before any write —
    // including the (lxv) wipe, or a bad blob would strand the install
    // keyless without the adopt that justified the disposal.
    final identityKeyPair = IdentityKeyPair(
      IdentityKey.fromBytes(base64Decode(ikPubBase64), 0),
      Curve.decodePrivatePoint(
        // Library caveat: curve calls mutate handed buffers — fresh copy.
        Uint8List.fromList(base64Decode(ikPrivBase64)),
      ),
    );
    base64Decode(dakPubBase64); // validity gate only

    // (lxxiii) clause 4: the wipe runs whenever RESIDUE is present — a held
    // identity OR surviving prekeys/sessions/next_pre_key_id with no identity
    // — never only when an identity exists. A held identity is the (lxv)
    // stale shape and requires the ceremony's disposal authorization (gated
    // above); a NEVER-PUBLISHED residue needs no separate consent: no peer
    // holds a ratchet against unpublished material, and the SAS plus the
    // authenticated blob already authorized installing over this store. The
    // wipe must be PROVEN before the first store write — installing the
    // received identity over foreign prekeys and a stale prekey counter is
    // the stranded-ratchet shape (lxxi)'s rider exists to prevent. Unproven
    // → the ceremony fails (the controller's catch aborts 'adopt_failed')
    // and the gate stays.
    final residue =
        holdsIdentity || await _hasPriorInstallResidue(existingPrefix);
    if (residue) {
      if (holdsIdentity) {
        // (lxv): every input parsed; the stale material may now go.
        E2ePersistentDiag.record('LINK_STALE_MATERIAL_DISPOSED', {
          'userId': userId,
        });
      }
      if (!await _wipeSignalMaterial(existingPrefix)) {
        E2ePersistentDiag.record('LINK_RESIDUE_DISPOSAL_DEFERRED', {
          'userId': userId,
        });
        throw StateError(
          'adoptProvisionedIdentity: residue disposal not proven',
        );
      }
    }

    _userId = userId;
    final p = 'e2e_${userId}_';
    _buildStores(p);

    final registrationId = generateRegistrationId(false);
    await _identityStore.initialize(identityKeyPair, registrationId);
    // (lxiv): adopted material is re-homed by this ceremony — drop any stamp
    // from a previous life; the post-rebind connect re-stamps the assigned id.
    try {
      await _storage.delete(key: _materialDeviceKey(userId));
    } catch (_) {}

    final signedPreKey = generateSignedPreKey(identityKeyPair, 0);
    await _signedPreKeyStore.storeSignedPreKey(signedPreKey.id, signedPreKey);
    final preKeys = generatePreKeys(0, _initialPreKeyBatchSize);
    await Future.wait(preKeys.map((pk) => _preKeyStore.storePreKey(pk.id, pk)));
    await _storage.write(
      key: '${p}next_pre_key_id',
      value: _initialPreKeyBatchSize.toString(),
    );

    // The account's device-authority public key, for verifying own signed
    // lists along the I7 chain (a linked device never holds the private
    // half, invariant I2).
    await _storage.write(key: '${p}dak_pub_v1', value: dakPubBase64);

    _keysForUpload = {
      'keyBundle': {
        'registrationId': registrationId,
        'identityPublicKey': base64Encode(
          identityKeyPair.getPublicKey().serialize(),
        ),
        'signedPreKeyId': signedPreKey.id,
        'signedPreKeyPublic': base64Encode(
          signedPreKey.getKeyPair().publicKey.serialize(),
        ),
        'signedPreKeySignature': base64Encode(signedPreKey.signature),
      },
      'oneTimePreKeys': preKeys.map(_preKeyToUploadFormat).toList(),
    };
    await _storage.write(key: '${p}setup_complete', value: 'true');

    needsKeyUpload = true;
    identityIncomplete = false;
    _initialized = true;
    _provisionalIdentityAdopted = true;
    E2ePersistentDiag.record('LINK_IDENTITY_ADOPTED', {'userId': userId});
  }

  /// Abort hygiene of a failed §5.1 ceremony (I1, falsification 18): delete
  /// EXACTLY what [adoptProvisionedIdentity] wrote, so N ends as unkeyed as
  /// it started. Only runs on a device whose ceremony this process started —
  /// the adopt path is reachable only while the device holds no identity.
  Future<void> discardProvisionedIdentity(int userId) async {
    // Invariant lock (T3 review NOTE): this delete is legal ONLY against an
    // identity this process adopted in a still-unsettled ceremony. Any other
    // caller would be destroying a real account's keys.
    if (!_provisionalIdentityAdopted) {
      throw StateError(
        'discardProvisionedIdentity: no provisional identity to discard',
      );
    }
    final p = 'e2e_${userId}_';
    final all = await _storage.readAll();
    for (final key in all.keys.toList()) {
      if (!key.startsWith(p)) continue;
      final suffix = key.substring(p.length);
      final wroteByAdopt =
          suffix == 'identity_record_v1' ||
          suffix == 'identity_key_pair' ||
          suffix == 'registration_id' ||
          suffix == 'next_pre_key_id' ||
          suffix == 'setup_complete' ||
          suffix == 'dak_pub_v1' ||
          suffix.startsWith('signed_pre_key_') ||
          suffix.startsWith('pre_key_');
      if (wroteByAdopt) {
        await _storage.delete(key: key);
      }
    }
    _keysForUpload = null;
    needsKeyUpload = false;
    _provisionalIdentityAdopted = false;
    _initialized = false;
    E2ePersistentDiag.record('LINK_IDENTITY_DISCARDED', {'userId': userId});
  }

  /// The full identity pair, for the §5.1 primary side building the
  /// ceremony blob. READ ONLY — the ceremony must never mint identity
  /// material of its own.
  Future<IdentityKeyPair> identityKeyPairForLinking() async {
    if (!_initialized) {
      throw StateError('encryption service not initialized');
    }
    return _identityStore.getIdentityKeyPair();
  }

  /// The phrase-sealed backup's plaintext (amendment (lxxviii)): the
  /// `identity_record_v1` string verbatim plus the `dak_record_v1_<uid>`
  /// string verbatim (null when this account never enrolled a DAK). Records
  /// ride as the exact strings the stores persist, so a restore reinstalls
  /// rather than re-derives.
  Future<IdentityBackupPayload> exportIdentityForBackup() async {
    final uid = _userId;
    if (uid == null || !_initialized) {
      throw StateError('encryption service not initialized');
    }
    final identity = await _storage.read(key: 'e2e_${uid}_identity_record_v1');
    if (identity == null) {
      throw StateError('no identity record to back up');
    }
    final dak = await _storage.read(key: 'dak_record_v1_$uid');
    return IdentityBackupPayload(userId: uid, identity: identity, dak: dak);
  }

  /// The public half stored in an `identity_record_v1` blob, base64, or null
  /// when the record is absent or unreadable. Only used to recognise a
  /// re-adopt of the SAME identity, so null is the safe answer: the caller
  /// then treats the held identity as different and refuses.
  String? _identityRecordPublicKey(String? record) {
    if (record == null) return null;
    try {
      final decoded = jsonDecode(record) as Map<String, dynamic>;
      final pair = IdentityKeyPair.fromSerialized(
        Uint8List.fromList(base64Decode(decoded['pair'] as String)),
      );
      return base64Encode(pair.getPublicKey().serialize());
    } catch (_) {
      return null;
    }
  }

  /// §6.2-recovery restore adopt (amendment (lxxviii) clause 3): reinstall
  /// the account identity + DAK from the phrase-sealed backup on a device
  /// that lost its keys.
  ///
  /// Same residue discipline as [adoptProvisionedIdentity] ((lxxiii) clause
  /// 3): everything parses BEFORE any write, residue (a held identity — only
  /// with [disposeStaleMaterial], or a re-adopt of the identity already held —
  /// or surviving prekeys/sessions) is wiped and PROVEN wiped before the first
  /// store write. The identity record and the registrationId are the BACKED-UP
  /// ones — the identity is preserved, never re-minted — while the signed
  /// prekey and one-time prekeys are fresh (their private halves died with the
  /// wipe; peers re-key).
  Future<void> adoptRestoredIdentity({
    required int userId,
    required IdentityBackupPayload payload,
    bool disposeStaleMaterial = false,
  }) async {
    if (payload.userId != userId) {
      throw StateError('adoptRestoredIdentity: backup belongs to another '
          'account (${payload.userId} != $userId)');
    }
    final existingPrefix = 'e2e_${userId}_';
    final heldRecord = await _storage.read(
      key: '${existingPrefix}identity_record_v1',
    );
    final holdsIdentity =
        heldRecord != null ||
        await _storage.read(key: '${existingPrefix}identity_key_pair') != null;
    // Parse EVERYTHING first: a damaged backup must fail before any write —
    // and before the held-identity decision below, which needs the pair.
    final IdentityKeyPair identityKeyPair;
    final int registrationId;
    try {
      final record = jsonDecode(payload.identity) as Map<String, dynamic>;
      identityKeyPair = IdentityKeyPair.fromSerialized(
        // Library caveat: curve calls mutate handed buffers — fresh copy.
        Uint8List.fromList(base64Decode(record['pair'] as String)),
      );
      registrationId = record['registrationId'] as int;
    } catch (_) {
      throw IdentityBackupCorrupt('identity_record');
    }
    if (holdsIdentity && !disposeStaleMaterial) {
      // A RETRY of this same restore is not a second identity: the (lxxviii)
      // machine adopts, then still has to fetch a nonce, upload and re-sign
      // the roster, and any of those can die on a flaky connection. Refusing
      // here would strand the install — it holds the identity but never
      // published its fresh prekeys — with no way to run the sequence again.
      // So a re-adopt of the IDENTICAL identity is idempotent, while a
      // DIFFERENT held identity is still refused: disposing that one needs
      // the (lxv)/(lxvii) authorization the caller passes explicitly.
      final heldPub = _identityRecordPublicKey(heldRecord);
      final backupPub = base64Encode(
        identityKeyPair.getPublicKey().serialize(),
      );
      if (heldPub == null || heldPub != backupPub) {
        throw StateError(
          'adoptRestoredIdentity: device already holds an identity',
        );
      }
    }
    String? dakPubBase64;
    final dakRecord = payload.dak;
    if (dakRecord != null) {
      try {
        final decoded = jsonDecode(dakRecord) as Map<String, dynamic>;
        if (decoded['userId'] != userId) throw StateError('dak user');
        dakPubBase64 = decoded['dakPub'] as String;
        base64Decode(dakPubBase64);
        base64Decode(decoded['dakPriv'] as String);
      } catch (_) {
        throw IdentityBackupCorrupt('dak_record');
      }
    }

    final residue =
        holdsIdentity || await _hasPriorInstallResidue(existingPrefix);
    if (residue) {
      if (holdsIdentity) {
        E2ePersistentDiag.record('RESTORE_STALE_MATERIAL_DISPOSED', {
          'userId': userId,
        });
      }
      if (!await _wipeSignalMaterial(existingPrefix)) {
        E2ePersistentDiag.record('RESTORE_RESIDUE_DISPOSAL_DEFERRED', {
          'userId': userId,
        });
        throw StateError(
          'adoptRestoredIdentity: residue disposal not proven',
        );
      }
    }

    _userId = userId;
    final p = 'e2e_${userId}_';
    _buildStores(p);

    await _identityStore.initialize(identityKeyPair, registrationId);
    // The teardown re-homes this install onto a freshly allocated device id;
    // the post-rebind connect re-stamps it.
    try {
      await _storage.delete(key: _materialDeviceKey(userId));
    } catch (_) {}

    if (dakRecord != null) {
      // Restored DAK, ARMED like DakStore.persistArmed: the list re-sign
      // after the rebind depends on this record surviving a round trip.
      final dakKey = 'dak_record_v1_$userId';
      await _storage.write(key: dakKey, value: dakRecord);
      if (await _storage.read(key: dakKey) != dakRecord) {
        throw StateError(
          'adoptRestoredIdentity: dak record failed read-back verification',
        );
      }
      await _storage.write(key: '${p}dak_pub_v1', value: dakPubBase64!);
    }

    final signedPreKey = generateSignedPreKey(identityKeyPair, 0);
    await _signedPreKeyStore.storeSignedPreKey(signedPreKey.id, signedPreKey);
    final preKeys = generatePreKeys(0, _initialPreKeyBatchSize);
    await Future.wait(preKeys.map((pk) => _preKeyStore.storePreKey(pk.id, pk)));
    await _storage.write(
      key: '${p}next_pre_key_id',
      value: _initialPreKeyBatchSize.toString(),
    );

    _keysForUpload = {
      'keyBundle': {
        'registrationId': registrationId,
        'identityPublicKey': base64Encode(
          identityKeyPair.getPublicKey().serialize(),
        ),
        'signedPreKeyId': signedPreKey.id,
        'signedPreKeyPublic': base64Encode(
          signedPreKey.getKeyPair().publicKey.serialize(),
        ),
        'signedPreKeySignature': base64Encode(signedPreKey.signature),
      },
      'oneTimePreKeys': preKeys.map(_preKeyToUploadFormat).toList(),
    };
    await _storage.write(key: '${p}setup_complete', value: 'true');

    needsKeyUpload = true;
    identityIncomplete = false;
    _initialized = true;
    E2ePersistentDiag.record('RESTORE_IDENTITY_ADOPTED', {'userId': userId});
    // (lxxvi) clause 3: raw keys just landed — wrap them NOW on a device
    // whose passcode wrapping is on, not at the next unlock.
    await PasscodeWrapHook.run();
  }

  /// The (lxxviii) clause-2 restore proof: XEdDSA by the CURRENT identity
  /// key over `identityPublicKey ‖ userId ‖ nonce` — byte-identical to the
  /// §6.1 `identitySignature` layout, with the "new" key being the unchanged
  /// one. Only the holder of `ikPriv` (restored from the backup) can produce
  /// it.
  Future<String> signRestoreProof(String nonceBase64) async {
    final uid = _userId;
    if (uid == null || !_initialized) {
      throw StateError('encryption service not initialized');
    }
    final pair = await _identityStore.getIdentityKeyPair();
    final message = Uint8List.fromList([
      ...pair.getPublicKey().serialize(),
      ...utf8.encode(uid.toString()),
      ...base64Decode(nonceBase64),
    ]);
    // Curve.calculateSignature mutates its input — already a fresh buffer.
    return base64Encode(
      Curve.calculateSignature(pair.getPrivateKey(), message),
    );
  }

  /// Get the public key data to upload to the server.
  Map<String, dynamic>? getKeysForUpload() => _keysForUpload;

  /// Generate identity key pair, signed pre-key, and one-time pre-keys.
  Future<void> _generateKeys() async {
    final uid = _userId; // always non-null when called from initialize()
    if (uid == null) return;
    final identityKeyPair = generateIdentityKeyPair();
    final registrationId = generateRegistrationId(false);

    await _identityStore.initialize(identityKeyPair, registrationId);

    // (lxiv): freshly minted material has no home yet — drop any stamp from a
    // previous life so the next server-confirmed device id re-stamps.
    try {
      await _storage.delete(key: _materialDeviceKey(uid));
    } catch (_) {}

    // Generate signed pre-key (id = 0)
    final signedPreKey = generateSignedPreKey(identityKeyPair, 0);
    await _signedPreKeyStore.storeSignedPreKey(signedPreKey.id, signedPreKey);

    // Generate one-time pre-keys (smaller batch for fast startup; preKeysLow replenishes)
    final preKeys = generatePreKeys(0, _initialPreKeyBatchSize);
    await Future.wait(preKeys.map((pk) => _preKeyStore.storePreKey(pk.id, pk)));

    // Save next pre-key id
    await _storage.write(
      key: 'e2e_${uid}_next_pre_key_id',
      value: _initialPreKeyBatchSize.toString(),
    );

    // Prepare public data for server upload
    _keysForUpload = {
      'keyBundle': {
        'registrationId': registrationId,
        'identityPublicKey': base64Encode(
          identityKeyPair.getPublicKey().serialize(),
        ),
        'signedPreKeyId': signedPreKey.id,
        'signedPreKeyPublic': base64Encode(
          signedPreKey.getKeyPair().publicKey.serialize(),
        ),
        'signedPreKeySignature': base64Encode(signedPreKey.signature),
      },
      'oneTimePreKeys': preKeys.map(_preKeyToUploadFormat).toList(),
    };

    await _storage.write(key: 'e2e_${uid}_setup_complete', value: 'true');
  }

  /// Check if we have an active session with the given user's [deviceId]
  /// (default 1 — the pre-multi-device address every legacy caller means).
  Future<bool> hasSession(int userId, {int deviceId = _deviceId}) async {
    final address = SignalProtocolAddress(userId.toString(), deviceId);
    return _sessionStore.containsSession(address);
  }

  /// Delete the session with the given user. Forces a fresh X3DH exchange
  /// on the next outgoing message (type-3 PreKeySignalMessage), which allows
  /// the remote peer to re-establish their session too.
  ///
  /// Serialized per peer (see [_sessionTails]) so a delete never lands in the
  /// middle of an in-flight encrypt/decrypt load→store window.
  Future<void> deleteSession(int userId, {int deviceId = _deviceId}) {
    return _runSessionSerialized(userId, deviceId, () async {
      final address = SignalProtocolAddress(userId.toString(), deviceId);
      await _sessionStore.deleteSession(address);
      debugPrint(
        '[EncryptionService] Session deleted for userId=$userId '
        'deviceId=$deviceId (broken session reset)',
      );
    });
  }

  /// TEMP storage-durability probe: peer ids with a persisted Signal session.
  /// Drives the SESSION_INVENTORY diag event (see [SecureSessionStore.inventoryPeerIds]).
  Future<List<String>> sessionInventoryPeerIds() async {
    if (!_initialized) return const [];
    return _sessionStore.inventoryPeerIds();
  }

  /// Build a session with the given user from their pre-key bundle.
  ///
  /// [preKeyBundle] must contain: registrationId, identityPublicKey,
  /// signedPreKeyId, signedPreKeyPublic, signedPreKeySignature.
  /// Optional: oneTimePreKeyId, oneTimePreKeyPublic (null when no unused OTPs).
  ///
  /// Serialized per peer (see [_sessionTails]): processPreKeyBundle archives
  /// the current ratchet state and stores a new record — racing it against an
  /// in-flight encrypt/decrypt store loses one side's advance.
  /// [expectedIdentityBase64] is the account's already-trusted identity key,
  /// or null when this account has never been contacted on ANY device. When
  /// present it MUST equal the bundle's key or the build is refused — see
  /// [_buildSessionSerialized].
  Future<void> buildSession(
    int userId,
    Map<String, dynamic> preKeyBundle, {
    int deviceId = _deviceId,
    required String? expectedIdentityBase64,
  }) {
    return _runSessionSerialized(
      userId,
      deviceId,
      () => _buildSessionSerialized(
        userId,
        deviceId,
        preKeyBundle,
        expectedIdentityBase64,
      ),
    );
  }

  Future<void> _buildSessionSerialized(
    int userId,
    int deviceId,
    Map<String, dynamic> preKeyBundle,
    String? expectedIdentityBase64,
  ) async {
    final address = SignalProtocolAddress(userId.toString(), deviceId);
    final builder = SessionBuilder(
      _cipherSessionStore,
      _preKeyStore,
      _signedPreKeyStore,
      _identityStore,
      address,
    );

    ECPublicKey? oneTimePreKey;
    if (preKeyBundle['oneTimePreKeyPublic'] != null) {
      oneTimePreKey = Curve.decodePoint(
        base64Decode(preKeyBundle['oneTimePreKeyPublic'] as String),
        0,
      );
    }

    final identityKey = IdentityKey.fromBytes(
      base64Decode(preKeyBundle['identityPublicKey'] as String),
      0,
    );

    // §3 SAYS EVERY DEVICE OF AN ACCOUNT SHARES ONE IDENTITY KEY. ENFORCE IT
    // (spec §12 amendment (xxxix)).
    //
    // Without this the store's TOFU is keyed per (peer, deviceId), so a peer's
    // newly linked device is a FRESH address: `existing == null`, no change to
    // detect, trusted in silence. The DAK-signed device list stops a server
    // inventing a device, but nothing stopped it serving a bundle carrying its
    // OWN identity key for a device the list legitimately names — a silent
    // MITM slot on every link, and precisely the capability §2 says a server
    // alone does not have.
    //
    // FAIL CLOSED. The alternative — build the session and warn — was
    // considered and rejected: a dismissible banner over a live MITM is worse
    // than a refusal, because the message is already encrypted to the attacker
    // by the time the user reads it. Refusing costs a peer device we cannot
    // verify; accepting costs the plaintext.
    //
    // A null anchor is genuine first contact with the ACCOUNT (not merely with
    // this device), which is irreducibly TOFU and stays trusting. The caller
    // resolves the anchor across the account's known devices, never from a
    // fixed device slot.
    final expected = expectedIdentityBase64;
    if (expected != null) {
      final offered = base64Encode(identityKey.serialize());
      if (offered != expected) {
        debugPrint(
          '[EncryptionService] REFUSED session userId=$userId '
          'deviceId=$deviceId reason=account_identity_mismatch',
        );
        // (lv) Refusing is right; refusing SILENTLY is what made this a
        // permanent outage. Stage the offered key and raise the identity
        // surface BEFORE throwing, so the banner exists and the out-of-band
        // comparison — the only door out — has a candidate to promote.
        await _recordAccountIdentityRefusal(userId, identityKey);
        throw AccountIdentityMismatch(userId: userId, deviceId: deviceId);
      }
    }

    // DO NOT pre-save the bundle's identity here. This code did that until
    // 2026-08-05, and it silently disabled the MITM warning on the ONE path
    // that matters:
    //   saveIdentity(bundle key) → processPreKeyBundle → isTrustedIdentity
    //   → getIdentity() returns the key we just wrote → _sameIdentity → true
    //   → early return → onIdentityChanged NEVER fires.
    // So a server serving its own (self-signed, therefore signature-valid)
    // bundle was accepted with no banner and no diagnostic — against this
    // store's own stated contract (signal_stores.dart: "a CHANGE is no longer
    // silent"). The pre-save was redundant twice over: our isTrustedIdentity is
    // TOFU and never throws UntrustedIdentityException (the exception the old
    // comment feared), and processPreKeyBundle itself persists the identity on
    // success (session_builder.dart: saveIdentity before storeSession).
    // Leave the store able to see the OLD key and decide.

    final bundle = PreKeyBundle(
      preKeyBundle['registrationId'] as int,
      deviceId,
      preKeyBundle['oneTimePreKeyId'] as int? ?? 0,
      oneTimePreKey,
      preKeyBundle['signedPreKeyId'] as int,
      Curve.decodePoint(
        base64Decode(preKeyBundle['signedPreKeyPublic'] as String),
        0,
      ),
      Uint8List.fromList(
        base64Decode(preKeyBundle['signedPreKeySignature'] as String),
      ),
      identityKey,
    );

    await builder.processPreKeyBundle(bundle);
    debugPrint(
      '[EncryptionService] Session built with userId=$userId deviceId=$deviceId',
    );
  }

  /// Tail of the in-flight session-mutation chain per (peer, device) address.
  /// Signal's Double Ratchet is stateful: EVERY operation that does
  /// load→mutate→store on an address's SessionRecord — encrypt, decrypt,
  /// buildSession, deleteSession — must run through [_runSessionSerialized].
  /// Two such operations interleaving at store await points lose one side's
  /// advance (lost update):
  ///  - encrypt vs encrypt: both load the same state and emit DUPLICATE
  ///    chain counters (the 2026-07-07 note-burst bug, 0.0.90);
  ///  - encrypt vs decrypt: a decrypt store landing after a concurrent
  ///    encrypt store rolls the SENDER chain back, so the next encrypt
  ///    reuses a counter the receiver already consumed →
  ///    DuplicateMessageException → permanent "[Decryption failed]" on a
  ///    brand-new message (the post-0.0.90 field reports). Reproduced
  ///    deterministically in encryption_encrypt_decrypt_race_probe_test.dart.
  ///
  /// Keyed by the COMPOSITE (peerId, deviceId), never peerId alone: two
  /// devices of one peer hold INDEPENDENT ratchets, and a shared tail would
  /// let a device-2 store clobber a device-1 store (T4, spec §5.4 — own
  /// devices are just another peer address to the ratchet layer).
  ///
  /// NOT a reentrant mutex: guarded methods must stay leaf-level and never
  /// await another guarded method for the same address, or they chain behind
  /// themselves and hang. Cross-operation sequencing (ensureSession →
  /// buildSession then encrypt) belongs at the provider layer as separate
  /// sequential acquisitions.
  final Map<(int, int), Future<void>> _sessionTails = {};

  /// Cross-context (Web Lock) name for one (peer, device) SessionRecord.
  ///
  /// Device 1 keeps the EXACT legacy name: during a rollout window an old
  /// PWA tab still locks `fireplace-e2e-session-<uid>-<peer>` for its
  /// device-1 mutations, and a renamed lock would let the two builds
  /// interleave on the same persisted record. Devices ≥ 2 get their own
  /// suffix so two devices of one peer never serialize against each other
  /// across tabs either.
  String _sessionLockName(int peerId, int deviceId) {
    final userId = _userId;
    if (userId == null) {
      throw StateError('EncryptionService is not initialized');
    }
    return deviceId == _deviceId
        ? 'fireplace-e2e-session-$userId-$peerId'
        : 'fireplace-e2e-session-$userId-$peerId-d$deviceId';
  }

  /// Queue [action] behind every in-flight mutation in this app engine, then
  /// take the origin-wide Web Lock for the same account/peer/device. The
  /// browser lock is load-bearing: separate PWA tabs have separate Dart heaps
  /// and therefore separate [_sessionTails], but they mutate the same
  /// persisted SessionRecord.
  Future<T> _runSessionSerialized<T>(
    int peerId,
    int deviceId,
    Future<T> Function() action,
  ) {
    final key = (peerId, deviceId);
    final tail = _sessionTails[key] ?? Future<void>.value();
    final result = tail.then(
      (_) =>
          _sessionCrossContextLock(_sessionLockName(peerId, deviceId), action),
    );
    _sessionTails[key] = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// In-flight encrypt count per (recipient, device) — the overlap probe. If
  /// this is ever >0 at enqueue, two sends WERE concurrent even if they did
  /// not feel "rapid" (a note send overlapping a resync decrypt, a
  /// typing-driven op, another message). Logged durably so the field report
  /// can confirm or rule out concurrency as the cause of a peer decrypt
  /// failure.
  final Map<(int, int), int> _encryptInFlight = {};

  /// Encrypt a plaintext string for the given recipient [deviceId] (default 1).
  /// Returns "{type}:{base64_body}" format.
  ///
  /// Serialized per (peer, device) with decrypt/buildSession/deleteSession
  /// (see [_sessionTails]): concurrent callers queue in call order.
  Future<String> encrypt(
    int recipientUserId,
    String plaintext, {
    int deviceId = _deviceId,
  }) {
    final key = (recipientUserId, deviceId);
    final inFlight = _encryptInFlight[key] ?? 0;
    if (inFlight > 0) {
      E2ePersistentDiag.record('ENCRYPT_OVERLAP', {
        'recipientId': recipientUserId,
        'deviceId': deviceId,
        'inFlight': inFlight,
      });
    }
    _encryptInFlight[key] = inFlight + 1;

    final result = _runSessionSerialized(
      recipientUserId,
      deviceId,
      () => _encryptSerialized(recipientUserId, deviceId, plaintext),
    );
    // Error-swallowed continuation as the decrement hook, so a failed encrypt
    // never leaks an unhandled async error (the owning caller still sees it
    // via `result`).
    result.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      final n = (_encryptInFlight[key] ?? 1) - 1;
      if (n <= 0) {
        _encryptInFlight.remove(key);
      } else {
        _encryptInFlight[key] = n;
      }
    });
    return result;
  }

  Future<String> _encryptSerialized(
    int recipientUserId,
    int deviceId,
    String plaintext,
  ) async {
    final address = SignalProtocolAddress(recipientUserId.toString(), deviceId);
    final cipher = SessionCipher(
      _cipherSessionStore,
      _preKeyStore,
      _signedPreKeyStore,
      _identityStore,
      address,
    );

    final ciphertext = await cipher.encrypt(
      Uint8List.fromList(utf8.encode(plaintext)),
    );

    return '${ciphertext.getType()}:${base64Encode(ciphertext.serialize())}';
  }

  /// Decrypt a ciphertext string from the given sender.
  /// Input format: "{type}:{base64_body}".
  ///
  /// Serialized per peer with encrypt/buildSession/deleteSession (see
  /// [_sessionTails]). The provider's per-sender decrypt chain orders the
  /// higher-level cache/persist side effects; THIS lock is the ratchet-record
  /// guard — without it a decrypt store can land over a concurrent encrypt
  /// store and roll the sender chain back.
  Future<String> decrypt(
    int senderUserId,
    String ciphertextStr, {
    int? messageId,
    int deviceId = _deviceId,
  }) {
    return _runSessionSerialized(senderUserId, deviceId, () async {
      if (messageId != null) {
        final replay = await _loadRawDecryptedContent(messageId, ciphertextStr);
        if (replay != null) {
          E2eDiagLog.add('DECRYPT_RAW_REPLAY', {
            'msgId': messageId,
            'senderId': senderUserId,
          });
          return replay;
        }
      }

      final plaintext = await _decryptSerialized(
        senderUserId,
        deviceId,
        ciphertextStr,
      );
      if (messageId != null) {
        await _saveRawDecryptedContent(messageId, ciphertextStr, plaintext);
      }
      return plaintext;
    });
  }

  Future<String> _decryptSerialized(
    int senderUserId,
    int deviceId,
    String ciphertextStr,
  ) async {
    final address = SignalProtocolAddress(senderUserId.toString(), deviceId);
    final cipher = SessionCipher(
      _cipherSessionStore,
      _preKeyStore,
      _signedPreKeyStore,
      _identityStore,
      address,
    );

    final colonIdx = ciphertextStr.indexOf(':');
    final type = int.parse(ciphertextStr.substring(0, colonIdx));
    final body = base64Decode(ciphertextStr.substring(colonIdx + 1));

    Uint8List plaintext;
    if (type == CiphertextMessage.prekeyType) {
      plaintext = await cipher.decrypt(PreKeySignalMessage(body));
    } else {
      plaintext = await cipher.decryptFromSignal(
        SignalMessage.fromSerialized(body),
      );
    }

    return utf8.decode(plaintext);
  }

  /// Generate more one-time pre-keys and return them for server upload.
  ///
  /// Serialized origin-wide. The whole body is a read-modify-write of
  /// `next_pre_key_id`, and same-origin PWA engines share that counter: two
  /// engines both handling `preKeysLow` could both read `next=20`, both mint
  /// ids 20..119 with DIFFERENT private halves, and both upload. The last
  /// local write wins, so the server ends up serving a public prekey whose
  /// private half this device overwrote — and the peer who draws it gets a
  /// bad-MAC session that no retry can fix.
  ///
  /// Its own lock name, never the per-peer session lock: this touches no
  /// SessionRecord, and reusing the session name would serialize prekey
  /// generation against unrelated conversations. Same shape as the existing
  /// raw-replay lock. Leaf-level, like every other guarded body — it must not
  /// call into a session-locked method.
  Future<List<Map<String, dynamic>>> generateMorePreKeys() {
    final uid = _userId;
    if (uid == null) return Future.value(const <Map<String, dynamic>>[]);
    return _sessionCrossContextLock(
      'fireplace-e2e-prekeys-$uid',
      () => _generateMorePreKeysLocked(uid),
    );
  }

  Future<List<Map<String, dynamic>>> _generateMorePreKeysLocked(int uid) async {
    final nextIdStr = await _storage.read(key: 'e2e_${uid}_next_pre_key_id');
    final storedNext = int.tryParse(nextIdStr ?? '');
    // If the counter was lost but pre-keys survive, derive the next id from the
    // highest stored key so we never reuse an id — reusing one overwrites a live
    // pre-key's private half while its public half is already on the server.
    int nextId;
    if (storedNext != null) {
      nextId = storedNext;
    } else {
      final highest = await _highestStoredPreKeyId();
      if (highest == null) {
        // Enumeration was INCONCLUSIVE (B2b design review R3): defaulting to
        // the fresh-install floor here is exactly the id-reuse hazard this
        // fallback exists to prevent. Skip replenishment this session; the
        // server threshold re-triggers it next time.
        E2ePersistentDiag.record('PREKEY_MINT_SKIPPED', {'userId': uid});
        return const [];
      }
      nextId = highest + 1;
    }

    final preKeys = generatePreKeys(nextId, _preKeyBatchSize);
    // Parallel writes (chunked to avoid overwhelming secure storage)
    const chunkSize = 25;
    for (var i = 0; i < preKeys.length; i += chunkSize) {
      final chunk = preKeys.skip(i).take(chunkSize).toList();
      await Future.wait(chunk.map((pk) => _preKeyStore.storePreKey(pk.id, pk)));
    }

    await _storage.write(
      key: 'e2e_${uid}_next_pre_key_id',
      value: (nextId + _preKeyBatchSize).toString(),
    );

    debugPrint(
      '[EncryptionService] Generated ${preKeys.length} more pre-keys (nextId=${nextId + _preKeyBatchSize})',
    );

    return preKeys.map(_preKeyToUploadFormat).toList();
  }

  /// Highest stored one-time pre-key id for the current user:
  /// [_initialPreKeyBatchSize] - 1 when a SUCCESSFUL enumeration finds none,
  /// or **null when the enumeration itself failed** — the caller must abort
  /// the mint, never substitute the fresh-install floor (B2b design review
  /// R3: that substitution reuses ids whose public halves the server already
  /// serves). Used only when the persisted next-id counter is missing.
  Future<int?> _highestStoredPreKeyId() async {
    final uid = _userId;
    if (uid == null) return null;
    final prefix = 'e2e_${uid}_pre_key_';
    var maxId = -1;
    try {
      final all = await _storage.readAll();
      for (final key in all.keys) {
        if (!key.startsWith(prefix)) continue;
        final id = int.tryParse(key.substring(prefix.length));
        if (id != null && id > maxId) maxId = id;
      }
    } catch (_) {
      return null;
    }
    return maxId < 0 ? _initialPreKeyBatchSize - 1 : maxId;
  }

  /// Get the identity key fingerprint (for display in Privacy & Safety).
  Future<String?> getIdentityFingerprint() async {
    if (!_initialized) return null;
    final keyPair = await _identityStore.getIdentityKeyPair();
    return _formatIdentityFingerprint(keyPair.getPublicKey());
  }

  /// Get the pinned trusted fingerprint for [peerId]'s ACCOUNT, if one exists.
  ///
  /// This is deliberately a read of the trusted identity store rather than a
  /// server-supplied bundle: the user must compare the key this device actually
  /// accepted after the warning, not a fresh network value.
  ///
  /// ACCOUNT-scoped, not `(peer, device 1)` (amendment (xlvii) clause 2, the
  /// same category error (xlvi) fixed everywhere else). The old address was
  /// wrong twice: [SignalIdentityStore.promotePendingAccountIdentity] only ever
  /// writes the account row, so the two diverged permanently after any
  /// acknowledged change, and a post-§6.2 peer has NO device 1 at all — ids are
  /// never reused — so the one out-of-band MITM check read an empty slot
  /// precisely for the accounts that had most recently survived a takeover.
  /// The legacy device-1 backfill inside [getAccountIdentity] keeps every
  /// single-device peer showing exactly what it showed before.
  Future<String?> getPeerIdentityFingerprint(int peerId) async {
    if (!_initialized) return null;
    try {
      final identity = await _identityStore.getAccountIdentity(
        peerId.toString(),
      );
      return identity == null ? null : _formatIdentityFingerprint(identity);
    } catch (_) {
      // Verification UI is advisory. Storage damage or an unavailable key must
      // leave it visibly unavailable, never turn the warning into an exception.
      return null;
    }
  }

  /// Both sides of the verify-security-keys ceremony for [peerId]: the key this
  /// device currently trusts, and the key an acknowledgement would pin.
  ///
  /// [servedIdentityBase64] is a freshly served account identity, used ONLY
  /// when no local candidate exists — the (xlvii) clause 3 shape, where the
  /// peer completed §6.2 and the accept gate refused their row before Signal
  /// could record anything to acknowledge. A stored candidate always wins over
  /// it, because a candidate came from a real inbound ciphertext.
  Future<PeerIdentityVerification> peerIdentityVerification(
    int peerId, {
    String? servedIdentityBase64,
  }) async {
    if (!_initialized) return const PeerIdentityVerification();
    try {
      final name = peerId.toString();
      final pinned = await _identityStore.getAccountIdentity(name);
      var offered = await _identityStore.pendingAccountIdentity(name);
      var offeredWasServed = false;
      if (offered == null &&
          servedIdentityBase64 != null &&
          servedIdentityBase64.isNotEmpty) {
        offered = IdentityKey.fromBytes(base64Decode(servedIdentityBase64), 0);
        offeredWasServed = true;
      }
      // An offer identical to the pin is not a CHANGE to confirm — but it must
      // still be offered, because clause 1 only clears a warning when the
      // anchor advances. Nulling it here left a standing alarm with no control
      // at all: an alarm the user cannot act on, which is the exact dead end
      // this amendment exists to remove. Re-affirming the key the user just
      // compared is a legitimate resolution, so the offer stays and only its
      // PRESENTATION changes.
      final offerMatchesPin =
          offered != null &&
          pinned != null &&
          base64Encode(offered.serialize()) == base64Encode(pinned.serialize());
      // RECORD a served offer as the pending candidate, so that every adoption
      // promotes a key this device wrote down (see [acknowledgePeerIdentity]).
      // This cannot clobber a genuine candidate: `offered` is taken from the
      // served key only when there was no candidate to begin with. Recording
      // grants no trust — the pending slot is read only by the display and by
      // the human-gated promotion.
      if (offeredWasServed && offered != null && !offerMatchesPin) {
        await _identityStore.stagePendingAccountIdentity(name, offered);
      }
      return PeerIdentityVerification(
        pinnedFingerprint: pinned == null
            ? null
            : _formatIdentityFingerprint(pinned),
        // Suppressed when it equals the pin: showing the same number twice
        // under "new" and "previous" labels reads as a mismatch.
        offeredFingerprint: offered == null || offerMatchesPin
            ? null
            : _formatIdentityFingerprint(offered),
        offeredIdentityBase64: offered == null
            ? null
            : base64Encode(offered.serialize()),
        offeredWasServed: offeredWasServed && offered != null,
        offerMatchesPin: offerMatchesPin,
      );
    } catch (_) {
      return const PeerIdentityVerification();
    }
  }

  /// The TOFU-pinned identity public key of [peerId]'s ACCOUNT (base64 of the
  /// serialized key), or null when none is stored or the read fails.
  ///
  /// This is what the T4 device-list cache verifies a peer's DAK enrollment
  /// against (I7 chain: their TOFU'd IK → E → DAK → list) — deliberately the
  /// STORED key, never a fresh network value, because the chain must anchor on
  /// the key this device actually accepted.
  ///
  /// ACCOUNT-scoped, not `(peer, device 1)` (spec §12 amendment (xlvi)). §3
  /// gives one identity key per account, so the device was never the right
  /// unit; the bug only surfaced once §6.2 started producing accounts with no
  /// device 1, whose freshly re-enrolled list then anchored on a revoked
  /// device's key — or on nothing — and could never verify.
  Future<String?> peerTofuIdentityBase64(int peerId) async {
    if (!_initialized) return null;
    try {
      final identity = await _identityStore.getAccountIdentity(
        peerId.toString(),
      );
      return identity == null ? null : base64Encode(identity.serialize());
    } catch (_) {
      // Fail closed at the caller: a null here means "cannot verify", and
      // the device-list cache refuses to trust anything without the anchor.
      return null;
    }
  }

  /// The account anchor for the (xxxix)/(lvi) SESSION GATE, where a failed read
  /// MUST NOT look like an absence ((lxii)).
  ///
  /// Deliberately a second contract rather than a flag on
  /// [peerTofuIdentityBase64], because the two callers need OPPOSITE polarities
  /// and a shared method cannot have both:
  ///  * The device-list chain wants null on failure — `DeviceListCache.adopt`
  ///    turns that into `no_tofu_identity` and refuses, so null is already
  ///    fail-closed there.
  ///  * This gate treats null as "genuine first contact with the ACCOUNT, which
  ///    is irreducibly TOFU" and stays TRUSTING, so null on failure is
  ///    fail-OPEN: one transient storage error would silently restore the
  ///    vacuous gate for that send and let a served substitute key through.
  ///
  /// So: a genuine absence still returns null; a read error THROWS, out of
  /// `ensureSession`, where (lix) restores the rebuild intent and the send fails
  /// visibly. Same polarity (lvii) just ruled for the persisted rollback pin,
  /// and the same answer `_hasPinnedAccountIdentity` already gives for the
  /// analogous question ("uncertainty answers YES on purpose").
  Future<String?> peerAccountAnchorForGate(int peerId) async {
    if (!_initialized) {
      throw StateError(
        'account anchor requested for $peerId before initialization',
      );
    }
    final identity = await _identityStore.getAccountIdentity(peerId.toString());
    return identity == null ? null : base64Encode(identity.serialize());
  }

  /// The identity key already trusted for [peerId] at [deviceId], or null if
  /// that address has never been contacted.
  ///
  /// Unlike [peerTofuIdentityBase64] this takes the device explicitly, because
  /// device 1 is NOT a safe default: ids are never reused and a post-§6.2
  /// account has no device 1 at all, so a fixed slot is empty exactly for the
  /// accounts that most recently survived a takeover.
  Future<String?> peerIdentityAt(int peerId, int deviceId) async {
    if (!_initialized) return null;
    try {
      final identity = await _identityStore.getIdentity(
        SignalProtocolAddress(peerId.toString(), deviceId),
      );
      return identity == null ? null : base64Encode(identity.serialize());
    } catch (_) {
      return null;
    }
  }

  /// Test-only: pin [identityBase64] as [peerId]'s TOFU identity, exactly as
  /// a first inbound bundle would. Lets device-list cache tests anchor the
  /// I7 chain without running a full X3DH session build.
  @visibleForTesting
  Future<void> debugSavePeerIdentity(int peerId, String identityBase64) async {
    await _identityStore.saveIdentity(
      SignalProtocolAddress(peerId.toString(), _deviceId),
      IdentityKey.fromBytes(base64Decode(identityBase64), 0),
    );
  }

  /// Formats every displayed Signal identity consistently: lowercase hex,
  /// grouped in fours so a human can compare it over another channel.
  String _formatIdentityFingerprint(IdentityKey identity) {
    final hex = identity
        .serialize()
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    final groups = <String>[];
    for (var i = 0; i < hex.length; i += 4) {
      final end = (i + 4 > hex.length) ? hex.length : i + 4;
      groups.add(hex.substring(i, end));
    }
    return groups.join(' ');
  }

  /// Current identity public key (base64) — the epoch tag sent with one-time
  /// pre-key uploads so the server binds each OTP to this identity and never
  /// serves a stale key from a superseded epoch. Null before init.
  Future<String?> currentIdentityPublicKeyBase64() async {
    if (!_initialized) return null;
    try {
      final keyPair = await _identityStore.getIdentityKeyPair();
      return base64Encode(keyPair.getPublicKey().serialize());
    } catch (_) {
      return null;
    }
  }

  /// Current locally minted registrationId — the (lxiv) install proof sent
  /// with one-time pre-key uploads so the server can tell this install from a
  /// foreign one sharing the account identity. Null before init.
  Future<int?> currentRegistrationId() async {
    if (!_initialized) return null;
    try {
      return await _identityStore.getLocalRegistrationId();
    } catch (_) {
      return null;
    }
  }

  String _materialDeviceKey(int userId) => 'e2e_${userId}_material_device_v1';

  /// (lxiv) clause 2 — which device id this install's Signal material was
  /// provisioned for. TOFU: absent → stamp [deviceId] and answer true; present
  /// → answer whether the stamp agrees. Every mint/adopt/rebind path CLEARS
  /// the stamp (an authorized re-homing of the material), so a contradiction
  /// can only mean material that survived a session-identity change it was
  /// never re-homed for — the revoked-device-signs-back-in shape, whose bundle
  /// re-upload would clobber the primary's published keys.
  Future<bool> confirmMaterialDeviceId(int deviceId) async {
    final userId = _userId;
    if (userId == null) return true;
    final key = _materialDeviceKey(userId);
    try {
      final existing = await _storage.read(key: key);
      final parsed = existing == null ? null : int.tryParse(existing);
      if (parsed == null) {
        await _storage.write(key: key, value: deviceId.toString());
        return true;
      }
      return parsed == deviceId;
    } catch (_) {
      // A storage failure is not evidence of a foreign install; fail open so
      // a flaky read cannot take a healthy device out of E2E duty. The server
      // guard ((lxiv) clause 1) still refuses a genuinely foreign write.
      return true;
    }
  }

  /// Clears the (lxiv) material-device stamp — called by every authorized
  /// re-homing of this install's material (the §6.2 rebind adoption; the mint
  /// paths clear inline). The next server-confirmed device id re-stamps.
  Future<void> clearMaterialDeviceStamp() async {
    final userId = _userId;
    if (userId == null) return;
    try {
      await _storage.delete(key: _materialDeviceKey(userId));
    } catch (_) {}
  }

  static Map<String, dynamic> _preKeyToUploadFormat(PreKeyRecord pk) => {
    'keyId': pk.id,
    'publicKey': base64Encode(pk.getKeyPair().publicKey.serialize()),
  };

  /// Build the public key bundle from stored keys for re-upload on reconnect.
  /// Returns null if keys are not loaded yet.
  Future<Map<String, dynamic>?> getKeyBundleForReupload() async {
    if (!_initialized) return null;
    try {
      final keyPair = await _identityStore.getIdentityKeyPair();
      final registrationId = await _identityStore.getLocalRegistrationId();
      final signedPreKey = await _signedPreKeyStore.loadSignedPreKey(0);
      return {
        'registrationId': registrationId,
        'identityPublicKey': base64Encode(keyPair.getPublicKey().serialize()),
        'signedPreKeyId': signedPreKey.id,
        'signedPreKeyPublic': base64Encode(
          signedPreKey.getKeyPair().publicKey.serialize(),
        ),
        'signedPreKeySignature': base64Encode(signedPreKey.signature),
      };
    } catch (e) {
      debugPrint('[EncryptionService] getKeyBundleForReupload failed: $e');
      return null;
    }
  }

  /// A Signal decrypt consumes a one-shot ratchet key before the provider can
  /// parse and persist the envelope. Keep a bounded raw replay under the
  /// message id while still holding the cross-context session lock. Exact
  /// ciphertext matching makes retention safe across edits and closes both the
  /// multi-engine duplicate and post-decrypt app-termination windows.
  Future<void> _saveRawDecryptedContent(
    int messageId,
    String ciphertext,
    String plaintext,
  ) async {
    final userId = _userId;
    if (userId == null) return;
    try {
      await _sessionCrossContextLock(
        'fireplace-e2e-raw-replay-$userId',
        () async {
          final prefs = await _sharedPrefs;
          await _reloadPrefsForCrossContext(prefs);
          final key = _rawDecryptedContentKey(userId, messageId);
          final payload = jsonEncode({
            'ciphertext': ciphertext,
            'plaintext': plaintext,
          });
          var ok = await prefs.setString(key, payload);
          if (!ok) ok = await prefs.setString(key, payload);
          if (!ok) {
            E2ePersistentDiag.record('DECRYPT_RAW_PERSIST_FAILED', {
              'msgId': messageId,
            });
            return;
          }
          await _pruneRawDecryptedContent(prefs, userId);
        },
      );
    } catch (_) {
      E2ePersistentDiag.record('DECRYPT_RAW_PERSIST_FAILED', {
        'msgId': messageId,
      });
    }
  }

  Future<String?> _loadRawDecryptedContent(
    int messageId,
    String ciphertext,
  ) async {
    final userId = _userId;
    if (userId == null) return null;
    try {
      final prefs = await _sharedPrefs;
      await _reloadPrefsForCrossContext(prefs);
      final raw = prefs.getString(_rawDecryptedContentKey(userId, messageId));
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['ciphertext'] != ciphertext) return null;
      return decoded['plaintext'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Reserved envelope keys stamped onto every persisted plaintext record.
  ///
  /// Stored in the CLEAR beside the payload, deliberately. Every sweep that
  /// has to SELECT records — purge one conversation, drop expired plaintext,
  /// age out old history — must do so without decrypting up to 2000 records,
  /// and with no conversation index there is nothing else to match on. What
  /// they reveal to someone already holding the device (which conversation,
  /// roughly when) is far less than the message text, which is the part that
  /// gets protected at rest.
  /// Spelled once, in [PlaintextRecordCodec]. These aliases exist so the sweeps
  /// below stay readable; a second literal copy here is exactly how the codec
  /// and the scans would drift apart and silently orphan records.
  static const String _metaConversationId =
      PlaintextRecordCodec.conversationIdKey;
  static const String _metaSavedAt = PlaintextRecordCodec.savedAtKey;
  static const String _metaCreatedAt = PlaintextRecordCodec.createdAtKey;
  static const String _metaExpiresAt = PlaintextRecordCodec.expiresAtKey;
  static const String _metaDisappearAfter =
      PlaintextRecordCodec.disappearAfterKey;

  /// Content values that are UI PLACEHOLDERS, never real message text.
  ///
  /// Mirrors the labels in `messaging_provider.dart` (and the placeholder set
  /// `MessageModel` filters on). Kept here because the guard in
  /// [saveDecryptedContent] is the last line of defence against a placeholder
  /// write destroying the only readable copy of a message, and that guard must
  /// not depend on the provider layer. `encryption_service_reload_race_test`
  /// pins these against `MessageModel` so the two cannot drift.
  @visibleForTesting
  static const Set<String> placeholderContents = <String>{
    '[encrypted]',
    '[Decryption failed]',
    '[Encryption not initialized]',
    '[Message no longer stored on this device]',
    // A row that predates this device's link (spec §12 amendment (viii)). It
    // must never overwrite real plaintext: a device that DID decrypt this
    // message keeps its copy even if a later payload arrives marked.
    '[Sent before this device was linked]',
  };

  /// Persist decrypted message content to survive app restart.
  ///
  /// Uses SharedPreferences (localStorage on web) instead of flutter_secure_storage
  /// (IndexedDB) because localStorage writes are synchronous in JS — they survive
  /// browser tab close, unlike in-flight IndexedDB transactions which are aborted.
  ///
  /// The `_`-prefixed envelope fields are what let later sweeps FIND this
  /// record. Without them a message is purgeable only while its row happens to
  /// be loaded: history pages in ~50 rows at a time while the store holds up
  /// to 2000 across sessions, so "clear chat history" on a freshly launched
  /// app would purge the visible page and strand the rest — no expiry, no
  /// conversation index, nothing left to name them by, ever.
  ///
  /// [createdAt] and [disappearAfterSeconds] are still stamped for UI expiry
  /// display and forward compatibility, but they no longer feed the sweep:
  /// a read-mode disappearing message is stored with `expiresAt: null` at
  /// DECRYPT time and receives its real deadline later — on `messageDelivered`
  /// or via the history-pass self-heal. Until a REAL stamp lands the record is
  /// NOT locally destroyable (see [_recordExpiryDeadlineMs]): the old
  /// never-read fallback destroyed five still-served records on 2026-08-02
  /// when the stamp event was lost. Unstamped residue is reconciliation's job.
  Future<void> saveDecryptedContent(
    int id,
    Map<String, dynamic> data, {
    int? conversationId,
    DateTime? createdAt,
    DateTime? expiresAt,
    int? disappearAfterSeconds,
  }) async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      final key = _decryptedContentKey(userId, id);
      Map<String, dynamic>? existing;
      // Authoritative: a cache miss here would let the narrower writes below
      // (above all the "[Decryption failed]" label) replace real plaintext.
      final existingRaw = _rawRecord(
        await _authoritativeSnapshot(),
        prefs,
        key,
      );
      if (existingRaw != null) {
        try {
          existing = jsonDecode(existingRaw) as Map<String, dynamic>;
        } catch (_) {}
      }

      // Never downgrade a keyed media entry to a keyless one. E2E media keys
      // (mediaKey/mediaIv) are persisted at first successful decrypt and are the
      // ONLY way to replay the message — re-decryption is impossible once the
      // Double Ratchet consumed the message key. A later keyless write (e.g. a
      // transient re-decrypt that throws DuplicateMessage and tries to store
      // "[Decryption failed]") must not destroy them.
      if (data['mediaKey'] == null && existing?['mediaKey'] != null) return;

      // Never let a PLACEHOLDER replace real plaintext. The failure path
      // persists "[Decryption failed]" so a terminal failure is not retried
      // forever, and it writes `content` alone. This record is the only copy —
      // the server's ciphertext can never be decrypted again once the ratchet
      // consumed its key — and hydration skips a record holding that label, so
      // the row is permanently unreadable afterwards. That turned ONE bad
      // decrypt (a transient failure, or a false cache miss on the read above)
      // into silent, irreversible loss of a message still sitting on disk.
      // Keeping the old plaintext costs at most a stale row; the alternative is
      // unrecoverable.
      final incomingContent = data['content'];
      final heldContent = existing?['content'];
      if (incomingContent is String &&
          placeholderContents.contains(incomingContent) &&
          heldContent is String &&
          heldContent.isNotEmpty &&
          !placeholderContents.contains(heldContent)) {
        return;
      }

      // Carry forward envelope metadata a later, narrower write does not supply
      // — the "[Decryption failed]" path writes `content` alone. Dropping
      // `_cid` here would make the record invisible to every conversation
      // purge from then on, which is the failure this metadata exists to stop.
      // `_savedAt` is preserved rather than refreshed so it means "age of the
      // record", not "last touched", and it is stamped from the LOCAL clock
      // because nothing destroys on it: the retention sweep compares it against
      // a CONFIRMED server clock and holds when there is none.
      final record = <String, dynamic>{
        ...data,
        if (conversationId != null)
          _metaConversationId: conversationId
        else if (existing?[_metaConversationId] != null)
          _metaConversationId: existing![_metaConversationId],
        _metaSavedAt:
            existing?[_metaSavedAt] ??
            DateTime.now().toUtc().millisecondsSinceEpoch,
        if (createdAt != null)
          _metaCreatedAt: createdAt.toUtc().millisecondsSinceEpoch
        else if (existing?[_metaCreatedAt] != null)
          _metaCreatedAt: existing![_metaCreatedAt],
        if (disappearAfterSeconds != null)
          _metaDisappearAfter: disappearAfterSeconds
        else if (existing?[_metaDisappearAfter] != null)
          _metaDisappearAfter: existing![_metaDisappearAfter],
        if (expiresAt != null)
          _metaExpiresAt: expiresAt.toUtc().millisecondsSinceEpoch
        else if (existing?[_metaExpiresAt] != null)
          _metaExpiresAt: existing![_metaExpiresAt],
      };
      final payload = jsonEncode(record);
      // A dropped write is how a decrypted message later re-decrypts, throws
      // DuplicateMessage (ratchet key consumed), and becomes a permanent
      // [Decryption failed] (the 2026-07-11 bob210 report — storage was
      // granted-persistent yet the plaintext was gone). setString returns
      // whether the backend commit succeeded (false on quota/exception); a
      // read-back would be vacuous because getString serves the plugin's
      // in-memory cache and matches even when the localStorage write dropped.
      // Retry once on failure, then surface a hard loss instead of swallowing it.
      var ok = false;
      try {
        ok = await prefs.setString(key, payload);
        if (!ok) ok = await prefs.setString(key, payload);
      } catch (_) {
        ok = false; // some backends throw (quota/exception) instead of false
      }
      if (!ok) {
        // Surface the hard loss even when the backend threw — otherwise the
        // outer catch swallows it and the message silently becomes a future
        // DuplicateMessage → permanent [Decryption failed].
        E2ePersistentDiag.record('DECRYPT_PERSIST_FAILED', {'msgId': id});
        return; // don't prune on a failed write
      }
      // Ledger AFTER the confirmed commit, never before: recording an id whose
      // plaintext did not land would refuse the one decrypt that still works.
      _noteDecrypted(id, data);
      await _pruneDecryptedContentCache(prefs, userId);
    } catch (_) {}
  }

  /// Retrieve persisted decrypted message content, or null if not found.
  /// On mobile, falls back to flutter_secure_storage for entries written by
  /// older versions ([_legacyDecryptedContentFallback]).
  Future<Map<String, dynamic>?> getDecryptedContent(int id) async {
    final userId = _userId;
    if (userId == null) return null;
    final key = _decryptedContentKey(userId, id);
    try {
      // Read the BACKING STORE, not the per-engine cache: a reload racing a
      // concurrent write drops the record from that cache while it survives
      // here, and a false miss re-decrypts a consumed ratchet key into a
      // permanent "[Decryption failed]".
      final prefs = await _sharedPrefs;
      final raw = _rawRecord(await _authoritativeSnapshot(), prefs, key);
      if (raw != null) return jsonDecode(raw) as Map<String, dynamic>;
      final oldRaw = await _legacyDecryptedContentFallback(key);
      if (oldRaw != null) return jsonDecode(oldRaw) as Map<String, dynamic>;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Tri-state existence probe for a stored record.
  ///
  /// `true` = on disk, `false` = DEFINITELY absent, `null` = could not
  /// determine. [getDecryptedContent] cannot answer this: it returns null for
  /// an unbound user, for any caught exception, AND for a real miss, so a
  /// transient storage failure is indistinguishable from loss. Anything that
  /// acts destructively on "the record is gone" must use this instead, and
  /// must treat `null` as "don't touch it".
  Future<bool?> recordExists(int id) async {
    final userId = _userId;
    if (userId == null) return null;
    final key = _decryptedContentKey(userId, id);
    try {
      final prefs = await _sharedPrefs;
      // Presence is decided on the RAW bytes, before any decode: a corrupt
      // record still means the plaintext was here, and reporting it absent
      // would retire a row whose bytes are sitting on disk.
      if (_rawRecord(await _authoritativeSnapshot(), prefs, key) != null) {
        return true;
      }
      if (await _legacyDecryptedContentFallback(key) != null) return true;
      return false;
    } catch (_) {
      return null;
    }
  }

  /// Legacy plaintext-cache fallback for entries written by older app versions.
  ///
  /// MOBILE ONLY, and provably so: [saveDecryptedContent] has only ever written
  /// through the raw [SharedPreferences] namespace, while [DualStorage.read]
  /// routes web reads to the `sig_`-prefixed async store. A
  /// `e2e_<uid>_decrypted_<id>` key therefore cannot exist there, so on web
  /// this lookup could only ever return null — at the cost of a full
  /// localStorage key enumeration per call (SharedPreferencesAsyncWeb filters
  /// its allowList only AFTER materialising every key). Rows with no persisted
  /// plaintext — terminal failures above all — miss on EVERY chat entry, so
  /// that was a recurring cost for a guaranteed null.
  Future<String?> _legacyDecryptedContentFallback(String key) async {
    if (kIsWeb) return null;
    return _storage.read(key: key);
  }

  /// Batched sibling of [getDecryptedContent]: resolves many message ids while
  /// paying the cross-engine coherence reload exactly ONCE.
  ///
  /// WHY THIS IS SAFE — read before "simplifying" it. The plaintext cache is
  /// itself a cross-engine coherence surface, NOT just a UI convenience: if
  /// another PWA engine persisted plaintext for a row and this engine's prefs
  /// snapshot is stale, we miss the cache, live-decrypt a ciphertext whose
  /// ratchet key the other engine already consumed, and land on
  /// DuplicateMessage -> "[Decryption failed]". That is exactly why
  /// [getDecryptedContent] reloads, and why deleting the reload is NOT the
  /// optimisation to make. Batching keeps the guarantee because:
  ///   * one reload at the head of the pass makes everything another engine
  ///     wrote BEFORE the pass visible to every row in it; and
  ///   * anything another engine writes DURING the pass is still caught by the
  ///     raw replay cache, which keeps its own reload
  ///     ([_loadRawDecryptedContent]) and is written before the peer-session
  ///     lock is released — bounded by [_rawDecryptedContentCacheLimit] (40)
  ///     records, i.e. the other engine would have to decrypt >40 messages
  ///     inside our pass to slip past both layers.
  /// A MISS IS NOT AN ANSWER. This reads the SharedPreferences namespace only,
  /// so callers must treat an absent id as "unknown" and fall through to
  /// [getDecryptedContent] (which also serves the mobile legacy store).
  /// Reading a miss as "no plaintext" would strand a row on "[encrypted]".
  /// Keeping the legacy store out of the batch is deliberate: on mobile that
  /// is a Keychain/Keystore hit per id, and a whole-pass prefetch would pay it
  /// for every row instead of only the rows that actually need it.
  Future<Map<int, Map<String, dynamic>>> getDecryptedContentMany(
    Iterable<int> ids,
  ) async {
    final userId = _userId;
    final result = <int, Map<String, dynamic>>{};
    if (userId == null) return result;
    final wanted = ids.toSet();
    if (wanted.isEmpty) return result;
    try {
      // ONE authoritative snapshot for the whole pass. This is the read the
      // history hydration depends on: every id it misses here is re-decrypted,
      // and for an already-decrypted message that means DuplicateMessage and a
      // permanent "[Decryption failed]".
      final prefs = await _sharedPrefs;
      final snapshot = await _authoritativeSnapshot();
      for (final id in wanted) {
        final raw = _rawRecord(
          snapshot,
          prefs,
          _decryptedContentKey(userId, id),
        );
        if (raw == null) continue;
        try {
          result[id] = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          // Corrupt record: leave the id absent so the caller falls through to
          // the authoritative single read.
        }
      }
    } catch (_) {
      return result;
    }
    return result;
  }

  /// Destroy EVERY persisted plaintext record for the signed-in account:
  /// message plaintext, the raw replay cache, and the pending-send records
  /// holding outgoing plaintext.
  ///
  /// IRREVERSIBLE, and far wider than [removeDecryptedContent] — this is the
  /// primitive behind the user-facing "delete all local history" action, so it
  /// destroys the only copy of every message this device still holds. Signal
  /// identity, sessions and pre-keys are NOT touched: wiping those would brick
  /// the account rather than clear it.
  ///
  /// Pending-send records go too. They exist for lost-ack reconciliation, but
  /// they hold outgoing plaintext, and a wipe that leaves the user's own
  /// messages readable is not a wipe. The cost of losing them is a send that
  /// was in flight during the wipe reconciling as "[encrypted]".
  Future<LocalHistoryWipeResult> clearDecryptedContentCache() async {
    final userId = _userId;
    if (userId == null) {
      return const LocalHistoryWipeResult(removed: 0, failedKeys: <String>{});
    }
    var removed = 0;
    final failed = <String>{};

    // Ids whose plaintext this wipe destroyed, so they can be marked retired
    // below. Collected as we go, because after the sweep the keys are gone and
    // nothing else names them.
    final wiped = <int>{};

    // Gate every removal on its commit result. `remove` returns false when the
    // backend refuses the write, and a wipe that reports success while the
    // plaintext is still on disk is the precise defect this action exists to
    // end. A whole-prefix failure is recorded as `<prefix>*` — the keys are
    // unknown because the enumeration itself threw.
    Future<void> sweepPrefs(String prefix, {bool collectIds = false}) async {
      try {
        final prefs = await _sharedPrefs;
        await _reloadPrefsForCrossContext(prefs);
        final keys = prefs
            .getKeys()
            .where((key) => key.startsWith(prefix))
            .toList();
        for (final key in keys) {
          var ok = await prefs.remove(key);
          if (!ok) ok = await prefs.remove(key);
          if (ok) {
            removed++;
            if (collectIds) {
              final id = int.tryParse(key.substring(prefix.length));
              if (id != null) wiped.add(id);
            }
          } else {
            failed.add(key);
          }
        }
      } catch (_) {
        failed.add('$prefix*');
      }
    }

    final prefix = _decryptedContentPrefix(userId);
    await sweepPrefs(prefix, collectIds: true);
    await sweepPrefs(_rawDecryptedContentPrefix(userId), collectIds: true);
    await sweepPrefs(_pendingSendPrefix(userId));

    // Retire what we destroyed, BEFORE reporting success.
    //
    // Without this the rows the user just wiped stay in the decrypt path: the
    // server still serves them, hydration finds no record, the re-decrypt hits
    // a ratchet key consumed at first decrypt, and every one of them renders a
    // permanent "[Decryption failed]" — the whole history at once, and
    // indistinguishable from the 2026-07-29 incident. Retention and LRU
    // eviction already do this for exactly the same reason; a user-initiated
    // wipe is the one destroyer that did not, so it turned a deliberate action
    // into what looks like catastrophic corruption.
    //
    // Bounded by `_retiredCap` (5000) against a record store capped at 2000, so
    // a full wipe fits with room to spare.
    if (wiped.isNotEmpty) {
      await markRetired(wiped);
      // Ledger hygiene: these ids are deliberately gone. The retired set
      // already renders them, but a surviving ledger entry would re-read as
      // UNEXPECTED loss if the retired write ever regressed. One lock, one write.
      await forgetDecryptedMany(wiped);
    }

    // Legacy store, swept on EVERY platform — deliberately not gated on
    // `!kIsWeb` the way the per-id path is. That gate rests on web never having
    // READ a `_decryptedContentKey` from this store, which proves the app
    // cannot surface such residue; it does not prove no build ever wrote it.
    // Residue the app cannot read is still plaintext on disk, and destroying
    // it is this action's entire promise. One enumeration on a one-shot,
    // user-initiated wipe is worth closing the unknown.
    try {
      final all = await _storage.readAll();
      for (final key in all.keys.where((key) => key.startsWith(prefix))) {
        try {
          await _storage.delete(key: key);
          removed++;
        } catch (_) {
          failed.add(key);
        }
      }
    } catch (_) {
      failed.add('${prefix}legacy*');
    }

    // A clean wipe leaves zero records. A dirty one leaves an unknown number,
    // so drop the estimate and let the next write re-seed it from a real scan
    // rather than carrying a figure that would evict live messages early.
    _cachedContentEstimate = failed.isEmpty ? 0 : null;
    if (failed.isNotEmpty) {
      E2ePersistentDiag.record('LOCAL_HISTORY_WIPE_INCOMPLETE', {
        'removed': removed,
        'failed': failed.length,
      });
    }
    return LocalHistoryWipeResult(
      removed: removed,
      failedKeys: failed,
      wipedIds: wiped,
    );
  }

  /// Permanently destroy the persisted plaintext for [ids].
  ///
  /// IRREVERSIBLE BY DESIGN — read this before calling it. The persisted
  /// record is the ONLY copy of the message: the server holds ciphertext whose
  /// Double Ratchet message key was consumed at first decrypt, so a purged
  /// message can never be recovered. Not from the server, not by re-decrypting
  /// — that lands on DuplicateMessage and a permanent "[Decryption failed]"
  /// (see [saveDecryptedContent]). Call this only when the message is provably
  /// gone for good: a server delete event, or an expiry gated on a
  /// server-confirmed clock. NEVER on the local clock alone — a device running
  /// fast would destroy messages that are still live server-side.
  ///
  /// Removes per id: the plaintext record, the raw replay record, and on
  /// mobile the legacy secure-store copy. Returns a [PlaintextPurgeResult] —
  /// callers MUST check [PlaintextPurgeResult.isComplete] before telling a
  /// user their messages are gone. A refused commit leaves plaintext on disk,
  /// and claiming a destruction that did not happen is the exact bug this
  /// whole change exists to remove.
  ///
  /// NOT a secure erase on its own, and deliberately does not pretend to be.
  /// localStorage is backed by LevelDB, whose write-ahead log keeps the old
  /// value until a compaction we do not control; overwriting a value before
  /// removing it only appends another record, so it is not attempted here.
  /// Unrecoverability comes from rotating the at-rest content key after a
  /// purge — residue is then ciphertext under a key that no longer exists.
  Future<PlaintextPurgeResult> removeDecryptedContent(Iterable<int> ids) async {
    final userId = _userId;
    final wanted = ids.toSet();
    if (wanted.isEmpty) return const PlaintextPurgeResult.empty();
    if (userId == null) {
      return PlaintextPurgeResult(removed: 0, failedIds: wanted);
    }

    var removed = 0;
    final failed = <int>{};
    final done = <int>{};
    try {
      final prefs = await _sharedPrefs;
      await _reloadPrefsForCrossContext(prefs);
      for (final id in wanted) {
        // `remove` returns false when the backend refuses the commit (quota,
        // or the dropped-write case documented in [saveDecryptedContent]);
        // removing an absent key returns true. So presence decides whether it
        // COUNTS as a removal, and the commit decides whether it SUCCEEDED —
        // conflating the two is how an operation reports success having done
        // nothing. Retry once, mirroring the write path.
        final key = _decryptedContentKey(userId, id);
        final present = prefs.containsKey(key);
        var ok = await prefs.remove(key);
        if (!ok) ok = await prefs.remove(key);
        if (!ok) {
          failed.add(id);
          continue;
        }
        if (present) removed++;
        if (!await prefs.remove(_rawDecryptedContentKey(userId, id))) {
          failed.add(id);
          continue;
        }
        done.add(id);
      }
    } catch (_) {
      // A throw says nothing about the ids not yet visited — their plaintext is
      // still on disk. Ids already confirmed committed stay counted.
      failed.addAll(wanted.difference(done));
    }

    // Legacy secure store, mobile only — web never wrote a
    // `_decryptedContentKey` there ([_legacyDecryptedContentFallback]), so the
    // scan is skipped rather than paying a full key enumeration for an empty
    // set. Deletion is unconditional: probing first would cost a Keychain read
    // per id purely to avoid a no-op delete.
    if (!kIsWeb) {
      for (final id in wanted) {
        try {
          await _storage.delete(key: _decryptedContentKey(userId, id));
        } catch (_) {
          failed.add(id);
        }
      }
    }

    // Keep the LRU estimate honest. Left high, it evicts early — which on this
    // cache means destroying the only copy of a live message.
    final estimate = _cachedContentEstimate;
    if (estimate != null && removed > 0) {
      _cachedContentEstimate = estimate > removed ? estimate - removed : 0;
    }
    if (failed.isNotEmpty) {
      E2ePersistentDiag.record('PLAINTEXT_PURGE_INCOMPLETE', {
        'requested': wanted.length,
        'removed': removed,
        'failed': failed.length,
      });
    }
    return PlaintextPurgeResult(removed: removed, failedIds: failed);
  }

  /// Update the stored expiry deadline for [messageId] without touching its
  /// payload.
  ///
  /// A read-mode disappearing message is persisted at DECRYPT time with no
  /// deadline — the server assigns one later, when the recipient reads, and
  /// pushes it on `messageDelivered`. Without this the record would carry only
  /// the never-read fallback and the sweep would hold that plaintext up to a
  /// day past the real deadline.
  ///
  /// No-op when nothing is persisted yet — but LOUDLY: the record that misses
  /// this stamp keeps no local deadline at all (see [_recordExpiryDeadlineMs]),
  /// so the miss is recorded in the diag ring and the history pass re-stamps
  /// from the served row (`EXPIRY_STAMP_MISS` / the self-heal in
  /// `messaging_provider.decrypt.dart`). A lost stamp therefore degrades to
  /// plaintext held until reconciliation — never to a wrong deletion.
  Future<void> stampRecordExpiry(int messageId, DateTime expiresAt) async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      final key = _decryptedContentKey(userId, messageId);
      // Authoritative: a false miss here silently drops the real deadline and
      // leaves the record with no local deadline at all.
      final raw = _rawRecord(await _authoritativeSnapshot(), prefs, key);
      if (raw == null) {
        // The record is not there yet (stamp raced the persist) or is gone.
        // Ring, not durable: routine and self-healing, but it must be visible
        // — this exact silence hid the 2026-08-02 destruction for a day.
        E2eDiagLog.add('EXPIRY_STAMP_MISS', {'msgId': messageId});
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final stampMs = expiresAt.toUtc().millisecondsSinceEpoch;
      // Idempotent: the history-pass self-heal calls this for every served
      // row that carries a deadline; rewriting an unchanged record every
      // pass would be 50 pointless commits per page.
      if (decoded[_metaExpiresAt] == stampMs) return;
      decoded[_metaExpiresAt] = stampMs;
      await prefs.setString(key, jsonEncode(decoded));
    } catch (_) {}
  }

  // ── Scan-based purges ────────────────────────────────────────────────────

  /// How long a plaintext record survives after it was first stored.
  ///
  /// This is a RETENTION POLICY, not a cache size: the record is the only copy
  /// of the message, so past this window it is gone from the device for good.
  static const Duration retentionWindow = Duration(days: 30);

  String _retentionEpochKey(int userId) => 'e2e_${userId}_retention_epoch_v1';

  /// Ids of every persisted plaintext record belonging to [conversationIds].
  ///
  /// Scans the whole prefix instead of working from loaded rows, because the
  /// store outlives memory: history pages in ~50 rows while up to 2000 records
  /// persist across sessions. Purging only what is loaded would strand the
  /// rest permanently — cleared and unfriended messages have no expiry, so no
  /// later sweep would ever revisit them.
  ///
  /// Returns ids rather than destroying them so the caller routes destruction
  /// through the durable purge backlog; a purge that bypassed it would have no
  /// retry when the store refuses a write.
  ///
  /// Records written before `_cid` existed carry no conversation and cannot be
  /// matched here; they age out via [destroyableMessageIds] instead.
  Future<Set<int>> messageIdsForConversations(
    Iterable<int> conversationIds,
  ) async {
    final targets = conversationIds.toSet();
    if (targets.isEmpty) return <int>{};
    return _messageIdsMatching(
      (id, record) => targets.contains(record[_metaConversationId]),
      // The user asked for this history to be gone: missing an id that is on
      // disk would leave it readable.
      authoritative: true,
    );
  }

  /// Ids whose plaintext is past its expiry deadline, split from those past
  /// [retentionWindow] — the two have different consequences downstream.
  ///
  /// [serverNow] MUST come from a CONFIRMED server clock. Callers do not call
  /// this at all when they have none: both rules destroy the only copy of a
  /// message, and a device whose clock is wrong by years would otherwise wipe
  /// its entire store on first launch. [expiryGrace] covers the server's own
  /// per-minute cleanup lag.
  ///
  /// `retired` is returned separately because retention is the ONE rule that
  /// destroys plaintext for a row the server still serves — see [markRetired].
  Future<({Set<int> expired, Set<int> retired})> destroyableMessageIds({
    required DateTime serverNow,
    required Duration expiryGrace,
  }) async {
    final userId = _userId;
    if (userId == null) return (expired: <int>{}, retired: <int>{});

    final nowMs = serverNow.toUtc().millisecondsSinceEpoch;
    final graceMs = expiryGrace.inMilliseconds;
    final retentionMs = retentionWindow.inMilliseconds;
    final epochMs = await _retentionEpoch(userId, nowMs);

    final expired = <int>{};
    final retired = <int>{};
    await _messageIdsMatching((id, record) {
      final deadline = _recordExpiryDeadlineMs(record);
      if (deadline != null && nowMs > deadline + graceMs) {
        expired.add(id);
        return false;
      }

      // Retention. A record with no stamp predates this build, so it ages from
      // the epoch: existing history fades over the coming window instead of
      // evaporating the moment the user upgrades.
      final savedAtRaw = record[_metaSavedAt];
      final savedAt = savedAtRaw is int ? savedAtRaw : epochMs;
      // A stamp in the FUTURE means the clock was wrong when it was written.
      // Treat that record as brand new rather than ancient.
      if (savedAt > nowMs) return false;
      if (nowMs - savedAt > retentionMs) {
        retired.add(id);
      }
      return false;
    }, authoritative: false);
    return (expired: expired, retired: retired);
  }

  /// Every message id whose plaintext this device has persisted.
  ///
  /// The union of both id-keyed stores: a record left in only one of them is
  /// still readable, so both must be visible to whoever decides what dies.
  ///
  /// Unlike [messageIdsForConversations] and [destroyableMessageIds] this
  /// reads no metadata at all, which is the entire point. Records written
  /// before the `_cid` / `_savedAt` stamps existed are invisible to both of
  /// those rules and would otherwise sit here until the LRU cap happened to
  /// evict them; they are exactly what server reconciliation is for.
  Future<Set<int>> storedMessageIds() async {
    final userId = _userId;
    if (userId == null) return <int>{};
    final prefixes = [
      _decryptedContentPrefix(userId),
      _rawDecryptedContentPrefix(userId),
    ];
    try {
      // DELIBERATELY the per-engine cache, not [_authoritativeSnapshot]. This is
      // the SOLE input to server reconciliation, which destroys the plaintext of
      // every id the server does not return — and expired rows ARE hard-deleted
      // server-side by a per-minute cron, so orphans genuinely exist. A
      // clobbered cache under-enumerates, which SUPPRESSES those purges; going
      // authoritative would enumerate the full set and destroy every orphan at
      // once on the first launch after this change. Over-retention is
      // recoverable, over-destruction is not, and none of this is needed to fix
      // the false-miss bug: only the record READS are.
      final prefs = await _sharedPrefs;
      await _reloadPrefsForCrossContext(prefs);
      final ids = <int>{};
      for (final key in prefs.getKeys()) {
        for (final prefix in prefixes) {
          if (!key.startsWith(prefix)) continue;
          final id = int.tryParse(key.substring(prefix.length));
          if (id != null) ids.add(id);
          break;
        }
      }
      return ids;
    } catch (_) {
      return <int>{};
    }
  }

  // ── Server reconciliation ────────────────────────────────────────────────

  String _reconcileStampKey(int userId) => 'e2e_${userId}_reconcile_last_v1';

  /// When the last COMPLETE reconciliation pass finished, in local-clock ms,
  /// or null if none ever has.
  ///
  /// The local clock is deliberate here, and it is the one place in this file
  /// where it is safe: this value only decides how OFTEN the device asks the
  /// server, never what gets destroyed. A wrong clock either re-asks too often
  /// (wasted round trips) or skips a pass (residue survives to the next one).
  /// Both directions are harmless because nothing dies unless the server
  /// itself named the survivors.
  Future<int?> lastReconcileAtMs() async {
    final userId = _userId;
    if (userId == null) return null;
    try {
      final prefs = await _sharedPrefs;
      await _reloadPrefsForCrossContext(prefs);
      return prefs.getInt(_reconcileStampKey(userId));
    } catch (_) {
      // Unreadable stamp reads as "never reconciled": re-asking costs a few
      // round trips, skipping would postpone the cleanup indefinitely.
      return null;
    }
  }

  /// Record that a pass completed at [atMs]. Only ever called when EVERY batch
  /// was answered — a partial pass must be retried, not throttled away.
  Future<void> markReconciledAt(int atMs) async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      await prefs.setInt(_reconcileStampKey(userId), atMs);
    } catch (_) {}
  }

  // ── Retired ids ──────────────────────────────────────────────────────────
  //
  // Ids whose plaintext this device destroyed while the server may STILL serve
  // the row. Retention is the only rule with that property: expiry and delete
  // both follow the server removing the row, but a message retired at 30 days
  // keeps coming back as an '[encrypted]' row forever. Without this set the
  // client would miss the cache, live-decrypt, hit DuplicateMessage (the
  // ratchet key was consumed at first decrypt) and render the permanent
  // '[Decryption failed]' label — indistinguishable from real data loss, and
  // enough of them to drown the persistent diag in false alarms.
  //
  // Checked BEFORE any decrypt attempt so a retired row shows a deliberate
  // state instead of an error.

  static const int _retiredCap = 5000;

  String _retiredKey(int userId) => 'e2e_${userId}_retired_v1';

  Future<Set<int>> retiredMessageIds() async {
    final userId = _userId;
    if (userId == null) return <int>{};
    try {
      final prefs = await _sharedPrefs;
      await _reloadPrefsForCrossContext(prefs);
      return _readRetired(prefs, userId);
    } catch (_) {
      return <int>{};
    }
  }

  /// Record that [ids] were retired by retention. Locked for the same reason
  /// the purge backlog is: one key, every same-origin PWA engine.
  Future<void> markRetired(Iterable<int> ids) async {
    final userId = _userId;
    if (userId == null) return;
    final incoming = ids.toSet();
    if (incoming.isEmpty) return;
    await _sessionCrossContextLock('fireplace-e2e-retired-$userId', () async {
      try {
        final prefs = await _sharedPrefs;
        await _reloadPrefsForCrossContext(prefs);
        final merged = <int>{..._readRetired(prefs, userId), ...incoming};
        // Bounded, keeping the HIGHEST ids: message ids ascend with age, so
        // the ones dropped are the oldest and least likely to be scrolled back
        // to. A dropped id degrades that row to '[Decryption failed]' instead
        // of the deliberate label — bounded degradation beats an unbounded key
        // competing with the Signal session records for quota.
        final sorted = merged.toList()..sort();
        final kept = sorted.length > _retiredCap
            ? sorted.sublist(sorted.length - _retiredCap)
            : sorted;
        await prefs.setString(_retiredKey(userId), jsonEncode(kept));
      } catch (_) {}
    });
  }

  Set<int> _readRetired(ContentKv prefs, int userId) {
    try {
      final raw = prefs.getString(_retiredKey(userId));
      if (raw == null) return <int>{};
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <int>{};
      return decoded.whereType<int>().toSet();
    } catch (_) {
      return <int>{};
    }
  }

  // ---------------------------------------------------------------------------
  // Terminal-duplicate observation counter
  // (docs/design/terminal-duplicate-retirement.md §3.3).
  //
  // Rows that fail `duplicate` with NO readable source and NO ledger entry
  // re-attempt a futile ratchet decrypt every boot, forever. The counter
  // records "observed terminal in N distinct process lifetimes"; the decrypt
  // path retires the row at [terminalDuplicateRetireSessions]. Everything here
  // fails toward the status quo: an unbound user, a refused write, a malformed
  // record, or a dropped cap entry all mean "count less" — slower to retire,
  // never faster.

  /// Distinct-process-lifetimes threshold before a terminal-duplicate row is
  /// retired (design §3.1).
  static const int terminalDuplicateRetireSessions = 3;

  static const int _dupTermCap = 64;

  /// Process-wide boot nonce (R1, design review): a process-lifetime static
  /// survives provider/service re-creation, so in-SPA logout→login and
  /// account switch re-inits share ONE nonce and an id increments at most
  /// once per process lifetime — "N sessions" means N distinct boots, not N
  /// re-inits. Mutable ONLY through [debugDupTermBootNonce]; production code
  /// never reassigns it.
  static String _dupTermBootNonce =
      '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(Object())}';

  /// Simulates a process restart in tests — the only writer besides the
  /// initializer.
  @visibleForTesting
  static set debugDupTermBootNonce(String value) => _dupTermBootNonce = value;

  String _dupTermKey(int userId) => 'e2e_${userId}_dupterm_v1';

  /// Record one terminal-duplicate observation for [id] and return the count
  /// AFTER this call, or null when nothing could be recorded (unbound user or
  /// storage failure — the caller must treat null as "no observation").
  ///
  /// Deliberately lockless: the key is last-write-wins across engines, so
  /// concurrent increments CLOBBER rather than sum — an under-count, the safe
  /// direction (design §3.3).
  Future<int?> noteTerminalDuplicate(int id) async {
    final userId = _userId;
    if (userId == null) return null;
    try {
      final prefs = await _sharedPrefs;
      await _reloadPrefsForCrossContext(prefs);
      final map = _readDupTerm(prefs, userId);
      final entry = map[id];
      if (entry != null && entry.bootNonce == _dupTermBootNonce) {
        // Already counted this boot — repeated chat entries in one process
        // lifetime are ONE observation.
        return entry.count;
      }
      final next = (entry?.count ?? 0) + 1;
      map[id] = (count: next, bootNonce: _dupTermBootNonce);
      if (!await _writeDupTerm(prefs, userId, map)) return null;
      return next;
    } catch (_) {
      return null;
    }
  }

  /// Delete [id]'s counter entry — a readable source EXISTS, so any prior
  /// observations were transient misses (design §3.3 reset). Undetermined
  /// answers must never reach here; the caller resets only on a DEFINITE true.
  Future<void> clearTerminalDuplicate(int id) async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      await _reloadPrefsForCrossContext(prefs);
      final map = _readDupTerm(prefs, userId);
      if (map.remove(id) == null) return;
      await _writeDupTerm(prefs, userId, map);
    } catch (_) {}
  }

  Map<int, ({int count, String bootNonce})> _readDupTerm(
    ContentKv prefs,
    int userId,
  ) {
    final out = <int, ({int count, String bootNonce})>{};
    try {
      final raw = prefs.getString(_dupTermKey(userId));
      if (raw == null) return out;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return out;
      for (final e in decoded.entries) {
        final id = int.tryParse(e.key);
        final v = e.value;
        if (id == null || v is! Map) continue;
        final n = v['n'];
        final b = v['b'];
        // A malformed entry is dropped, restarting its count from zero — the
        // safe direction.
        if (n is! int || n < 1 || b is! String) continue;
        out[id] = (count: n, bootNonce: b);
      }
      return out;
    } catch (_) {
      return <int, ({int count, String bootNonce})>{};
    }
  }

  Future<bool> _writeDupTerm(
    ContentKv prefs,
    int userId,
    Map<int, ({int count, String bootNonce})> map,
  ) {
    // Bounded, keeping the HIGHEST ids — same convention as [markRetired]:
    // ids ascend with age, and an evicted entry merely restores the status quo
    // (retry forever) for that row, never a phantom count.
    final ids = map.keys.toList()..sort();
    final kept = ids.length > _dupTermCap
        ? ids.sublist(ids.length - _dupTermCap)
        : ids;
    final encoded = <String, Object>{
      for (final id in kept)
        '$id': {'n': map[id]!.count, 'b': map[id]!.bootNonce},
    };
    return prefs.setString(_dupTermKey(userId), jsonEncode(encoded));
  }

  // ---------------------------------------------------------------------------
  // Decrypt ledger — "ids whose plaintext I have successfully persisted at
  // least once".
  //
  // [markRetired] answers "I destroyed this deliberately". The ledger answers
  // the question the app could not previously ask at all: a record is missing
  // NOW — did it ever exist? Without an answer, a record lost to quota,
  // eviction, corruption or a bug is indistinguishable from a message that was
  // never decrypted, so the app re-runs Signal decrypt on a ciphertext whose
  // ratchet key it already consumed, gets DuplicateMessage, and the row becomes
  // a permanent '[Decryption failed]'. That is precisely the 2026-07-29
  // incident's mechanism, and every storage-loss path can re-trigger it.
  //
  // Fail-safe in each direction that matters, which is why it is safe to let
  // this gate decryption at all:
  //  * recorded ONLY after a CONFIRMED commit of real plaintext, so a failed
  //    write can never mark a message "already decrypted" and lock it out of
  //    the one decrypt that would have worked;
  //  * a load failure, a miss, or an evicted entry degrades to the OLD
  //    behaviour (attempt the decrypt) — never to a false "unavailable";
  //  * an edit drops the entry through [forgetDecrypted], because an edited
  //    row carries NEW ciphertext that genuinely has not been decrypted.
  //
  // Cap tracks the record store, it is not an independent guess: the store
  // holds `_decryptedContentCacheLimit` (2000) and anything evicted past that
  // already went through [markRetired], so the ledger only covers ids whose
  // records
  // still exist and might yet be lost. A little headroom over that is enough.
  static const int _ledgerCap = 3000;

  /// Deliberately OUTSIDE `_decryptedContentPrefix`, matching the `retired_v1`
  /// convention. A key inside that namespace is swept by every record scan:
  /// the LRU prune sorts by `int.tryParse(suffix) ?? 0`,
  /// so the ledger would sort as id 0 and be the FIRST thing evicted once the
  /// store passes its cap — deleting itself on exactly the heavy accounts it
  /// exists to protect — and a full local wipe would take it too.
  String _ledgerKey(int userId) => 'e2e_${userId}_ledger_v1';

  /// Buffered so a 50-row history pass costs ONE read-modify-write of the id
  /// list instead of fifty. Per-row storage work on web is what turned the
  /// plaintext reload into 65-77 ms for a single page; do not make this eager.
  final Set<int> _pendingLedgerIds = <int>{};

  /// Flush when a pass is large enough that losing the buffer would matter,
  /// so a long history pass cannot sit on an unbounded unpersisted set.
  static const int _ledgerFlushThreshold = 32;

  void _noteDecrypted(int id, Map<String, dynamic> data) {
    // The terminal-failure label goes through this same persist path. Recording
    // it would tell a later pass "already decrypted" about a row that never
    // was, and permanently refuse the real decrypt.
    final content = data['content'];
    if (content is String && placeholderContents.contains(content)) return;
    _pendingLedgerIds.add(id);
    if (_pendingLedgerIds.length >= _ledgerFlushThreshold) {
      flushDecryptedLedger().ignore();
    }
  }

  /// Persist buffered ledger ids. Called at decrypt-pass boundaries and safe to
  /// call at any time. A failed commit leaves the ids buffered for the next
  /// attempt rather than dropping them on the floor.
  Future<void> flushDecryptedLedger() async {
    final userId = _userId;
    if (userId == null || _pendingLedgerIds.isEmpty) return;
    final batch = Set<int>.from(_pendingLedgerIds);
    await _sessionCrossContextLock('fireplace-e2e-ledger-$userId', () async {
      try {
        final prefs = await _sharedPrefs;
        await _reloadPrefsForCrossContext(prefs);
        final merged = <int>{..._readLedger(prefs, userId), ...batch};
        // Highest ids kept, same reasoning as markRetired: ids ascend with age,
        // so a dropped entry is the oldest and its row is the least likely to
        // still be served. Dropping one only restores the old behaviour.
        final sorted = merged.toList()..sort();
        final kept = sorted.length > _ledgerCap
            ? sorted.sublist(sorted.length - _ledgerCap)
            : sorted;
        if (await prefs.setString(_ledgerKey(userId), jsonEncode(kept))) {
          _pendingLedgerIds.removeAll(batch);
        }
      } catch (_) {}
    });
  }

  /// One-time backfill for accounts that predate the ledger.
  ///
  /// Without it the ledger only ever covers messages decrypted AFTER it ships,
  /// so every conversation a user already has stays exactly as fragile as
  /// before — which is most of the value, missing. Every id that has a stored
  /// plaintext record is BY DEFINITION an id whose plaintext was persisted, so
  /// the existing store already IS the ledger's history; it just was not
  /// written down.
  ///
  /// Seeds ONLY from `_decryptedContentPrefix`, never [storedMessageIds].
  /// That helper unions the raw `_decrypt_raw_v1_` cache too, and [recordExists]
  /// cannot see that prefix — so an id living only there would seed as
  /// "decrypted before", probe as definitely-absent, and be permanently
  /// retired, even though `_loadRawDecryptedContent` could still serve it. The
  /// seed must stay a SUBSET of what [recordExists] can confirm.
  ///
  /// Reads the per-engine cache, which can under-enumerate. Safe direction: a
  /// missing entry restores the OLD behaviour (attempt the decrypt), it never
  /// invents a false "unavailable".
  Future<void> backfillLedgerFromStore() async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      await _reloadPrefsForCrossContext(prefs);
      // Presence of the key is the "already seeded" marker, so this enumerates
      // once per account rather than on every launch.
      if (prefs.getString(_ledgerKey(userId)) != null) return;
      final prefix = _decryptedContentPrefix(userId);
      final seed = <int>[];
      // Enumerate the SAME source [recordExists] trusts. `getKeys()` serves the
      // plugin's in-memory cache, which still lists a key whose commit was
      // refused (quota) — seeding one of those would hand the gate an id it can
      // only ever probe as definitely-absent, and it would be retired
      // permanently. Fall back to the cache only where no authoritative read
      // exists, which is also where writes cannot be silently dropped.
      final snapshot = await _authoritativeSnapshot();
      final keys = snapshot?.keys ?? prefs.getKeys();
      for (final key in keys) {
        if (!key.startsWith(prefix)) continue;
        final id = int.tryParse(key.substring(prefix.length));
        if (id != null) seed.add(id);
      }
      seed.sort();
      final kept = seed.length > _ledgerCap
          ? seed.sublist(seed.length - _ledgerCap)
          : seed;
      // An EMPTY seed writes no marker, so the backfill is retried next launch.
      //
      // This runs exactly once per account, and it is the only run that ever
      // matters. If the authoritative snapshot came back empty or partial on
      // that single attempt — a transient storage hiccup — writing the marker
      // anyway would persist an empty ledger and disable the feature for that
      // account permanently, with no retry, no diagnostic, and no way to
      // notice: the brick this exists to prevent would stay armed while the
      // docs claim it is covered. An empty store costs a trivial re-scan
      // instead, and the first real decrypt writes the key anyway (which then
      // serves as the marker).
      if (kept.isEmpty) return;
      await prefs.setString(_ledgerKey(userId), jsonEncode(kept));
    } catch (_) {}
  }

  Future<Set<int>> decryptedLedgerIds() async {
    final userId = _userId;
    if (userId == null) return <int>{};
    try {
      final prefs = await _sharedPrefs;
      await _reloadPrefsForCrossContext(prefs);
      return <int>{..._readLedger(prefs, userId), ..._pendingLedgerIds};
    } catch (_) {
      return <int>{..._pendingLedgerIds};
    }
  }

  /// Drop [id] because its ciphertext changed — an edit replaces the payload
  /// under the same message id, so the new one has never been decrypted and
  /// MUST be allowed through. Without this an edited message would render
  /// "no longer stored" forever.
  Future<void> forgetDecrypted(int id) async {
    final userId = _userId;
    if (userId == null) return;
    await _sessionCrossContextLock('fireplace-e2e-ledger-$userId', () async {
      try {
        final prefs = await _sharedPrefs;
        await _reloadPrefsForCrossContext(prefs);
        // Inside the lock: a pre-lock removal races a flush that snapshotted
        // its batch earlier and writes the id straight back in.
        _pendingLedgerIds.remove(id);
        // This is the ONE ledger operation whose failure is destructive — a
        // surviving entry for replaced ciphertext hides the edit or retires it.
        // So: read authoritatively (getString serves the clobberable cache, the
        // exact 2026-07-29 mechanism), and write UNCONDITIONALLY. The old
        // `if (!current.remove(id)) return;` skipped the write whenever the read
        // came back short, which is precisely when the entry survives.
        final current = await _readLedgerAuthoritative(prefs, userId);
        current.remove(id);
        final sorted = current.toList()..sort();
        await prefs.setString(_ledgerKey(userId), jsonEncode(sorted));
      } catch (_) {}
    });
  }

  /// Drop every id in [ids] from the ledger, one lock and one write.
  ///
  /// For DELIBERATE destruction (expiry sweep, delete purges, the full wipe):
  /// a purged record whose ledger entry survives makes the next served copy of
  /// that row read as UNEXPECTED loss — `LEDGER_RECORD_LOST` plus a permanent
  /// retire — turning an ordered deletion into a false alarm (the 2026-08-02
  /// dump carried exactly this ambiguity). Same authoritative-read /
  /// unconditional-write discipline as [forgetDecrypted].
  Future<void> forgetDecryptedMany(Iterable<int> ids) async {
    final userId = _userId;
    final drop = ids.toSet();
    if (userId == null || drop.isEmpty) return;
    await _sessionCrossContextLock('fireplace-e2e-ledger-$userId', () async {
      try {
        final prefs = await _sharedPrefs;
        await _reloadPrefsForCrossContext(prefs);
        _pendingLedgerIds.removeAll(drop);
        final current = await _readLedgerAuthoritative(prefs, userId);
        current.removeAll(drop);
        final sorted = current.toList()..sort();
        await prefs.setString(_ledgerKey(userId), jsonEncode(sorted));
      } catch (_) {}
    });
  }

  /// Ledger read that does not trust the per-engine cache. Used wherever a
  /// short read would cause destruction rather than merely lose protection.
  Future<Set<int>> _readLedgerAuthoritative(ContentKv prefs, int userId) async {
    try {
      final raw = _rawRecord(
        await _authoritativeSnapshot(),
        prefs,
        _ledgerKey(userId),
      );
      if (raw == null) return <int>{};
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <int>{};
      return decoded.whereType<int>().toSet();
    } catch (_) {
      return <int>{};
    }
  }

  /// True when the raw replay cache still holds plaintext for [id].
  ///
  /// [decrypt] consults that cache BEFORE the ratchet and returns its plaintext
  /// with zero ratchet work, so a row it covers is fully readable even when the
  /// `_decrypted_` record is gone. Anything about to act destructively on "the
  /// plaintext is lost" must ask this too, or it destroys readable data.
  /// `null` = could not determine.
  Future<bool?> rawReplayExists(int id) async {
    final userId = _userId;
    if (userId == null) return null;
    try {
      final prefs = await _sharedPrefs;
      final raw = _rawRecord(
        await _authoritativeSnapshot(),
        prefs,
        _rawDecryptedContentKey(userId, id),
      );
      return raw != null;
    } catch (_) {
      return null;
    }
  }

  Set<int> _readLedger(ContentKv prefs, int userId) {
    try {
      final raw = prefs.getString(_ledgerKey(userId));
      if (raw == null) return <int>{};
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <int>{};
      return decoded.whereType<int>().toSet();
    } catch (_) {
      return <int>{};
    }
  }

  /// Deadline that may AUTHORIZE DESTRUCTION for this record — nothing else.
  ///
  /// Only a REAL server-assigned stamp (`_metaExpiresAt`, written at save from
  /// the row or upgraded by [stampRecordExpiry]) qualifies. The never-read
  /// fallback (`createdAt + kNeverReadRetentionSeconds`) is deliberately NOT
  /// computed here anymore: a record exists only because this device decrypted
  /// the message, which on this client happens in the active conversation —
  /// i.e. the message WAS read and the server's real deadline is
  /// `readAt + disappearAfterSeconds`, up to a full unread-window LATER than
  /// the fallback. The stamp travels on a single unacked socket event and can
  /// be lost (race with the persist, missed socket window), and on 2026-08-02
  /// the fallback destroyed five records the server was still serving —
  /// `LEDGER_RECORD_LOST` ×5, the ledger's first real catch. An unstamped
  /// record now simply does not expire locally; residue is cleaned by server
  /// reconciliation once the row is hard-deleted (≤ reconcile interval late).
  /// Over-retention is recoverable, over-destruction is not.
  int? _recordExpiryDeadlineMs(Map<String, dynamic> record) {
    final expiresAt = record[_metaExpiresAt];
    if (expiresAt is int) return expiresAt;
    return null;
  }

  /// First moment this account ran a build that stamps `_savedAt`, in ms.
  ///
  /// One key rather than back-stamping every legacy record: a bulk rewrite of
  /// up to 2000 entries, each the only copy of a message, is exactly the
  /// operation that must not half-fail (see the dropped-write case in
  /// [saveDecryptedContent]). Same ageing behaviour, none of the exposure.
  Future<int> _retentionEpoch(int userId, int nowMs) async {
    try {
      final prefs = await _sharedPrefs;
      final key = _retentionEpochKey(userId);
      final existing = prefs.getInt(key);
      if (existing != null) return existing;
      await prefs.setInt(key, nowMs);
      return nowMs;
    } catch (_) {
      return nowMs;
    }
  }

  /// Message ids whose persisted record satisfies [test].
  ///
  /// [test] receives the id alongside the record so a caller can bucket ids by
  /// rule in one pass instead of scanning the store once per rule.
  ///
  /// [authoritative] picks WHICH VIEW is scanned, and the two callers want
  /// opposite directions — do not collapse them:
  ///  * true for a user-requested deletion ([messageIdsForConversations]). The
  ///    user asked for this plaintext to be gone, so missing an id that is on
  ///    disk leaves readable history behind. Under-enumerating is the failure.
  ///  * false for automatic destruction ([destroyableMessageIds]). Nobody asked
  ///    for it, the record is the only copy, and a reload-clobbered cache
  ///    under-enumerates, which SUPPRESSES destruction. Over-retention is
  ///    recoverable, over-destruction is not.
  Future<Set<int>> _messageIdsMatching(
    bool Function(int id, Map<String, dynamic> record) test, {
    required bool authoritative,
  }) async {
    final userId = _userId;
    if (userId == null) return <int>{};
    final prefix = _decryptedContentPrefix(userId);

    final Map<String, Object>? snapshot;
    final ContentKv prefs;
    final List<String> keys;
    try {
      prefs = await _sharedPrefs;
      snapshot = authoritative ? await _authoritativeSnapshot() : null;
      if (snapshot == null) await _reloadPrefsForCrossContext(prefs);
      keys = _recordKeys(snapshot, prefs, prefix).toList();
    } catch (_) {
      return <int>{};
    }

    final matched = <int>{};
    var skipped = 0;
    for (final key in keys) {
      final id = int.tryParse(key.substring(prefix.length));
      if (id == null) continue;
      // Same view the keys came from. Reading content off the cache while
      // enumerating from the store would drop a key that is on disk, and the
      // authoritative caller is the one that must not miss.
      final raw = _rawRecord(snapshot, prefs, key);
      if (raw == null) continue;

      Map<String, dynamic>? record;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) record = decoded;
      } catch (_) {
        // Unreadable record. A decode failure says nothing about what it
        // holds, so nothing is ever destroyed on that basis.
      }
      if (record == null && authoritative) {
        // Erasure completeness (design doc §3.1): a sealed-store envelope is
        // undecodable in a session that cannot unseal it (prefs fallback,
        // rollback, unsealable row, proven key loss), but its conversation id
        // is cleartext in the framing precisely so a USER-REQUESTED deletion
        // still selects it — destroying a row the user asked to destroy is
        // correct even when it cannot be read. Authoritative scans only: a
        // synthetic record has no `_savedAt`, and letting it default to the
        // retention epoch would re-arm epoch-based destruction of rows a
        // fallback session merely cannot read.
        final envelope = SealedWebEnvelope.tryParse(raw);
        if (envelope != null) {
          record = <String, dynamic>{
            if (envelope.cid != null) _metaConversationId: envelope.cid,
          };
        }
      }
      if (record == null) {
        skipped++;
        continue;
      }

      // Deliberately OUTSIDE any catch. A predicate that throws is a bug, and
      // swallowing it here would turn every sweep into a silent no-op that
      // looks exactly like "nothing to purge" — the one failure this feature
      // cannot afford to have quietly.
      if (test(id, record)) matched.add(id);
    }

    if (skipped > 0) {
      final payload = {'scanned': keys.length, 'skipped': skipped};
      // Durable-channel hygiene (design doc §3.5): on an authoritative scan a
      // skip means a user-requested erasure met a value even the envelope
      // parser could not classify — evidence, always durable. On automatic
      // scans a fallback session sweeping over sealed envelopes would emit
      // this once per sweep, and the cap-80 durable log must not let routine
      // noise evict destruction evidence: first occurrence durable, repeats
      // to the ring.
      if (authoritative || !_scanSkippedDiagRecorded) {
        if (!authoritative) _scanSkippedDiagRecorded = true;
        E2ePersistentDiag.record('PLAINTEXT_SCAN_SKIPPED', payload);
      } else {
        E2eDiagLog.add('PLAINTEXT_SCAN_SKIPPED', payload);
      }
    }
    return matched;
  }

  /// Destroy the pending-send record for [ciphertext], if any.
  ///
  /// The sender's own outgoing plaintext is keyed by ciphertext, not by message
  /// id, so an id-only purge leaves it on disk until its TTL expires. The
  /// deleted row carries the ciphertext, so the caller can close that gap.
  ///
  /// Returns whether the record is confirmed gone. Idempotent — removing an
  /// absent key succeeds. A false here means the OUTGOING plaintext is still
  /// readable, so it must reach the caller's result rather than being
  /// swallowed; that is the whole reason this is not `Future<void>`.
  Future<bool> removePendingSendRecord(String ciphertext) async {
    final userId = _userId;
    if (userId == null) return false;
    try {
      final prefs = await _sharedPrefs;
      final key = _pendingSendRecordKey(userId, ciphertext);
      var ok = await prefs.remove(key);
      if (!ok) ok = await prefs.remove(key);
      return ok;
    } catch (_) {
      return false;
    }
  }

  // ── Durable purge backlog ────────────────────────────────────────────────
  //
  // A delete purge is fire-and-forget from a synchronous socket handler: the
  // tab can close or the PWA reload mid-write, and a refused commit is
  // reported but not retried. Nothing would ever revisit that residue — the
  // message is gone from `_messages`, gone from the server, and invisible to
  // the expiry sweep, because a plain deleted message has no `expiresAt`. So
  // the obligation is written down BEFORE the purge runs and cleared only on a
  // confirmed-complete result, which makes purging at-least-once across
  // crashes instead of best-effort within one frame.

  static const int _purgeBacklogCap = 2000;

  String _purgeBacklogKey(int userId) => 'e2e_${userId}_purge_pending_v1';

  String _purgeBacklogLockName(int userId) =>
      'fireplace-e2e-purge-backlog-$userId';

  /// Record that [ids] and [ciphertexts] are owed a purge.
  ///
  /// Read-modify-write on ONE key shared by every same-origin PWA engine, so
  /// it runs under the cross-context lock for the same reason the pre-key
  /// counter does: without it, tab B holding a pre-write snapshot can call
  /// [resolvePurged] and write back a set missing tab A's entry. The
  /// obligation would vanish with both operations reporting success, and the
  /// residue this backlog exists to catch would never be revisited.
  /// Returns whether the obligation is durably recorded. A false answer means
  /// the purge is about to run with NO retry behind it — a refused write (the
  /// realistic localStorage case is quota exhaustion) cannot be remembered, so
  /// the most this can do is stop being silent about it. The caller
  /// distinguishes "purge failed and will be retried" from "purge failed and is
  /// now lost", which are very different things for a feature whose whole
  /// promise is that plaintext eventually dies.
  Future<bool> enqueuePurge(
    Iterable<int> ids,
    Iterable<String> ciphertexts,
  ) async {
    final userId = _userId;
    if (userId == null) return false;
    final newIds = ids.toSet();
    final newCiphertexts = ciphertexts.toSet();
    if (newIds.isEmpty && newCiphertexts.isEmpty) return true;
    var recorded = false;
    await _sessionCrossContextLock(_purgeBacklogLockName(userId), () async {
      try {
        final prefs = await _sharedPrefs;
        await _reloadPrefsForCrossContext(prefs);
        final backlog = _readPurgeBacklog(prefs, userId);
        // Insertion-ordered, so trimming from the front drops the entries that
        // have already been retried longest. Bounded because a persistently
        // failing store must not grow this to the localStorage quota and take
        // the Signal session records down with it.
        final mergedIds = <int>{...backlog.ids, ...newIds};
        final mergedCiphertexts = <String>{
          ...backlog.ciphertexts,
          ...newCiphertexts,
        };
        final keptIds = mergedIds.length > _purgeBacklogCap
            ? mergedIds.skip(mergedIds.length - _purgeBacklogCap).toSet()
            : mergedIds;
        final keptCiphertexts = mergedCiphertexts.length > _purgeBacklogCap
            ? mergedCiphertexts
                  .skip(mergedCiphertexts.length - _purgeBacklogCap)
                  .toSet()
            : mergedCiphertexts;
        if (keptIds.length != mergedIds.length ||
            keptCiphertexts.length != mergedCiphertexts.length) {
          E2ePersistentDiag.record('PURGE_BACKLOG_OVERFLOW', {
            'ids': mergedIds.length,
            'ciphertexts': mergedCiphertexts.length,
          });
        }
        recorded = await prefs.setString(
          _purgeBacklogKey(userId),
          jsonEncode({
            'ids': keptIds.toList(),
            'cts': keptCiphertexts.toList(),
          }),
        );
      } catch (_) {
        recorded = false;
      }
      if (!recorded) {
        E2ePersistentDiag.record('PURGE_BACKLOG_WRITE_FAILED', {
          'ids': newIds.length,
          'ciphertexts': newCiphertexts.length,
        });
      }
    });
    return recorded;
  }

  /// Everything still owed a purge. Drained at startup and after `socketReady`.
  Future<({Set<int> ids, Set<String> ciphertexts})> purgeBacklog() async {
    final userId = _userId;
    if (userId == null) return (ids: <int>{}, ciphertexts: <String>{});
    try {
      final prefs = await _sharedPrefs;
      await _reloadPrefsForCrossContext(prefs);
      return _readPurgeBacklog(prefs, userId);
    } catch (_) {
      return (ids: <int>{}, ciphertexts: <String>{});
    }
  }

  String _purgeAmnestyKey(int userId) => 'e2e_${userId}_purge_amnesty_v1';

  /// One-time upgrade amnesty: drop backlog obligations that only the OLD
  /// expiry rule could have created.
  ///
  /// Builds ≤ 0.1.3 let the never-read fallback condemn UNSTAMPED records, and
  /// `enqueuePurge` writes the obligation durably BEFORE the purge runs. An
  /// obligation whose disk removal was then refused survives the upgrade, and
  /// `drainPurgeBacklog` replays it with no re-validation — destroying a
  /// still-served record the fixed sweep now refuses to touch (review finding,
  /// 2026-08-03). Amnesty is exactly the ambiguous class: an id whose record
  /// STILL EXISTS and carries NO real stamp. A legitimate delete-flow
  /// obligation caught by this filter degrades to over-retention only:
  /// reconciliation purges it once the server confirms the row is gone, and
  /// the 30-day retention bound covers the rest. Ciphertext obligations are
  /// untouched — the expiry sweep never enqueued any. Runs once per account.
  Future<void> amnestyUnstampedPurgeObligations() async {
    final userId = _userId;
    if (userId == null) return;
    await _sessionCrossContextLock(_purgeBacklogLockName(userId), () async {
      try {
        final prefs = await _sharedPrefs;
        await _reloadPrefsForCrossContext(prefs);
        if (prefs.getString(_purgeAmnestyKey(userId)) != null) return;
        final backlog = _readPurgeBacklog(prefs, userId);
        final kept = <int>{};
        final snapshot = await _authoritativeSnapshot();
        for (final id in backlog.ids) {
          final raw = _rawRecord(
            snapshot,
            prefs,
            _decryptedContentKey(userId, id),
          );
          if (raw == null) {
            // Record already gone: replay is a harmless no-op that cleans
            // the backlog. Keep it.
            kept.add(id);
            continue;
          }
          try {
            final decoded = jsonDecode(raw);
            final stamped =
                decoded is Map<String, dynamic> &&
                decoded[_metaExpiresAt] is int;
            // A REAL stamp means the new sweep would (re-)condemn it anyway.
            if (stamped) kept.add(id);
          } catch (_) {
            // Unreadable record: refuse destruction, drop the obligation.
          }
        }
        final dropped = backlog.ids.length - kept.length;
        if (dropped > 0) {
          await prefs.setString(
            _purgeBacklogKey(userId),
            jsonEncode({
              'ids': kept.toList(),
              'cts': backlog.ciphertexts.toList(),
            }),
          );
          E2ePersistentDiag.record('PURGE_AMNESTY', {'dropped': dropped});
        }
        // Marker AFTER the rewrite: an interrupted amnesty retries next run.
        await prefs.setString(
          _purgeAmnestyKey(userId),
          DateTime.now().toUtc().toIso8601String(),
        );
      } catch (_) {}
    });
  }

  /// Drop [ids] and [ciphertexts] from the backlog after a CONFIRMED-complete
  /// purge. Never call this on a partial result: a surviving entry is the only
  /// thing that will bring the failure back for another attempt.
  Future<void> resolvePurged(
    Iterable<int> ids,
    Iterable<String> ciphertexts,
  ) async {
    final userId = _userId;
    if (userId == null) return;
    await _sessionCrossContextLock(_purgeBacklogLockName(userId), () async {
      try {
        final prefs = await _sharedPrefs;
        await _reloadPrefsForCrossContext(prefs);
        final backlog = _readPurgeBacklog(prefs, userId);
        final remainingIds = backlog.ids.difference(ids.toSet());
        final remainingCiphertexts = backlog.ciphertexts.difference(
          ciphertexts.toSet(),
        );
        if (remainingIds.isEmpty && remainingCiphertexts.isEmpty) {
          await prefs.remove(_purgeBacklogKey(userId));
          return;
        }
        await prefs.setString(
          _purgeBacklogKey(userId),
          jsonEncode({
            'ids': remainingIds.toList(),
            'cts': remainingCiphertexts.toList(),
          }),
        );
      } catch (_) {}
    });
  }

  ({Set<int> ids, Set<String> ciphertexts}) _readPurgeBacklog(
    ContentKv prefs,
    int userId,
  ) {
    try {
      final raw = prefs.getString(_purgeBacklogKey(userId));
      if (raw == null) return (ids: <int>{}, ciphertexts: <String>{});
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return (ids: <int>{}, ciphertexts: <String>{});
      return (
        ids: (decoded['ids'] as List?)?.whereType<int>().toSet() ?? <int>{},
        ciphertexts:
            (decoded['cts'] as List?)?.whereType<String>().toSet() ??
            <String>{},
      );
    } catch (_) {
      return (ids: <int>{}, ciphertexts: <String>{});
    }
  }

  // ── Pending-send reconcile store (lost `messageSent` ack) ────────────────
  //
  // A socket drop inside the ack window orphans the sender's plaintext under
  // a tempId: the server row later arrives as '[encrypted]' and a Signal
  // sender CANNOT decrypt its own ciphertext (it is encrypted to the
  // recipient's ratchet) — the 07-08 field case (msg 14667). At SEND_EMIT the
  // emitted ciphertext + plaintext payload are recorded here; the ack
  // consumes the entry; a history merge reconciles an own '[encrypted]' row
  // by EXACT ciphertext equality (unique by ratchet construction). NEVER
  // match heuristically — review rejected timestamp proximity because a
  // wrong match persists the WRONG plaintext under a real id, permanently.
  //
  // Lifecycle: consumed on ack/reconcile, TTL-pruned, capped; wiped by
  // clearAllKeys and clearDecryptedContentCache (plaintext at rest).
  // Deliberately NOT cleared on reconnect — the lost-ack case IS a reconnect.
  //
  // ONE SharedPreferences key PER ciphertext — deliberately NOT a shared JSON
  // map: concurrent burst sends doing read-modify-write on one blob is the
  // same lost-update shape as the _sessionTails bug. Per-key setString/remove
  // needs no serialization at all.

  static const int _pendingSendCap = 40;
  static const Duration _pendingSendTtl = Duration(hours: 72);

  String _pendingSendPrefix(int userId) => 'e2e_${userId}_pendsend_v1_';

  String _pendingSendRecordKey(int userId, String ciphertext) =>
      '${_pendingSendPrefix(userId)}$ciphertext';

  /// Record an emitted send (ciphertext → plaintext payload) for lost-ack
  /// reconciliation. Silent on failure (send must never be blocked by this).
  Future<void> savePendingSendRecord(
    String ciphertext,
    Map<String, dynamic> data,
  ) async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await _sharedPrefs;
      final now = DateTime.now().millisecondsSinceEpoch;
      await prefs.setString(
        _pendingSendRecordKey(userId, ciphertext),
        jsonEncode(<String, dynamic>{'at': now, 'data': data}),
      );
      await _prunePendingSendRecords(prefs, userId, now);
    } catch (_) {}
  }

  /// Read a pending-send record WITHOUT consuming it. The reconcile path
  /// peeks, persists under the real id, VERIFIES the persist by read-back
  /// (saveDecryptedContent swallows failures), and only then takes — so a
  /// failed persist leaves the record for the next history pass instead of
  /// destroying the only surviving plaintext copy.
  Future<Map<String, dynamic>?> peekPendingSendRecord(String ciphertext) async {
    final userId = _userId;
    if (userId == null) return null;
    try {
      final prefs = await _sharedPrefs;
      final raw = prefs.getString(_pendingSendRecordKey(userId, ciphertext));
      if (raw == null) return null;
      final entry = jsonDecode(raw);
      final data = entry is Map ? entry['data'] : null;
      return data is Map ? data.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// Consume the pending-send record whose ciphertext equals [ciphertext]
  /// EXACTLY, or null. Removing on read keeps normal acks self-cleaning and
  /// prevents a stale record from ever being applied twice.
  Future<Map<String, dynamic>?> takePendingSendRecord(String ciphertext) async {
    final userId = _userId;
    if (userId == null) return null;
    try {
      final prefs = await _sharedPrefs;
      final key = _pendingSendRecordKey(userId, ciphertext);
      final raw = prefs.getString(key);
      if (raw == null) return null;
      await prefs.remove(key);
      final entry = jsonDecode(raw);
      final data = entry is Map ? entry['data'] : null;
      return data is Map ? data.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// TTL + cap sweep. Concurrent sweeps may double-remove a key — harmless
  /// (remove is idempotent); an entry is never modified in place.
  Future<void> _prunePendingSendRecords(
    ContentKv prefs,
    int userId,
    int now,
  ) async {
    final prefix = _pendingSendPrefix(userId);
    final cutoff = now - _pendingSendTtl.inMilliseconds;
    final live = <MapEntry<String, int>>[];
    for (final key
        in prefs.getKeys().where((k) => k.startsWith(prefix)).toList()) {
      int? at;
      try {
        final entry = jsonDecode(prefs.getString(key) ?? '');
        final v = entry is Map ? entry['at'] : null;
        if (v is int) at = v;
      } catch (_) {}
      if (at == null || at < cutoff) {
        await prefs.remove(key);
      } else {
        live.add(MapEntry(key, at));
      }
    }
    if (live.length > _pendingSendCap) {
      live.sort((a, b) => a.value.compareTo(b.value));
      for (final e in live.take(live.length - _pendingSendCap)) {
        await prefs.remove(e.key);
      }
    }
  }

  /// Clear all E2E encryption keys for this user from storage.
  /// Uses selective deletion (not deleteAll) to avoid wiping non-E2E data.
  ///
  /// Deliberately does NOT clear the per-account in-RAM collections (peer
  /// warnings, key-change notes, refusals, rebuild intents, device-list pins):
  /// `initialize` drops them when the account CHANGES ((lxxxiv) rider) —
  /// nulling `_userId` here is what makes the next login take that branch.
  /// A new per-account collection belongs on that list, not here.
  Future<void> clearAllKeys() async {
    final userId = _userId;
    if (userId != null) {
      final prefix = 'e2e_${userId}_';
      // DualStorage.readAll() merges both storages
      final all = await _storage.readAll();
      final keysToDelete = all.keys.where((k) => k.startsWith(prefix)).toList();
      for (final key in keysToDelete) {
        await _storage.delete(key: key);
      }
      // SharedPreferences: clear decrypted content cache entries
      try {
        final prefs = await _sharedPrefs;
        await _reloadPrefsForCrossContext(prefs);
        final spKeysToDelete = prefs
            .getKeys()
            .where((k) => k.startsWith(prefix))
            .toList();
        for (final key in spKeysToDelete) {
          await prefs.remove(key);
        }
      } catch (_) {}
    }
    _initialized = false;
    needsKeyUpload = false;
    _keysForUpload = null;
    _userId = null;
    _prefs = null;
    _prefsOpening = null;
    _storage.clearPrefsCache();
    debugPrint('[EncryptionService] All encryption keys cleared');
  }

  /// Mid-session passcode re-lock: drop every piece of key material and
  /// plaintext this instance holds in RAM, WITHOUT touching storage.
  ///
  /// This is what makes a re-lock a real revocation rather than a UI barrier.
  /// [clearAllKeys] is the destructive sibling (logout/account deletion) and
  /// deliberately shares only the cache-dropping tail with this method.
  ///
  /// What it drops, and why each one matters:
  ///
  ///  * the open content store's keys AND its decrypted view — that view holds
  ///    the plaintext of every sealed row read this session;
  ///  * the web Signal store's keys, and both store memos, so the next open is
  ///    re-decided from scratch (locked ⇒ it refuses, rather than degrading to
  ///    a plaintext backend);
  ///  * the in-RAM Signal identity;
  ///  * `_initialized`, so `initialize` rebuilds the stores on the next
  ///    unlock instead of taking the reconnect shortcut.
  ///
  /// Called only where wrapping is on (web), because with wrapping off the
  /// same keys are readable again the moment the store re-opens, so a teardown
  /// would cost an E2E re-init and buy nothing.
  Future<void> revokeForPasscodeLock() async {
    final prefs = _prefs;
    if (prefs is SealedWebContentKv) prefs.revoke();
    _prefs = null;
    _prefsOpening = null;
    await revokePlatformContentKv();
    await _storage.revokeWebSession();
    if (_initialized) _identityStore.forgetInMemoryIdentity();
    _initialized = false;
    _keysForUpload = null;
    needsKeyUpload = false;
    // Deliberately NOT cleared: `_peersWithChangedIdentity` (an unacknowledged
    // identity warning must survive) and `_pendingLedgerIds` (dropping the
    // buffer would lose the record that a plaintext was persisted). Both hold
    // ids only — no key material, no message content.
    E2eDiagLog.add('E2E_REVOKE_FOR_LOCK', const {});
  }

  String _decryptedContentPrefix(int userId) => 'e2e_${userId}_decrypted_';

  String _decryptedContentKey(int userId, int messageId) =>
      '${_decryptedContentPrefix(userId)}$messageId';

  String _rawDecryptedContentPrefix(int userId) =>
      'e2e_${userId}_decrypt_raw_v1_';
  static const int _rawDecryptedContentCacheLimit = 40;

  String _rawDecryptedContentKey(int userId, int messageId) =>
      '${_rawDecryptedContentPrefix(userId)}$messageId';

  Future<void> _pruneRawDecryptedContent(ContentKv prefs, int userId) async {
    final prefix = _rawDecryptedContentPrefix(userId);
    final keys = prefs
        .getKeys()
        .where((key) => key.startsWith(prefix))
        .toList();
    if (keys.length <= _rawDecryptedContentCacheLimit) return;
    keys.sort((a, b) {
      final aId = int.tryParse(a.substring(prefix.length)) ?? 0;
      final bId = int.tryParse(b.substring(prefix.length)) ?? 0;
      return aId.compareTo(bId);
    });
    for (final key in keys.take(keys.length - _rawDecryptedContentCacheLimit)) {
      await prefs.remove(key);
    }
  }

  /// Live estimate of how many plaintext records this account has cached.
  ///
  /// Seeded by ONE key scan per service instance, then incremented per write.
  /// Deliberately not a "sweep every N writes" counter: that resets on every
  /// app start, so a user who opens one chat per launch would never reach the
  /// threshold and the cache would grow without bound. On web that ends at the
  /// localStorage quota — and the first casualty is not this cache, it is
  /// `WebSignalKvStore.write` failing to persist session and identity records.
  /// A size estimate keeps the bound across restarts.
  ///
  /// Over-counting (an overwrite counted as a new record) only makes a sweep
  /// happen slightly early; every sweep resets the estimate to the true count.
  int? _cachedContentEstimate;

  Future<void> _pruneDecryptedContentCache(ContentKv prefs, int userId) async {
    // NO reload here: the only caller (saveDecryptedContent) reloaded a few
    // lines earlier and has not awaited anything that could invalidate it.
    if (_decryptedContentCacheLimit <= 0) {
      await clearDecryptedContentCache();
      return;
    }

    final prefix = _decryptedContentPrefix(userId);
    // One scan per instance to establish the baseline. It must cover the SAME
    // key set the sweep below evicts from — on mobile that includes the legacy
    // secure store, and counting only prefs would let the real total sit over
    // the cap while the estimate says otherwise.
    var estimate =
        _cachedContentEstimate ??
        (await _cachedContentKeys(prefs, prefix)).length;
    _cachedContentEstimate = ++estimate;
    if (estimate <= _decryptedContentCacheLimit) return;

    // Over the cap: pay for the real scan, evict, and re-anchor the estimate.
    final keys = (await _cachedContentKeys(prefs, prefix)).toList();
    if (keys.length <= _decryptedContentCacheLimit) {
      _cachedContentEstimate = keys.length;
      return;
    }

    keys.sort((a, b) {
      final aId = int.tryParse(a.substring(prefix.length)) ?? 0;
      final bId = int.tryParse(b.substring(prefix.length)) ?? 0;
      return aId.compareTo(bId);
    });

    final overflow = keys.length - _decryptedContentCacheLimit;
    final evicted = <int>{};
    var stillPresent = 0;
    for (final key in keys.take(overflow)) {
      // Gate on the commit, like every other purge path here: a discarded
      // result lets the estimate be re-anchored as though the eviction landed.
      var ok = await prefs.remove(key);
      if (!ok) ok = await prefs.remove(key);
      try {
        await _storage.delete(key: key);
      } catch (_) {}
      if (ok) {
        // Both stores are filtered by the same prefix in _cachedContentKeys, so
        // this parse is valid for either; a non-numeric suffix yields null and
        // is skipped rather than polluting the capped, id-sorted retired set.
        final id = int.tryParse(key.substring(prefix.length));
        if (id != null) evicted.add(id);
      } else {
        stillPresent++;
      }
    }

    // Eviction has the SAME property retention does, and fires far more often:
    // the server row is still alive and `hiddenByUserIds` does not filter it,
    // so it re-serves as '[encrypted]', the re-decrypt hits DuplicateMessage
    // (that ratchet key was consumed long ago) and the row bricks to a
    // persisted '[Decryption failed]'. Recording the ids keeps those rows out
    // of the decrypt path so they render a deliberate state instead of what
    // looks exactly like data loss — the LRU cap has been quietly destroying
    // history for any account past the limit, and the eviction was silent.
    if (evicted.isNotEmpty) await markRetired(evicted);

    _cachedContentEstimate = keys.length - evicted.length;
    if (stillPresent > 0) {
      E2ePersistentDiag.record('PLAINTEXT_EVICTION_INCOMPLETE', {
        'attempted': overflow,
        'failed': stillPresent,
      });
    }
  }

  /// Every key holding a persisted plaintext record for [prefix], across both
  /// stores. The seeding count and the eviction sweep MUST use the same set,
  /// or the estimate can sit under the cap while the real total is over it.
  Future<Set<String>> _cachedContentKeys(ContentKv prefs, String prefix) async {
    return <String>{
      // DELIBERATELY the per-engine cache, not [_storeSnapshot]. Eviction here
      // destroys the only copy of a message and calls [markRetired], which is
      // permanent. A reload-clobbered cache UNDER-counts, which suppresses
      // eviction — the safe direction. Making this authoritative would let an
      // account sitting at the cap evict a batch of its oldest history on the
      // first launch after the change. Retention pressure is a separate problem
      // from record visibility; do not "fix" it here.
      ...prefs.getKeys().where((key) => key.startsWith(prefix)),
      // Legacy store, mobile only. On web DualStorage reads the `sig_`-prefixed
      // async namespace, which never held a `_decryptedContentKey`, so this
      // matched nothing while decoding EVERY value in localStorage
      // (SharedPreferencesAsyncWeb.getPreferences has no prefix filter) — on
      // every single saveDecryptedContent. Measured ~2.5 ms per persisted
      // message at the 2000-record cap, all of it for an empty set.
      if (!kIsWeb)
        ...(await _storage.readAll()).keys.where(
          (key) => key.startsWith(prefix),
        ),
    };
  }
}

/// Outcome of [EncryptionService.removeDecryptedContent].
///
/// Purging plaintext is irreversible, so a caller has to be able to tell
/// "nothing was there" apart from "the store refused the write". Only
/// [isComplete] licenses telling a user their messages are gone.
class PlaintextPurgeResult {
  const PlaintextPurgeResult({
    required this.removed,
    required this.failedIds,
    this.failedCiphertexts = const <String>{},
  });

  const PlaintextPurgeResult.empty()
    : removed = 0,
      failedIds = const <int>{},
      failedCiphertexts = const <String>{};

  /// Records confirmed present before the call and confirmed removed after it.
  final int removed;

  /// Ids whose plaintext may still be on disk: the backend refused the commit,
  /// or threw before the id was reached. Safe to retry — purging is idempotent.
  final Set<int> failedIds;

  /// Ciphertexts whose pending-send record — the SENDER's own outgoing
  /// plaintext — may still be on disk. Tracked separately from [failedIds]
  /// because that store is keyed by ciphertext and a caller retrying needs the
  /// key, not the id.
  final Set<String> failedCiphertexts;

  bool get isComplete => failedIds.isEmpty && failedCiphertexts.isEmpty;
}

/// Outcome of [EncryptionService.clearDecryptedContentCache].
///
/// Separate from [PlaintextPurgeResult] because a whole-store wipe cannot
/// always name what it failed on: when the key enumeration itself throws, the
/// failure is recorded as a prefix rather than a message id.
class LocalHistoryWipeResult {
  const LocalHistoryWipeResult({
    required this.removed,
    required this.failedKeys,
    this.wipedIds = const <int>{},
  });

  /// Records confirmed removed and confirmed committed.
  final int removed;

  /// Keys — or `<prefix>*` markers — whose plaintext may still be on disk.
  final Set<String> failedKeys;

  /// Message ids whose record this wipe destroyed AND retired. The provider
  /// mirrors these into its in-memory retired set: `markRetired` persists to
  /// disk only, and a same-session history pass reading the stale RAM set was
  /// how a deliberate wipe could masquerade as `LEDGER_RECORD_LOST`.
  final Set<int> wipedIds;

  /// Only this licenses telling the user their history is gone.
  bool get isComplete => failedKeys.isEmpty;
}

/// Both sides of the verify-security-keys ceremony (spec §12 amendment
/// (xlvii) clause 2).
///
/// The dialog used to display [pinnedFingerprint] while its confirm button
/// promoted a stored candidate nobody had seen, so the user compared one number
/// and adopted another. Adoption now pins exactly [offeredIdentityBase64] — the
/// key whose fingerprint was on screen.
class PeerIdentityVerification {
  const PeerIdentityVerification({
    this.pinnedFingerprint,
    this.offeredFingerprint,
    this.offeredIdentityBase64,
    this.offeredWasServed = false,
    this.offerMatchesPin = false,
  });

  /// Fingerprint of the account anchor this device already accepted, or null
  /// on genuine first contact with the account.
  final String? pinnedFingerprint;

  /// Fingerprint of the key an acknowledgement would pin, or null when there is
  /// nothing NEW to compare — either no offer at all, or an offer that already
  /// equals the pin (see [offerMatchesPin]). Never equal to
  /// [pinnedFingerprint]: rendering the same number under "new" and "previous"
  /// labels reads as a mismatch.
  final String? offeredFingerprint;

  /// Base64 of the offered key, passed straight back to
  /// [EncryptionService.acknowledgePeerIdentity] so what was verified is what
  /// gets pinned.
  final String? offeredIdentityBase64;

  /// The offer came from a FRESH server fetch rather than a stored candidate —
  /// the (xlvii) clause 3 shape, where the peer completed §6.2 and no inbound
  /// ciphertext ever got far enough to leave a candidate behind. Worth telling
  /// the user apart: nothing about this key has been corroborated by a message
  /// that actually decrypted, so the out-of-band comparison is the only check
  /// there is.
  final bool offeredWasServed;

  /// The offered key IS the pinned one, so nothing actually changed.
  ///
  /// Kept as an offer rather than discarded: clause 1 clears a warning only
  /// when the anchor advances, so discarding this left a standing alarm with no
  /// control to resolve it — an alarm the user cannot act on, which is the dead
  /// end this amendment exists to remove. Re-affirming the compared key is a
  /// legitimate resolution; the UI presents it as "unchanged", not as a change.
  final bool offerMatchesPin;

  /// Is there a key to adopt?
  bool get hasOffer =>
      offeredIdentityBase64 != null && offeredIdentityBase64!.isNotEmpty;
}
