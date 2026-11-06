import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/chat_action_tiles.dart';
import 'package:fireplace/widgets/ping_glyph.dart';
import 'package:fireplace/widgets/emoji/fireplace_emoji_picker.dart';
import 'package:fireplace/widgets/input/chat_input_bar.dart';
import 'package:fireplace/widgets/input/composer_keyboard_signals.dart';
import 'package:fireplace/utils/web_keyboard_inset.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/chat_seed.dart';

Widget _providerScope({
  required Widget child,
  ConversationsProvider? conversations,
}) => MultiProvider(
  providers: [
    if (conversations != null)
      ChangeNotifierProvider<ConversationsProvider>.value(value: conversations)
    else
      ChangeNotifierProvider(create: (_) => ConversationsProvider()),
    ChangeNotifierProvider(create: (_) => MessagingProvider()),
    ChangeNotifierProvider(
      create: (_) => SettingsProvider(initialThemePreference: 'light'),
    ),
  ],
  child: child,
);

Future<ChatInputBarState> _pump(WidgetTester tester) async {
  final key = GlobalKey<ChatInputBarState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: RpgTheme.themeDataLight,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: _providerScope(child: ChatInputBar(key: key)),
      ),
    ),
  );
  await tester.pump();
  return key.currentState!;
}

Future<ChatInputBarState> _pumpWithBottomInset(WidgetTester tester) async {
  final key = GlobalKey<ChatInputBarState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: RpgTheme.themeDataLight,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Builder(
        // Simulate a home-indicator safe area so the ergonomic bottom buffer
        // would render while the keyboard is down.
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(bottom: 34),
            viewPadding: const EdgeInsets.only(bottom: 34),
          ),
          child: Scaffold(
            body: _providerScope(child: ChatInputBar(key: key)),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return key.currentState!;
}

Future<ChatInputBarState> _pumpWithChatSurface(WidgetTester tester) async {
  final key = GlobalKey<ChatInputBarState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: RpgTheme.themeDataLight,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: _providerScope(
          child: Column(
            children: [
              Expanded(
                child: Listener(
                  key: const ValueKey('chat-surface'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) =>
                      key.currentState?.dismissForChatSurfaceTap(),
                  child: const SizedBox.expand(),
                ),
              ),
              ChatInputBar(key: key),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return key.currentState!;
}

Future<ChatInputBarState> _pumpWithPlainOutsideSurface(
  WidgetTester tester,
) async {
  final key = GlobalKey<ChatInputBarState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: RpgTheme.themeDataLight,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: _providerScope(
          child: Column(
            children: [
              Expanded(
                child: Listener(
                  key: const ValueKey('plain-outside-surface'),
                  behavior: HitTestBehavior.opaque,
                  child: const SizedBox.expand(),
                ),
              ),
              ChatInputBar(key: key),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return key.currentState!;
}

/// A ConversationsProvider with one active conversation between users 1 (self)
/// and 2, so the ping tile's active-conversation gate passes on the VM.
ConversationsProvider _activeConversationsProvider() {
  final convs = ConversationsProvider();
  convs.setCurrentUserId(1);
  seedConversations(convs, <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 42,
      'userOne': <String, dynamic>{'id': 1, 'username': 'me', 'tag': '0001'},
      'userTwo': <String, dynamic>{'id': 2, 'username': 'them', 'tag': '0002'},
      'createdAt': DateTime.now().toIso8601String(),
    },
  ]);
  convs.setActiveConversation(42);
  return convs;
}

/// Pumps the composer with an active conversation so ping-tile taps route
/// through the real `_sendPing`/`onPingSent` path.
Future<ChatInputBarState> _pumpWithActiveConversation(
  WidgetTester tester,
) async {
  final key = GlobalKey<ChatInputBarState>();
  final convs = _activeConversationsProvider();
  addTearDown(convs.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: RpgTheme.themeDataLight,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: _providerScope(
          conversations: convs,
          child: ChatInputBar(key: key),
        ),
      ),
    ),
  );
  await tester.pump();
  return key.currentState!;
}

/// Two independent outside surfaces: a chat-surface that routes taps through
/// [ChatInputBarState.dismissForChatSurfaceTap] (panel must survive) and a
/// plain surface whose taps reach the composer TapRegion normally (panel must
/// collapse). Used to prove the chat-surface suppression flag RESETS.
Future<ChatInputBarState> _pumpWithChatSurfaceAndOutside(
  WidgetTester tester,
) async {
  final key = GlobalKey<ChatInputBarState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: RpgTheme.themeDataLight,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: _providerScope(
          child: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Listener(
                        key: const ValueKey('chat-surface'),
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (_) =>
                            key.currentState?.dismissForChatSurfaceTap(),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    Expanded(
                      child: Listener(
                        key: const ValueKey('plain-outside'),
                        behavior: HitTestBehavior.opaque,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                ),
              ),
              ChatInputBar(key: key),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return key.currentState!;
}

Future<void> _openEmojiPanel(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('composer-emoji-toggle')));
  await tester.pumpAndSettle();
  expect(find.byType(FireplaceEmojiPicker), findsOneWidget);
}

void main() {
  setUp(() => composerKeyboardCollapseGuard.value = false);
  tearDown(() {
    composerKeyboardCollapseGuard.value = false;
    composerBottomPanelPinned.value = false;
    setSharedKeyboardInsetSourceForTest(null);
  });

  // Boundary: the empty-text no-op must still precede any send side effect, so it
  // must NOT arm the collapse guard (the guard is armed only on a real send).
  testWidgets('empty send is a no-op and does not arm the collapse guard', (
    tester,
  ) async {
    final state = await _pump(tester);
    state.sendForTest();
    await tester.pump();
    expect(composerKeyboardCollapseGuard.value, isFalse);
  });

  // A real send routes through `_send()` (which dispatches to MessagingProvider)
  // and arms the keyboard collapse guard so the viewport keeps the flash guard.
  testWidgets('non-empty send arms the keyboard collapse guard', (
    tester,
  ) async {
    final state = await _pump(tester);
    await tester.enterText(find.byType(TextField), 'hello');
    state.sendForTest();
    await tester.pump();
    expect(composerKeyboardCollapseGuard.value, isTrue);
  });

  // Android/desktop web parity: tapping the chat surface outside the composer
  // should hide the keyboard. The old blanket no-op was only meant for iOS
  // WebKit send-button bounce, but it blocked Android PWA dismissal too.
  testWidgets('tap outside unfocuses the composer outside iOS WebKit', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);

    field.onTapOutside!(const PointerDownEvent(position: Offset(1, 1)));
    await tester.pump();

    expect(field.focusNode!.hasFocus, isFalse);
  });

  testWidgets(
    'send button tap stays inside composer tap region and keeps focus',
    (tester) async {
      await _pump(tester);
      await tester.enterText(find.byType(TextField), 'send from button');
      await tester.tap(find.byType(TextField));
      await tester.pump();

      final fieldBefore = tester.widget<TextField>(find.byType(TextField));
      expect(fieldBefore.focusNode!.hasFocus, isTrue);

      await tester.tap(find.byKey(const ValueKey('composer_text_send_layer')));
      await tester.pump();

      final fieldAfter = tester.widget<TextField>(find.byType(TextField));
      expect(fieldAfter.focusNode!.hasFocus, isTrue);
      expect(fieldAfter.controller!.text, isEmpty);
    },
  );

  testWidgets(
    'action panel tap stays inside composer tap region and keeps focus',
    (tester) async {
      await _pump(tester);
      await tester.enterText(find.byType(TextField), 'keep keyboard');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();

      expect(find.byType(ChatActionTiles), findsOneWidget);
      final fieldBefore = tester.widget<TextField>(find.byType(TextField));
      expect(fieldBefore.focusNode!.hasFocus, isTrue);

      final actionPanelTopLeft = tester.getTopLeft(
        find.byType(ChatActionTiles),
      );
      await tester.tapAt(actionPanelTopLeft + const Offset(4, 4));
      await tester.pump();

      final fieldAfter = tester.widget<TextField>(find.byType(TextField));
      expect(fieldAfter.focusNode!.hasFocus, isTrue);
    },
  );

  testWidgets(
    'plain outside tap closes the action panel and unfocuses composer',
    (tester) async {
      final state = await _pumpWithPlainOutsideSurface(tester);
      await tester.enterText(find.byType(TextField), 'outside dismisses');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();

      expect(state.isActionPanelOpenForTest, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('plain-outside-surface')));
      await tester.pumpAndSettle();

      expect(state.isActionPanelOpenForTest, isFalse);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse,
      );
    },
  );

  // 2026-07-07 ruling: a chat-surface tap with the lower action panel open now
  // ALWAYS dismisses the keyboard, while the panel itself survives (only the
  // panel is exempt from the tap). The unfocus is gated to non-iOS-WebKit; on
  // the VM isIOSWebKit() is false, so this exercises the Android/desktop path.
  testWidgets(
    'chat surface tap keeps the action panel but dismisses the keyboard (non-iOS)',
    (tester) async {
      final state = await _pumpWithChatSurface(tester);
      await tester.enterText(find.byType(TextField), 'keep lower panel stable');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();

      expect(state.isActionPanelOpenForTest, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('chat-surface')));
      await tester.pumpAndSettle();

      // Panel survives the tap; the keyboard is dismissed (field unfocused).
      expect(state.isActionPanelOpenForTest, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse,
      );
    },
  );

  // D2 fix: MediaQuery.viewInsets reads 0 on iOS WebKit with the keyboard up,
  // so keyboardVisible folds in the shared visualViewport inset. The ergonomic
  // bottom buffer (driven by bottomInteractivePadding, which also sizes the
  // action panel's ChatActionTiles) must collapse to 0 when that inset is up,
  // otherwise the filler renders underneath the raised keyboard. The panel is
  // opened first: since the instant-mount change (H3) ChatActionTiles only
  // exists while the panel is open.
  testWidgets('a raised web keyboard inset removes the ergonomic bottom buffer', (
    tester,
  ) async {
    Future<void> openActionPanel() async {
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pump();
    }

    double buffer() => tester
        .widget<ChatActionTiles>(find.byType(ChatActionTiles))
        .bottomPadding;

    // Keyboard down, bottom safe-area inset present -> ergonomic buffer applied.
    await _pumpWithBottomInset(tester);
    await openActionPanel();
    expect(buffer(), greaterThan(0));

    // Same layout, but the shared source reports a keyboard while viewInsets
    // still reads 0: the buffer must be suppressed.
    setSharedKeyboardInsetSourceForTest(_FakeInsetSource(300));
    await _pumpWithBottomInset(tester);
    await openActionPanel();
    expect(buffer(), 0);
  });

  // H3: the lower action panel is instant-mount (no SizeTransition). A single
  // pump must mount it on open and fully unmount it on close — a lingering
  // animation would keep ChatActionTiles in the tree for a frame after close,
  // so `findsNothing` after one pump is the discriminating assertion.
  testWidgets('action panel mounts and unmounts instantly with a single pump', (
    tester,
  ) async {
    final state = await _pump(tester);
    expect(find.byType(ChatActionTiles), findsNothing);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pump();
    expect(state.isActionPanelOpenForTest, isTrue);
    expect(find.byType(ChatActionTiles), findsOneWidget);

    // Icon flips to keyboard_arrow_up while the panel is open.
    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.pump();
    expect(state.isActionPanelOpenForTest, isFalse);
    expect(find.byType(ChatActionTiles), findsNothing);
  });

  // Focus must NEVER move the composer (owner report 2026-09-12, desktop +
  // mobile screenshots; reverts H1). The ergonomic buffer is resting
  // clearance over the home indicator / bottom nav, so collapsing it on focus
  // shrank the bar and — in the real bottom-anchored layout — slid the input
  // row DOWN by that clearance with nothing lifting it (behind the bottom nav
  // on desktop web, where no soft keyboard ever arrives). Bar height is the
  // observable: only a real keyboard inset may shrink it (test above).
  testWidgets('composer focus leaves the bar geometry untouched', (
    tester,
  ) async {
    await _pumpWithBottomInset(tester);
    final restingHeight = tester.getSize(find.byType(ChatInputBar)).height;

    await tester.tap(find.byType(TextField));
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    expect(tester.getSize(find.byType(ChatInputBar)).height, restingHeight);
  });

  // 07-03 contract, extended 0.0.99: a chat-surface tap with the action panel
  // open suppresses the follow-up composer-TapRegion outside-tap so the panel
  // survives. That suppression flag must RESET post-frame — otherwise every
  // later outside tap would be swallowed and the panel could never be
  // dismissed by tapping away. The 'chat surface tap keeps the action panel'
  // test covers survival; this one guards the reset.
  testWidgets(
    'chat-surface tap suppresses the follow-up outside-collapse but the flag resets',
    (tester) async {
      final state = await _pumpWithChatSurfaceAndOutside(tester);
      await tester.enterText(find.byType(TextField), 'panel stays put');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();
      expect(state.isActionPanelOpenForTest, isTrue);

      // Chat-surface tap: keyboard dismissed, panel survives (follow-up
      // composer-TapRegion outside-tap suppressed).
      await tester.tap(find.byKey(const ValueKey('chat-surface')));
      await tester.pumpAndSettle();
      expect(state.isActionPanelOpenForTest, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse,
      );

      // Flag reset: an independent outside tap now collapses the panel.
      await tester.tap(find.byKey(const ValueKey('plain-outside')));
      await tester.pumpAndSettle();
      expect(state.isActionPanelOpenForTest, isFalse);
    },
  );

  // Ping is keyboard-neutral (2026-07-09): tapping the ping tile must not
  // dismiss a raised keyboard. The panel's Listener captures focus at
  // pointer-down; when it was focused, `_refocusComposerAfterPing` heals the
  // (web-only) DOM blur by re-requesting focus, which arms the collapse guard.
  // The guard flip is the observable proof the gated refocus actually ran
  // (opening the panel does not arm it on the VM).
  testWidgets(
    'ping with the field focused runs the gated refocus and keeps focus',
    (tester) async {
      final state = await _pumpWithActiveConversation(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pump();

      expect(state.isActionPanelOpenForTest, isTrue);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);
      expect(composerKeyboardCollapseGuard.value, isFalse);

      await tester.tap(find.byType(PingGlyph));
      await tester.pump();

      // Gated refocus ran (focus was up at pointer-down) -> guard armed.
      expect(composerKeyboardCollapseGuard.value, isTrue);

      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
    },
  );

  // The refocus is GATED on focus-at-pointer-down: a ping from the panel-open,
  // keyboard-hidden state must never summon the keyboard. A broken gate would
  // requestFocus unconditionally and flip the field to focused + arm the guard.
  testWidgets(
    'ping with the field unfocused stays unfocused and never arms the guard',
    (tester) async {
      final state = await _pumpWithActiveConversation(tester);
      // Open the panel from a keyboard-hidden state; never focus the field.
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pump();

      expect(state.isActionPanelOpenForTest, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse,
      );
      expect(composerKeyboardCollapseGuard.value, isFalse);

      await tester.tap(find.byType(PingGlyph));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse,
      );
      expect(composerKeyboardCollapseGuard.value, isFalse);
    },
  );

  // Callback seam: the ping tile fires `onPingSent` after a ping send, but ONLY
  // when a conversation is active (the composer wires refocus to this).
  testWidgets('ping tile fires onPingSent when a conversation is active', (
    tester,
  ) async {
    var pings = 0;
    final convs = _activeConversationsProvider();
    addTearDown(convs.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<ConversationsProvider>.value(value: convs),
              ChangeNotifierProvider(create: (_) => MessagingProvider()),
            ],
            child: ChatActionTiles(onPingSent: () => pings++),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(PingGlyph));
    await tester.pump();

    expect(pings, 1);
  });

  testWidgets(
    'ping tile does not fire onPingSent without an active conversation',
    (tester) async {
      var pings = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: RpgTheme.themeDataLight,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: MultiProvider(
              providers: [
                ChangeNotifierProvider(create: (_) => ConversationsProvider()),
                ChangeNotifierProvider(create: (_) => MessagingProvider()),
              ],
              child: ChatActionTiles(onPingSent: () => pings++),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byType(PingGlyph));
      await tester.pump();
      expect(pings, 0);

      // Drain the top-snackbar auto-dismiss timer the no-conversation guard spawns.
      await tester.pump(const Duration(seconds: 3));
    },
  );

  // Regression: the composer emoji picker must mutate the actual draft field,
  // not just render a detached picker.
  testWidgets('emoji picker opens and inserts a suggested emoji', (
    tester,
  ) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField), 'Fire ');

    await tester.tap(find.byKey(const ValueKey('composer-emoji-toggle')));
    await tester.pumpAndSettle();

    final suggestedFire = find.byKey(const ValueKey('emoji-picker-option-🔥'));
    expect(suggestedFire, findsOneWidget);

    await tester.tap(suggestedFire);
    await tester.pump();

    expect(find.widgetWithText(TextField, 'Fire 🔥'), findsOneWidget);
  });

  // Telegram parity: focusing the text field swaps the emoji panel for the
  // keyboard — they must never be stacked at the same time.
  testWidgets('composer focus gain closes the emoji panel', (tester) async {
    await _pump(tester);
    await _openEmojiPanel(tester);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(find.byType(FireplaceEmojiPicker), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
  });

  testWidgets(
    'emoji toggle keeps the lower action panel visible when opening emoji',
    (tester) async {
      final state = await _pump(tester);
      await tester.enterText(find.byType(TextField), 'stack panels');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();

      expect(state.isActionPanelOpenForTest, isTrue);
      expect(find.byType(ChatActionTiles), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('composer-emoji-toggle')));
      await tester.pumpAndSettle();

      expect(state.isActionPanelOpenForTest, isTrue);
      expect(find.byType(ChatActionTiles), findsOneWidget);
      expect(find.byType(FireplaceEmojiPicker), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse,
      );
    },
  );

  testWidgets(
    'action panel toggle keeps the emoji panel visible when opening actions',
    (tester) async {
      final state = await _pump(tester);
      await _openEmojiPanel(tester);

      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();

      expect(state.isActionPanelOpenForTest, isTrue);
      expect(find.byType(ChatActionTiles), findsOneWidget);
      expect(find.byType(FireplaceEmojiPicker), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse,
      );
    },
  );

  testWidgets(
    'chat surface tap closes emoji while keeping the action panel visible',
    (tester) async {
      final state = await _pumpWithChatSurface(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('composer-emoji-toggle')));
      await tester.pumpAndSettle();

      expect(state.isActionPanelOpenForTest, isTrue);
      expect(find.byType(ChatActionTiles), findsOneWidget);
      expect(find.byType(FireplaceEmojiPicker), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-surface')));
      await tester.pumpAndSettle();

      expect(state.isActionPanelOpenForTest, isTrue);
      expect(find.byType(ChatActionTiles), findsOneWidget);
      expect(find.byType(FireplaceEmojiPicker), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse,
      );
    },
  );

  // System back with the panel open must be consumed by the panel
  // (Telegram/Signal parity); only the next back leaves the chat route.
  testWidgets('system back closes the emoji panel before popping the route', (
    tester,
  ) async {
    final key = GlobalKey<ChatInputBarState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(body: Center(child: Text('conversations-root'))),
      ),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            Scaffold(body: _providerScope(child: ChatInputBar(key: key))),
      ),
    );
    await tester.pumpAndSettle();
    await _openEmojiPanel(tester);

    // First back: consumed by the panel — the chat route must survive.
    await navigator.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(FireplaceEmojiPicker), findsNothing);
    expect(find.byType(ChatInputBar), findsOneWidget);

    // Second back: nothing left to close, the route pops normally.
    await navigator.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(ChatInputBar), findsNothing);
    expect(find.text('conversations-root'), findsOneWidget);
  });

  // Sending from the emoji panel keeps the panel up and the keyboard down:
  // no refocus may sneak in (a refocus would also close the panel via the
  // focus-gain listener).
  testWidgets('send with the emoji panel open keeps it open and unfocused', (
    tester,
  ) async {
    final state = await _pump(tester);
    await tester.enterText(find.byType(TextField), 'from the panel');
    await _openEmojiPanel(tester);

    state.sendForTest();
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(find.byType(FireplaceEmojiPicker), findsOneWidget);
    expect(field.focusNode!.hasFocus, isFalse);
    // Draft consumed proves the send actually ran (not an early no-op return).
    expect(field.controller!.text, isEmpty);
  });

  testWidgets(
    'chat surface tap closes emoji panel and leaves composer unfocused',
    (tester) async {
      await _pumpWithChatSurface(tester);
      await _openEmojiPanel(tester);

      await tester.tap(find.byKey(const ValueKey('chat-surface')));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(find.byType(FireplaceEmojiPicker), findsNothing);
      expect(field.focusNode!.hasFocus, isFalse);
    },
  );

  // Recording replaces the composer row; a stacked emoji panel must drop
  // with it (mic tap dismisses the panel, Telegram parity).
  testWidgets('starting voice recording closes the emoji panel', (
    tester,
  ) async {
    final state = await _pump(tester);
    await _openEmojiPanel(tester);

    state.setRecordingForTest(true);
    await tester.pump();

    expect(find.byType(FireplaceEmojiPicker), findsNothing);
  });
  testWidgets(
    'emoji panel reserves full layout on open while its content slides up',
    (tester) async {
      await _pump(tester);

      await tester.tap(find.byKey(const ValueKey('composer-emoji-toggle')));
      await tester.pump(); // first frame of the entrance
      // Layout half: panel mounted at full height, viewport pin already set —
      // the keyboard's space is reserved from this exact frame.
      expect(find.byType(FireplaceEmojiPicker), findsOneWidget);
      expect(composerBottomPanelPinned.value, isTrue);
      // Paint half: content starts a full panel-height below (pure transform).
      final slide = tester.widget<SlideTransition>(
        find
            .ancestor(
              of: find.byType(FireplaceEmojiPicker),
              matching: find.byType(SlideTransition),
            )
            .first, // nearest ancestor: the panel's own slide
      );
      expect(slide.position.value, const Offset(0, 1));

      await tester.pumpAndSettle();
      expect(slide.position.value, Offset.zero);
    },
  );

  testWidgets(
    'chat-surface tap keeps the emoji panel mounted through the exit slide',
    (tester) async {
      final state = await _pumpWithChatSurface(tester);
      await _openEmojiPanel(tester);

      await tester.tap(find.byKey(const ValueKey('chat-surface')));
      await tester.pump(); // first frame of the exit
      // Logical state flips instantly...
      expect(state.isEmojiPickerOpenForTest, isFalse);
      // ...but the panel still occupies layout (pin held) while the content
      // slides out; it unmounts and releases the pin when the exit completes.
      expect(find.byType(FireplaceEmojiPicker), findsOneWidget);
      expect(composerBottomPanelPinned.value, isTrue);

      await tester.pumpAndSettle();
      expect(find.byType(FireplaceEmojiPicker), findsNothing);
      expect(composerBottomPanelPinned.value, isFalse);
    },
  );

  testWidgets('reduce motion mounts the emoji panel with no entrance slide', (
    tester,
  ) async {
    final key = GlobalKey<ChatInputBarState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: Scaffold(
              body: _providerScope(child: ChatInputBar(key: key)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('composer-emoji-toggle')));
    await tester.pump(); // single frame: content already at rest
    expect(find.byType(FireplaceEmojiPicker), findsOneWidget);
    final slide = tester.widget<SlideTransition>(
      find
          .ancestor(
            of: find.byType(FireplaceEmojiPicker),
            matching: find.byType(SlideTransition),
          )
          .first, // nearest ancestor: the panel's own slide
    );
    expect(slide.position.value, Offset.zero);
    // Flush the picker's internal init timer; the assertions above already
    // proved the single-frame mount.
    await tester.pumpAndSettle();
  });
}

/// Fake iOS-WebKit shared inset source (isActive true) with a fixed inset, so
/// the keyboardVisible fold-in can be exercised on the VM.
class _FakeInsetSource implements KeyboardInsetSource {
  _FakeInsetSource(double initial) : _inset = ValueNotifier<double>(initial);

  final ValueNotifier<double> _inset;

  @override
  ValueNotifier<double> get inset => _inset;

  @override
  bool get isActive => true;

  @override
  void dispose() {}
}
