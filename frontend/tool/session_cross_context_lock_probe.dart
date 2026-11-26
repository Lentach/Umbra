import 'dart:async';
import 'dart:js_interop';

import 'package:fireplace/services/encryption/session_cross_context_lock.dart';
import 'package:web/web.dart' as web;

@JS('disableWebLocksForProbe')
external void disableWebLocksForProbe();

/// Browser smoke probe for the origin-wide Signal session lock.
///
/// Compile and serve using the commands in
/// `docs/runbooks/e2e-decryption-failed.md` Step 3A, or just run
/// `node scripts/verify-session-lock-probe.mjs`. The page title becomes
/// `SESSION_LOCK_PASS` only when same-name requests queue and a missing Web
/// Locks API fails closed without running the guarded action.
///
/// A failed assertion sets `SESSION_LOCK_FAIL: <reason>`. That distinction is
/// load-bearing: if a regression merely left the title at PENDING, the runner
/// could not tell "the lock is broken" from "the page never finished", and
/// would report the one thing this probe exists to catch as a harness glitch.
Future<void> main() async {
  try {
    await _runProbe();
    web.document.title = 'SESSION_LOCK_PASS';
  } catch (e) {
    web.document.title = 'SESSION_LOCK_FAIL: $e';
  }
}

Future<void> _runProbe() async {
  final firstStarted = Completer<void>();
  final releaseFirst = Completer<void>();
  var secondStarted = false;

  final first = runSessionCrossContextLocked('same-name', () async {
    firstStarted.complete();
    await releaseFirst.future;
    return 'first';
  });
  await firstStarted.future;
  final second = runSessionCrossContextLocked('same-name', () async {
    secondStarted = true;
    return 'second';
  });
  await Future<void>.delayed(Duration.zero);
  if (secondStarted) throw StateError('same-name lock did not queue');
  releaseFirst.complete();
  if (await first != 'first' || await second != 'second') {
    throw StateError('wrong lock result');
  }

  // The device-link ceremony's lock (`fireplace-e2e-link-<uid>`): a held name
  // refuses an `ifAvailable` request without running it, and runs it once the
  // holder releases.
  final release = await holdCrossContextLock('link-name');
  var ranWhileHeld = false;
  if (await runCrossContextLockIfAvailable('link-name', () async {
    ranWhileHeld = true;
  })) {
    throw StateError('ifAvailable ran against a held lock');
  }
  if (ranWhileHeld) throw StateError('ifAvailable action ran while held');
  release();
  // The release settles a promise tick after `release()`; poll briefly for it.
  var ranAfterRelease = false;
  for (var i = 0; i < 50 && !ranAfterRelease; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await runCrossContextLockIfAvailable('link-name', () async {
      ranAfterRelease = true;
    });
  }
  if (!ranAfterRelease) {
    throw StateError('ifAvailable did not run against a free lock');
  }

  disableWebLocksForProbe();
  var unlockedActionRan = false;
  try {
    await runSessionCrossContextLocked('unsupported', () async {
      unlockedActionRan = true;
      return 'unsafe';
    });
    throw StateError('missing Web Locks API did not fail closed');
  } on UnsupportedError {
    if (unlockedActionRan) throw StateError('Signal mutation ran unlocked');
  }
}
