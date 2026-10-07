import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import 'android_fcm_local_notifications.dart';

/// H1 (decision R81, ER81b): a box message journaled while the NATIVE app is
/// hidden posts a LOCAL, content-free card on this device.
///
/// The box wakes a device only for an unsubscribed queue or a detached
/// socket, and a native device gets nothing for a live one (E83), so a
/// backgrounded app whose socket lives on got nothing. No visibility signal
/// goes to the box; the device notifies itself. The card names no sender and
/// no chat, and it is the same card the bare FCM box wake-up shows, so one
/// replaces the other.
///
/// Web has its own card (decision 76): the page asks the push SW through
/// `ConversationsProvider.postHiddenArrivalCard`, so here web is never
/// hidden and posts nothing — two cards per message otherwise.
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
       _post = post ?? showBoxMessageLocalNotification,
       _now = now ?? DateTime.now;

  static const Duration alertWindow = Duration(seconds: 10);

  final bool Function() _isHidden;
  final Future<void> Function() _post;
  final DateTime Function() _now;
  DateTime? _lastAlertAt;

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
    if (kIsWeb) return false;
    final state = WidgetsBinding.instance.lifecycleState;
    return state != null && state != AppLifecycleState.resumed;
  }
}
