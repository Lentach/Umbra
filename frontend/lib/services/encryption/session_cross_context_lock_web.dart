import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Web Locks are origin-scoped, so separate PWA tabs/windows/workers requesting
/// the same name cannot mutate one persisted Signal SessionRecord concurrently.
Future<T> runSessionCrossContextLocked<T>(
  String name,
  Future<T> Function() action,
) async {
  final navigatorObject = web.window.navigator as JSObject;
  if (!navigatorObject.hasProperty('locks'.toJS).toDart) {
    throw UnsupportedError(
      'End-to-end encryption requires the browser Web Locks API',
    );
  }

  final result = Completer<T>();
  JSAny? onGranted(JSAny? _) {
    return (() async {
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
        rethrow;
      }
      return null;
    })().toJS;
  }

  final locks = navigatorObject.getProperty<JSObject?>('locks'.toJS);
  if (locks == null) {
    throw UnsupportedError(
      'End-to-end encryption requires the browser Web Locks API',
    );
  }
  try {
    final request = locks.callMethod<JSPromise<JSAny?>>(
      'request'.toJS,
      name.toJS,
      onGranted.toJS,
    );
    unawaited(
      request.toDart.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (!result.isCompleted) result.completeError(error, stackTrace);
        },
      ),
    );
  } catch (error, stackTrace) {
    if (!result.isCompleted) result.completeError(error, stackTrace);
  }
  return result.future;
}

JSObject _locksOrThrow() {
  final navigatorObject = web.window.navigator as JSObject;
  final locks = navigatorObject.hasProperty('locks'.toJS).toDart
      ? navigatorObject.getProperty<JSObject?>('locks'.toJS)
      : null;
  if (locks == null) {
    throw UnsupportedError(
      'End-to-end encryption requires the browser Web Locks API',
    );
  }
  return locks;
}

/// Takes [name] and keeps it until the returned release runs. The browser
/// frees the lock itself when the tab dies, so a crashed holder never strands
/// the name.
Future<void Function()> holdCrossContextLock(String name) {
  final locks = _locksOrThrow();
  final granted = Completer<void Function()>();
  final release = Completer<void>();
  JSAny? onGranted(JSAny? _) {
    granted.complete(() {
      if (!release.isCompleted) release.complete();
    });
    return (() async {
      await release.future;
      return null;
    })().toJS;
  }

  try {
    final request = locks.callMethod<JSPromise<JSAny?>>(
      'request'.toJS,
      name.toJS,
      onGranted.toJS,
    );
    unawaited(
      request.toDart.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (!granted.isCompleted) granted.completeError(error, stackTrace);
        },
      ),
    );
  } catch (error, stackTrace) {
    if (!granted.isCompleted) granted.completeError(error, stackTrace);
  }
  return granted.future;
}

/// Runs [action] under [name] only when no other context holds it right now.
Future<bool> runCrossContextLockIfAvailable(
  String name,
  Future<void> Function() action,
) async {
  final locks = _locksOrThrow();
  final done = Completer<bool>();
  JSAny? onGranted(JSAny? lock) {
    if (lock == null) {
      done.complete(false);
      return null;
    }
    return (() async {
      try {
        await action();
        done.complete(true);
      } catch (error, stackTrace) {
        done.completeError(error, stackTrace);
      }
      return null;
    })().toJS;
  }

  try {
    final options = JSObject()..setProperty('ifAvailable'.toJS, true.toJS);
    final request = locks.callMethod<JSPromise<JSAny?>>(
      'request'.toJS,
      name.toJS,
      options,
      onGranted.toJS,
    );
    unawaited(
      request.toDart.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (!done.isCompleted) done.completeError(error, stackTrace);
        },
      ),
    );
  } catch (error, stackTrace) {
    if (!done.isCompleted) done.completeError(error, stackTrace);
  }
  return done.future;
}
