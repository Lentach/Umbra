import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'fcm_background_stub.dart'
    if (dart.library.io) 'services/android_fcm_local_notifications.dart'
    as fcm_background;
import 'utils/notify_conv_param_stub.dart'
    if (dart.library.html) 'utils/notify_conv_param_web.dart';
import 'utils/link_fragment_stub.dart'
    if (dart.library.html) 'utils/link_fragment_web.dart';
import 'services/device_link/pending_link_code.dart';
import 'utils/pending_deep_link_stub.dart'
    if (dart.library.html) 'utils/pending_deep_link_web.dart';
import 'l10n/app_localizations.dart';
import 'providers/auth_provider.dart';
import 'providers/connection_provider.dart';
import 'providers/conversations_provider.dart';
import 'providers/encryption_provider.dart';
import 'providers/friends_provider.dart';
import 'providers/messaging_provider.dart';
import 'providers/passcode_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/auth_screen.dart';
import 'screens/device_link_gate_screen.dart';
import 'screens/main_shell.dart';
import 'services/content_key_canary.dart';
import 'services/portrait_lock_service.dart';
import 'theme/app_scroll_behavior.dart';
import 'utils/storage_persist.dart';
import 'utils/e2e_persistent_diag.dart';
import 'utils/web_document_background.dart';
import 'utils/device_link_route_guard.dart';
import 'widgets/boot_honeycomb.dart';
import 'widgets/portrait_lock_shell.dart';
import 'widgets/passcode_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PortraitLockService.initialize();
  // Firebase + FCM background handler must be ready before [runApp] (native only).
  // Android auto-init from google-services can exist before Dart sees Firebase.apps.
  if (!kIsWeb) {
    // Push is a NON-CRITICAL dependency: a Firebase/FCM init failure must never
    // crash the whole app to a blank screen before runApp. Record it and boot
    // without push instead of rethrowing.
    try {
      if (Firebase.apps.isEmpty) {
        // No options: Android's default FirebaseApp comes from the committed
        // google-services.json via the google-services Gradle plugin. Passing
        // Dart-side options here read the PLACEHOLDER firebase_secrets values,
        // so a clean-checkout APK initialized Firebase with a bogus appId and
        // push silently died. iOS will use GoogleService-Info.plist the same
        // way when it exists.
        await Firebase.initializeApp();
      }
    } on FirebaseException catch (e) {
      // duplicate-app is benign (Android google-services auto-init races Dart).
      if (e.code != 'duplicate-app') {
        debugPrint('[main] Firebase init failed (booting without push): $e');
      }
    } catch (e) {
      debugPrint('[main] Firebase init failed (booting without push): $e');
    }
    // Only wire the background handler if Firebase actually came up.
    if (Firebase.apps.isNotEmpty) {
      try {
        FirebaseMessaging.onBackgroundMessage(
          fcm_background.firebaseMessagingBackgroundHandler,
        );
      } catch (e) {
        debugPrint('[main] FCM background handler wiring failed: $e');
      }
    }
  }
  // Always consume the SW-written IndexedDB record (read + delete) so it can
  // never re-fire on a later launch; iOS killed-PWA cold start arrives with no
  // URL param (start_url), so the record is the only deep-link carrier there.
  final pendingDeepLinkConvId = await consumePendingNotificationDeepLink();
  final coldStartConvId = consumeNotifyConvParam() ?? pendingDeepLinkConvId;
  stripNotifyConvParam();
  // A QR scanned by a phone camera lands here as `/link#fp-link.v1.…`. Park
  // the code for the devices screen and scrub the URL — the code is one-shot
  // and must not survive a refresh or sit in history.
  final linkFragment = consumeLinkFragment();
  if (linkFragment != null) PendingLinkCode.arm(linkFragment);
  stripLinkFragment();
  // Load the durable E2E failure log (survives restarts) before the UI mounts.
  await E2ePersistentDiag.init();
  // Measure WebCrypto-backed secure-store durability without delaying first paint.
  ContentKeyCanary().checkAndArm().ignore();
  // Ask the browser for persistent (eviction-proof) storage at every boot —
  // not only mid-E2E-flow. A whole-origin eviction wiped a user's tokens AND
  // Signal identity (2026-07-24 incident); installed PWAs are usually granted
  // this silently. Awaited with a hard bound (08-16 handoff §5.3): firing it
  // unawaited meant the keystore could be created before persistence was even
  // requested, and every field `granted: true` reading was post-loss. Boot
  // still cannot hang on a browser prompt — 3 s and we move on.
  try {
    final r = await requestPersistentStorage().timeout(
      const Duration(seconds: 3),
      onTimeout: () => const {'supported': false, 'granted': false},
    );
    if (r['granted'] != true) {
      E2ePersistentDiag.record('STORAGE_NOT_PERSISTENT', {
        'supported': r['supported'] ?? false,
      });
    }
  } catch (_) {}
  // Resolve the saved theme BEFORE runApp so frame 1 paints the right theme:
  // without this, returning users flash the fresh-install default (Hot Stone)
  // for a frame while the async prefs load runs. NON-CRITICAL: a prefs/plugin
  // failure must never block boot — pass null so the app boots on the
  // fresh-install default (Hot Stone field initializer) while the provider's
  // own async load retries the read.
  String? initialTheme;
  try {
    initialTheme = await SettingsProvider.storedThemePreference();
  } catch (e) {
    debugPrint('[main] theme preference read failed, will retry async: $e');
  }
  runApp(
    FireplaceApp(
      coldStartConversationId: coldStartConvId,
      initialThemePreference: initialTheme,
    ),
  );
}

class FireplaceApp extends StatefulWidget {
  const FireplaceApp({
    super.key,
    this.coldStartConversationId,
    this.initialThemePreference,
  });

  final int? coldStartConversationId;

  /// Resolved saved theme passed by [main] so the first frame already wears
  /// it; null (tests) falls back to the provider's async prefs load.
  final String? initialThemePreference;

  @override
  State<FireplaceApp> createState() => _FireplaceAppState();
}

class _FireplaceAppState extends State<FireplaceApp> {
  /// Built once, from the provider instance that lives for the app's life —
  /// a NavigatorObserver outlives any single build (issue #175).
  DeviceLinkGateRouteGuard? _gateGuard;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(
          create: (_) =>
              SettingsProvider(
                initialThemePreference: widget.initialThemePreference,
              ),
        ),
        ChangeNotifierProvider(create: (_) => EncryptionProvider()),
        ChangeNotifierProvider(create: (_) => FriendsProvider()),
        ChangeNotifierProvider(create: (_) => ConversationsProvider()),
        ChangeNotifierProvider(create: (_) => MessagingProvider()),
        ChangeNotifierProvider(
          create: (_) => ConnectionProvider(
            coldStartConversationId: widget.coldStartConversationId,
          ),
        ),
        // 8th provider (was 7): the app-level Passcode Lock. Reads its
        // credential immediately so `PasscodeGate` can hold the first frame
        // instead of flashing the shell on a locked cold start.
        ChangeNotifierProvider(
          create: (_) => PasscodeProvider()..initialize().ignore(),
        ),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, _) {
          _gateGuard ??= DeviceLinkGateRouteGuard(
            context.read<EncryptionProvider>(),
          );
          return MaterialApp(
            title: 'Umbra',
            debugShowCheckedModeBanner: false,
            scrollBehavior: const AppScrollBehavior(),
            builder: (context, child) {
              // Android PWA white-void fix: keep the browser document painted
              // in the ACTIVE theme background so the strip Chrome exposes
              // while the window resizes around the keyboard is never white
              // (rationale in utils/web_document_background.dart). Theme.of
              // resolves the effective light/dark theme here.
              syncWebDocumentBackground(
                Theme.of(context).scaffoldBackgroundColor,
              );
              return PortraitLockShell(
                child: PasscodeGate(child: child ?? const SizedBox.shrink()),
              );
            },
            theme: settings.lightTheme,
            darkTheme: settings.darkTheme,
            themeMode: settings.themeMode,
            locale: settings.locale,
            supportedLocales: const [Locale('pl'), Locale('en')],
            localizationsDelegates: const [
              ...AppLocalizations.localizationsDelegates,
            ],
            navigatorObservers: [_gateGuard!],
            home: const AuthGate(),
          );
        },
      ),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _previousLoggedInState = false;
  bool _previousGated = false;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final conn = context.read<ConnectionProvider>();

    // The server can end this device's session (multi-device spec §5.5): the
    // primary revoked it. Wired here because this is the one place that holds
    // the connection, the auth session and the locale at once. Logout
    // semantics — the local history and Signal keys stay (spec §1 non-goal).
    final l10n = AppLocalizations.of(context);
    conn.onDeviceRevoked = (reason) => auth.logoutBecauseDeviceRevoked(
      // (lxxviii): a phrase restore elsewhere is not a takeover and not a
      // deliberate revocation — word the sign-out accordingly.
      reason == 'restored'
          ? l10n.deviceRevokedRestoredNotice
          : l10n.deviceRevokedNotice,
    );

    // The mirror case (spec §6.2): a reset teardown re-homed this account onto
    // a NEWLY allocated device and handed back the session bound to it. Same
    // storage path as login and as the §5.1 provisioning rebind — a second
    // token path would drift. Without this the recovering device publishes its
    // pre-keys under the device the teardown just revoked.
    conn.onSessionRebound = auth.adoptProvisionedSession;

    // Detect logout transition (true → false) - ensure clean disconnect, and
    // pop every route pushed above this gate. Amendment (lxvi) clause 1: a
    // SERVER-initiated end (§5.5 `deviceRevoked`) lands while the user may be
    // inside a pushed chat or the devices screen; swapping this subtree to
    // AuthScreen leaves that route on top, rendering a blank surface over the
    // very notice that tells the user what to do next.
    if (!auth.isLoggedIn && _previousLoggedInState) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        conn.disconnect(isLogout: true);
        if (!mounted) return;
        Navigator.of(context).popUntil((route) => route.isFirst);
      });
    }

    _previousLoggedInState = auth.isLoggedIn;

    if (auth.isRestoringSession) {
      return const Scaffold(body: Center(child: BootHoneycomb()));
    }

    if (auth.isLoggedIn) {
      // (lxxiii) clause 3: an enrolled account that lost its keys (or whose
      // guard could not be asked) meets a GATE, not a banner. MainShell stays
      // MOUNTED but Offstage — the socket, the guard's own round trip and the
      // reset hydration all live under the shell; unmounting it would starve
      // the gate of the very state that opens it. The gate is not a pushed
      // route, so the (lxvi) clause-1 popUntil on logout is unaffected.
      final gated = context.select<EncryptionProvider, bool>(
        (e) => e.needsDeviceLink || e.identityCheckUnavailable,
      );
      // TWO defences, because they cover opposite directions (issue #175):
      //
      // 1. Here: routes ALREADY on the stack when the verdict lands (a
      //    reconnect init after a mid-session wipe leaves the user inside a
      //    chat or the devices screen). Edge-triggered, because that is when
      //    the stack changes meaning.
      // 2. `DeviceLinkGateRouteGuard` on the root navigator: routes pushed
      //    AFTER the verdict. A push does not rebuild `AuthGate`, so this
      //    build-time branch cannot see them — and `MainShell` keeps building
      //    under `Offstage` while gated, which is exactly how a chat got
      //    pushed over the gate on the 0.2.41 APK.
      //
      // Both keep non-page routes (dialogs, sheets) and the ceremony's own
      // scanner — see `gateKeepsRoute`.
      if (gated && !_previousGated) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.of(context).popUntil(gateKeepsRoute);
        });
      }
      _previousGated = gated;
      return Stack(
        children: [
          Offstage(offstage: gated, child: const MainShell()),
          if (gated) const DeviceLinkGateScreen(),
        ],
      );
    }
    _previousGated = false;
    return const AuthScreen();
  }
}
