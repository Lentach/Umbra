import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, ValueNotifier;

import '../push_android_stub.dart'
    if (dart.library.io) 'android_fcm_local_notifications.dart'
    as push_android;
import '../utils/pending_deep_link_stub.dart'
    if (dart.library.html) '../utils/pending_deep_link_web.dart';
import '../utils/page_lifecycle_stub.dart'
    if (dart.library.html) '../utils/page_lifecycle_web.dart';
import 'web_push_bridge_stub.dart'
    if (dart.library.html) 'web_push_bridge_web.dart';

enum WebPushRequestStatus {
  subscribed,
  denied,
  unsupported,
  requiresStandalone,
  noChange,
  failed,
}

class WebPushRequestResult {
  final WebPushRequestStatus status;
  final String? details;

  const WebPushRequestResult(this.status, {this.details});
}

/// Local push setup: the web browser subscription and the Android FCM
/// permission / notification channel. Neither is registered with the server;
/// the box notifier registration (`PushBoxSource`, E9) reads them itself.
///
/// Privacy: a push carries no message content. A bare wake-up shows a
/// generic card ([android_fcm_local_notifications.dart]) that names no chat.
class PushService {
  final WebPushBridge _webPushBridge = createWebPushBridge();

  /// Web only: this browser has notification permission and can subscribe,
  /// yet holds no subscription the box notifier can register — none at all (a
  /// Safari revocation, a logout), or one under an old VAPID key that the
  /// engine would not swap without a tap (iOS, decision 90, E90a). The chat
  /// list shows a line whose tap runs [requestWebPushFromUserGesture]. One
  /// browser, one answer, whichever [PushService] instance found it.
  static final ValueNotifier<bool> webPushNeedsTap = ValueNotifier(false);

  /// Set by main.dart from the `notify_conv` URL param before initialize() is called.
  /// Drained once by ConnectionProvider._onSocketReady().
  int? coldStartConversationId;

  // VAPID public key for web push, injected via the WEB_PUSH_VAPID_PUBLIC_KEY
  // dart-define at build time (deploy-web.ps1 passes it). NO hardcoded fallback:
  // an empty key makes web-push subscribe fail loudly instead of silently
  // subscribing to a stale/wrong key (which causes 400 delivery + the backend
  // pruning the subscription). MUST match the backend VAPID pair (CLAUDE.md §3, §5).
  static const String _vapidKey = String.fromEnvironment(
    'WEB_PUSH_VAPID_PUBLIC_KEY',
    defaultValue: '',
  );

  PushService();

  /// Sets up local push handling after WebSocket connect: web refreshes its
  /// existing browser subscription and listens for notification clicks;
  /// Android asks for permission and readies the local notification channel
  /// (a push card names no chat, so there is no native tap routing).
  /// Nothing is registered with the server; the box notifier registration
  /// reads the subscription / FCM token itself.
  ///
  /// **`initialize` runs once per LOGIN, not once per app run** — an earlier
  /// version of this comment claimed the latter and that wrong model is what
  /// let the process-sticky cold-start reads replay across accounts (#175).
  /// Anything registered here must therefore be idempotent or cancelled first.
  ///
  /// [onNavigateToConversation]: web notification click routing.
  Future<void> initialize({
    void Function(int conversationId)? onNavigateToConversation,
  }) async {
    if (kIsWeb) {
      await _refreshExistingWebSubscription();
      if (onNavigateToConversation != null) {
        _webPushBridge.listenForNotificationClicks((convId) {
          // Click handled live — drop the SW's IndexedDB fallback record so it
          // cannot re-trigger navigation on the next cold start. EXCEPT while a
          // frozen-page reload may follow (freeze-reload guard): the SW's
          // queued click message flushes on the same thaw, and this record is
          // then the ONLY carrier of the tapped conversation across the
          // reload — deleting it would cold-boot onto the conversations list
          // (field bug, users 48/90, Aug 2026). A record left behind is
          // bounded: consumed-and-deleted by the next drain, max age 5 min.
          if (!frozenPageReloadImminent()) {
            clearPendingNotificationDeepLink().ignore();
          }
          if (convId != null) onNavigateToConversation(convId);
        });
      }
      return;
    }
    try {
      // Request permission (Android 13+, iOS always). The FCM token itself is
      // read by the box notifier registration (`PushBoxSource`).
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        return; // User denied
      }

      if (defaultTargetPlatform == TargetPlatform.android) {
        await push_android.initAndroidFcmLocalNotificationsOnMainIsolate();
      }
    } catch (_) {
      // Push setup failed (Firebase not configured, no permission, etc.) — silently ignored
    }
  }

  /// Logout: drops this device's push subscription (web: unsubscribes the
  /// browser subscription; native: cancels the listeners and deletes the FCM
  /// token). Local only, the server is never called.
  Future<void> unregister() async {
    if (kIsWeb) {
      if (!_webPushBridge.isSupported) return;
      webPushNeedsTap.value = false;
      try {
        await _webPushBridge.unsubscribe();
      } catch (_) {
        // Best-effort — don't block logout.
      }
      return;
    }
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {
      // Best-effort — don't block logout
    }
  }

  /// Web: asks for notification permission and creates this browser's push
  /// subscription. Must run inside a user gesture. The box notifier
  /// registration (`PushBoxSource`) picks the subscription up through
  /// `subscriptionChanged`; nothing is sent to the server from here.
  Future<WebPushRequestResult> requestWebPushFromUserGesture() async {
    if (!kIsWeb) {
      return const WebPushRequestResult(WebPushRequestStatus.unsupported);
    }
    if (!_webPushBridge.isSupported) {
      return const WebPushRequestResult(WebPushRequestStatus.unsupported);
    }
    if (!_webPushBridge.isStandaloneOrNotRequired()) {
      return const WebPushRequestResult(
        WebPushRequestStatus.requiresStandalone,
      );
    }

    try {
      final payload = await _webPushBridge.requestSubscriptionFromUserGesture(
        vapidPublicKey: _vapidKey,
      );
      if (payload == null) {
        final permission = _webPushBridge.notificationPermission;
        if (permission == 'denied') {
          return const WebPushRequestResult(WebPushRequestStatus.denied);
        }
        return const WebPushRequestResult(WebPushRequestStatus.noChange);
      }
      webPushNeedsTap.value = false;
      return const WebPushRequestResult(WebPushRequestStatus.subscribed);
    } catch (e) {
      return WebPushRequestResult(
        WebPushRequestStatus.failed,
        details: e.toString(),
      );
    }
  }

  /// Web: refreshes this browser's existing subscription (a VAPID swap, a
  /// revoked one) and tells the chat list whether a tap is needed to make one.
  Future<void> _refreshExistingWebSubscription() async {
    if (!_webPushBridge.isSupported) return;
    if (_webPushBridge.notificationPermission != 'granted') return;

    try {
      final payload = await _webPushBridge.registerExistingSubscription(
        vapidPublicKey: _vapidKey,
      );
      webPushNeedsTap.value =
          payload == null && _webPushBridge.isStandaloneOrNotRequired();
    } catch (_) {
      // Best-effort only on startup/reconnect.
    }
  }
}
