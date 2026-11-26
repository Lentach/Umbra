import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show Rect;

import 'web_focus_guard_stub.dart'
    if (dart.library.js_interop) 'web_focus_guard_web.dart' as impl;

// Indirection so widget tests can observe register/unregister calls without the
// web implementation (which only loads under dart.library.js_interop).
void Function(String id, Rect rect) _registerImpl = impl.registerFocusGuardRect;
void Function(String id) _unregisterImpl = impl.unregisterFocusGuardRect;

/// Installs the capture-phase touchstart/mousedown listener once (web/iOS only).
void ensureFocusGuardListenerInstalled() =>
    impl.ensureFocusGuardListenerInstalled();

/// Upserts the screen [rect] guarded under [id].
void registerFocusGuardRect(String id, Rect rect) => _registerImpl(id, rect);

/// Removes the guard rect for [id].
void unregisterFocusGuardRect(String id) => _unregisterImpl(id);

@visibleForTesting
void setFocusGuardHooksForTest({
  void Function(String id, Rect rect)? register,
  void Function(String id)? unregister,
}) {
  if (register != null) _registerImpl = register;
  if (unregister != null) _unregisterImpl = unregister;
}

@visibleForTesting
void resetFocusGuardHooksForTest() {
  _registerImpl = impl.registerFocusGuardRect;
  _unregisterImpl = impl.unregisterFocusGuardRect;
}
