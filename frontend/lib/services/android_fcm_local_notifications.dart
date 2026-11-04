import 'dart:ui' show DartPluginRegistrant;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'auth_token_store.dart';
import 'wake_up_revocation_check.dart';


const String _androidChannelId = 'fireplace_messages';
const String _androidChannelName = 'Messages';
const String _androidChannelDescription = 'Alerts for new encrypted chat messages';

final FlutterLocalNotificationsPlugin _mainIsolateNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

final FlutterLocalNotificationsPlugin _backgroundIsolateNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

bool _mainIsolatePluginReady = false;

bool get _isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

bool _backgroundIsolateReady = false;

/// Required FCM background entrypoint (separate isolate).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (kIsWeb) return;
  // Plugins with Dart-side registration (shared_preferences) need it in a
  // background isolate; it is idempotent.
  DartPluginRegistrant.ensureInitialized();
  try {
    if (Firebase.apps.isEmpty) {
      // No options: the background isolate must also use the NATIVE default
      // app (google-services.json), not the placeholder Dart-side options —
      // see main.dart. This isolate can start before main() ever ran.
      await Firebase.initializeApp();
    }
  } on FirebaseException catch (e) {
    if (e.code != 'duplicate-app') rethrow;
  }
  if (!_isAndroid) return;

  if (!_backgroundIsolateReady) {
    await _backgroundIsolateNotificationsPlugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_umbra'),
        iOS: DarwinInitializationSettings(),
      ),
    );
    final android = _backgroundIsolateNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _androidChannelId,
        _androidChannelName,
        description: _androidChannelDescription,
        importance: Importance.high,
      ),
    );
    _backgroundIsolateReady = true;
  }

  // The box's FCM wake-up is `{type:'new_message'}` and nothing else (E9).
  if (message.data['type'] != 'new_message') return;
  await _showWakeUpCard(_backgroundIsolateNotificationsPlugin);
  await _endWakeUpsIfRevoked();
}

/// Prefs-backed pacing state of [RevokedWakeUpCheck]. This isolate keeps its
/// own prefs cache, so every read reloads it.
class _PrefsWakeCheckState implements WakeCheckStateStore {
  static const String _key = 'wake_check_v1';

  @override
  Future<WakeCheckState?> read() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return WakeCheckState.tryParse(prefs.getString(_key));
  }

  @override
  Future<void> write(WakeCheckState state) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_key, state.toJson())) {
      throw StateError('wake-up check state refused');
    }
  }
}

RevokedWakeUpCheck? _wakeUpCheck;

/// Decision 129 (E129a): a closed, revoked device ends its own wake-ups. Runs
/// AFTER the card (the wake-up is never delayed), asks the server whether this
/// install's stored session belongs to a revoked device and, on the explicit
/// answer only, deletes the FCM token (see [RevokedWakeUpCheck]). The queues
/// are not touched: their keys live in the content store the main isolate
/// owns. Never throws — a wake-up is not failed by this.
Future<void> _endWakeUpsIfRevoked() async {
  try {
    final check = _wakeUpCheck ??= RevokedWakeUpCheck(
      refreshToken: () async {
        final stored = await AuthTokenStore().read();
        return stored.readFailed ? null : stored.refresh;
      },
      probe: (token) async {
        final client = http.Client();
        try {
          return await probeSessionStanding(
            client: client,
            baseUrl: AppConfig.baseUrl,
            refreshToken: token,
          );
        } finally {
          client.close();
        }
      },
      dropPushRegistration: () => FirebaseMessaging.instance.deleteToken(),
      state: _PrefsWakeCheckState(),
    );
    debugPrint('[wake-up] revoked-device check: ${(await check.run()).name}');
  } on Object catch (e) {
    debugPrint('[wake-up] revoked-device check failed: ${e.runtimeType}');
  }
}

/// Main isolate: plugin + channel for [showBoxMessageLocalNotification].
Future<void> initAndroidFcmLocalNotificationsOnMainIsolate() async {
  if (!_isAndroid || _mainIsolatePluginReady) return;

  await _mainIsolateNotificationsPlugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    ),
  );

  final android = _mainIsolateNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      _androidChannelId,
      _androidChannelName,
      description: _androidChannelDescription,
      importance: Importance.high,
    ),
  );

  _mainIsolatePluginReady = true;
}

/// The one message card: content-free and naming no chat (id 0, tag
/// `fireplace-message`), so every wake-up replaces the last. Tapping it just
/// opens the app; nothing is routed.
Future<void> _showWakeUpCard(FlutterLocalNotificationsPlugin plugin) {
  return plugin.show(
    id: 0,
    title: 'Umbra',
    body: 'You have a new message',
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        _androidChannelId,
        'Umbra',
        channelDescription: _androidChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        // Status-bar small icon: monochrome white-on-transparent hex mark
        // (res/drawable-*/ic_stat_umbra.png). A full-colour icon here renders
        // as a white square in the status bar.
        icon: '@drawable/ic_stat_umbra',
        tag: 'fireplace-message',
      ),
    ),
  );
}

/// H1 (decision R81, ER81b): a box message journaled while the app is
/// hidden. Content-free and naming no chat — the same id and tag as the card
/// a bare FCM box wake-up shows ([_showWakeUpCard]), so a wake-up and this
/// card are ONE card, and each message replaces the last. Main isolate only:
/// the app is alive, or the box's own push would have woken it.
Future<void> showBoxMessageLocalNotification() async {
  if (!_isAndroid || !_mainIsolatePluginReady) return;
  await _showWakeUpCard(_mainIsolateNotificationsPlugin);
}
