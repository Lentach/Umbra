import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/services/e2e_lock_revoker.dart';
import 'package:fireplace/services/encryption/content_key_wrap.dart';
import 'package:fireplace/services/passcode_unlock_gate.dart';
import 'package:fireplace/services/passcode_kdf.dart';
import 'package:fireplace/services/passcode_store.dart';
import 'package:fireplace/services/passcode_wrap_hook.dart';
import 'package:fireplace/utils/passcode_autolock.dart';
import 'package:fireplace/widgets/input/composer_keyboard_signals.dart';

import '../support/passcode_fakes.dart';

void main() {
  const t0 = 1757000000000;

  late MemoryPasscodeStore store;
  late FakePasscodeKdf kdf;
  late int now;
  late PasscodeProvider passcode;

  late MemorySecureKv vaultStore;
  late ContentKeyWrap vault;
  late PasscodeUnlockGate gate;
  late E2eLockRevoker revoker;
  late List<String> revokerCalls;
  late int relaunches;
  late bool canRelaunch;
  late bool pickerActive;

  PasscodeProvider build({
    bool wrapKeys = false,
    FakeLockSignalHub? tabs,
  }) => PasscodeProvider(
    openLockSignalFn: tabs?.open,
    store: store,
    kdf: kdf,
    nowMs: () => now,
    vault: vault,
    gate: gate,
    revoker: revoker,
    wrapKeys: wrapKeys,
    canRelaunch: () => canRelaunch,
    relaunch: () => relaunches++,
    nativePickerActive: () => pickerActive,
  );

  setUp(() {
    store = MemoryPasscodeStore();
    kdf = FakePasscodeKdf();
    now = t0;
    vaultStore = MemorySecureKv();
    vault = ContentKeyWrap(sealer: FakeContentSealer(), meta: vaultStore);
    gate = PasscodeUnlockGate();
    revokerCalls = <String>[];
    relaunches = 0;
    canRelaunch = false;
    pickerActive = false;
    revoker = E2eLockRevoker()
      ..onRevoke = () async {
        revokerCalls.add('revoke');
      }
      ..onRestore = () async {
        revokerCalls.add('restore');
      };
    passcode = build();
  });

  String hex(int seed) => List<int>.generate(32, (i) => (seed + i) & 0xff)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  // WEB-05 [web-only: retire with §7]: two tabs of one origin. Each has its
  // own provider, vault and revoker (RAM is per tab); the passcode store is the
  // shared localStorage.
  group('a lock in one tab locks the others (WEB-05)', () {
    late FakeLockSignalHub tabs;
    late PasscodeProvider tabA;
    late PasscodeProvider tabB;
    late ContentKeyWrap vaultB;
    late List<String> revokerCallsB;
    late int relaunchesB;

    setUp(() async {
      tabs = FakeLockSignalHub();
      tabA = build(wrapKeys: true, tabs: tabs);
      await tabA.initialize();
      await tabA.enable(passcode: '123456', mode: PasscodeMode.digits6);

      vaultB = ContentKeyWrap(sealer: FakeContentSealer(), meta: vaultStore);
      revokerCallsB = <String>[];
      relaunchesB = 0;
      tabB = PasscodeProvider(
        store: store,
        kdf: kdf,
        nowMs: () => now,
        vault: vaultB,
        gate: PasscodeUnlockGate()..open(),
        revoker: E2eLockRevoker()
          ..onRevoke = () async {
            revokerCallsB.add('revoke');
          },
        wrapKeys: true,
        canRelaunch: () => true,
        relaunch: () => relaunchesB++,
        nativePickerActive: () => false,
        openLockSignalFn: tabs.open,
      );
      await tabB.initialize();
      expect(await tabB.unlock('123456'), PasscodeUnlockResult.ok);
      expect(tabB.state, PasscodeLockState.unlocked);
    });

    test('the padlock in tab A revokes tab B the same way', () async {
      await tabA.lockNow();
      await pumpEventQueue();

      expect(tabB.state, PasscodeLockState.locked);
      expect(vaultB.isLocked, isTrue);
      expect(revokerCallsB, ['revoke']);
      expect(relaunchesB, 1);
      // Tab A did its own lock once and was not told back.
      expect(revokerCalls, ['revoke']);
      expect(tabs.announcements, 1, reason: 'B must not echo the lock');
    });

    test('an auto-lock on the tab the user just left does not lock the other',
        () async {
      await tabA.setAutoLockSeconds(0);

      await tabA.noteBackgrounded(); // the immediate setting: A locks itself
      await pumpEventQueue();

      expect(tabA.state, PasscodeLockState.locked);
      expect(tabs.announcements, 0);
      expect(tabB.state, PasscodeLockState.unlocked);
    });

    test('a tab that is already locked ignores the signal', () async {
      await tabB.lockNow();
      await pumpEventQueue();
      final before = revokerCallsB.length;

      await tabA.lockNow();
      await pumpEventQueue();

      expect(revokerCallsB.length, before);
    });
  });

  group('key wrapping (Phase 2)', () {
    test('enabling wraps the existing content keys and opens the E2E gate',
        () async {
      vaultStore.store['fp_sig_key_kidA'] = hex(9);
      vaultStore.store['fp_content_key_kidB'] = hex(20);
      await passcode.initialize();
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();

      final ok = await wrapping.enable(
        passcode: '123456',
        mode: PasscodeMode.digits6,
      );

      expect(ok, isTrue);
      expect(await vault.isWrappingOn(), isTrue);
      expect(vault.isLocked, isFalse);
      expect(
        WrappedContentKey.isEnvelope(vaultStore.store['fp_sig_key_kidA']!),
        isTrue,
      );
      expect(gate.isOpen, isTrue);
    });

    test('a wrapped device boots LOCKED even inside the auto-lock window',
        () async {
      // The KEK exists only in RAM, so a fresh process cannot read the key
      // material however recently the app was used. Demanding the code is
      // arithmetic here, not policy.
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();
      await wrapping.enable(passcode: '123456', mode: PasscodeMode.digits6);
      await wrapping.noteBackgrounded();
      now += 1000; // well inside the 60 s window
      // A real process restart loses the RAM-only KEK; the vault object is
      // shared in this test, so lock it to model the reboot honestly.
      vault.lock();

      final rebooted = build(wrapKeys: true);
      await rebooted.initialize();

      expect(rebooted.state, PasscodeLockState.locked);
      expect(gate.isOpen, isFalse, reason: 'E2E must wait for the unlock');
    });

    test('the right code reopens the vault and the gate', () async {
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();
      await wrapping.enable(passcode: '123456', mode: PasscodeMode.digits6);
      vault.lock();
      gate.close();
      wrapping.lockNow();

      expect(await wrapping.unlock('123456'), PasscodeUnlockResult.ok);
      expect(vault.isLocked, isFalse);
      expect(gate.isOpen, isTrue);
    });

    test('locking drops the KEK, closes the gate AND revokes the live stack',
        () async {
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();
      await wrapping.enable(passcode: '123456', mode: PasscodeMode.digits6);

      await wrapping.lockNow();

      expect(vault.isLocked, isTrue);
      expect(gate.isOpen, isFalse);
      // Without this the already-open stores keep their content keys — and
      // their decrypted rows — in RAM, and a re-lock is only a UI barrier.
      expect(revokerCalls, ['revoke']);
    });

    test('the lock screen covers the app BEFORE the teardown finishes',
        () async {
      final held = Completer<void>();
      revoker.onRevoke = () => held.future;
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();
      await wrapping.enable(passcode: '123456', mode: PasscodeMode.digits6);

      final locking = wrapping.lockNow();

      // A teardown that takes a moment must never leave the shell visible.
      expect(wrapping.state, PasscodeLockState.locked);
      held.complete();
      await locking;
    });

    test('web replaces the process after the teardown, so the heap goes too',
        () async {
      canRelaunch = true;
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();
      await wrapping.enable(passcode: '123456', mode: PasscodeMode.digits6);

      await wrapping.lockNow();

      expect(revokerCalls, ['revoke']);
      expect(relaunches, 1, reason: 'the message list lives outside the E2E '
          'stack; only a reload clears it');
    });

    test('an unlock that did not restart the process brings E2E back',
        () async {
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();
      await wrapping.enable(passcode: '123456', mode: PasscodeMode.digits6);
      await wrapping.lockNow();

      expect(await wrapping.unlock('123456'), PasscodeUnlockResult.ok);
      await Future<void>.delayed(Duration.zero);

      expect(revokerCalls, ['revoke', 'restore']);
    });

    test('a gate-only device neither revokes nor relaunches', () async {
      // Android by owner ruling: the same keys are readable again the instant
      // the store re-opens, so a teardown would cost an E2E re-init and buy
      // nothing.
      canRelaunch = true;
      await passcode.initialize();
      await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);

      await passcode.lockNow();

      expect(passcode.isLocked, isTrue);
      expect(revokerCalls, isEmpty);
      expect(relaunches, 0);
    });

    test('a passcode without wrapping does not revoke either', () async {
      // Wrapping is on for the platform but was never turned on for this
      // device (an enable that failed at the meta write). Revoking would tear
      // down a stack whose keys are still raw on disk, for nothing.
      canRelaunch = true;
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();
      await wrapping.enable(passcode: '123456', mode: PasscodeMode.digits6);
      await vault.unwrapAllKeys(kPasscodeWrappedKeyPrefixes);
      await vault.disableWrapping();

      await wrapping.lockNow();

      expect(revokerCalls, isEmpty);
      expect(relaunches, 0);
    });

    test('4-digit codes are refused wherever wrapping is on', () async {
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();

      expect(
        await wrapping.enable(passcode: '1234', mode: PasscodeMode.digits4),
        isFalse,
        reason: '10k candidates are minutes offline once the code IS the key',
      );
      expect(await vault.isWrappingOn(), isFalse);
      // Still fine while the passcode is only a gate.
      expect(
        await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4),
        isTrue,
      );
    });

    test('disabling unwraps every key first, so nothing is orphaned',
        () async {
      vaultStore.store['fp_content_key_kidB'] = hex(20);
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();
      await wrapping.enable(passcode: '123456', mode: PasscodeMode.digits6);

      expect(await wrapping.disable(passcode: '123456'), isTrue);

      expect(await vault.isWrappingOn(), isFalse);
      expect(vaultStore.store['fp_content_key_kidB'], hex(20));
      expect(wrapping.state, PasscodeLockState.disabled);
    });

    test('changing the code re-wraps the keys under the new KEK', () async {
      vaultStore.store['fp_content_key_kidB'] = hex(20);
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();
      await wrapping.enable(passcode: '123456', mode: PasscodeMode.digits6);
      final firstKekId = WrappedContentKey.kekIdOf(
        vaultStore.store['fp_content_key_kidB']!,
      );
      now += 5000;

      final ok = await wrapping.change(
        current: '123456',
        next: '654321',
        mode: PasscodeMode.digits6,
      );

      expect(ok, isTrue);
      final secondKekId = WrappedContentKey.kekIdOf(
        vaultStore.store['fp_content_key_kidB']!,
      );
      expect(secondKekId, isNot(firstKekId));
      // And the new code opens it on a fresh process.
      vault.lock();
      final rebooted = build(wrapKeys: true);
      await rebooted.initialize();
      expect(await rebooted.unlock('654321'), PasscodeUnlockResult.ok);
      expect(vault.isLocked, isFalse);
    });
  });

  group('initialize', () {
    test('a device with no passcode ends up disabled and never locked',
        () async {
      await passcode.initialize();

      expect(passcode.state, PasscodeLockState.disabled);
      expect(passcode.isEnabled, isFalse);
      expect(passcode.isLocked, isFalse);
    });

    test('an enabled passcode boots LOCKED once the auto-lock window passed',
        () async {
      await passcode.initialize();
      await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
      await passcode.noteBackgrounded();
      now += const Duration(minutes: 5).inMilliseconds;

      final rebooted = build();
      await rebooted.initialize();

      expect(rebooted.state, PasscodeLockState.locked);
      expect(rebooted.isLocked, isTrue);
    });

    test('boots UNLOCKED inside the window, because a web PWA cold-boots on '
        'thaw and a stricter rule would make the timer meaningless there',
        () async {
      await passcode.initialize();
      await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
      await passcode.setAutoLockSeconds(60);
      await passcode.noteBackgrounded();
      now += const Duration(seconds: 5).inMilliseconds;

      final rebooted = build();
      await rebooted.initialize();

      expect(rebooted.state, PasscodeLockState.unlocked);
    });

    test('an enabled passcode with no stamp on disk boots locked', () async {
      await passcode.initialize();
      await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
      await store.saveLastActiveAt(null);

      final rebooted = build();
      await rebooted.initialize();

      expect(rebooted.state, PasscodeLockState.locked);
    });
  });

  group('a store that throws', () {
    test('never leaves the gate holding on unknown', () async {
      // Holding `unknown` forever would brick the app behind a blank
      // surface. Fail open, same call the store makes for a partial
      // credential.
      final broken = PasscodeProvider(
        store: _ThrowingStore(),
        kdf: kdf,
        nowMs: () => now,
      );

      await broken.initialize();

      expect(broken.state, PasscodeLockState.disabled);
      expect(broken.isLocked, isFalse);
    });

    testWidgets('a store that HANGS cannot hold the gate forever',
        (tester) async {
      // Worse than throwing: no error, no completion. Observed for real —
      // `SharedPreferences.getInstance()` never answers under the widget-test
      // binding without mock values, and the gate covered the app forever.
      final hung = PasscodeProvider(
        store: _HangingStore(),
        kdf: kdf,
        nowMs: () => now,
      );

      final done = hung.initialize();
      await tester.pump(kPasscodeStoreReadTimeout + const Duration(seconds: 1));
      await done;

      expect(hung.state, PasscodeLockState.disabled);
    });
    test('a FLAGGED device never fails open when the credential read dies',
        () async {
      // The bypass this closes: the flag lives in prefs and answers, only the
      // Keystore half fails. Reading the flag inside the timed load made that
      // indistinguishable from "no passcode was ever set" — and that branch
      // UNLOCKS the app. A slow Keystore must never be a way in.
      final broken = PasscodeProvider(
        store: _ThrowingStore()..flag = true,
        kdf: kdf,
        nowMs: () => now,
        vault: vault,
        gate: gate,
        revoker: revoker,
      );

      await broken.initialize();

      expect(broken.state, PasscodeLockState.locked);
      expect(await broken.unlock('1234'), PasscodeUnlockResult.unavailable);
      broken.dispose();
    });
  });

  group('an unavailable credential (device regression 2026-09-04)', () {
    // Observed on the emulator: EVERY cold boot lost all three 250 ms
    // Keystore attempts, the record came back `credentialDamaged`, and the
    // correct 4-digit code was refused with "could not secure the code on
    // this device" — pointing the user at the destructive erase to get back
    // into an app whose credential was perfectly intact.
    PasscodeRecord unavailableRecord() => PasscodeRecord(
      enabled: false,
      credentialUnavailable: true,
      mode: PasscodeMode.digits4,
      salt: null,
      verifier: null,
      iterations: 1,
      autoLockSeconds: 3600,
      lastActiveAtMs: now,
      failedAttempts: 0,
      lockoutUntilMs: null,
    );

    test('locks without claiming the credential is broken', () async {
      store.record = unavailableRecord();
      final slow = build();

      await slow.initialize();

      expect(slow.state, PasscodeLockState.locked);
      // The distinction that matters to the user: "not yet readable" must not
      // render as "unrecoverable, erase your history".
      expect(slow.credentialResolved, isFalse);
      slow.dispose();
    });

    testWidgets('retries until storage answers, then the real code works',
        (tester) async {
      store.record = unavailableRecord();
      final slow = build();
      await slow.initialize();
      expect(slow.credentialResolved, isFalse);

      // Storage wakes up (a Keystore that answered on the fourth try).
      await store.saveCredential(
        mode: PasscodeMode.digits4,
        salt: Uint8List.fromList(List.filled(16, 7)),
        verifier: await kdf.derive(
          passcode: '1234',
          salt: Uint8List.fromList(List.filled(16, 7)),
          iterations: 1,
        ),
        iterations: 1,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(Duration.zero);

      expect(slow.credentialResolved, isTrue);
      expect(slow.state, PasscodeLockState.locked, reason: 'still locked');
      expect(await slow.unlock('1234'), PasscodeUnlockResult.ok);
      slow.dispose();
    });

    testWidgets('a read that finally answers "gone" IS damaged',
        (tester) async {
      store.record = unavailableRecord();
      final slow = build();
      await slow.initialize();

      store.record = PasscodeRecord(
        enabled: false,
        credentialDamaged: true,
        mode: PasscodeMode.digits4,
        salt: null,
        verifier: null,
        iterations: 1,
        autoLockSeconds: 3600,
        lastActiveAtMs: now,
        failedAttempts: 0,
        lockoutUntilMs: null,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(Duration.zero);

      expect(slow.state, PasscodeLockState.locked);
      expect(slow.credentialResolved, isTrue);
      expect(await slow.unlock('1234'), PasscodeUnlockResult.unavailable);
      slow.dispose();
    });
  });

  group('a damaged credential', () {
    // Flag true, verifier unreadable: a passcode EXISTS and cannot be
    // checked. Fail CLOSED — the opposite polarity to an unreadable store,
    // because here there is positive evidence the user set one.
    PasscodeProvider damagedProvider() {
      store.record = PasscodeRecord(
        enabled: false,
        credentialDamaged: true,
        mode: PasscodeMode.digits4,
        salt: null,
        verifier: null,
        iterations: 1,
        autoLockSeconds: 3600,
        lastActiveAtMs: now,
        failedAttempts: 0,
        lockoutUntilMs: null,
      );
      return build();
    }

    test('boots LOCKED even though nothing can verify a code', () async {
      final damaged = damagedProvider();
      await damaged.initialize();

      expect(damaged.state, PasscodeLockState.locked);
    });

    test('every code attempt reports unavailable, never wrong', () async {
      final damaged = damagedProvider();
      await damaged.initialize();

      expect(await damaged.unlock('1234'), PasscodeUnlockResult.unavailable);
      expect(damaged.state, PasscodeLockState.locked);
      expect(damaged.failedAttempts, 0);
    });

    test('an erase is the way out and it clears the wreckage', () async {
      final damaged = damagedProvider();
      await damaged.initialize();

      // What the eraser does to storage, then the gate's re-read.
      await store.clearCredential();
      await damaged.initialize();

      expect(damaged.state, PasscodeLockState.disabled);
      expect(store.record.enabled, isFalse);
      expect(store.record.credentialDamaged, isFalse);
    });
  });

  group('enable', () {
    test('stores a credential and leaves the app unlocked', () async {
      await passcode.initialize();

      final ok = await passcode.enable(
        passcode: '123456',
        mode: PasscodeMode.digits6,
      );

      expect(ok, isTrue);
      expect(passcode.state, PasscodeLockState.unlocked);
      expect(passcode.isEnabled, isTrue);
      expect(passcode.mode, PasscodeMode.digits6);
      expect(store.record.enabled, isTrue);
      expect(store.record.verifier, isNotNull);
      expect(store.record.iterations, kPasscodeKdfIterations);
    });

    test('rejects a code that does not match its mode length', () async {
      await passcode.initialize();

      expect(
        await passcode.enable(passcode: '123', mode: PasscodeMode.digits4),
        isFalse,
      );
      expect(
        await passcode.enable(passcode: '12345', mode: PasscodeMode.digits6),
        isFalse,
      );
      expect(
        await passcode.enable(passcode: 'ab', mode: PasscodeMode.alphanumeric),
        isFalse,
      );
      expect(store.credentialWrites, 0);
      expect(passcode.state, PasscodeLockState.disabled);
    });

    test('a derivation failure enables nothing at all', () async {
      await passcode.initialize();
      kdf.broken = true;

      expect(
        await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4),
        isFalse,
      );
      expect(store.credentialWrites, 0);
      expect(passcode.state, PasscodeLockState.disabled);
    });
  });

  group('unlock', () {
    setUp(() async {
      await passcode.initialize();
      await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
      passcode.lockNow();
    });

    test('the right code unlocks and clears the failure count', () async {
      expect(await passcode.unlock('1234'), PasscodeUnlockResult.ok);
      expect(passcode.state, PasscodeLockState.unlocked);
      expect(passcode.failedAttempts, 0);
    });

    test('a wrong code stays locked and counts the attempt', () async {
      expect(await passcode.unlock('9999'), PasscodeUnlockResult.wrong);
      expect(passcode.state, PasscodeLockState.locked);
      expect(passcode.failedAttempts, 1);
      expect(store.record.failedAttempts, 1);
    });

    test('a correct code after failures resets the counter', () async {
      await passcode.unlock('9999');
      await passcode.unlock('8888');
      expect(passcode.failedAttempts, 2);

      expect(await passcode.unlock('1234'), PasscodeUnlockResult.ok);
      expect(passcode.failedAttempts, 0);
      expect(store.record.failedAttempts, 0);
      expect(store.record.lockoutUntilMs, isNull);
    });

    test('a derivation failure is reported, not counted as a wrong code',
        () async {
      kdf.broken = true;

      expect(await passcode.unlock('1234'), PasscodeUnlockResult.unavailable);
      expect(passcode.failedAttempts, 0);
      expect(passcode.state, PasscodeLockState.locked);
    });

    test('unlocking while the backoff is active is refused without a derive',
        () async {
      for (var i = 0; i < kPasscodeAttemptsBeforeBackoff; i++) {
        await passcode.unlock('0000');
      }
      expect(passcode.lockoutRemaining, isNotNull);

      final callsBefore = kdf.calls;
      expect(
        await passcode.unlock('1234'),
        PasscodeUnlockResult.temporarilyBlocked,
      );
      expect(kdf.calls, callsBefore, reason: 'must not even hash while blocked');

      now += passcodeBackoffFor(kPasscodeAttemptsBeforeBackoff).inMilliseconds;
      expect(await passcode.unlock('1234'), PasscodeUnlockResult.ok);
    });
  });

  group('auto-lock', () {
    setUp(() async {
      await passcode.initialize();
      await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
      await passcode.setAutoLockSeconds(60);
    });

    test('backgrounding stamps the clock and returning early stays unlocked',
        () async {
      await passcode.noteBackgrounded();
      expect(store.record.lastActiveAtMs, t0);

      now += const Duration(seconds: 30).inMilliseconds;
      await passcode.evaluateOnForeground();

      expect(passcode.state, PasscodeLockState.unlocked);
    });

    test('returning after the window locks', () async {
      await passcode.noteBackgrounded();
      now += const Duration(seconds: 61).inMilliseconds;

      await passcode.evaluateOnForeground();

      expect(passcode.state, PasscodeLockState.locked);
    });

    test('a second "leaving" signal while still away does not move the stamp: '
        'the phone wake path (hidden → inactive → resumed) must judge from the '
        'real departure', () async {
      // Proven on the Pixel_7 emulator 2026-09-06 against the deployed 0.2.17
      // build: screen off 75 s with a 1-minute window → Chats, no lock. On
      // wake Flutter web delivers `inactive` before `resumed` (visible but not
      // yet focused); MainShell treats `inactive` as a departure and called
      // noteBackgrounded(), which re-stamped `passcode_last_active_at` at the
      // wake instant, so evaluateOnForeground() saw ~0 s away. Both edges
      // stay wired — on iOS `inactive` may be the only departure signal — the
      // provider just refuses to restamp a departure it already recorded.
      await passcode.noteBackgrounded(); // screen off (blur / hidden)
      final departedAt = store.record.lastActiveAtMs;
      now += const Duration(seconds: 75).inMilliseconds;

      await passcode.noteBackgrounded(); // wake: `inactive` before `resumed`
      expect(store.record.lastActiveAtMs, departedAt,
          reason: 'the stamp is the moment we LEFT, not the moment we came back');

      await passcode.evaluateOnForeground(); // `resumed`
      expect(passcode.state, PasscodeLockState.locked);
    });

    test('after a return has been judged, the next departure stamps afresh',
        () async {
      await passcode.noteBackgrounded();
      now += const Duration(seconds: 10).inMilliseconds;
      await passcode.evaluateOnForeground();
      expect(passcode.state, PasscodeLockState.unlocked);

      // A pull of the notification shade: `inactive` then `resumed` while the
      // page stays visible. First signal of a NEW departure — it must stamp.
      now += const Duration(seconds: 30).inMilliseconds;
      await passcode.noteBackgrounded();
      expect(store.record.lastActiveAtMs, now);
      now += const Duration(seconds: 5).inMilliseconds;
      await passcode.evaluateOnForeground();
      expect(passcode.state, PasscodeLockState.unlocked);

      // And a real departure after that is measured from ITS stamp.
      now += const Duration(seconds: 1).inMilliseconds;
      await passcode.noteBackgrounded();
      now += const Duration(seconds: 61).inMilliseconds;
      await passcode.evaluateOnForeground();
      expect(passcode.state, PasscodeLockState.locked);
    });

    test('a lock closes the departure: after unlocking, leaving again stamps '
        'and locks as a fresh departure', () async {
      await passcode.noteBackgrounded();
      now += const Duration(seconds: 61).inMilliseconds;
      await passcode.evaluateOnForeground();
      expect(passcode.state, PasscodeLockState.locked);
      expect(await passcode.unlock('1234'), PasscodeUnlockResult.ok);

      now += const Duration(seconds: 5).inMilliseconds;
      await passcode.noteBackgrounded();
      expect(store.record.lastActiveAtMs, now);
      now += const Duration(seconds: 61).inMilliseconds;
      await passcode.evaluateOnForeground();
      expect(passcode.state, PasscodeLockState.locked);
    });

    test('after a lock and an unlock, a SHORT absence stays unlocked — the '
        'pre-lock departure must not be the reference', () async {
      // The wake that shows the lock screen is itself a "return" the verdict
      // skips (state is locked). If that left the departure open, the next
      // leave would not stamp and the return would be judged against the
      // departure from BEFORE the lock: the app would lock every single time,
      // whatever the setting says.
      await passcode.noteBackgrounded();
      now += const Duration(seconds: 61).inMilliseconds;
      await passcode.evaluateOnForeground(); // wake → locked
      expect(passcode.state, PasscodeLockState.locked);
      await passcode.evaluateOnForeground(); // `resumed` arrives while locked
      expect(await passcode.unlock('1234'), PasscodeUnlockResult.ok);

      now += const Duration(seconds: 30).inMilliseconds;
      await passcode.noteBackgrounded();
      now += const Duration(seconds: 5).inMilliseconds;
      await passcode.evaluateOnForeground();
      expect(passcode.state, PasscodeLockState.unlocked);
    });

    test('with immediate auto-lock, backgrounding locks on the spot', () async {
      await passcode.setAutoLockSeconds(0);
      await passcode.noteBackgrounded();

      expect(passcode.state, PasscodeLockState.locked);
    });

    test('the native picker surface is not a departure: at 0 s neither the '
        'backgrounding nor the return locks while it is up', () async {
      // Attach → the OS camera/file sheet hides the page. Locking here
      // revokes the keys and (on web) replaces the process, so the picked
      // bytes never reach the composer — the same shape the freeze-reload
      // guard already suppresses for `composerNativePickerActive`.
      await passcode.setAutoLockSeconds(0);
      pickerActive = true;

      await passcode.noteBackgrounded();
      expect(passcode.state, PasscodeLockState.unlocked);
      expect(revokerCalls, isEmpty);

      now += const Duration(seconds: 20).inMilliseconds;
      await passcode.evaluateOnForeground();
      expect(passcode.state, PasscodeLockState.unlocked);
    });

    test('the picker span still stamps the clock, so a later return is judged '
        'from the picker, not from a stale stamp', () async {
      // Window 60 s: a real departure at t0, back at +30 (stays unlocked, the
      // stamp is NOT refreshed by returning), picker at +50. Without a fresh
      // stamp the return from the picker at +70 would read as 70 s away and
      // lock a user who never left.
      await passcode.noteBackgrounded();
      now += const Duration(seconds: 30).inMilliseconds;
      await passcode.evaluateOnForeground();
      expect(passcode.state, PasscodeLockState.unlocked);

      now += const Duration(seconds: 20).inMilliseconds;
      pickerActive = true;
      await passcode.noteBackgrounded();
      expect(store.record.lastActiveAtMs, now);

      now += const Duration(seconds: 20).inMilliseconds;
      pickerActive = false;
      await passcode.evaluateOnForeground();
      expect(passcode.state, PasscodeLockState.unlocked);
    });

    test('once the picker span ends the guard is gone: the next backgrounding '
        'locks as before', () async {
      await passcode.setAutoLockSeconds(0);
      pickerActive = true;
      await passcode.noteBackgrounded(); // the sheet hides the page
      expect(passcode.state, PasscodeLockState.unlocked);
      // The sheet closes: the page is visible again before the picked file's
      // change event lands, so the flag is still up at this return.
      await passcode.evaluateOnForeground();
      expect(passcode.state, PasscodeLockState.unlocked);

      pickerActive = false;
      await passcode.noteBackgrounded(); // a real departure
      expect(passcode.state, PasscodeLockState.locked);
    });

    test('the latch guards the stamp, not the verdict: at 0 s a second '
        '"leaving" signal after the picker span ended still locks, even with '
        'no return in between', () async {
      await passcode.setAutoLockSeconds(0);
      pickerActive = true;
      await passcode.noteBackgrounded();
      final departedAt = store.record.lastActiveAtMs;
      expect(passcode.state, PasscodeLockState.unlocked);

      // The span self-caps (3 min) without the page ever reporting visible;
      // the next lifecycle signal must still be able to lock.
      now += const Duration(seconds: 5).inMilliseconds;
      pickerActive = false;
      await passcode.noteBackgrounded();
      expect(passcode.state, PasscodeLockState.locked);
      expect(store.record.lastActiveAtMs, departedAt,
          reason: 'the second signal locks but does not move the departure');
    });

    test('the curtain drops synchronously on a departure and lifts only after '
        'the return verdict — never before a lock', () async {
      final seen = <String>[];
      passcode.addListener(() {
        seen.add('${passcode.curtained ? 'curtain' : 'clear'}/'
            '${passcode.state.name}');
      });

      final leaving = passcode.noteBackgrounded();
      // Before the first await inside noteBackgrounded resolves.
      expect(passcode.curtained, isTrue);
      await leaving;

      // Inside the window: the curtain lifts, the app is unlocked.
      now += const Duration(seconds: 10).inMilliseconds;
      await passcode.evaluateOnForeground();
      expect(passcode.curtained, isFalse);
      expect(passcode.state, PasscodeLockState.unlocked);

      // Past the window: no notification may ever show "clear + unlocked"
      // between the curtain and the lock — that frame would be the chat.
      seen.clear();
      await passcode.noteBackgrounded();
      now += const Duration(seconds: 61).inMilliseconds;
      await passcode.evaluateOnForeground();
      expect(passcode.state, PasscodeLockState.locked);
      expect(passcode.curtained, isFalse);
      expect(seen, isNot(contains('clear/unlocked')));
    });

    test('no curtain while already locked (the lock screen is the cover) and '
        'none for the attach picker (the OS sheet is)', () async {
      passcode.lockNow();
      await passcode.noteBackgrounded();
      expect(passcode.curtained, isFalse);
      expect(await passcode.unlock('1234'), PasscodeUnlockResult.ok);

      // A curtain over the composer would flash for a frame when the sheet
      // closes — the same exemption the immediate lock has.
      pickerActive = true;
      await passcode.noteBackgrounded();
      expect(passcode.curtained, isFalse);
      await passcode.evaluateOnForeground(); // picker still up at this return
      expect(passcode.curtained, isFalse);
      expect(passcode.state, PasscodeLockState.unlocked);
    });

    test('a disabled passcode never locks on return', () async {
      await passcode.disable(passcode: '1234');
      await passcode.noteBackgrounded();
      now += const Duration(days: 1).inMilliseconds;

      await passcode.evaluateOnForeground();

      expect(passcode.state, PasscodeLockState.disabled);
    });
  });

  group('disable and change', () {
    setUp(() async {
      await passcode.initialize();
      await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
    });

    test('the right code disables and destroys the credential', () async {
      expect(await passcode.disable(passcode: '1234'), isTrue);
      expect(passcode.state, PasscodeLockState.disabled);
      expect(store.record.enabled, isFalse);
      expect(store.record.verifier, isNull);
    });

    test('a wrong code changes nothing', () async {
      expect(await passcode.disable(passcode: '0000'), isFalse);
      expect(passcode.state, PasscodeLockState.unlocked);
      expect(store.record.enabled, isTrue);
    });

    test('change swaps the credential and the new code unlocks', () async {
      expect(
        await passcode.change(
          current: '1234',
          next: '654321',
          mode: PasscodeMode.digits6,
        ),
        isTrue,
      );
      expect(passcode.mode, PasscodeMode.digits6);

      passcode.lockNow();
      expect(await passcode.unlock('1234'), PasscodeUnlockResult.wrong);
      expect(await passcode.unlock('654321'), PasscodeUnlockResult.ok);
    });

    test('change with a wrong current code keeps the old credential',
        () async {
      expect(
        await passcode.change(
          current: '0000',
          next: '654321',
          mode: PasscodeMode.digits6,
        ),
        isFalse,
      );
      expect(passcode.mode, PasscodeMode.digits4);

      passcode.lockNow();
      expect(await passcode.unlock('1234'), PasscodeUnlockResult.ok);
    });
  });

  group('forgotten passcode', () {
    test('has no provider-side escape: only an erase can clear the credential',
        () async {
      // Owner ruling 2026-09-04: no password door. The provider deliberately
      // exposes nothing that drops the credential — that power lives in
      // `services/local_data_eraser.dart`, behind a typed confirmation, and
      // it destroys the guarded data along with the code. Re-reading a wiped
      // store is what actually opens the gate.
      await passcode.initialize();
      await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
      passcode.lockNow();

      await store.clearCredential();
      await passcode.initialize();

      expect(passcode.state, PasscodeLockState.disabled);
      expect(store.record.enabled, isFalse);
      expect(store.record.verifier, isNull);
    });
  });

  group('notifications', () {
    test('lockNow notifies listeners exactly once', () async {
      await passcode.initialize();
      await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);

      var notifications = 0;
      passcode.addListener(() => notifications++);
      passcode.lockNow();

      expect(notifications, 1);
      expect(passcode.isLocked, isTrue);
    });

    test('lockNow on a disabled passcode does nothing and does not notify',
        () async {
      await passcode.initialize();

      var notifications = 0;
      passcode.addListener(() => notifications++);
      passcode.lockNow();

      expect(notifications, 0);
      expect(passcode.state, PasscodeLockState.disabled);
    });
  });

  group('key-material entropy floor (web wrapping)', () {
    test('a 4-digit code typed as a Custom passcode is refused under wrapping',
        () async {
      // The digits4 MODE is already refused. This is the same 10^4 space
      // reached through the alphanumeric mode, which only checked length.
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();

      final ok = await wrapping.enable(
        passcode: '1234',
        mode: PasscodeMode.alphanumeric,
      );

      expect(ok, isFalse);
      expect(wrapping.isEnabled, isFalse);
    });

    test('an all-numeric 6-char Custom code is refused under wrapping',
        () async {
      // Same space as digits6 but arriving by the path with no character
      // rule at all; the owner's ruling is that key material may not be
      // all digits however it is typed.
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();

      expect(
        await wrapping.enable(
          passcode: '123456',
          mode: PasscodeMode.alphanumeric,
        ),
        isFalse,
      );
    });

    test('a short Custom code is refused under wrapping even with letters',
        () async {
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();

      expect(
        await wrapping.enable(
          passcode: 'ab1c',
          mode: PasscodeMode.alphanumeric,
        ),
        isFalse,
      );
    });

    test('a 6-char Custom code with a letter is accepted under wrapping',
        () async {
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();

      expect(
        await wrapping.enable(
          passcode: 'abc123',
          mode: PasscodeMode.alphanumeric,
        ),
        isTrue,
      );
      expect(wrapping.isEnabled, isTrue);
    });

    test('the floor does not apply where the code is only a gate', () async {
      // Android: the passcode is a verifier, not key material, so the
      // 4-character minimum the owner kept stays in force there.
      await passcode.initialize();

      expect(
        await passcode.enable(
          passcode: '1234',
          mode: PasscodeMode.alphanumeric,
        ),
        isTrue,
      );
    });

    test('change refuses a weak Custom code under wrapping', () async {
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();
      // Asserted, not assumed: 'abc123' with digits6 fails the ^\d+$ shape
      // rule, so an unchecked enable here left the passcode DISABLED and
      // change() then returned false at its `isEnabled` guard — green with
      // or without the floor this test exists to pin.
      expect(
        await wrapping.enable(passcode: '123456', mode: PasscodeMode.digits6),
        isTrue,
      );

      expect(
        await wrapping.change(
          current: '123456',
          next: '999999',
          mode: PasscodeMode.alphanumeric,
        ),
        isFalse,
      );
      // The credential must not have moved.
      expect(await wrapping.verifyCurrent('123456'), isTrue);
    });
  });

  group('settings-prompt throttle', () {
    test('verifyCurrent counts a wrong code toward the lockout', () async {
      await passcode.initialize();
      await passcode.enable(passcode: '123456', mode: PasscodeMode.digits6);

      for (var i = 0; i < kPasscodeAttemptsBeforeBackoff; i++) {
        expect(await passcode.verifyCurrent('000000'), isFalse);
      }

      expect(passcode.lockoutRemaining, isNotNull);
    });

    test('verifyCurrent refuses outright while locked out, even if correct',
        () async {
      await passcode.initialize();
      await passcode.enable(passcode: '123456', mode: PasscodeMode.digits6);
      for (var i = 0; i < kPasscodeAttemptsBeforeBackoff; i++) {
        await passcode.verifyCurrent('000000');
      }
      expect(passcode.lockoutRemaining, isNotNull);

      // The whole point: no oracle. A correct code is not confirmed while the
      // cooldown is running, so the grind cannot proceed at KDF speed.
      expect(await passcode.verifyCurrent('123456'), isFalse);
    });

    test('a correct code clears the attempt state', () async {
      await passcode.initialize();
      await passcode.enable(passcode: '123456', mode: PasscodeMode.digits6);
      await passcode.verifyCurrent('000000');
      await passcode.verifyCurrent('000000');

      expect(await passcode.verifyCurrent('123456'), isTrue);
      expect(passcode.failedAttempts, 0);
      expect(passcode.lockoutRemaining, isNull);
    });

    test('disable is throttled through the same path', () async {
      await passcode.initialize();
      await passcode.enable(passcode: '123456', mode: PasscodeMode.digits6);
      for (var i = 0; i < kPasscodeAttemptsBeforeBackoff; i++) {
        expect(await passcode.disable(passcode: '000000'), isFalse);
      }

      expect(passcode.lockoutRemaining, isNotNull);
      expect(await passcode.disable(passcode: '123456'), isFalse);
      expect(passcode.isEnabled, isTrue);
    });

    test('change is throttled through the same path', () async {
      await passcode.initialize();
      await passcode.enable(passcode: '123456', mode: PasscodeMode.digits6);
      for (var i = 0; i < kPasscodeAttemptsBeforeBackoff; i++) {
        await passcode.change(
          current: '000000',
          next: '654321',
          mode: PasscodeMode.digits6,
        );
      }

      expect(passcode.lockoutRemaining, isNotNull);
      expect(
        await passcode.change(
          current: '123456',
          next: '654321',
          mode: PasscodeMode.digits6,
        ),
        isFalse,
      );
    });
  });

  group('link ceremony exemption — (lxxvi) clause 2', () {
    // Built with build(), which leaves `ceremonyActive` at its DEFAULT, so
    // these tests prove the real wiring to the `linkCeremonyActive` global —
    // not just an injected predicate.
    setUp(() async {
      await passcode.initialize();
      await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
      await passcode.setAutoLockSeconds(0);
    });

    tearDown(() {
      linkCeremonyActive.value = false;
    });

    test('at 0 s a background during the ceremony neither locks nor curtains: '
        'a lock there revokes keys mid-adopt and (web) relaunches the page',
        () async {
      linkCeremonyActive.value = true;

      await passcode.noteBackgrounded();

      expect(passcode.state, PasscodeLockState.unlocked);
      expect(passcode.curtained, isFalse,
          reason: 'the scanner/permission sheet is the cover, not ours');
    });

    test('the foreground verdict is exempt too', () async {
      linkCeremonyActive.value = true;
      await passcode.noteBackgrounded();

      await passcode.evaluateOnForeground();

      expect(passcode.state, PasscodeLockState.unlocked);
    });

    test('FALSIFICATION control: the same background with no ceremony locks',
        () async {
      linkCeremonyActive.value = false;

      await passcode.noteBackgrounded();

      expect(passcode.state, PasscodeLockState.locked);
    });
  });

  group('PasscodeWrapHook — (lxxvi) clause 3', () {
    // The provider CONSTRUCTOR wires the static seam, so these tests go
    // through `PasscodeWrapHook.run()` — the exact call the adopt paths make
    // — not through `wrapRawKeysNow()` directly.
    tearDown(() {
      PasscodeWrapHook.afterRawKeysLanded = null;
    });

    test('raw keys landed by an adopt are wrapped by run() while wrapping is '
        'on and the vault is open', () async {
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();
      await wrapping.enable(passcode: '123456', mode: PasscodeMode.digits6);
      // adoptProvisionedIdentity/adoptRestoredIdentity land a RAW key after
      // the enable pass already wrapped everything else.
      vaultStore.store['fp_sig_key_adopted'] = hex(3);

      await PasscodeWrapHook.run();

      expect(
        WrappedContentKey.isEnvelope(vaultStore.store['fp_sig_key_adopted']!),
        isTrue,
        reason: 'a crash after adopt must not leave key material raw on a '
            'device whose passcode is key material',
      );
    });

    test('a no-op while the vault is LOCKED: no KEK in RAM means nothing can '
        'be wrapped; the next unlock resumes instead', () async {
      final wrapping = build(wrapKeys: true);
      await wrapping.initialize();
      await wrapping.enable(passcode: '123456', mode: PasscodeMode.digits6);
      vault.lock();
      vaultStore.store['fp_sig_key_adopted'] = hex(3);

      await PasscodeWrapHook.run();

      expect(vaultStore.store['fp_sig_key_adopted'], hex(3));
    });

    test('a no-op with wrapping off: nothing to protect, nothing converted',
        () async {
      final plain = build();
      await plain.initialize();
      await plain.enable(passcode: '1234', mode: PasscodeMode.digits4);
      vaultStore.store['fp_sig_key_adopted'] = hex(3);

      await PasscodeWrapHook.run();

      expect(vaultStore.store['fp_sig_key_adopted'], hex(3));
    });

    test('with no provider constructed, run() is a safe no-op', () async {
      PasscodeWrapHook.afterRawKeysLanded = null;
      await PasscodeWrapHook.run();
    });
  });
}

class _ThrowingStore implements PasscodeStore {
  /// What the cheap non-secret store answers. The secret half below is what
  /// fails, which is the real-world shape: prefs answer, the Keystore does not.
  bool flag = false;

  @override
  Future<bool> readEnabledFlag() async => flag;

  @override
  Future<PasscodeRecord> load() async => throw StateError('storage down');

  @override
  Future<void> clearCredential() async {}

  @override
  Future<void> saveAttemptState({
    required int failedAttempts,
    required int? lockoutUntilMs,
  }) async {}

  @override
  Future<void> saveAutoLockSeconds(int seconds) async {}

  @override
  Future<void> saveCredential({
    required PasscodeMode mode,
    required Uint8List salt,
    required Uint8List verifier,
    required int iterations,
  }) async {}

  @override
  Future<void> saveLastActiveAt(int? epochMs) async {}
}

/// Never completes — models a platform channel that silently stops answering.
class _HangingStore extends _ThrowingStore {
  @override
  Future<PasscodeRecord> load() => Completer<PasscodeRecord>().future;
}
