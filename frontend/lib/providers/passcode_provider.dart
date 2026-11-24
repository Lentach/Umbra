import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/e2e_lock_revoker.dart';
import '../services/encryption/content_key_manager.dart';
import '../services/encryption/content_key_wrap.dart';
import '../services/lock_signal.dart';
import '../services/lock_signal_stub.dart'
    if (dart.library.html) '../services/lock_signal_web.dart';
import '../services/passcode_kdf.dart';
import '../services/passcode_store.dart';
import '../services/passcode_unlock_gate.dart';
import '../services/passcode_wrap_hook.dart';
import '../utils/app_relaunch.dart';
import '../utils/e2e_persistent_diag.dart';
import '../utils/passcode_autolock.dart';
import '../utils/privacy_curtain.dart';
import '../widgets/input/composer_keyboard_signals.dart';

/// Where the app-level Passcode Lock stands right now.
enum PasscodeLockState {
  /// Before [PasscodeProvider.initialize] answers. Callers MUST treat this as
  /// "do not decide" — painting the chat list here would flash it for a frame
  /// on every cold start of a locked app.
  unknown,

  /// No passcode configured.
  disabled,

  /// Configured and satisfied for this foreground session.
  unlocked,

  /// Configured and demanding the code.
  locked,
}

enum PasscodeUnlockResult {
  ok,
  wrong,

  /// Too many wrong codes: refused without even hashing.
  temporarilyBlocked,

  /// The KDF itself is unavailable (no webcrypto native on this host). NOT a
  /// wrong code — it must never consume an attempt.
  unavailable,
}

/// Shortest accepted custom alphanumeric passcode.
const int kPasscodeMinAlphanumericLength = 4;

/// Shortest custom passcode accepted where the code is real key material.
///
/// Six characters with at least one non-digit, versus the four that suffice
/// for a pure gate. Not security theatre: under wrapping the KEK has no
/// entropy but this, and the wrapped envelopes plus the KEK salt sit in the
/// same origin storage they protect, so every candidate can be tried
/// OFFLINE at GPU speed. It does not make a hand-chosen code strong — it
/// only refuses the spaces small enough to fall in seconds.
const int kPasscodeMinKeyMaterialLength = 6;

/// Ceiling on the boot-time credential read.
///
/// The gate covers the app until this resolves, so a storage layer that HANGS
/// (rather than throws) would otherwise leave a blank surface with no way in
/// and no error — the worst failure this feature can have.
///
/// **It MUST stay above `DevicePasscodeStore.secretReadBudget` (4.8 s) plus
/// the SharedPreferences read that precedes it**, so that a slow-but-working
/// Keystore resolves through the store's own retries rather than through this
/// ceiling. `test/services/passcode_store_test.dart` asserts the ordering.
///
/// Firing it is no longer a bypass risk: the enabled flag is read separately
/// and first ([PasscodeStore.readEnabledFlag]), so a flagged device answers
/// LOCKED here whatever the secret half does. Before 2026-09-04 the flag came
/// out of the timed read, and this timeout meant "no passcode" — i.e. unlock.
const Duration kPasscodeStoreReadTimeout = Duration(milliseconds: 6000);

/// Key families the passcode wrap covers: the payload keys that seal the
/// Signal rows and the decrypted-content rows. Deliberately NOT the sealed
/// rows themselves and NOT the SQLCipher DB key (native only) — see
/// `services/encryption/content_key_wrap.dart` for why encrypting a row's
/// cleartext envelope prefix would re-trigger the 0.1.10 identity loss.
const List<String> kPasscodeWrappedKeyPrefixes = <String>[
  ContentKeyManager.contentKeyPrefix,
  ContentKeyManager.sigKeyPrefix,
];

/// The app-level passcode: a device-local gate in front of the whole logged-in
/// shell, in the shape Zangi ships and the owner approved on 2026-09-03.
///
/// Scope is deliberately a GATE, not at-rest encryption: it does not wrap the
/// Signal identity, the content keys or the JWT. Wrapping those is a separate,
/// opt-in tier — `services/encryption/content_key_manager.dart` documents why
/// auth-binding key material is a way to LOSE history, and this repo has spent
/// three handoffs on identity loss. Consequences of the gate-only scope, stated
/// plainly: on Android the protected material is already Keystore-backed and
/// the window is `FLAG_SECURE`, so the gate is a real improvement; on web the
/// verifier and everything it guards sit in the same localStorage, so the gate
/// stops a person holding the phone and nothing more.
///
/// Forgetting the passcode is NOT survivable, by design (owner ruling
/// 2026-09-04): there is no password door, because a recovery path the
/// account password can walk through is not a lock. The only way past a
/// forgotten code is `services/local_data_eraser.dart` — destroy every local
/// store and sign in again — which is the model Telegram, Threema, Phantom
/// and Trust Wallet all ship.
class PasscodeProvider extends ChangeNotifier {
  PasscodeProvider({
    PasscodeStore? store,
    PasscodeKdf? kdf,
    int Function()? nowMs,
    ContentKeyWrap? vault,
    PasscodeUnlockGate? gate,
    E2eLockRevoker? revoker,
    @visibleForTesting LockSignalOpener? openLockSignalFn,
    bool? wrapKeys,
    @visibleForTesting bool Function()? canRelaunch,
    @visibleForTesting void Function()? relaunch,
    @visibleForTesting bool Function()? nativePickerActive,
    @visibleForTesting bool Function()? ceremonyActive,
  }) : _store = store ?? DevicePasscodeStore(),
       _kdf = kdf ?? const Pbkdf2PasscodeKdf(),
       _now = nowMs ?? _wallClock,
       _vault = vault ?? ContentKeyWrap.instance,
       _gate = gate ?? PasscodeUnlockGate.instance,
       _revoker = revoker ?? E2eLockRevoker.instance,
       _wrapKeys = wrapKeys ?? kIsWeb,
       // Never in a widget test: a real reload would take the test host with
       // it. `canRelaunchApp()` is false off-web, which covers the unit
       // suite; the explicit override covers a test that forces `wrapKeys`.
       _canRelaunch = canRelaunch ?? canRelaunchApp,
       _relaunch = relaunch ?? relaunchApp,
       _nativePickerActive =
           nativePickerActive ?? (() => composerNativePickerActive.value),
       _ceremonyActive = ceremonyActive ?? (() => linkCeremonyActive.value) {
    // (lxxvi) clause 3: the adopt paths (`adoptProvisionedIdentity`,
    // `adoptRestoredIdentity`) land RAW keys in the stores and then call
    // `PasscodeWrapHook.run()`, which must reach the vault THIS provider
    // owns. Last-writer-wins is correct: the app has exactly one live
    // PasscodeProvider.
    PasscodeWrapHook.afterRawKeysLanded = wrapRawKeysNow;
    _lockSignal = (openLockSignalFn ?? openLockSignal)(_lockFromPeer);
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final PasscodeStore _store;
  final PasscodeKdf _kdf;
  final int Function() _now;

  /// Phase 2: the passcode-derived wrap around the local content keys.
  final ContentKeyWrap _vault;

  /// Phase 2: holds the E2E boot until the vault is open.
  final PasscodeUnlockGate _gate;

  /// Tears the LIVE E2E stack down on a re-lock, and brings it back on an
  /// unlock that did not restart the process.
  final E2eLockRevoker _revoker;

  /// [web-only: retire with §7] Tells the other tabs of this origin that the
  /// user locked here, and hears them (WEB-05). No-op off-web.
  late final LockSignal _lockSignal;

  /// Web-only in-place process restart. See [_lock] step 3.
  final bool Function() _canRelaunch;
  final void Function() _relaunch;

  /// True while the composer's OS camera/file sheet is up. That sheet hides
  /// the page (visibility loss on web, `paused` on Android) without the user
  /// going anywhere, and a lock there revokes the keys and — on web —
  /// replaces the process before the picked bytes reach the composer. Same
  /// signal, same reason, as the freeze-reload suppression in `MainShell`.
  /// The span self-caps at 3 minutes (`composer_keyboard_signals.dart`), so
  /// a stuck flag degrades to the pre-guard behaviour, never to a dead lock.
  final bool Function() _nativePickerActive;

  /// True while a link ceremony or an enrolment is running
  /// (`linkCeremonyActive`, raised by `LinkCeremonyController`). The ceremony
  /// hides the page for reasons of its own — the QR scanner, the permission
  /// sheet, the user looking at the OTHER device — and a lock in that window
  /// revokes keys and (on web) replaces the process in the middle of
  /// `adoptProvisionedIdentity`'s writes. Exempt exactly like the picker
  /// (amendment (lxxvi) clause 2). No self-cap: the ceremony has a server-side
  /// 10-minute TTL and a terminal state on every path.
  final bool Function() _ceremonyActive;

  /// A departure signal that is CAUSED by an in-app surface, not by the user
  /// leaving: the attach picker's OS sheet, or a live link ceremony. Neither
  /// may trigger the immediate lock, the curtain, or (in the gate) the DOM
  /// curtain.
  bool _departureExempt() => _nativePickerActive() || _ceremonyActive();

  /// Backoff for the credential re-read in [_retryCredentialRead]. Capped so
  /// a device that never answers costs one read every 8 s and nothing more.
  static const List<Duration> _credentialRetryDelays = [
    Duration(milliseconds: 400),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  Timer? _credentialRetry;
  int _credentialRetryAttempt = 0;

  /// Whether enabling the passcode should also wrap the local key material.
  /// Web only by owner ruling (2026-09-04): on Android the same material is
  /// already Keystore-backed behind `FLAG_SECURE`, and wrapping it there would
  /// turn every Keystore fault into permanent history loss on the platform
  /// where a forgotten code is currently survivable. Injectable so the
  /// behaviour is testable off-web.
  final bool _wrapKeys;

  bool get wrapsKeys => _wrapKeys;

  PasscodeRecord _record = PasscodeRecord.disabled;
  PasscodeLockState _state = PasscodeLockState.unknown;

  PasscodeLockState get state => _state;

  bool get isEnabled =>
      _state == PasscodeLockState.locked || _state == PasscodeLockState.unlocked;

  bool get isLocked => _state == PasscodeLockState.locked;

  PasscodeMode get mode => _record.mode;

  int get autoLockSeconds => _record.autoLockSeconds;

  int get failedAttempts => _record.failedAttempts;

  /// Time left on the brute-force cooldown, or null when attempts are allowed.
  Duration? get lockoutRemaining {
    final until = _record.lockoutUntilMs;
    if (until == null) return null;
    final remaining = until - _now();
    if (remaining <= 0) return null;
    return Duration(milliseconds: remaining);
  }

  /// Reads the stored credential and applies the auto-lock policy to this
  /// boot. A cold boot is treated exactly like a foreground return on purpose:
  /// on web a backgrounded PWA is FROZEN and then REPLACED by a hard reload
  /// (`utils/page_lifecycle_web.dart`), so "cold boot" and "came back" are the
  /// same event there, and a stricter rule would make the user's auto-lock
  /// choice meaningless on the primary platform.
  Future<void> initialize() async {
    // The FLAG comes first, from the cheap non-secret store, because it is
    // the one fact that decides whether failing OPEN below is allowed at all.
    // Reading it inside the timed load made "a passcode exists but storage is
    // slow" indistinguishable from "no passcode was ever set", and the second
    // reading unlocks the app — a complete bypass off a slow Keystore.
    final flagged = await _readFlagQuiet();
    try {
      _record = await _store.load().timeout(kPasscodeStoreReadTimeout);
    } catch (e) {
      E2ePersistentDiag.record('PASSCODE_STORE_UNREADABLE', {
        'errorType': e.runtimeType.toString(),
        'flagged': flagged,
      });
      if (flagged) {
        // A passcode EXISTS. Stay closed and keep trying; never unlock.
        await _enterUnavailable();
        return;
      }
      // Nothing readable at all, not even the flag. Inventing a lock for
      // someone who may never have set one would let a storage hiccup lock a
      // user out of their own app, and holding `unknown` forever would brick
      // the app behind a blank surface with no way in.
      _record = PasscodeRecord.disabled;
      _gate.open();
      _setState(PasscodeLockState.disabled);
      return;
    }
    if (_record.credentialUnavailable) {
      // The flag read TRUE and the credential read did not answer. Transient
      // by nature (a first Keystore read on a cold, loaded device), so this
      // locks and RETRIES — it does not tell the user their credential is
      // broken and point them at the erase. That misdiagnosis was live on
      // Android until 2026-09-04: every cold boot lost all three 250 ms
      // attempts and refused the correct code.
      await _enterUnavailable();
      return;
    }
    if (_record.credentialDamaged) {
      // Opposite polarity, deliberately: the flag READ TRUE and the read
      // ANSWERED that the verifier is gone. Resolving that to "unlocked" is
      // the error-as-absence inversion that `AuthTokenStore` was hardened
      // against — a wiped or tampered Keystore entry would silently open the
      // app. Fail CLOSED; the lock screen's erase action is the way through,
      // and every code entry reports `unavailable` rather than "wrong".
      E2ePersistentDiag.record('PASSCODE_CREDENTIAL_DAMAGED', const {});
      await _closeGateIfWrapping();
      _setState(PasscodeLockState.locked);
      return;
    }
    if (!_record.enabled) {
      _gate.open();
      _setState(PasscodeLockState.disabled);
      return;
    }
    var lock = shouldLockOnForeground(
      enabled: true,
      lastActiveAtMs: _record.lastActiveAtMs,
      nowMs: _now(),
      autoLockSeconds: _record.autoLockSeconds,
    );
    // With wrapping on, the KEK lives only in RAM, so a process that starts
    // with a locked vault CANNOT read the key material no matter what the
    // auto-lock window says. Demanding the code is then not a policy choice
    // but arithmetic: without it there is nothing to show.
    if (!lock && await _vault.isWrappingOn() && _vault.isLocked) {
      lock = true;
    }
    if (lock) {
      await _closeGateIfWrapping();
    } else {
      _gate.open();
    }
    _setState(lock ? PasscodeLockState.locked : PasscodeLockState.unlocked);
  }

  /// The flag alone, never throwing: a store that cannot even answer this is
  /// the "nothing readable" case, and that one is allowed to fail open.
  Future<bool> _readFlagQuiet() async {
    try {
      return await _store.readEnabledFlag().timeout(kPasscodeStoreReadTimeout);
    } catch (_) {
      return false;
    }
  }

  /// A passcode exists and its credential did not answer. Lock, and keep
  /// asking until storage answers — a device whose Keystore wakes up on the
  /// third try must end up with a working code, not with an erase prompt.
  Future<void> _enterUnavailable() async {
    E2ePersistentDiag.recordDeduped(
      'PASSCODE_CREDENTIAL_UNAVAILABLE',
      const {},
      matchAll: const ['PASSCODE_CREDENTIAL_UNAVAILABLE'],
    );
    await _closeGateIfWrapping();
    _setState(PasscodeLockState.locked);
    notifyListeners(); // the screen re-reads `credentialResolved`
    _scheduleCredentialRetry();
  }

  /// Whether a code entered right now can be checked at all. False only in
  /// the retrying state above, which the lock screen shows as "still
  /// loading" rather than as a failure the user must erase their way out of.
  bool get credentialResolved =>
      !_record.credentialUnavailable || _record.enabled;

  void _scheduleCredentialRetry() {
    if (_credentialRetry != null) return;
    final delay = _credentialRetryDelays[_credentialRetryAttempt.clamp(
      0,
      _credentialRetryDelays.length - 1,
    )];
    _credentialRetry = Timer(delay, () {
      _credentialRetry = null;
      _credentialRetryAttempt++;
      _retryCredentialRead();
    });
  }

  /// Deliberately unbounded (with a capped delay): while this is failing the
  /// app is locked and unusable anyway, so there is no state worth giving up
  /// for. The lock screen keeps its erase action throughout, so a device
  /// whose storage never recovers is not stuck without a way out.
  Future<void> _retryCredentialRead() async {
    PasscodeRecord next;
    try {
      next = await _store.load().timeout(kPasscodeStoreReadTimeout);
    } catch (_) {
      _scheduleCredentialRetry();
      return;
    }
    if (next.credentialUnavailable) {
      _scheduleCredentialRetry();
      return;
    }
    _record = next;
    if (next.credentialDamaged) {
      // The read finally answered: the credential really is gone.
      E2ePersistentDiag.record('PASSCODE_CREDENTIAL_DAMAGED', const {});
      notifyListeners();
      return;
    }
    if (!next.enabled) {
      // Disabled underneath us (an erase, or another engine on the origin).
      _gate.open();
      _setState(PasscodeLockState.disabled);
      return;
    }
    // The credential is readable now. Still LOCKED — the boot policy already
    // said so — but the code the user types will be checked for real.
    notifyListeners();
  }

  /// Holds the E2E boot only when there is something it could not read: with
  /// wrapping off, a locked UI must never stall the encryption stack.
  Future<void> _closeGateIfWrapping() async {
    if (await _vault.isWrappingOn()) _gate.close();
  }

  /// Turns the lock on. Returns false — changing nothing — when the code does
  /// not fit its mode, when the mode is not allowed under wrapping, or when
  /// the KDF is unavailable.
  Future<bool> enable({
    required String passcode,
    required PasscodeMode mode,
  }) async {
    if (!isValidPasscode(passcode, mode, keyMaterial: _wrapKeys)) return false;
    if (!_modeAllowed(mode)) return false;
    final salt = generatePasscodeSalt();
    final verifier = await _derive(passcode, salt, kPasscodeKdfIterations);
    if (verifier == null) return false;

    await _store.saveCredential(
      mode: mode,
      salt: salt,
      verifier: verifier,
      iterations: kPasscodeKdfIterations,
    );
    _record = await _store.load();
    if (_wrapKeys) await _turnWrappingOn(passcode);
    _gate.open();
    _setState(PasscodeLockState.unlocked);
    return true;
  }

  /// Turns the lock off. Requires the current code.
  ///
  /// Unwrapping comes FIRST and must succeed: dropping the credential while
  /// keys are still wrapped would leave envelopes whose KEK can never be
  /// re-derived — unreadable history with no passcode to blame.
  Future<bool> disable({required String passcode}) async {
    if (!isEnabled) return false;
    if (!await verifyCurrent(passcode)) return false;
    if (await _vault.isWrappingOn()) {
      if (_vault.isLocked && !await _openVault(passcode)) return false;
      if (!await _vault.unwrapAllKeys(kPasscodeWrappedKeyPrefixes)) {
        return false;
      }
      await _vault.disableWrapping();
    }
    await _store.clearCredential();
    _record = await _store.load();
    _gate.open();
    _setState(PasscodeLockState.disabled);
    return true;
  }

  /// Checks the CURRENT code for the settings screens, to gate a change or a
  /// disable. Returns false for a wrong code and for an unavailable KDF alike
  /// — the caller's next step is the same either way, and neither may reveal
  /// anything more.
  ///
  /// It DOES change state, despite the name: a wrong code advances the
  /// attempt ladder and notifies, a right one clears it. Callers that show a
  /// "wrong passcode" message on false must therefore check
  /// [lockoutRemaining] first, or they will tell a user their correct code is
  /// wrong for the length of a cooldown.
  ///
  /// Throttled on the SAME ladder as [unlock], and for the same reason: this
  /// is a credential oracle. Left unmetered it let anyone who reached a
  /// momentarily-unlocked app grind the code at KDF speed from Settings,
  /// leaving no persisted trace — and on web recovering the code yields the
  /// KEK, hence every future lock too.
  Future<bool> verifyCurrent(String passcode) async {
    if (!isEnabled) return false;
    // Refuse before the KDF runs: while the cooldown is live not even a
    // correct code is confirmed, so there is nothing to learn by waiting.
    if (lockoutRemaining != null) return false;

    final matched = await _matches(passcode);
    // An unavailable KDF is not a wrong code and must not consume an attempt.
    if (matched == null) return false;
    if (matched) {
      await _clearAttemptState();
      return true;
    }
    await _registerFailedAttempt();
    return false;
  }

  /// Replaces the credential (and possibly the mode). Requires the old code.
  Future<bool> change({
    required String current,
    required String next,
    required PasscodeMode mode,
  }) async {
    if (!isEnabled) return false;
    if (!isValidPasscode(next, mode, keyMaterial: _wrapKeys)) return false;
    if (!_modeAllowed(mode)) return false;
    if (!await verifyCurrent(current)) return false;

    final salt = generatePasscodeSalt();
    final verifier = await _derive(next, salt, kPasscodeKdfIterations);
    if (verifier == null) return false;

    // Re-wrap BEFORE the credential moves: if the rekey fails, the old code
    // still opens both the verifier and the vault, so the device stays
    // consistent rather than half-migrated.
    if (await _vault.isWrappingOn()) {
      final kekSalt = generatePasscodeSalt();
      final kek = await _derive(next, kekSalt, kPasscodeKdfIterations);
      if (kek == null) return false;
      final ok = await _vault.rekey(
        newKek: kek,
        newKekId: _newKekId(),
        iterations: kPasscodeKdfIterations,
        saltB64: base64Encode(kekSalt),
        prefixes: kPasscodeWrappedKeyPrefixes,
      );
      if (!ok) return false;
    }

    await _store.saveCredential(
      mode: mode,
      salt: salt,
      verifier: verifier,
      iterations: kPasscodeKdfIterations,
    );
    _record = await _store.load();
    _setState(PasscodeLockState.unlocked);
    return true;
  }

  Future<PasscodeUnlockResult> unlock(String passcode) async {
    if (!isEnabled) return PasscodeUnlockResult.unavailable;
    if (lockoutRemaining != null) {
      return PasscodeUnlockResult.temporarilyBlocked;
    }

    final matched = await _matches(passcode);
    if (matched == null) return PasscodeUnlockResult.unavailable;

    if (matched) {
      // The verifier said yes, but on a wrapped device the code must also
      // OPEN the vault, and a code that verifies while the KEK cannot be
      // rebuilt must not unlock the UI: the app would come up with every
      // local key unreadable and no explanation.
      if (!await _openVault(passcode)) {
        return PasscodeUnlockResult.unavailable;
      }
      await _clearAttemptState();
      _gate.open();
      _setState(PasscodeLockState.unlocked);
      // Bring the E2E stack back if a re-lock revoked it and the process
      // survived (native, or a web reload the platform refused). A no-op on
      // the boot path, where E2E was never up and is waiting on the gate this
      // call just opened. NOT awaited: the UI must reveal itself now, and the
      // revoker serializes this behind any teardown still in flight.
      _revoker.restore().ignore();
      return PasscodeUnlockResult.ok;
    }

    await _registerFailedAttempt();
    return PasscodeUnlockResult.wrong;
  }

  /// Wipes the attempt ladder after a code is accepted. No write when there
  /// is nothing to clear, so a normal unlock costs no storage round trip.
  Future<void> _clearAttemptState() async {
    if (_record.failedAttempts == 0 && _record.lockoutUntilMs == null) return;
    await _store.saveAttemptState(failedAttempts: 0, lockoutUntilMs: null);
    _record = await _store.load();
  }

  /// Advances the cooldown ladder by one wrong code. Shared by [unlock] and
  /// [verifyCurrent] so Settings cannot be a cheaper oracle than the lock
  /// screen.
  Future<void> _registerFailedAttempt() async {
    final failed = _record.failedAttempts + 1;
    final backoff = passcodeBackoffFor(failed);
    await _store.saveAttemptState(
      failedAttempts: failed,
      lockoutUntilMs: backoff == Duration.zero
          ? null
          : _now() + backoff.inMilliseconds,
    );
    _record = await _store.load();
    notifyListeners();
  }

  Future<void> setAutoLockSeconds(int seconds) async {
    if (!kPasscodeAutoLockChoices.contains(seconds)) return;
    if (seconds == _record.autoLockSeconds) return;
    await _store.saveAutoLockSeconds(seconds);
    _record = await _store.load();
    notifyListeners();
  }

  /// Demand the code now (the Chats-header padlock).
  ///
  /// Returns the future of the teardown so a caller (or a test) can await the
  /// revocation; the UI does not, because [_lock] flips the state — and so
  /// covers the app — before the first await.
  Future<void> lockNow() {
    if (_state != PasscodeLockState.unlocked) return Future<void>.value();
    final locking = _lock();
    // After _lock's synchronous half, so this tab is already covered. Only the
    // user's own padlock is announced: an auto-lock fires on the tab the user
    // just LEFT, and must not lock the one they went to.
    _lockSignal.announce();
    return locking;
  }

  /// Another tab of this origin was locked by the user: run the same lock,
  /// without announcing it back.
  void _lockFromPeer() {
    if (_state != PasscodeLockState.unlocked) return;
    unawaited(_lock());
  }

  /// Locking is a real revocation wherever the passcode is real key material,
  /// and a UI barrier where it is only a verifier.
  ///
  /// Three steps, in this order:
  ///
  ///  1. drop the KEK and close the E2E gate, and flip the state so the lock
  ///     screen covers the app in THIS frame — everything after is async;
  ///  2. with wrapping on, revoke the live E2E stack ([E2eLockRevoker]): the
  ///     open stores forget their keys and their decrypted rows, so nothing
  ///     can be decrypted again until the code comes back. Without this the
  ///     already-open stores keep serving plaintext from RAM and only a cold
  ///     boot was arithmetic;
  ///  3. on web, replace the process ([relaunchApp]). Step 2 cannot reach what
  ///     it does not own — the message list, the conversation previews, the
  ///     rendered text — and a hard reload takes the whole heap with it. This
  ///     is the same replacement `page_lifecycle_web.dart` performs on every
  ///     thaw of a frozen PWA, so it lands on this app's best-tested boot,
  ///     which then demands the code (the KEK is RAM-only, so a wrapped device
  ///     boots locked whatever the auto-lock window says).
  ///
  /// Step 2 stays useful even when step 3 is refused (a reload requested from
  /// a `pagehide` handler can be ignored): the keys are gone either way, and
  /// unlocking then re-initialises E2E in place through
  /// `EncryptionProvider.restoreAfterPasscodeUnlock`.
  ///
  /// Where wrapping is off (Android, by owner ruling) neither step runs: the
  /// same keys are readable again the instant the store re-opens, so a
  /// teardown would cost an E2E re-init and buy nothing. That platform's lock
  /// is a UI barrier and `frontend/CLAUDE.md` §10b says so out loud.
  Future<void> _lock() async {
    // A lock closes the departure: after the unlock the next "leaving"
    // signal is a NEW departure and must stamp.
    _away = false;
    _curtained = false; // the lock screen is the cover now
    _vault.lock();
    _gate.close();
    _setState(PasscodeLockState.locked);
    if (!_wrapKeys || !await _vault.isWrappingOn()) return;
    await _revoker.revoke();
    if (_canRelaunch()) _relaunch();
  }

  /// True from a departure signal until the next foreground verdict: the
  /// gate paints the lock screen's chrome over the app meanwhile.
  ///
  /// On wake the browser re-shows the LAST PAINTED frame before any code runs
  /// (owner, both phones, 2026-09-06: "for a millisecond there is the chat").
  /// No verdict can beat that frame; the only cure is to have painted
  /// something else on the way OUT. `blur` arrives about a second before the
  /// page is hidden on Android (probe 2026-09-06), so the curtain gets its
  /// frame. It is a cover, not a lock — no keypad, nothing revoked — and it is
  /// lifted only AFTER the return verdict, or lifting it would itself flash
  /// the chat before a lock lands.
  bool _curtained = false;
  bool get curtained => _curtained;

  void _setCurtained(bool next) {
    if (_curtained == next) return;
    _curtained = next;
    // The DOM curtain (web) is normally already up — the page's own blur
    // handler showed it before this code ran. Belt and braces for a departure
    // signal that reached Flutter without one. It is LIFTED by the gate, after
    // it has painted the state that replaces it.
    if (next) showDomCurtain();
    notifyListeners();
  }

  /// True between the first "leaving" signal and the next foreground verdict.
  ///
  /// One departure arrives as SEVERAL signals: `blur` and `visibilitychange`
  /// on the way out, and on the way back in Flutter web delivers `inactive`
  /// (visible, not yet focused) BEFORE `resumed`, and `MainShell` rightly
  /// treats `inactive` as a departure — on iOS it may be the only one it
  /// gets. Without this flag that late `inactive` re-stamped the clock at the
  /// WAKE instant, and the verdict a moment later saw ~0 s away: a phone left
  /// screen-off for 15 minutes came back unlocked (owner, iOS + Android PWA,
  /// 2026-09-06; reproduced on the Pixel_7 emulator with the persisted stamp
  /// read on both edges). The stamp must be the moment we LEFT.
  bool _away = false;

  /// The app left the foreground: stamp the clock, and lock immediately when
  /// the user chose the immediate setting.
  ///
  /// The stamp is written on the way OUT because that is the only moment the
  /// away-time can start being measured, and because on web the process may
  /// never run code again (frozen page replaced, or iOS killing the PWA).
  /// Only the FIRST signal of a departure writes it; see [_away].
  ///
  /// While the native picker is up the stamp is still written — the return
  /// is judged from the picker, not from whatever older departure the stamp
  /// held — but the immediate lock is held back; see [_nativePickerActive].
  Future<void> noteBackgrounded() async {
    if (!isEnabled) return;
    // Synchronously, before any await: this frame is the one the browser will
    // show on wake.
    // Not for the attach picker: its sheet hides the page, and a curtain
    // over the composer would flash for a frame when the sheet closes —
    // the same exemption the immediate lock has.
    if (_state == PasscodeLockState.unlocked && !_departureExempt()) {
      _setCurtained(true);
    }
    // The latch guards the STAMP only. The verdict below still runs on every
    // signal, so a second "leaving" signal can still lock at 0 s (e.g. the
    // picker span ended without a return ever being reported) — it just
    // cannot move the moment we left.
    if (!_away) {
      _away = true;
      await _store.saveLastActiveAt(_now());
    }
    _record = await _store.load();
    if (_record.autoLockSeconds <= 0 && !_departureExempt()) {
      // Awaited: on web this backgrounding IS the last code this process may
      // ever run, so the revocation has to finish before we yield.
      await _lock();
      return;
    }
    notifyListeners();
  }

  /// The app came back to the foreground.
  ///
  /// A return from the native picker is not a return from anywhere: the
  /// picked bytes are about to land in the composer, and at 0 s the rule
  /// below would lock (and on web relaunch) before they do. The departure is
  /// closed all the same, so the NEXT departure stamps afresh.
  Future<void> evaluateOnForeground() async {
    if (!isEnabled) return;
    _away = false;
    if (_state == PasscodeLockState.locked) {
      _setCurtained(false);
      return;
    }
    if (_departureExempt()) {
      _setCurtained(false);
      return;
    }
    // Re-read: another PWA engine on the same origin may have moved the stamp.
    _record = await _store.load();
    final lock = shouldLockOnForeground(
      enabled: true,
      lastActiveAtMs: _record.lastActiveAtMs,
      nowMs: _now(),
      autoLockSeconds: _record.autoLockSeconds,
    );
    if (lock) {
      await _lock();
    } else {
      _setCurtained(false);
    }
  }

  /// Whether [mode] may be used on this device.
  ///
  /// A 4-digit code is 10 000 candidates, and once it is the key rather than
  /// a verifier those candidates can be tried OFFLINE against the wrapped
  /// keys — the published Bitwarden PIN exploit is exactly this. So the shape
  /// stays available while the passcode is only a gate (owner ruling
  /// 2026-09-04) and is refused wherever wrapping is on.
  bool _modeAllowed(PasscodeMode mode) =>
      !(_wrapKeys && mode == PasscodeMode.digits4);

  /// Re-derives the KEK from [passcode] and opens the vault. True when there
  /// is nothing to open (wrapping off) or the vault is now open.
  ///
  /// Also finishes any interrupted migration: `wrapRawKeys` is idempotent, so
  /// every unlock is a resume point and a device interrupted mid-enable
  /// converges instead of staying half-wrapped.
  Future<bool> _openVault(String passcode) async {
    if (!await _vault.isWrappingOn()) return true;
    final meta = await _vault.readMeta();
    if (meta == null) return false;
    final kek = await _derive(passcode, meta.salt, meta.iterations);
    if (kek == null) return false;
    _vault.unlock(kek: kek, kekId: meta.kekId);
    await _vault.wrapRawKeys(kPasscodeWrappedKeyPrefixes);
    return true;
  }

  /// (lxxvi) clause 3: called (via [PasscodeWrapHook]) after
  /// `adoptProvisionedIdentity` / `adoptRestoredIdentity` land raw keys, so a
  /// crash in that window cannot leave key material raw on a device whose
  /// passcode is real key material. The idempotent `wrapRawKeys` path: only
  /// still-raw keys are converted, each write armed (read back and proven to
  /// unwrap). A no-op wherever there is nothing to do — wrapping off, or the
  /// vault locked (no KEK in RAM means nothing can be wrapped; the next
  /// unlock's own `wrapRawKeys` resume covers that window instead).
  Future<void> wrapRawKeysNow() async {
    if (!_wrapKeys) return;
    if (!await _vault.isWrappingOn()) return;
    if (_vault.isLocked) return;
    await _vault.wrapRawKeys(kPasscodeWrappedKeyPrefixes);
  }

  /// Turns wrapping on for a code that was just accepted. Best-effort by
  /// design: if it fails the user still has the Phase 1 gate, which is
  /// strictly better than refusing to set a passcode at all — and the failure
  /// is recorded rather than guessed at later.
  Future<void> _turnWrappingOn(String passcode) async {
    final kekSalt = generatePasscodeSalt();
    final kek = await _derive(passcode, kekSalt, kPasscodeKdfIterations);
    if (kek == null) {
      E2ePersistentDiag.record('PASSCODE_WRAP_ENABLE_FAILED', {
        'stage': 'derive',
      });
      return;
    }
    final on = await _vault.enableWrapping(
      kek: kek,
      kekId: _newKekId(),
      iterations: kPasscodeKdfIterations,
      saltB64: base64Encode(kekSalt),
    );
    if (!on) {
      E2ePersistentDiag.record('PASSCODE_WRAP_ENABLE_FAILED', {
        'stage': 'meta',
      });
      return;
    }
    final wrapped = await _vault.wrapRawKeys(kPasscodeWrappedKeyPrefixes);
    E2ePersistentDiag.record('PASSCODE_WRAP_ENABLED', {'keys': wrapped ?? -1});
  }

  String _newKekId() => 'kek${_now()}';

  Future<bool?> _matches(String passcode) async {
    final salt = _record.salt;
    final verifier = _record.verifier;
    if (salt == null || verifier == null) return null;
    final candidate = await _derive(passcode, salt, _record.iterations);
    if (candidate == null) return null;
    return constantTimeBytesEqual(candidate, verifier);
  }

  Future<Uint8List?> _derive(String passcode, Uint8List salt, int iterations) {
    return _kdf
        .derive(passcode: passcode, salt: salt, iterations: iterations)
        .then<Uint8List?>((v) => v)
        // A KDF failure must be a reported, recoverable state — never a
        // silent "wrong code", which would burn attempts and, on the settings
        // screens, look like the user's own code stopped working.
        .onError<Object>((_, _) => null);
  }

  void _setState(PasscodeLockState next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _credentialRetry?.cancel();
    _credentialRetry = null;
    _lockSignal.close();
    super.dispose();
  }
}

/// Why a candidate passcode was refused; [PasscodeRefusal.none] means it is
/// acceptable. A reason rather than a bare bool because the setup screen has
/// to tell the user which rule they hit — a silent refusal on the Custom
/// path is a dead end, since the keypad modes enforce their own shape.
enum PasscodeRefusal {
  none,

  /// Wrong length, or a non-digit in a numeric mode.
  shape,

  /// Long enough to be a gate code, too weak to be a KEK: under wrapping the
  /// passcode IS the key, so it must clear
  /// [kPasscodeMinKeyMaterialLength] characters and contain something that
  /// is not a digit.
  tooWeakForKeys,
}

/// Whether [passcode] is acceptable for [mode]: exact length and digits only
/// for the numeric modes, at least [kPasscodeMinAlphanumericLength] characters
/// for a custom one.
///
/// [keyMaterial] is true wherever the code derives the KEK (web wrapping). It
/// raises the Custom floor, because that mode had no character rule at all:
/// `1234` typed as a Custom code produced exactly the 10^4 KEK space the
/// [PasscodeProvider._modeAllowed] digits4 refusal exists to forbid, and
/// `123456` the same 10^6 space as digits6 (owner ruling 2026-09-05). The
/// numeric keypad modes are governed by that refusal, not by this floor.
PasscodeRefusal refusePasscode(
  String passcode,
  PasscodeMode mode, {
  bool keyMaterial = false,
}) {
  final fixed = mode.fixedLength;
  if (fixed != null) {
    if (passcode.length != fixed) return PasscodeRefusal.shape;
    return RegExp(r'^\d+$').hasMatch(passcode)
        ? PasscodeRefusal.none
        : PasscodeRefusal.shape;
  }
  final trimmed = passcode.trim();
  if (trimmed.length < kPasscodeMinAlphanumericLength) {
    return PasscodeRefusal.shape;
  }
  if (!keyMaterial) return PasscodeRefusal.none;
  if (trimmed.length < kPasscodeMinKeyMaterialLength) {
    return PasscodeRefusal.tooWeakForKeys;
  }
  return RegExp(r'^\d+$').hasMatch(trimmed)
      ? PasscodeRefusal.tooWeakForKeys
      : PasscodeRefusal.none;
}

bool isValidPasscode(
  String passcode,
  PasscodeMode mode, {
  bool keyMaterial = false,
}) =>
    refusePasscode(passcode, mode, keyMaterial: keyMaterial) ==
    PasscodeRefusal.none;
