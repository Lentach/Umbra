import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import 'box/box_notifiers.dart';
import 'box/box_wire.dart';
import 'web_push_bridge_stub.dart'
    if (dart.library.html) 'web_push_bridge_web.dart';

/// The app's push layer as box notifier registration sees it (E9): the Web
/// Push subscription on web, the FCM token on native.
///
/// A challenge code reaches the RUNNING app only — the push SW forwards it
/// to open pages, FCM's `onMessage` fires in the foreground — so no target
/// is offered while the page is hidden or the app is not resumed.
class PushBoxSource implements BoxPushSource {
  PushBoxSource({WebPushBridge? bridge})
    : _bridge = bridge ?? createWebPushBridge();

  final WebPushBridge _bridge;

  static bool get _firebase => Firebase.apps.isNotEmpty;

  @override
  Future<BoxPushTarget?> target() async {
    try {
      if (kIsWeb) {
        if (!_bridge.pageVisible) return null;
        final token = await _bridge.boxToken();
        return token == null
            ? null
            : (platform: NotifierPlatform.webpush, token: token);
      }
      if (!_firebase ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return null;
      }
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.getNotificationSettings();
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        return null;
      }
      final token = await messaging.getToken();
      return token == null ? null : (platform: NotifierPlatform.fcm, token: token);
    } on Object {
      return null;
    }
  }

  @override
  Stream<void> get targetChanged {
    if (kIsWeb) return _bridge.subscriptionChanged;
    if (!_firebase) return const Stream.empty();
    return FirebaseMessaging.instance.onTokenRefresh.map((_) {});
  }

  @override
  Stream<Uint8List> get challengeCodes {
    final raw = kIsWeb
        ? _bridge.boxChallengeCodes
        : _firebase
        ? FirebaseMessaging.onMessage
              .where((m) => m.data['type'] == 'notifier_challenge')
              .map((m) => m.data['code'])
        : const Stream.empty();
    return raw
        .map((code) => boxB64Decode(code, kBoxCodeBytes))
        .where((code) => code != null)
        .cast<Uint8List>();
  }
}
