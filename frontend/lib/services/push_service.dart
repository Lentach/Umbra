import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show
        debugPrint,
        defaultTargetPlatform,
        kIsWeb,
        TargetPlatform,
        ValueNotifier;
import '../push_android_stub.dart'
    if (dart.library.io) 'android_fcm_local_notifications.dart'
    as push_android;
import '../utils/pending_deep_link_stub.dart'
    if (dart.library.html) '../utils/pending_deep_link_web.dart';
import '../utils/page_lifecycle_stub.dart'
    if (dart.library.html) '../utils/page_lifecycle_web.dart';
import 'api_service.dart';
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

/// Whether this PROCESS has already consumed the terminated-state FCM open
/// (`getInitialMessage`). Deliberately top-level: `PushService` is rebuilt per
/// session, and the launch fact is per process (#175).
bool _coldStartFcmOpenDelivered = false;

// No `@visibleForTesting` reset hook: nothing on the host can drive
// `getInitialMessage`, so a hook here would be dead API pretending to be
// coverage. The latch is device-observed (#175), and the doc above says so.

/// Handles FCM push notification registration and token lifecycle.
///
/// Privacy strategy (Signal/Wire-style): FCM only receives { type: 'new_message' }.
/// Message content is NEVER sent through FCM — the app wakes up and fetches
/// the message from your own server via WebSocket.
///
/// Android: data messages show a grouped local notification (see
/// [android_fcm_local_notifications.dart]); tap routes via [onNavigateToConversation].
class PushService {
  final ApiService _api;
  final WebPushBridge _webPushBridge = createWebPushBridge();

  StreamSubscription<RemoteMessage>? _androidFcmOpenedSubscription;

  /// Cancelled and re-listened on every [initialize] (i.e. every login), so a
  /// second session cannot leave a live listener from the first behind.
  StreamSubscription<String>? _tokenRefreshSubscription;

  /// Web only: this browser has notification permission and can subscribe,
  /// yet holds no subscription the server can push to — none at all (a
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

  PushService(this._api);

  /// Initialize push notifications and register the FCM token with the server.
  /// Call after WebSocket connect so the user is authenticated.
  /// [jwtToken] is the current user's JWT for the backend API call.
  ///
  /// [currentJwtToken] supplies the JWT that is current AT CALL TIME. The
  /// `onTokenRefresh` listener below outlives many token rotations, so
  /// capturing [jwtToken] there registered a rotated device token with a stale
  /// JWT — 401, swallowed, push silently dead until the next launch.
  ///
  /// **`initialize` runs once per LOGIN, not once per app run** — an earlier
  /// version of this comment claimed the latter and that wrong model is what
  /// let the process-sticky cold-start reads replay across accounts (#175).
  /// Anything registered here must therefore be idempotent or cancelled first.
  ///
  /// [onNavigateToConversation]: notification tap routing (Android FCM + web push).
  Future<void> initialize(
    String jwtToken, {
    String? Function()? currentJwtToken,
    void Function(int conversationId)? onNavigateToConversation,
  }) async {
    if (kIsWeb) {
      await _registerExistingWebSubscription(jwtToken);
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
      // Request permission (Android 13+, iOS always, Web when called)
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        return; // User denied
      }

      final fcmToken = await FirebaseMessaging.instance.getToken(
        vapidKey: null,
      );
      if (fcmToken == null) return;

      final platform = _currentPlatform();
      await _api.registerFcmToken(jwtToken, fcmToken, platform);

      // Handle token rotation — Firebase periodically refreshes tokens. Cancel
      // first: `initialize` runs per LOGIN, so re-listening without this piles
      // up one live listener per session and re-registers the token N times.
      await _tokenRefreshSubscription?.cancel();
      _tokenRefreshSubscription = FirebaseMessaging.instance.onTokenRefresh
          .listen((newToken) {
            final token = currentJwtToken?.call() ?? jwtToken;
            _api.registerFcmToken(token, newToken, platform).catchError((
              error,
            ) {
              debugPrint(
                '[PushService] FCM token re-registration failed: $error',
              );
            });
          });

      if (defaultTargetPlatform == TargetPlatform.android) {
        await push_android.initAndroidFcmLocalNotificationsOnMainIsolate();
        push_android.setAndroidNotificationConversationTapHandler(
          onNavigateToConversation,
        );

        await push_android.deliverPendingLocalNotificationTapIfAny(
          onConversationId: (id) {
            onNavigateToConversation?.call(id);
          },
        );

        // Same stickiness as the launch-details read above (#175): a
        // terminated-state open is a COLD-START fact, but `initialize` runs on
        // every login, so an unlatched re-read hands the previous account's
        // conversation id to the next one. Process-level, not per-instance:
        // a new PushService per login would reset a field.
        if (!_coldStartFcmOpenDelivered) {
          _coldStartFcmOpenDelivered = true;
          final initial = await FirebaseMessaging.instance.getInitialMessage();
          if (initial != null) {
            push_android.handleFcmRemoteMessageOpen(
              initial,
              onConversationId: (id) => onNavigateToConversation?.call(id),
            );
          }
        }

        await _androidFcmOpenedSubscription?.cancel();
        _androidFcmOpenedSubscription = FirebaseMessaging.onMessageOpenedApp
            .listen((message) {
              push_android.handleFcmRemoteMessageOpen(
                message,
                onConversationId: (id) => onNavigateToConversation?.call(id),
              );
            });
      }
    } catch (_) {
      // Push setup failed (Firebase not configured, no permission, etc.) — silently ignored
    }
  }

  /// Unregister FCM token from the server and delete it from Firebase.
  /// Call on logout BEFORE clearing the JWT.
  Future<void> unregister(String jwtToken) async {
    if (kIsWeb) {
      await _unregisterWebPush(jwtToken);
      return;
    }
    try {
      await _androidFcmOpenedSubscription?.cancel();
      _androidFcmOpenedSubscription = null;
      await _tokenRefreshSubscription?.cancel();
      _tokenRefreshSubscription = null;
      push_android.setAndroidNotificationConversationTapHandler(null);

      final fcmToken = await FirebaseMessaging.instance.getToken(
        vapidKey: null,
      );
      if (fcmToken != null) {
        await _api.removeFcmToken(jwtToken, fcmToken);
      }
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {
      // Best-effort — don't block logout
    }
  }

  Future<WebPushRequestResult> requestWebPushFromUserGesture(
    String jwtToken,
  ) async {
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
      await _api.registerWebPushSubscription(jwtToken, payload);
      webPushNeedsTap.value = false;
      return const WebPushRequestResult(WebPushRequestStatus.subscribed);
    } catch (e) {
      return WebPushRequestResult(
        WebPushRequestStatus.failed,
        details: e.toString(),
      );
    }
  }

  Future<void> _registerExistingWebSubscription(String jwtToken) async {
    if (!_webPushBridge.isSupported) return;
    if (_webPushBridge.notificationPermission != 'granted') return;

    try {
      final payload = await _webPushBridge.registerExistingSubscription(
        vapidPublicKey: _vapidKey,
      );
      webPushNeedsTap.value =
          payload == null && _webPushBridge.isStandaloneOrNotRequired();
      if (payload == null) return;
      await _api.registerWebPushSubscription(jwtToken, payload);
    } catch (_) {
      // Best-effort only on startup/reconnect.
    }
  }

  Future<void> _unregisterWebPush(String jwtToken) async {
    if (!_webPushBridge.isSupported) return;
    webPushNeedsTap.value = false;
    try {
      final endpoint = await _webPushBridge.unsubscribe();
      if (endpoint != null) {
        await _api.removeWebPushSubscription(jwtToken, endpoint);
      }
    } catch (_) {
      // Best-effort — don't block logout.
    }
  }

  static String _currentPlatform() {
    if (kIsWeb) return 'web';
    if (defaultTargetPlatform == TargetPlatform.iOS) return 'ios';
    return 'android'; // Android or any other native platform
  }
}
