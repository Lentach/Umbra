import 'lock_signal.dart';

/// Non-web: one process, nothing to tell. [web-only: retire with §7]
LockSignal openLockSignal(void Function() onPeerLocked) =>
    const _NoLockSignal();

class _NoLockSignal implements LockSignal {
  const _NoLockSignal();

  @override
  void announce() {}

  @override
  void close() {}
}
