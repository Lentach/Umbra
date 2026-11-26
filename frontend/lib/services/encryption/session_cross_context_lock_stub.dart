/// Native/non-web fallback. Cross-isolate native use is unsupported by the
/// single-device app; the caller's in-process queue remains the lock.
Future<T> runSessionCrossContextLocked<T>(
  String name,
  Future<T> Function() action,
) => action();

/// Pass-through: one process, nothing to hold against.
Future<void Function()> holdCrossContextLock(String name) async => () {};

/// Pass-through: the lock is always free, so [action] always runs.
Future<bool> runCrossContextLockIfAvailable(
  String name,
  Future<void> Function() action,
) async {
  await action();
  return true;
}
