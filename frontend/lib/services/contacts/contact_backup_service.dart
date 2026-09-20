import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../utils/e2e_persistent_diag.dart';
import '../api_exception.dart';
import '../api_service.dart';
import '../auth_token_store.dart';
import 'contact_backup.dart';
import 'contact_store.dart';

/// What this session can do with the server-held contact backup.
enum ContactBackupState {
  /// Nothing resolved yet — no session, or the login resolve is in flight.
  idle,

  /// The content key is in hand: restore has run and uploads are enabled.
  ready,

  /// A row exists that THIS session cannot open (the password did not derive
  /// any wrap's key, or another device re-minted the content key behind a
  /// phrase restore). Uploads are DISABLED: overwriting would replace a row
  /// someone can still open with one nobody can.
  locked,

  /// The server could not be asked. Uploads are disabled for now; the next
  /// login tries again.
  unreachable,
}

/// Owns the account's server-held contact backup (metadata-privacy PR2.4).
///
/// Lifecycle, in the order it actually happens:
///  1. A password door ([onSession] with a password) resolves the row: GET,
///     then either the CACHED content key matches the row's `ckId` — the
///     common path, no PBKDF2 at all — or one PBKDF2-600k derivation opens a
///     wrap. A 404 means this account has no row yet, so this client mints
///     the salt and the content key and the first store mutation uploads.
///  2. `ConnectionProvider.connect()` awaits [ready] within a budget and
///     calls [applyRestore] AFTER the store is open and BEFORE the socket, so
///     a wiped device shows its contacts before the first `friendsList`.
///  3. Every committed store mutation calls [scheduleUpload] through
///     `ContactStore.onChanged`. Change-driven, never timer-driven: a store
///     that failed to open or was never written to emits nothing, so it can
///     never overwrite a good row with an empty one.
///
/// Two refusals are load-bearing and neither is an error path:
///  * [ContactBackupState.locked] never writes. The local graph is not worth
///    more than a row other devices can still open.
///  * A 401 marks the upload dirty instead of dropping it; the next session
///    flushes it.
class ContactBackupService {
  ContactBackupService({
    required ApiService api,
    required AuthTokenStore tokens,
    ContactBackupCodec? codec,
    Duration uploadDebounce = const Duration(seconds: 5),
  }) : _api = api,
       _tokens = tokens,
       _codec = codec ?? ContactBackupCodec(),
       _uploadDebounce = uploadDebounce;

  final ApiService _api;
  final AuthTokenStore _tokens;
  final ContactBackupCodec _codec;
  final Duration _uploadDebounce;

  ContactStore? _store;
  int? _userId;
  String? _token;

  Uint8List? _ck;
  String? _ckId;
  String? _salt;
  int _rev = 0;
  List<ContactBackupWrap> _wraps = const [];

  /// The blob currently on the server, verbatim. Held so a WRAP-only change
  /// (a password change, a phrase enrolment, a prune) can be written without
  /// the store — those happen at doors where the store is not even open, and
  /// re-sealing there would publish an empty graph.
  String? _blob;

  /// The opened blob, held between the login resolve and [applyRestore] —
  /// the store is not open yet at resolve time.
  ContactBackupPayload? _pendingRestore;

  ContactBackupState _state = ContactBackupState.idle;
  Completer<void>? _resolving;
  Timer? _debounce;
  bool _dirty = false;
  bool _uploading = false;
  int _restoredCount = 0;

  ContactBackupState get state => _state;

  /// Records the last [applyRestore] wrote. Zero on every ordinary login.
  int get restoredCount => _restoredCount;

  /// Settles when the in-flight login resolve finishes. Already-complete when
  /// none is running, so a caller may always await it.
  Future<void> get ready => _resolving?.future ?? Future<void>.value();

  /// Wires the store whose mutations drive uploads. Idempotent.
  void attach(ContactStore store) {
    if (identical(_store, store)) return;
    _store?.onChanged = null;
    _store = store;
    store.onChanged = scheduleUpload;
  }

  /// A fresh access token for the same account (silent refresh, §6.2 rebind).
  void onToken(String token) {
    _token = token;
    if (_dirty) scheduleUpload();
  }

  /// Resolve the row for [userId].
  ///
  /// [password] is the account password in the ONLY moment it exists — the
  /// login/register/recover call. [phrase] is the recovery phrase when the
  /// caller came through the phrase door; it is tried after the password so
  /// a wiped device whose owner forgot the password still gets its graph.
  ///
  /// Never throws: every failure lands in [state].
  Future<void> onSession({
    required int userId,
    required String token,
    String? password,
    String? phrase,
  }) async {
    final previous = _resolving;
    if (previous != null && !previous.isCompleted) {
      await previous.future;
    }
    if (_userId != userId) {
      _resetSession();
      _userId = userId;
    }
    _token = token;
    final gate = Completer<void>();
    _resolving = gate;
    try {
      await _resolveRow(password: password, phrase: phrase);
    } on Object catch (e) {
      // The doc comment promises this never throws, and it has to be true:
      // every caller fires it unawaited from a credential door, so an escape
      // is an unhandled async error — which `flutter_test` turns into a
      // failed test and a release build turns into a silent zone error. A
      // refused primitive (webcrypto absent on a bare host, a Keystore
      // fault) is exactly that shape.
      _state = ContactBackupState.unreachable;
      E2ePersistentDiag.record('CONTACT_BACKUP_RESOLVE_FAILED', {
        'error': e.runtimeType.toString(),
      });
    } finally {
      if (!gate.isCompleted) gate.complete();
    }
  }

  /// Writes every restored contact the store does NOT already hold, and the
  /// account's own profile when the store has none. Upgrade-only by
  /// construction: a local record always wins, because it is newer than any
  /// blob by definition (the blob was written FROM a local record).
  ///
  /// Returns how many rows it wrote.
  Future<int> applyRestore() async {
    final payload = _pendingRestore;
    final store = _store;
    final userId = _userId;
    _restoredCount = 0;
    if (payload == null || store == null || userId == null) return 0;
    if (!store.isOpen || store.userId != userId) return 0;
    if (payload.userId != userId) {
      // A blob for another account cannot be this account's graph.
      _pendingRestore = null;
      E2ePersistentDiag.record('CONTACT_BACKUP_FOREIGN', const {});
      return 0;
    }
    _pendingRestore = null;

    final missing = [
      for (final record in payload.contacts)
        if (store.byUserId(record.userId) == null) record,
    ];
    if (missing.isNotEmpty) {
      final byId = {for (final r in missing) r.userId: r};
      await store.reconcile(
        byId.keys,
        // `current` is DISK truth read inside the lock, so a record that
        // landed between the check above and the lock still wins.
        (peerId, current) => current ?? byId[peerId],
      );
      await store.settled;
      _restoredCount = missing.length;
    }
    if (store.self == null && payload.self != null) {
      await store.setSelf(payload.self!);
    }
    if (_restoredCount > 0) {
      E2ePersistentDiag.record('CONTACT_BACKUP_RESTORED', {
        'count': _restoredCount,
      });
    }
    return _restoredCount;
  }

  /// Adds a wrap of the content key under [secret] WITHOUT re-sealing the
  /// blob, and uploads it immediately.
  ///
  /// Called before a password change, which is the only order that works:
  /// `setPassword` revokes every token, so a wrap uploaded afterwards would
  /// need a fresh session to carry it. Additive for a password (the old wrap
  /// keeps other devices working until each proves the new one at its next
  /// login); replacing for a phrase (only one phrase is ever live).
  Future<bool> addWrap({
    required ContactWrapKind kind,
    required String secret,
  }) async {
    final ck = _ck;
    final salt = _salt;
    if (ck == null || salt == null || _state != ContactBackupState.ready) {
      return false;
    }
    final ContactBackupWrap fresh;
    try {
      final key = await _codec.deriveWrapKey(
        kind: kind,
        secret: secret,
        salt: salt,
      );
      fresh = await _codec.wrap(kind: kind, wrapKey: key, ck: ck);
    } on ContactBackupCorrupt {
      return false;
    }
    // A phrase wrap REPLACES the previous one — only one phrase is ever
    // live. A password wrap is ADDITIVE, but two is the whole window: the
    // one other devices still hold, and the one this change introduces.
    final kept = <ContactBackupWrap>[
      for (final w in _wraps)
        if (!(w.kind == ContactWrapKind.phrase &&
            kind == ContactWrapKind.phrase))
          w,
    ];
    if (kind == ContactWrapKind.password) {
      while (kept.where((w) => w.kind == ContactWrapKind.password).length > 1) {
        kept.removeAt(
          kept.indexWhere((w) => w.kind == ContactWrapKind.password),
        );
      }
    }
    _wraps = [...kept, fresh];
    return _putWraps();
  }

  /// Debounced upload. Coalesces the burst of write-throughs a reconnect's
  /// four server lists produce into one PUT.
  void scheduleUpload() {
    if (_state != ContactBackupState.ready) {
      _dirty = true;
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(_uploadDebounce, () {
      unawaited(uploadNow());
    });
  }

  /// Writes the CURRENT wraps against the blob the server already holds.
  /// Used by every wrap-only change; never touches the graph.
  Future<bool> _putWraps() async {
    final blob = _blob;
    if (blob == null) {
      // Nothing uploaded yet (a freshly minted row). The staged wraps ride
      // along with the first real upload.
      _dirty = true;
      return false;
    }
    return _commit(() async => blob);
  }

  /// Seals the store's current view and writes it. Returns whether the server
  /// holds this view now.
  Future<bool> uploadNow() async {
    final store = _store;
    final userId = _userId;
    if (store == null || userId == null) return false;
    if (_state != ContactBackupState.ready) {
      _dirty = true;
      return false;
    }
    // A store that is not open for THIS account has no view to publish, and
    // publishing "nothing" would destroy the row a wiped device needs.
    if (!store.isOpen || store.userId != userId) return false;
    // The restore has not been applied yet, so the store is missing rows the
    // blob still holds. Uploading here would delete them server-side.
    if (_pendingRestore != null) {
      _dirty = true;
      return false;
    }
    return _commit(() async {
      await store.settled;
      return _codec.sealPayload(
        _ck!,
        ContactBackupPayload(
          userId: userId,
          self: store.self,
          contacts: store.all,
        ),
      );
    });
  }

  /// Logout: the content key dies with the session, by design. The next
  /// password login unwraps it again from the row.
  Future<void> clear() async {
    _debounce?.cancel();
    _store?.onChanged = null;
    _store = null;
    _resetSession();
    _userId = null;
    _token = null;
    await _tokens.clearContactBackupKey();
  }

  // ---------- internals ----------

  void _resetSession() {
    _debounce?.cancel();
    _debounce = null;
    _ck = null;
    _ckId = null;
    _salt = null;
    _rev = 0;
    _wraps = const [];
    _blob = null;
    _pendingRestore = null;
    _dirty = false;
    _restoredCount = 0;
    _state = ContactBackupState.idle;
  }

  /// GET the row and establish the content key, or decide why we cannot.
  Future<void> _resolveRow({String? password, String? phrase}) async {
    final userId = _userId;
    final token = _token;
    if (userId == null || token == null) return;

    final Map<String, dynamic>? raw;
    try {
      raw = await _api.fetchContactBackup(token);
    } on Object {
      _state = ContactBackupState.unreachable;
      E2ePersistentDiag.record('CONTACT_BACKUP_UNREACHABLE', const {});
      return;
    }

    if (raw == null) {
      // No row. Only a session that can also make a wrap may mint one — a
      // content key nobody can unwrap is worse than no backup at all.
      if (password == null) {
        _state = ContactBackupState.unreachable;
        return;
      }
      await _mint(password: password, phrase: phrase);
      return;
    }

    final ContactBackupRow row;
    try {
      row = ContactBackupRow.fromJson(raw);
    } on ContactBackupCorrupt catch (e) {
      _state = ContactBackupState.locked;
      E2ePersistentDiag.record('CONTACT_BACKUP_CORRUPT', {'reason': e.reason});
      return;
    }
    _rev = row.rev;
    _salt = row.salt;
    _ckId = row.ckId;
    _wraps = row.wraps;
    _blob = row.blob;

    // 1. The cached key, when it is the row's key. No derivation at all —
    //    this is what every ordinary login takes.
    final cached = await _tokens.readContactBackupKey(userId);
    if (cached != null && cached.ckId == row.ckId) {
      final bytes = _decodeKey(cached.ck);
      if (bytes != null) {
        await _adopt(bytes, row, persist: false);
        return;
      }
    }

    // 2. A secret we hold in this one moment.
    for (final attempt in [
      if (password != null) (ContactWrapKind.password, password),
      if (phrase != null) (ContactWrapKind.phrase, phrase),
    ]) {
      final ck = await _tryWraps(row, attempt.$1, attempt.$2);
      if (ck == null) continue;
      await _adopt(ck, row, persist: true);
      if (attempt.$1 == ContactWrapKind.phrase && password != null) {
        // The phrase door just changed the password, so the row's password
        // wrap is under the OLD one and nothing would open it next login.
        await addWrap(kind: ContactWrapKind.password, secret: password);
      } else if (attempt.$1 == ContactWrapKind.password) {
        await _pruneSupersededPasswordWraps(attempt.$2);
      }
      return;
    }

    _state = ContactBackupState.locked;
    E2ePersistentDiag.record('CONTACT_BACKUP_LOCKED', {
      'wraps': row.wraps.length,
      'hadSecret': (password != null || phrase != null).toString(),
    });
  }

  Future<Uint8List?> _tryWraps(
    ContactBackupRow row,
    ContactWrapKind kind,
    String secret,
  ) async {
    final candidates = [
      for (final w in row.wraps)
        if (w.kind == kind) w,
    ];
    if (candidates.isEmpty) return null;
    final Uint8List key;
    try {
      key = await _codec.deriveWrapKey(
        kind: kind,
        secret: secret,
        salt: row.salt,
      );
    } on ContactBackupCorrupt {
      return null;
    }
    for (final candidate in candidates) {
      final ck = await _codec.unwrap(candidate, key);
      if (ck != null) return ck;
    }
    return null;
  }

  /// Takes [ck] as this session's key, opens the blob, and goes ready.
  Future<void> _adopt(
    Uint8List ck,
    ContactBackupRow row, {
    required bool persist,
  }) async {
    _ck = ck;
    _ckId = row.ckId;
    if (persist) {
      await _tokens.writeContactBackupKey(
        userId: _userId!,
        ckId: row.ckId,
        ck: base64Url.encode(ck).replaceAll('=', ''),
      );
    }
    try {
      _pendingRestore = await _codec.openPayload(ck, row.blob);
    } on ContactBackupCorrupt catch (e) {
      // The wrap opened, so the key is right and the BLOB is damaged. The
      // local graph is then the only truth; go ready so the next mutation
      // replaces the blob rather than leaving a row nobody can use.
      _pendingRestore = null;
      E2ePersistentDiag.record('CONTACT_BACKUP_BLOB_UNREADABLE', {
        'reason': e.reason,
      });
    }
    _state = ContactBackupState.ready;
    if (_dirty) scheduleUpload();
  }

  Future<void> _mint({required String password, String? phrase}) async {
    final (ck, ckId) = ContactBackupCodec.mintContentKey();
    final salt = ContactBackupCodec.mintSalt();
    final wraps = <ContactBackupWrap>[];
    try {
      wraps.add(
        await _codec.wrap(
          kind: ContactWrapKind.password,
          wrapKey: await _codec.deriveWrapKey(
            kind: ContactWrapKind.password,
            secret: password,
            salt: salt,
          ),
          ck: ck,
        ),
      );
      if (phrase != null) {
        wraps.add(
          await _codec.wrap(
            kind: ContactWrapKind.phrase,
            wrapKey: await _codec.deriveWrapKey(
              kind: ContactWrapKind.phrase,
              secret: phrase,
              salt: salt,
            ),
            ck: ck,
          ),
        );
      }
    } on ContactBackupCorrupt {
      _state = ContactBackupState.unreachable;
      return;
    }
    _ck = ck;
    _ckId = ckId;
    _salt = salt;
    _wraps = wraps;
    _rev = 0;
    _blob = null;
    _pendingRestore = null;
    await _tokens.writeContactBackupKey(
      userId: _userId!,
      ckId: ckId,
      ck: base64Url.encode(ck).replaceAll('=', ''),
    );
    _state = ContactBackupState.ready;
    // Nothing is uploaded here: the store is not open yet, and the first
    // write-through after connect is what carries the real graph.
    _dirty = true;
  }

  /// A password login proves which password wrap is live; every other one is
  /// a superseded password that must stop opening the backup.
  Future<void> _pruneSupersededPasswordWraps(String password) async {
    final passwordWraps = _wraps
        .where((w) => w.kind == ContactWrapKind.password)
        .length;
    if (passwordWraps < 2) return;
    final ck = _ck;
    final salt = _salt;
    if (ck == null || salt == null) return;
    try {
      final key = await _codec.deriveWrapKey(
        kind: ContactWrapKind.password,
        secret: password,
        salt: salt,
      );
      final live = <ContactBackupWrap>[];
      for (final w in _wraps) {
        if (w.kind != ContactWrapKind.password) {
          live.add(w);
        } else if (await _codec.unwrap(w, key) != null) {
          live.add(w);
        }
      }
      if (live.length == _wraps.length) return;
      _wraps = live;
    } on ContactBackupCorrupt {
      return;
    }
    await _putWraps();
  }

  /// One PUT, with exactly one re-read-and-retry on a 409.
  ///
  /// The 409 is the server refusing a write against a rev it no longer holds
  /// — another device wrote. Re-reading is the whole recovery: if the row is
  /// still ours (same salt, same ckId) we write again on top of it; if it is
  /// not, we are [ContactBackupState.locked] and must leave it alone.
  ///
  /// [produce] is called per attempt so a retry publishes the store as it is
  /// NOW, not a snapshot the 409 already proved stale.
  Future<bool> _commit(Future<String> Function() produce) async {
    final token = _token;
    final ckId = _ckId;
    final salt = _salt;
    if (token == null || ckId == null || salt == null || _ck == null) {
      return false;
    }
    if (_uploading) {
      _dirty = true;
      return false;
    }
    _uploading = true;
    _debounce?.cancel();
    _debounce = null;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final String blob;
        try {
          blob = await produce();
        } on ContactBackupCorrupt {
          return false;
        }
        try {
          final answer = await _api.putContactBackup(
            token,
            baseRev: _rev,
            salt: salt,
            ckId: ckId,
            wraps: [for (final w in _wraps) w.toJson()],
            blob: blob,
          );
          final rev = answer['rev'];
          if (rev is int) _rev = rev;
          _blob = blob;
          _dirty = false;
          return true;
        } on ApiException catch (e) {
          // 401: the access token expired mid-flight. Never a dropped
          // mutation — the next token refresh flushes it.
          if (e.statusCode != 409 || attempt == 1) {
            _dirty = true;
            return false;
          }
        } on Object {
          _dirty = true;
          return false;
        }
        if (!await _rereadForRetry(token, ckId, salt)) return false;
      }
      return false;
    } finally {
      _uploading = false;
    }
  }

  /// Re-reads the row after a 409 and reports whether a retry is legitimate.
  Future<bool> _rereadForRetry(String token, String ckId, String salt) async {
    final Map<String, dynamic>? raw;
    try {
      raw = await _api.fetchContactBackup(token);
    } on Object {
      _dirty = true;
      return false;
    }
    if (raw == null) {
      // The row vanished (account reset elsewhere). Writing ours back under
      // baseRev 0 is a creation, which is exactly right.
      _rev = 0;
      return true;
    }
    final ContactBackupRow row;
    try {
      row = ContactBackupRow.fromJson(raw);
    } on ContactBackupCorrupt {
      _state = ContactBackupState.locked;
      _dirty = true;
      return false;
    }
    if (row.ckId != ckId || row.salt != salt) {
      // Another device re-minted behind a phrase restore. Our key cannot open
      // the row and our password is long gone, so this session stops writing.
      _state = ContactBackupState.locked;
      _dirty = true;
      E2ePersistentDiag.record('CONTACT_BACKUP_REKEYED', const {});
      return false;
    }
    _rev = row.rev;
    _wraps = row.wraps;
    return true;
  }

  static Uint8List? _decodeKey(String encoded) {
    try {
      final padded = encoded.padRight((encoded.length + 3) & ~3, '=');
      final bytes = base64Url.decode(padded);
      return bytes.length == 32 ? bytes : null;
    } on Object {
      return null;
    }
  }
}
