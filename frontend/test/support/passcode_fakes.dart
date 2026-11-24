import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/local_data_eraser.dart';
import 'package:fireplace/services/lock_signal.dart';
import 'package:fireplace/services/encryption/content_sealer.dart';
import 'package:fireplace/services/secure_kv.dart';
import 'package:fireplace/services/passcode_kdf.dart';
import 'package:fireplace/services/passcode_store.dart';

/// Deterministic stand-in for PBKDF2: same contract (passcode + salt +
/// iterations in, stable bytes out), no native library. The real primitive is
/// covered by `test/services/passcode_kdf_test.dart` and the on-device run.
class FakePasscodeKdf implements PasscodeKdf {
  int calls = 0;
  bool broken = false;

  @override
  Future<Uint8List> derive({
    required String passcode,
    required Uint8List salt,
    required int iterations,
    int lengthBytes = 32,
  }) async {
    calls++;
    if (broken) throw StateError('webcrypto unavailable');
    final seed = utf8.encode('$passcode|${base64Encode(salt)}|$iterations');
    final out = Uint8List(lengthBytes);
    for (var i = 0; i < lengthBytes; i++) {
      out[i] = seed[i % seed.length] ^ (i * 31 & 0xff);
    }
    return out;
  }
}

/// In-memory [PasscodeStore] with the same visible semantics as
/// `DevicePasscodeStore` (which has its own tests against SharedPreferences).
class MemoryPasscodeStore implements PasscodeStore {
  PasscodeRecord record = PasscodeRecord.disabled;
  int credentialWrites = 0;

  @override
  Future<PasscodeRecord> load() async => record;

  /// Mirrors `DevicePasscodeStore`: the flag lives in the non-secret store,
  /// so it is readable even when the credential is not.
  @override
  Future<bool> readEnabledFlag() async =>
      record.enabled || record.credentialDamaged || record.credentialUnavailable;

  @override
  Future<void> saveCredential({
    required PasscodeMode mode,
    required Uint8List salt,
    required Uint8List verifier,
    required int iterations,
  }) async {
    credentialWrites++;
    record = PasscodeRecord(
      enabled: true,
      mode: mode,
      salt: salt,
      verifier: verifier,
      iterations: iterations,
      autoLockSeconds: record.autoLockSeconds,
      lastActiveAtMs: record.lastActiveAtMs,
      failedAttempts: 0,
      lockoutUntilMs: null,
    );
  }

  @override
  Future<void> clearCredential() async {
    record = PasscodeRecord(
      enabled: false,
      mode: record.mode,
      salt: null,
      verifier: null,
      iterations: record.iterations,
      autoLockSeconds: record.autoLockSeconds,
      lastActiveAtMs: record.lastActiveAtMs,
      failedAttempts: 0,
      lockoutUntilMs: null,
    );
  }

  @override
  Future<void> saveAutoLockSeconds(int seconds) async {
    record = _copy(autoLockSeconds: seconds);
  }

  @override
  Future<void> saveLastActiveAt(int? epochMs) async {
    record = _copy(lastActiveAtMs: epochMs, clearLastActive: epochMs == null);
  }

  @override
  Future<void> saveAttemptState({
    required int failedAttempts,
    required int? lockoutUntilMs,
  }) async {
    record = _copy(
      failedAttempts: failedAttempts,
      lockoutUntilMs: lockoutUntilMs,
      clearLockout: lockoutUntilMs == null,
    );
  }

  PasscodeRecord _copy({
    int? autoLockSeconds,
    int? lastActiveAtMs,
    bool clearLastActive = false,
    int? failedAttempts,
    int? lockoutUntilMs,
    bool clearLockout = false,
  }) => PasscodeRecord(
    enabled: record.enabled,
    credentialDamaged: record.credentialDamaged,
    mode: record.mode,
    salt: record.salt,
    verifier: record.verifier,
    iterations: record.iterations,
    autoLockSeconds: autoLockSeconds ?? record.autoLockSeconds,
    lastActiveAtMs:
        clearLastActive ? null : (lastActiveAtMs ?? record.lastActiveAtMs),
    failedAttempts: failedAttempts ?? record.failedAttempts,
    lockoutUntilMs:
        clearLockout ? null : (lockoutUntilMs ?? record.lockoutUntilMs),
  );
}

/// In-memory [LocalDataEraser]: records that the destructive path ran, and
/// can report a partial failure so the UI's honesty about it is testable.
class FakeLocalDataEraser implements LocalDataEraser {
  FakeLocalDataEraser({this.failed = const <LocalDataEraseArm>[]});

  int calls = 0;
  List<LocalDataEraseArm> failed;

  @override
  Future<LocalDataEraseReport> eraseEverything() async {
    calls++;
    return LocalDataEraseReport(failed: failed);
  }
}

/// In-memory secure storage for the passcode vault's meta record and the
/// wrapped content keys.
class MemorySecureKv implements SecureKv {
  final Map<String, String> store = {};

  @override
  Future<String?> read(String key) async => store[key];

  @override
  Future<void> write(String key, String value) async => store[key] = value;

  @override
  Future<void> delete(String key) async => store.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(store);
}

/// Reversible keyed stand-in for AES-GCM: enough to prove that a wrong KEK
/// fails to open, without needing the native webcrypto library.
class FakeContentSealer implements ContentSealer {
  @override
  Future<Uint8List?> seal(Uint8List key, Uint8List plaintext) async =>
      Uint8List.fromList([...key.take(4), ...plaintext]);

  @override
  Future<Uint8List?> unseal(Uint8List key, Uint8List sealed) async {
    if (sealed.length < 4) return null;
    for (var i = 0; i < 4; i++) {
      if (sealed[i] != key[i]) return null;
    }
    return Uint8List.fromList(sealed.sublist(4));
  }
}

/// Stands in for one `BroadcastChannel` name shared by several tabs: a message
/// reaches every OTHER opener, never the one that posted it, and carries no
/// payload (like the real signal).
class FakeLockSignalHub {
  final List<void Function()> _listeners = <void Function()>[];
  int announcements = 0;

  LockSignal open(void Function() onPeerLocked) {
    final tab = _FakeTabSignal(this, onPeerLocked);
    _listeners.add(onPeerLocked);
    return tab;
  }
}

class _FakeTabSignal implements LockSignal {
  _FakeTabSignal(this._hub, this._onPeerLocked);

  final FakeLockSignalHub _hub;
  final void Function() _onPeerLocked;

  @override
  void announce() {
    _hub.announcements++;
    for (final listener in List<void Function()>.of(_hub._listeners)) {
      if (listener != _onPeerLocked) listener();
    }
  }

  @override
  void close() => _hub._listeners.remove(_onPeerLocked);
}
