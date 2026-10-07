/// Non-web stub — Web Push is only used on `dart:library.html` builds.
class WebPushBridge {
  bool get isSupported => false;

  bool isStandaloneOrNotRequired() => false;

  String get notificationPermission => 'denied';

  Future<Map<String, dynamic>?> registerExistingSubscription({
    required String vapidPublicKey,
    String? userAgent,
  }) async =>
      null;

  Future<Map<String, dynamic>?> requestSubscriptionFromUserGesture({
    required String vapidPublicKey,
    String? userAgent,
  }) async =>
      null;

  Future<String?> unsubscribe() async => null;

  Future<String?> boxToken() async => null;

  bool get pageVisible => false;

  Stream<String> get boxChallengeCodes => const Stream.empty();

  Stream<void> get subscriptionChanged => const Stream.empty();

  void listenForNotificationClicks(
      void Function(int? conversationId) handler) {}
}

WebPushBridge createWebPushBridge() => WebPushBridge();
