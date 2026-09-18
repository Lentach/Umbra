import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'contacts_screen.dart';
import 'conversations_screen.dart';
import 'settings_screen.dart';
import 'devices_screen.dart';
import '../services/device_link/pending_link_code.dart';
import '../l10n/app_localizations.dart';
import '../constants/app_constants.dart';
import '../providers/auth_provider.dart';
import '../providers/connection_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/passcode_provider.dart';
import '../providers/friends_provider.dart';
import 'chat_detail_screen.dart';
import '../utils/pending_deep_link_stub.dart'
    if (dart.library.html) '../utils/pending_deep_link_web.dart';
import '../utils/page_lifecycle_stub.dart'
    if (dart.library.html) '../utils/page_lifecycle_web.dart';
import '../utils/e2e_diag_log.dart';
import '../utils/tab_visibility.dart';
import '../utils/instant_opaque_route.dart';
import '../utils/notification_nav_decision.dart';
import '../services/unread_badge_sync.dart';
import '../services/encryption/native_content_store.dart';
import '../widgets/top_snackbar.dart';
import '../widgets/input/composer_keyboard_signals.dart';
import '../widgets/console_glyphs.dart';
import '../widgets/glass/glass_bottom_nav.dart';
import '../widgets/own_identity_replaced_banner.dart';
import '../widgets/identity_reset_pending_banner.dart';
import '../widgets/update_available_banner.dart';
import 'user_card_screen.dart';

/// Shell after login: bottom nav with Conversations, Contacts, Settings.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  StreamSubscription<dynamic>? _tabVisibilitySub;
  StreamSubscription<dynamic>? _pageResumeSub;
  StreamSubscription<dynamic>? _freezeReloadSub;
  UnreadBadgeSync? _unreadBadgeSync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      final conn = context.read<ConnectionProvider>();
      auth.setOnAccessTokenChanged(conn.applyRefreshedAccessToken);
      // A QR scanned by the phone camera booted us at `/link#<code>`: route
      // straight to the devices screen, which consumes the code once it
      // knows this install holds the DAK. Pushed on the ROOT navigator, above
      // the shell, like the settings path does.
      if (PendingLinkCode.isArmed && mounted) {
        Navigator.of(
          context,
          rootNavigator: true,
        ).push(MaterialPageRoute(builder: (_) => const DevicesScreen()));
      }
    });
    if (kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _unreadBadgeSync = UnreadBadgeSync(
          context.read<ConversationsProvider>(),
        );
      });
    }
    WidgetsBinding.instance.addObserver(this);
    if (kIsWeb) {
      _tabVisibilitySub = registerTabVisibilityListener((visible) {
        if (!mounted) return;
        E2eDiagLog.add('TAB_VIS', {'visible': visible});
        final auth = context.read<AuthProvider>();
        // On web this listener is the reliable background/foreground signal
        // (Flutter's lifecycle events are thinner in the browser), so the
        // passcode clock is driven from BOTH here and
        // didChangeAppLifecycleState. Both paths are idempotent.
        if (!visible) {
          unawaited(context.read<PasscodeProvider>().noteBackgrounded());
          if (auth.currentUser != null && auth.token != null) {
            context.read<ConversationsProvider>().setClientVisible(false);
          }
          return;
        }
        unawaited(context.read<PasscodeProvider>().evaluateOnForeground());
        unawaited(_recoverForeground(markVisible: true));
      });
      // bfcache restore: the snapshot is coherent, only the socket is dead —
      // soft recovery. `resume` after a TAB FREEZE is different: the thawed
      // Flutter engine is untrustworthy (mid-screen composer, lag, dead chat
      // — field bug on 0.1.18, users 48/90), so a frozen page is REPLACED via
      // the freeze-reload guard below, mimicking the swipe-close + icon
      // relaunch users prove works. The pending deep-link survives in
      // IndexedDB; the loop guard degrades to this same soft recovery.
      _pageResumeSub = registerPageShowRecoveryListener(() {
        if (!mounted) return;
        E2eDiagLog.add('PAGE_RESUME', {'source': 'pageshow'});
        unawaited(_recoverForeground(markVisible: false));
      });
      _freezeReloadSub = installFreezeReloadGuard(
        onFallbackRecover: () {
          if (!mounted) return;
          E2eDiagLog.add('PAGE_RESUME', {'source': 'freeze-loop-guard'});
          unawaited(_recoverForeground(markVisible: false));
        },
        // The attachment camera/file dialog backgrounds the tab and freezes
        // the page; reloading on that resume would destroy the pending
        // <input type=file> and the picked bytes. Soft-recover instead while
        // the picker surface is up (emulator-proven 2026-08-21).
        suppressReload: () => composerNativePickerActive.value,
      );
      if (consumeFrozenReloadMarker()) {
        // This boot IS the replacement of a frozen page — the only surviving
        // evidence, since the RAM diag log died with the reloaded page.
        E2eDiagLog.add('BOOT_AFTER_FROZEN', {});
      }
    }
  }

  Future<void> _recoverForeground({required bool markVisible}) async {
    final auth = context.read<AuthProvider>();
    await auth.ensureSessionReady();
    if (!mounted) return;
    if (!auth.isLoggedIn) return;
    // Only a real visibility signal may claim "user is looking": a background
    // unfreeze must not re-enable read receipts or server push suppression.
    if (markVisible) {
      context.read<ConversationsProvider>().setClientVisible(true);
    }
    context.read<ConnectionProvider>().ensureReconnectIfNeeded();
    // iOS PWA: a notification tap on a suspended WebView loses the SW's
    // click postMessage — the SW also persisted the target conversation
    // to IndexedDB, so drain it now that the tab is visible again.
    final pendingConvId = await consumePendingNotificationDeepLink();
    if (pendingConvId != null && mounted) {
      context
          .read<ConversationsProvider>()
          .requestNavigateToConversationFromNotification(pendingConvId);
    }
  }

  void _openMyProfile() {
    final user = context.read<AuthProvider>().currentUser;
    if (user == null) return;
    Navigator.of(context).push(
      instantOpaqueRoute(
        builder: (_) => UserCardScreen(
          data: UserCardVisualData.fromUser(
            user,
            isSelf: true,
            hasConversation: false,
          ),
        ),
      ),
    );
  }

  void _openAcceptedConversation(int conversationId) {
    if (!mounted) return;

    if (MediaQuery.of(context).size.width >=
        AppConstants.layoutBreakpointDesktop) {
      setState(() => _selectedIndex = 0);
      context.read<ConversationsProvider>().openConversation(conversationId);
      return;
    }

    Navigator.of(context).push(
      instantOpaqueRoute(
        builder: (_) => ChatDetailScreen(conversationId: conversationId),
      ),
    );
  }

  @override
  void dispose() {
    final badge = _unreadBadgeSync;
    _unreadBadgeSync = null;
    if (badge != null) {
      unawaited(badge.dispose());
    }
    _tabVisibilitySub?.cancel();
    _pageResumeSub?.cancel();
    _freezeReloadSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final auth = context.read<AuthProvider>();
    E2eDiagLog.add('LIFECYCLE', {
      'state': state.name,
      'loggedIn': auth.currentUser != null,
    });
    if (auth.currentUser == null || auth.token == null) return;

    switch (state) {
      case AppLifecycleState.resumed:
        // Ordered FIRST: the lock verdict must be taken before any reconnect
        // or resync work paints anything behind it.
        unawaited(context.read<PasscodeProvider>().evaluateOnForeground());
        unawaited(() async {
          await auth.ensureSessionReady();
          if (!mounted) return;
          context.read<ConnectionProvider>().ensureReconnectIfNeeded();
          context.read<ConversationsProvider>().setClientVisible(true);
        }());
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
      case AppLifecycleState.inactive:
        // Treat inactive as background for push: iOS/Android often enter inactive
        // (app switcher, home gesture) before paused; leaving it true kept
        // pushClientState.clientVisible true so the server skipped pushes while
        // the user was no longer looking at the chat.
        context.read<ConversationsProvider>().setClientVisible(false);
        // Owed shred rotation: fire now instead of waiting out the debounce —
        // background is the last CPU this process may ever get. No-op unless
        // a purge stamped an obligation (native only; instance null on web).
        unawaited(
          NativeContentStore.instance?.onAppBackground() ?? Future.value(),
        );
        // Stamp the away-clock on the way OUT: on web this process may never
        // run code again (a frozen page is REPLACED by a reload on thaw, and
        // iOS can kill the PWA outright), so the persisted stamp is the only
        // thing the next boot can reason from.
        unawaited(context.read<PasscodeProvider>().noteBackgrounded());
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Consumer2<FriendsProvider, ConversationsProvider>(
      builder: (context, friends, convs, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final accepted = context
              .read<FriendsProvider>()
              .consumePendingFriendAccepted();
          if (accepted == null) return;

          final l10n = AppLocalizations.of(context);
          final message = l10n.friendAcceptedYourRequest(accepted.name);
          if (accepted.chatReady && accepted.conversationId != null) {
            showTopSnackBar(
              context,
              message,
              onTap: () => _openAcceptedConversation(accepted.conversationId!),
              actionLabel: l10n.invitationOpenChat,
            );
          } else {
            showTopSnackBar(context, message);
          }
        });
        // Notification deep-link — Option A: route through the SAME open path
        // the conversations list uses, and only for conversations that exist
        // locally. Gated on the first server snapshot: consuming earlier would
        // either race an empty list (cold start) or mount a chat for a stale
        // id from an old notification (deleted conversation) — such a screen
        // renders empty and sendMessage finds no conversation, so typed text
        // vanished. Stale id ⇒ land on the conversations tab and stop.
        if (shouldConsumeNotificationNav(
          pendingConversationId: convs.pendingNotificationConversationId,
          hasLoadedConversationsOnce: convs.hasLoadedConversationsOnce,
        )) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final provider = context.read<ConversationsProvider>();
            final id = provider.consumePendingNotificationConversationId();
            final decision = decideNotificationNav(
              consumedId: id,
              conversationExistsLocally:
                  id != null && provider.getConversationById(id) != null,
              isDesktop:
                  MediaQuery.of(context).size.width >=
                  AppConstants.layoutBreakpointDesktop,
              isAlreadyActive: provider.activeConversationId == id,
            );
            if (decision.switchToConversationsTab) {
              setState(() => _selectedIndex = 0);
            }
            if (decision.action == NotificationNavAction.setActiveDesktop) {
              provider.setActiveConversation(id!);
            } else if (decision.action ==
                NotificationNavAction.pushMobileChat) {
              Navigator.of(context).pushAndRemoveUntil(
                instantOpaqueRoute<void>(
                  builder: (_) => ChatDetailScreen(conversationId: id!),
                ),
                (route) => route.isFirst,
              );
            }
          });
        }
        return _buildScaffold(context, theme, colorScheme);
      },
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final bottomNavigation = GlassBottomNav(
      currentIndex: _selectedIndex,
      onTap: (index) => setState(() => _selectedIndex = index),
      destinations: [
        GlassNavDestination(
          icon: const ConsoleGlyphIcon(ConsoleGlyph.chats),
          label: AppLocalizations.of(context).chat,
        ),
        GlassNavDestination(
          icon: const ConsoleGlyphIcon(ConsoleGlyph.contacts),
          label: AppLocalizations.of(context).contacts,
        ),
        GlassNavDestination(
          icon: const ConsoleGlyphIcon(ConsoleGlyph.settings),
          label: AppLocalizations.of(context).settings,
        ),
      ],
    );

    return Scaffold(
      extendBody: true,
      // ONE SafeArea for the WHOLE shell — the banner stack AND the tabs.
      // Sibling SafeAreas do not consume the inset for each other: each
      // applies the FULL top inset to its own subtree only
      // (`MediaQuery.removePadding`). The previous shape therefore paid it
      // TWICE — this wrapper sat around the banner stack alone, where it
      // occupies a status-bar height even when both banners render nothing
      // (the normal state), and then `MainTabScreenHeader` applied its own
      // SafeArea inside every tab. On native that showed as a phantom
      // status-bar band above the title capsule (owner-reported 2026-09-14);
      // on web it hid because `padding.top` is 0 there — the PWA shell handles
      // the notch in CSS (`viewport-fit=cover` + `env()`).
      //
      // Consequence for the tabs, and why their scroll padding still reads
      // right: inside this SafeArea `MediaQuery.paddingOf(context).top` is 0,
      // so `media.top + MainTabScreenHeader.clearance` collapses to the
      // clearance alone — which is correct, because the inset is already
      // spent here. Those lists scroll BEHIND the floating header, so they
      // must keep clearing the capsule.
      //
      // `bottom: false` on purpose: the bottom nav consumes `media.bottom`
      // itself under `extendBody: true`.
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Column(
              children: const [
                // The keyless/damaged and (lxiv)-mismatch states now open the
                // (lxxiii) DeviceLinkGateScreen ABOVE this (Offstage) shell —
                // their banners are gone; a banner behind an Offstage shell is
                // dead code.
                // Phase 0a takeover alarm: another sign-in replaced this
                // account's key bundle. Usually a legitimate new device/browser
                // sign-in; durable until dismissed.
                OwnIdentityReplacedBanner(),
                // Phase 0b reset ceremony: a countdown is running toward
                // replacing this account's keys. Above the fold with a one-tap
                // cancel, because the delay only protects anyone who sees it.
                IdentityResetPendingBanner(),
                // A newer sideloaded APK exists. NOT a security banner and
                // deliberately not dressed as one — neutral tone, collapsed,
                // dismissible per build. Renders nothing off Android or when
                // no channel is published.
                UpdateAvailableBanner(),
              ],
            ),
            Expanded(
              child: IndexedStack(
                index: _selectedIndex,
                children: [
                  ConversationsScreen(onAvatarTap: _openMyProfile),
                  const ContactsScreen(),
                  const SettingsScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(top: false, child: bottomNavigation),
    );
  }
}
