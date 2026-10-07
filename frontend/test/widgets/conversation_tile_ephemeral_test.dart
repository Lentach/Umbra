import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/conversation_tile.dart';
import 'package:fireplace/widgets/hearth_fade_hex.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

MessageModel _lastMessage({
  int? disappearAfterSeconds,
  DateTime? expiresAt,
  DateTime? createdAt,
}) {
  return MessageModel(
    id: 1,
    content: 'hello',
    senderId: 2,
    senderUsername: 'alice',
    conversationId: 10,
    createdAt: createdAt ?? DateTime.now().subtract(const Duration(minutes: 2)),
    disappearAfterSeconds: disappearAfterSeconds,
    expiresAt: expiresAt,
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: RpgTheme.themeDataLight,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => MessagingProvider()),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: child,
      ),
    ),
  );
}

void main() {
  group('ConversationTile ephemeral hex', () {
    testWidgets('shows pre-read hex for pre-read last message', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ConversationTile(
            conversationId: 10,
            displayName: 'Alice',
            lastMessage: _lastMessage(disappearAfterSeconds: 3600),
            onTap: () {},
            onDelete: () {},
          ),
        ),
      );

      expect(find.byType(HearthFadeHexIndicator), findsOneWidget);
      expect(find.text('1h'), findsNothing);
      expect(find.text('1m'), findsNothing);
    });

    testWidgets('shows a muted indicator only when the conversation is muted',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          ConversationTile(
            conversationId: 10,
            displayName: 'Alice',
            isMuted: true,
            onTap: () {},
            onDelete: () {},
          ),
        ),
      );

      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
      expect(find.byTooltip('Notifications muted'), findsOneWidget);
    });

    testWidgets('shows lit hex for post-read last message', (tester) async {
      final expiresAt =
          DateTime.now().add(const Duration(hours: 2, minutes: 10));
      await tester.pumpWidget(
        _wrap(
          ConversationTile(
            conversationId: 10,
            displayName: 'Alice',
            lastMessage: _lastMessage(
              disappearAfterSeconds: 7200,
              expiresAt: expiresAt,
            ),
            onTap: () {},
            onDelete: () {},
          ),
        ),
      );

      expect(find.byType(HearthFadeHexIndicator), findsOneWidget);
      expect(find.text('2h'), findsNothing);
    });

    testWidgets('hides hex when conversation timer on but last message plain',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          ConversationTile(
            conversationId: 10,
            displayName: 'Alice',
            lastMessage: _lastMessage(),
            onTap: () {},
            onDelete: () {},
          ),
        ),
      );

      expect(find.byType(HearthFadeHexIndicator), findsNothing);
    });

    testWidgets('hides hex when last message expired', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ConversationTile(
            conversationId: 10,
            displayName: 'Alice',
            lastMessage: _lastMessage(
              disappearAfterSeconds: 60,
              expiresAt: DateTime.now().subtract(const Duration(seconds: 5)),
            ),
            onTap: () {},
            onDelete: () {},
          ),
        ),
      );

      expect(find.byType(HearthFadeHexIndicator), findsNothing);
    });

    testWidgets('shows hex for grandfathered send-time expiresAt only',
        (tester) async {
      final expiresAt = DateTime.now().add(const Duration(hours: 3));
      final message = _lastMessage(expiresAt: expiresAt);
      expect(HearthFadeHexIndicator.showsEphemeralState(message), isTrue);
      final countdown = HearthFadeHexIndicator.countdownLabel(message);
      expect(countdown, isNotNull);

      await tester.pumpWidget(
        _wrap(
          ConversationTile(
            conversationId: 10,
            displayName: 'Alice',
            lastMessage: message,
            onTap: () {},
            onDelete: () {},
          ),
        ),
      );

      expect(find.byType(HearthFadeHexIndicator), findsOneWidget);
      expect(find.text(countdown!), findsNothing);
    });

    testWidgets('rebuilds hex when tick notifier updates', (tester) async {
      final messaging = MessagingProvider();
      addTearDown(messaging.dispose);
      final expiresAt = DateTime.now().add(const Duration(seconds: 90));

      await tester.pumpWidget(
        MaterialApp(
          theme: RpgTheme.themeDataLight,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MultiProvider(
              providers: [
                ChangeNotifierProvider.value(value: messaging),
                ChangeNotifierProvider(create: (_) => SettingsProvider()),
              ],
              child: ConversationTile(
                conversationId: 10,
                displayName: 'Alice',
                lastMessage: _lastMessage(
                  disappearAfterSeconds: 120,
                  expiresAt: expiresAt,
                ),
                onTap: () {},
                onDelete: () {},
              ),
            ),
          ),
        ),
      );

      double hexProgress() {
        final painter = tester
            .widgetList<CustomPaint>(
              find.descendant(
                of: find.byType(HearthFadeHexIndicator),
                matching: find.byType(CustomPaint),
              ),
            )
            .map((w) => w.painter)
            .whereType<HearthFadeHexPainter>()
            .single;
        return painter.progress;
      }

      expect(find.byType(HearthFadeHexIndicator), findsOneWidget);
      final before = hexProgress();

      // Let real wall-clock time advance so the countdown actually moves, then
      // bump the tick. The tile recomputes progress from DateTime.now() on
      // rebuild; if the ValueListenableBuilder wiring were removed the tile
      // would not rebuild and the painter would keep its stale progress.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      messaging.countdownTickNotifier.value++;
      await tester.pump();

      expect(find.byType(HearthFadeHexIndicator), findsOneWidget);
      expect(
        hexProgress(),
        lessThan(before),
        reason: 'tick rebuild must recompute countdown progress',
      );
    });
  });
}
