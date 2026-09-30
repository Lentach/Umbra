import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import 'android_fcm_local_notifications.dart';
import 'web_push_bridge_stub.dart'
    if (dart.library.html) 'web_push_bridge_web.dart';

/// H1 (decision 81): a box message journaled while the app is hidden posts a
/// LOCAL, content-free card on this device.
///
/// The box wakes a device only for an unsubscribed queue or a detached
/// socket, so a hidden app whose socket lives on got nothing. No visibility
/// signal goes to the box (decision 81); the device notifies itself. The card
/// names no sender and no chat, and every message replaces the one before it.
///
/// "Hidden" is read from the platform at the moment of the message, never from
/// `ConversationsProvider.isClientVisible`: that flag starts `true` on every
/// connect, so an app that (re)connects while hidden would read as visible.
///
/// One alert per [alertWindow]: a backlog drained after a reconnect stores
/// many messages in a burst, and the card carries no content, so a second one
/// inside the window would only buzz again.
class BoxHiddenNotifier {
  BoxHiddenNotifier({
    bool Function()? isHidden,
    Future<void> Function()? post,
    DateTime Function()? now,
  }) : _isHidden = isHidden ?? _platformHidden,
       _post = post ?? _platformPost,
       _now = now ?? DateTime.now;

  static const Duration alertWindow = Duration(seconds: 10);

  final bool Function() _isHidden;
  final Future<void> Function() _post;
  final DateTime Function() _now;
  DateTime? _lastAlertAt;

  static final WebPushBridge _web = createWebPushBridge();

  /// Posts the card when the app is hidden and no alert went out in the last
  /// [alertWindow]. Never throws: a card that cannot be posted must not fail
  /// the message it announces.
  Future<void> notifyIfHidden() async {
    try {
      if (!_isHidden()) return;
      final now = _now();
      final last = _lastAlertAt;
      if (last != null && now.difference(last) < alertWindow) return;
      _lastAlertAt = now;
      await _post();
    } on Object {
      // Best effort: the message itself is already stored and shown.
    }
  }

  static bool _platformHidden() {
    if (kIsWeb) return !_web.pageVisible;
    final state = WidgetsBinding.instance.lifecycleState;
    return state != null && state != AppLifecycleState.resumed;
  }

  static Future<void> _platformPost() =>
      kIsWeb ? _web.showBoxMessageCard() : showBoxMessageLocalNotification();
}
