import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;
import '../utils/web_ios_webkit_web.dart';

@JS()
extension type _NavigatorStandalone(JSObject _) {
  external bool? get standalone;
}

class WebPushBridge {
  static const String _serviceWorkerPath = '/web-push-sw.js';
  static const String _serviceWorkerScope = '/web-push-scope/';

  bool get isSupported {
    return web.window.isSecureContext &&
        _navigatorHas('serviceWorker') &&
        _windowHas('Notification');
  }

  /// Whether the platform's "must be standalone PWA" requirement for Web Push
  /// is satisfied (or not applicable).
  ///
  /// Only iOS Safari/WebKit refuses to subscribe a tab to Web Push; it
  /// requires the page to be added to the Home Screen and launched in
  /// standalone display mode. Every other engine (Chrome / Edge / Firefox /
  /// Comet on desktop and Android) can subscribe from a regular tab in any
  /// secure context, so we let them through.
  bool isStandaloneOrNotRequired() {
    if (!isIOSWebKit()) return true;
    if (web.window.matchMedia('(display-mode: standalone)').matches) {
      return true;
    }
    try {
      if (_NavigatorStandalone(web.window.navigator as JSObject).standalone ==
          true) {
        return true;
      }
    } catch (_) {
      // navigator.standalone is iOS Safari–only; ignore on engines that lack it.
    }
    return false;
  }

  String get notificationPermission => web.Notification.permission;

  Future<Map<String, dynamic>?> registerExistingSubscription({
    required String vapidPublicKey,
    String? userAgent,
  }) async {
    if (!isSupported || notificationPermission != 'granted') return null;
    final registration = await _registerServiceWorker();
    final subscription =
        await registration.pushManager.getSubscription().toDart;
    return _toPayload(subscription, userAgent);
  }

  Future<Map<String, dynamic>?> requestSubscriptionFromUserGesture({
    required String vapidPublicKey,
    String? userAgent,
  }) async {
    if (!isSupported) return null;
    final permission = (await web.Notification.requestPermission().toDart).toDart;
    if (permission != 'granted') return null;

    final registration = await _registerServiceWorker();
    var subscription =
        await registration.pushManager.getSubscription().toDart;
    final created = subscription == null;
    subscription ??=
        await _subscribe(registration, vapidPublicKey);
    if (created) _subscriptionChanged.add(null);
    return _toPayload(subscription, userAgent);
  }

  /// This browser's push subscription as the box takes it (E9):
  /// `PushSubscription.toJSON()`, JSON-encoded, with nothing the box's parser
  /// refuses (it takes `endpoint`, `keys` and `expirationTime` only — never
  /// the `userAgent` the account-side registration adds). Null without a
  /// subscription or permission.
  Future<String?> boxToken() async {
    if (!isSupported || notificationPermission != 'granted') return null;
    final registration = await _registerServiceWorker();
    final subscription =
        await registration.pushManager.getSubscription().toDart;
    final payload = _toPayload(subscription, null);
    if (payload == null) return null;
    return jsonEncode({
      'endpoint': payload['endpoint'],
      'keys': payload['keys'],
      'expirationTime': payload['expirationTime'],
    });
  }

  /// Whether this page is on screen: the push SW hands a challenge code to
  /// open pages, and posts no notification only for a visible one.
  bool get pageVisible => web.document.visibilityState == 'visible';

  static final StreamController<String> _boxChallengeCodes =
      StreamController.broadcast();
  static final StreamController<void> _subscriptionChanged =
      StreamController.broadcast();

  /// The code of every `notifier_challenge` push the SW forwarded. Empty
  /// where push is unsupported: `navigator.serviceWorker` is undefined in an
  /// insecure context and in some in-app WebViews, and touching it throws.
  Stream<String> get boxChallengeCodes {
    if (!isSupported) return const Stream.empty();
    _listenToWorker();
    return _boxChallengeCodes.stream;
  }

  /// The subscription may be new or different (the SW's
  /// `pushsubscriptionchange`, a subscribe from a user gesture), or the page
  /// came back on screen — when a challenge can be taken again. Empty where
  /// push is unsupported, as [boxChallengeCodes].
  Stream<void> get subscriptionChanged {
    if (!isSupported) return const Stream.empty();
    _listenToWorker();
    return _subscriptionChanged.stream;
  }

  static bool _workerListenerRegistered = false;

  static void _listenToWorker() {
    if (_workerListenerRegistered) return;
    _workerListenerRegistered = true;
    final container = web.window.navigator.serviceWorker as JSObject
      ..callMethod<JSAny?>(
        'addEventListener'.toJS,
        'message'.toJS,
        ((JSObject event) {
          try {
            final data = event.getProperty<JSObject?>('data'.toJS);
            if (data == null) return;
            final type = data.getProperty<JSAny?>('type'.toJS).dartify();
            if (type == 'box-notifier-challenge') {
              final code = data.getProperty<JSAny?>('code'.toJS).dartify();
              if (code is String) _boxChallengeCodes.add(code);
            } else if (type == 'push-subscription-change') {
              _subscriptionChanged.add(null);
            }
          } on Object {
            // A message this page cannot read is not ours to act on.
          }
        }).toJS,
      );
    web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        if (web.document.visibilityState == 'visible') {
          _subscriptionChanged.add(null);
        }
      }).toJS,
    );
    // The same WebKit rule as [listenForNotificationClicks]: messages stay
    // queued until startMessages() (idempotent).
    try {
      container.callMethod<JSAny?>('startMessages'.toJS);
    } on Object {
      // Engines without startMessages() deliver without it.
    }
  }

  Future<String?> unsubscribe() async {
    if (!isSupported) return null;
    final registration = await _registerServiceWorker();
    final subscription =
        await registration.pushManager.getSubscription().toDart;
    if (subscription == null) return null;
    final endpoint = subscription.endpoint;
    await subscription.unsubscribe().toDart;
    return endpoint;
  }

  Future<web.ServiceWorkerRegistration> _registerServiceWorker() {
    return web.window.navigator.serviceWorker
        .register(
          _serviceWorkerPath.toJS,
          web.RegistrationOptions(scope: _serviceWorkerScope),
        )
        .toDart;
  }

  Future<web.PushSubscription> _subscribe(
    web.ServiceWorkerRegistration registration,
    String vapidPublicKey,
  ) {
    final keyBytes = _base64UrlToUint8List(vapidPublicKey);
    return registration.pushManager
        .subscribe(
          web.PushSubscriptionOptionsInit(
            userVisibleOnly: true,
            applicationServerKey: keyBytes.toJS,
          ),
        )
        .toDart;
  }

  Map<String, dynamic>? _toPayload(
    web.PushSubscription? subscription,
    String? userAgent,
  ) {
    if (subscription == null) return null;
    final p256dhBuffer = subscription.getKey('p256dh');
    final authBuffer = subscription.getKey('auth');
    if (p256dhBuffer == null || authBuffer == null) {
      return null;
    }

    return {
      'endpoint': subscription.endpoint,
      'keys': {
        'p256dh': _toBase64Url(_bytesFromArrayBuffer(p256dhBuffer)),
        'auth': _toBase64Url(_bytesFromArrayBuffer(authBuffer)),
      },
      'expirationTime': subscription.expirationTime,
      'userAgent': userAgent ?? web.window.navigator.userAgent,
    };
  }

  bool _navigatorHas(String property) =>
      (web.window.navigator as JSObject).hasProperty(property.toJS).toDart;

  bool _windowHas(String property) =>
      (web.window as JSObject).hasProperty(property.toJS).toDart;

  Uint8List _bytesFromArrayBuffer(JSArrayBuffer buffer) =>
      Uint8List.view(buffer.toDart);

  Uint8List _base64UrlToUint8List(String value) {
    final output = base64Url.normalize(value);
    return base64Url.decode(output);
  }

  String _toBase64Url(Uint8List bytes) {
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  // Tracks whether the SW 'message' listener has been registered.
  static bool _clickListenerRegistered = false;

  /// Register a listener on navigator.serviceWorker 'message' events.
  /// Filters on `type == 'push-notification-click'` and calls [handler] with the
  /// conversationId (null if absent). Safe to call multiple times — only registers once.
  void listenForNotificationClicks(
      void Function(int? conversationId) handler) {
    if (_clickListenerRegistered) return;
    _clickListenerRegistered = true;

    (web.window.navigator.serviceWorker as JSObject).callMethod<JSAny?>(
      'addEventListener'.toJS,
      'message'.toJS,
      ((JSObject event) {
        try {
          final data = event.getProperty<JSObject?>('data'.toJS);
          if (data == null) return;
          final type = data.getProperty<JSString?>('type'.toJS)?.toDart;
          if (type != 'push-notification-click') return;
          final convIdJs = data.getProperty<JSAny?>('conversationId'.toJS);
          int? convId;
          if (convIdJs != null) {
            final raw = convIdJs.dartify();
            if (raw is num) convId = raw.toInt();
          }
          handler(convId);
        } catch (_) {}
      }).toJS,
    );

    // REQUIRED: with addEventListener (vs the onmessage setter) the spec keeps
    // client messages queued until startMessages() is called — WebKit enforces
    // this strictly, so without it the SW's notification-click postMessage is
    // queued forever and taps never navigate (iOS PWA Bug 2).
    try {
      (web.window.navigator.serviceWorker as JSObject)
          .callMethod<JSAny?>('startMessages'.toJS);
    } catch (_) {}
  }

}

WebPushBridge createWebPushBridge() => WebPushBridge();
