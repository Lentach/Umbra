import 'package:flutter/widgets.dart';

import 'soft_keyboard_stub.dart'
    if (dart.library.js_interop) 'soft_keyboard_web.dart' as impl;

/// Best-effort: show the virtual keyboard when the field has focus but
/// [MediaQuery.viewInsets] still report zero height.
Future<void> showSoftKeyboardIfHidden({
  required BuildContext context,
  required bool hasFocus,
}) =>
    impl.showSoftKeyboardIfHidden(context: context, hasFocus: hasFocus);
