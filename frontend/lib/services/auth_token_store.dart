import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/e2e_persistent_diag.dart';
import 'secure_kv.dart';

/// Where the JWT + refresh token live at rest.
///
/// Web AND non-Android hosts (desktop dev, the flutter_test VM): plain
/// SharedPreferences, exactly the historical behavior — on web,
/// flutter_secure_storage's backing loses data when tabs close, which is
/// disqualifying for the token that keeps a session alive; and the only
/// shipped native platform is the Android APK.
///
/// Native: flutter_secure_storage. The refresh token is a long-lived bearer
/// credential; in the plaintext prefs XML it was readable at rest by anyone
/// with the device image (issue #105 inventory item 7). A one-time migration
/// moves tokens out of prefs, gated the same way every migration here is:
/// copy, VERIFY by fresh read-back, and only then delete the prefs copy — a
/// failed secure write must leave the working tokens where they were, because
/// "logged out on next launch" is a real cost and prefs is merely the status
/// quo, not a regression.
///
/// Failure honesty (0.1.11, handoff §5.4): a broken store used to read as
/// "no tokens" — the error-as-absence inversion that manufactures a permanent
/// logout out of a transient storage hiccup (the app then DELETED the intact
/// token it believed absent). [read] now retries briefly and, if storage still
/// answers with errors, reports `readFailed: true` — a state the caller MUST
/// treat as "do not decide", never as logged-out. Failed writes are recorded
/// durably so a "logged out next boot" finally has a paper trail.
class AuthTokenStore {
  AuthTokenStore({SecureKv? secure, bool? useSecureStorage})
    : _secure = secure ?? const FlutterSecureStorageKv(FlutterSecureStorage()),
      _useSecure = useSecureStorage ?? (!kIsWeb && Platform.isAndroid);

  final SecureKv _secure;

  /// Same platform rule as the content-store opener: secure storage on real
  /// Android only. Overridable so tests can drive the native path with a
  /// fake [SecureKv] on any host.
  final bool _useSecure;

  static const String _accessKey = 'jwt_token';
  static const String _refreshKey = 'refresh_token';

  /// The PR2.4 contact-backup content key, stored BESIDE the session and
  /// never in the `e2e_<uid>_` namespace.
  ///
  /// Why here: CK's lifetime is the session's. A device holding CK keeps
  /// uploading through a password change made on another device (only the
  /// WRAP moves), and losing CK costs nothing — the next password login
  /// unwraps it again from the server row. Eviction therefore takes the
  /// session and CK together, which is exactly the coupling we want.
  ///
  /// Deliberately NOT part of [_migrateFromPrefs]'s trigger: that branch
  /// fires on "no tokens in secure storage", and a missing CK must never be
  /// read as a missing session.
  ///
  /// Value is `<userId>.<ckId>.<base64url(ck)>` — the account is pinned so a
  /// login that skipped a logout cannot inherit the previous account's key,
  /// and `ckId` lets the caller tell "I hold the row's CK" from "I hold a
  /// CK" without a trial decryption.
  ///
  /// Web caveat, recorded in `docs/METADATA.md`: on web this is cleartext
  /// localStorage, so a browser profile plus a DB dump reads the graph.
  /// Weaker than the §10a promise elsewhere, and the price of a PWA that
  /// survives its own eviction.
  static const String _contactBackupKeyKey = 'contact_backup_ck';

  /// Retry cadence for [read]: storage plugins fail transiently (Android
  /// Keystore after OS updates/backup restores; browser storage under early
  /// boot contention). Three quick attempts before conceding.
  static const List<Duration> _readRetryDelays = [
    Duration(milliseconds: 150),
    Duration(milliseconds: 400),
  ];

  /// `readFailed: true` means storage ERRORED on every attempt — the tokens
  /// may well exist. Callers MUST NOT treat that as "logged out" and MUST NOT
  /// clear anything in response.
  Future<({String? access, String? refresh, bool readFailed})> read() async {
    Object? lastError;
    for (var attempt = 0; attempt <= _readRetryDelays.length; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_readRetryDelays[attempt - 1]);
      }
      try {
        final r = await _readOnce();
        return (access: r.access, refresh: r.refresh, readFailed: false);
      } catch (e) {
        lastError = e;
      }
    }
    // Deduped for the same reason AUTH_SESSION_END's repeat-prone reasons
    // are: the provider reads up to 3× per failed boot and the durable log
    // is an 80-entry FIFO — plain records from a chronically failing store
    // would evict the BOOT_MARKERS wipe forensics. Eviction re-arms it.
    E2ePersistentDiag.recordDeduped('AUTH_TOKENS_UNREADABLE', {
      'errorType': lastError.runtimeType.toString(),
      'platform': _useSecure ? 'secure' : 'prefs',
    }, matchAll: ['platform: ${_useSecure ? 'secure' : 'prefs'}']);
    return (access: null, refresh: null, readFailed: true);
  }

  Future<({String? access, String? refresh})> _readOnce() async {
    if (!_useSecure) {
      final prefs = await SharedPreferences.getInstance();
      return (
        access: prefs.getString(_accessKey),
        refresh: prefs.getString(_refreshKey),
      );
    }
    var access = await _secure.read(_accessKey);
    var refresh = await _secure.read(_refreshKey);
    if (access == null && refresh == null) {
      final migrated = await _migrateFromPrefs();
      access = migrated.access;
      refresh = migrated.refresh;
    } else {
      // Tokens already secure: any prefs copy is residue from the
      // pre-migration build. Best-effort cleanup, never gating (it catches
      // internally, so it cannot fail this read).
      await _removePrefsCopies();
    }
    return (access: access, refresh: refresh);
  }

  Future<void> write({required String access, required String refresh}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _writeOnce(access, refresh);
        return;
      } catch (_) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
    }
    // A refused write costs a re-login on the next cold start; the session in
    // memory is unaffected. It used to also be INVISIBLE — record it so the
    // next "logged out overnight" dump explains itself.
    E2ePersistentDiag.record('AUTH_TOKEN_WRITE_FAILED', {
      'platform': _useSecure ? 'secure' : 'prefs',
    });
  }

  Future<void> _writeOnce(String access, String refresh) async {
    if (!_useSecure) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_accessKey, access);
      await prefs.setString(_refreshKey, refresh);
      return;
    }
    await _secure.write(_accessKey, access);
    await _secure.write(_refreshKey, refresh);
    await _removePrefsCopies();
  }

  Future<void> clear() async {
    await clearContactBackupKey();
    if (!_useSecure) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_accessKey);
        await prefs.remove(_refreshKey);
      } catch (_) {}
      return;
    }
    try {
      await _secure.delete(_accessKey);
      await _secure.delete(_refreshKey);
    } catch (_) {}
    await _removePrefsCopies();
  }

  /// The cached contact-backup content key for [userId], or null when there
  /// is none, it belongs to another account, or storage refused.
  ///
  /// A failure answers null on purpose — unlike [read], "do not decide" has
  /// no meaning here: the only cost of a missed CK is one PBKDF2 at the next
  /// password login, and the caller never deletes anything in response.
  Future<({String ckId, String ck})?> readContactBackupKey(int userId) async {
    final String? raw;
    try {
      raw = _useSecure
          ? await _secure.read(_contactBackupKeyKey)
          : (await SharedPreferences.getInstance()).getString(
              _contactBackupKeyKey,
            );
    } on Object {
      return null;
    }
    if (raw == null) return null;
    final parts = raw.split('.');
    if (parts.length != 3) return null;
    if (int.tryParse(parts[0]) != userId) return null;
    if (parts[1].isEmpty || parts[2].isEmpty) return null;
    return (ckId: parts[1], ck: parts[2]);
  }

  Future<void> writeContactBackupKey({
    required int userId,
    required String ckId,
    required String ck,
  }) async {
    final value = '$userId.$ckId.$ck';
    try {
      if (_useSecure) {
        await _secure.write(_contactBackupKeyKey, value);
      } else {
        await (await SharedPreferences.getInstance()).setString(
          _contactBackupKeyKey,
          value,
        );
      }
    } on Object {
      // A refused write costs one PBKDF2 at the next login; the CK in RAM
      // keeps this session uploading. Nothing to escalate.
    }
  }

  Future<void> clearContactBackupKey() async {
    try {
      if (_useSecure) {
        await _secure.delete(_contactBackupKeyKey);
      } else {
        await (await SharedPreferences.getInstance()).remove(
          _contactBackupKeyKey,
        );
      }
    } on Object {
      // Same: a refused delete leaves a key the next login overwrites.
    }
  }

  /// One-time move of a pre-Phase-2 install's tokens into secure storage.
  /// Copy -> fresh read-back -> only then remove from prefs.
  Future<({String? access, String? refresh})> _migrateFromPrefs() async {
    // The initial prefs READ is deliberately OUTSIDE the try: swallowing a
    // read failure here reported a storage ERROR as clean absence
    // (readFailed: false, null tokens) for exactly the installs whose tokens
    // still live in prefs — the error-as-absence hole this class exists to
    // close. A throw propagates to read()'s retry/readFailed machinery.
    final prefs = await SharedPreferences.getInstance();
    final access = prefs.getString(_accessKey);
    final refresh = prefs.getString(_refreshKey);
    if (access == null && refresh == null) {
      return (access: null, refresh: null);
    }
    // From here on the tokens ARE in hand: any migration failure serves the
    // prefs copy rather than failing the read. Copy -> fresh read-back ->
    // only then delete; a failed secure write leaves the working set where
    // it was.
    try {
      var verified = true;
      if (access != null) {
        await _secure.write(_accessKey, access);
        verified &= await _secure.read(_accessKey) == access;
      }
      if (refresh != null) {
        await _secure.write(_refreshKey, refresh);
        verified &= await _secure.read(_refreshKey) == refresh;
      }
      if (!verified) {
        // The secure copy is not proven; the prefs copy stays the working
        // set. Serve it so this launch still logs in.
        return (access: access, refresh: refresh);
      }
      await prefs.remove(_accessKey);
      await prefs.remove(_refreshKey);
      return (access: access, refresh: refresh);
    } catch (_) {
      return (access: access, refresh: refresh);
    }
  }

  Future<void> _removePrefsCopies() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_accessKey)) await prefs.remove(_accessKey);
      if (prefs.containsKey(_refreshKey)) await prefs.remove(_refreshKey);
    } catch (_) {}
  }
}
