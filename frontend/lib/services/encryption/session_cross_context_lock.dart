// Keyed on dart.library.js_interop, NOT dart.library.html: the latter is FALSE
// under `flutter build web --wasm`, which would silently select the stub and
// delete the cross-context lock with no diagnostic. The web implementation is
// package:web + dart:js_interop and compiles unchanged on both web backends.
import 'session_cross_context_lock_stub.dart'
    if (dart.library.js_interop) 'session_cross_context_lock_web.dart'
    as impl;

typedef SessionCrossContextLockRunner =
    Future<T> Function<T>(String name, Future<T> Function() action);

/// Serializes one Signal session mutation across every app context sharing the
/// same origin. Native builds only need the in-process queue in
/// [EncryptionService]; web builds additionally use the browser Web Locks API.
Future<T> runSessionCrossContextLocked<T>(
  String name,
  Future<T> Function() action,
) => impl.runSessionCrossContextLocked(name, action);

/// Holds [name] until the returned release is called, or until this context
/// dies (the browser frees a lock with its tab). Waits while another context
/// holds it. Off web this grants at once and the release does nothing.
typedef CrossContextLockHolder = Future<void Function()> Function(String name);

/// Runs [action] only if [name] can be taken right now (`ifAvailable`);
/// returns false, with [action] never run, when another context holds it.
/// Off web the lock is a pass-through and [action] always runs.
typedef CrossContextTryLockRunner =
    Future<bool> Function(String name, Future<void> Function() action);

Future<void Function()> holdCrossContextLock(String name) =>
    impl.holdCrossContextLock(name);

Future<bool> runCrossContextLockIfAvailable(
  String name,
  Future<void> Function() action,
) => impl.runCrossContextLockIfAvailable(name, action);
