import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/message/chat_message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/box_send_harness.dart';
import '../../support/l10n.dart';

/// Decision 152 (option C): a message written while the friend's new key
/// waits for the tap on the calm line is held back, and its row says so in
/// neutral words (the real send path failed it; nothing is faked but the
/// calm hold itself, which needs a PreKey frame).
void main() {
  late BoxSendHarness h;

  setUp(() async {
    final harness = await BoxSendHarness.create();
    h = harness..bob([1]);
  });
  tearDown(() => h.dispose());

  Future<void> pumpRow(
    WidgetTester tester, {
    required MessageModel message,
    bool ceremony = true,
  }) => tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
        ChangeNotifierProvider<MessagingProvider>.value(value: h.provider),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(),
        ),
      ],
      child: MaterialApp(
        theme: RpgTheme.themeDataBlue,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              child: ChatMessageBubble(
                message: message,
                isMine: true,
                peerRefusedIdentity: ceremony,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<MessageModel> writeDuringHold(WidgetTester tester) async {
    h.provider.seedCalmHoldForTest(2, CalmHoldState.waiting);
    await tester.runAsync(() async {
      h.provider.sendMessage('hello');
      await h.pump();
    });
    final row = h.provider.messages.single;
    expect(row.deliveryStatus, MessageDeliveryStatus.failed);
    return row;
  }

  testWidgets('the held-back row names the line in neutral words and keeps '
      'its Retry', (tester) async {
    final row = await writeDuringHold(tester);

    await pumpRow(tester, message: row);

    expect(find.text(l10n.messageSendWaitsForCalmHold), findsOneWidget);
    expect(find.text(l10n.messageSendBlockedKeysChanged), findsNothing);
    expect(find.text(l10n.messageRetrySend), findsOneWidget);
  });

  testWidgets('without a calm line in the chat the row says nothing about '
      'it', (tester) async {
    final row = await writeDuringHold(tester);

    await pumpRow(tester, message: row, ceremony: false);

    expect(find.text(l10n.messageSendWaitsForCalmHold), findsNothing);
    expect(find.text(l10n.messageRetrySend), findsOneWidget);
  });

  testWidgets('once the line is gone the row is plain again', (tester) async {
    final row = await writeDuringHold(tester);
    h.provider.onFriendshipEnded(2);

    await pumpRow(tester, message: row);

    expect(find.text(l10n.messageSendWaitsForCalmHold), findsNothing);
  });

  testWidgets('a refusal for a key change wins over the neutral line', (
    tester,
  ) async {
    final row = await writeDuringHold(tester);
    h.provider.markSendRefusedForIdentityForTest(row.tempId!);

    await pumpRow(tester, message: row);

    expect(find.text(l10n.messageSendBlockedKeysChanged), findsOneWidget);
    expect(find.text(l10n.messageSendWaitsForCalmHold), findsNothing);
  });
}
