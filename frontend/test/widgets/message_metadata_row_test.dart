import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/hearth_fade_hex.dart';
import 'package:fireplace/widgets/message/message_metadata_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

MessageModel _message({
  int? disappearAfterSeconds,
  DateTime? expiresAt,
  DateTime? createdAt,
}) {
  return MessageModel(
    id: 1,
    content: 'hi',
    senderId: 2,
    senderUsername: 'alice',
    conversationId: 1,
    createdAt: createdAt ?? DateTime.now().subtract(const Duration(minutes: 1)),
    disappearAfterSeconds: disappearAfterSeconds,
    expiresAt: expiresAt,
  );
}

void main() {
  group('MessageMetadataRow ephemeral hex', () {
    testWidgets('pre-read shows pre-read hex without countdown', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: RpgTheme.themeDataLight,
          home: Scaffold(
            body: MultiProvider(
              providers: [
                ChangeNotifierProvider(create: (_) => MessagingProvider()),
                ChangeNotifierProvider(create: (_) => SettingsProvider()),
              ],
              child: MessageMetadataRow(
                message: _message(disappearAfterSeconds: 3600),
                isMine: false,
                timeColor: Colors.grey,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(HearthFadeHexIndicator), findsOneWidget);
      expect(find.textContaining('h'), findsNothing);
    });

    testWidgets('post-read shows hex and countdown', (tester) async {
      final expiresAt = DateTime.now().add(const Duration(hours: 3, minutes: 5));
      await tester.pumpWidget(
        MaterialApp(
          theme: RpgTheme.themeDataLight,
          home: Scaffold(
            body: MultiProvider(
              providers: [
                ChangeNotifierProvider(create: (_) => MessagingProvider()),
                ChangeNotifierProvider(create: (_) => SettingsProvider()),
              ],
              child: MessageMetadataRow(
                message: _message(
                  disappearAfterSeconds: 7200,
                  expiresAt: expiresAt,
                ),
                isMine: true,
                timeColor: Colors.white,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(HearthFadeHexIndicator), findsOneWidget);
      expect(find.text('3h'), findsOneWidget);
    });

    testWidgets('never-read past retention hides ephemeral indicator',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: RpgTheme.themeDataLight,
          home: Scaffold(
            body: MultiProvider(
              providers: [
                ChangeNotifierProvider(create: (_) => MessagingProvider()),
                ChangeNotifierProvider(create: (_) => SettingsProvider()),
              ],
              child: MessageMetadataRow(
                message: _message(
                  disappearAfterSeconds: 3600,
                  createdAt: DateTime.now().subtract(
                    const Duration(seconds: 86401),
                  ),
                ),
                isMine: false,
                timeColor: Colors.grey,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(HearthFadeHexIndicator), findsNothing);
    });

    testWidgets('plain message hides ephemeral indicator', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: RpgTheme.themeDataLight,
          home: Scaffold(
            body: MultiProvider(
              providers: [
                ChangeNotifierProvider(create: (_) => MessagingProvider()),
                ChangeNotifierProvider(create: (_) => SettingsProvider()),
              ],
              child: MessageMetadataRow(
                message: _message(),
                isMine: false,
                timeColor: Colors.grey,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(HearthFadeHexIndicator), findsNothing);
    });
  });

  group('MessageMetadataRow countdown ticker subscription', () {
    Widget host(MessageModel message) => MaterialApp(
      theme: RpgTheme.themeDataLight,
      home: Scaffold(
        body: MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => MessagingProvider()),
            ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ],
          child: MessageMetadataRow(
            message: message,
            isMine: false,
            timeColor: Colors.grey,
          ),
        ),
      ),
    );

    testWidgets('a non-ephemeral row never subscribes to the 1 Hz tick', (
      tester,
    ) async {
      await tester.pumpWidget(host(_message()));

      // countdownTickNotifier ticks once per second unconditionally, so a
      // subscription here rebuilds every visible bubble's metadata forever.
      expect(find.byType(ValueListenableBuilder<int>), findsNothing);
    });

    testWidgets('an ephemeral row still subscribes', (tester) async {
      await tester.pumpWidget(
        host(
          _message(
            disappearAfterSeconds: 3600,
            expiresAt: DateTime.now().add(const Duration(minutes: 30)),
          ),
        ),
      );

      expect(find.byType(ValueListenableBuilder<int>), findsOneWidget);
      expect(find.byType(HearthFadeHexIndicator), findsOneWidget);
    });
  });
}
