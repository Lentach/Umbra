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

  testWidgets('the held-back row is calm: the waiting words, no Retry', (
    tester,
  ) async {
    final row = await writeDuringHold(tester);

    await pumpRow(tester, message: row);

    expect(find.text(l10n.messageWaitingTapCalmLine), findsOneWidget);
    expect(find.text(l10n.messageSendBlockedKeysChanged), findsNothing);
    expect(find.text(l10n.messageRetrySend), findsNothing);
  });

  testWidgets('a waiting row is calm whether or not a ceremony is open', (
    tester,
  ) async {
    final row = await writeDuringHold(tester);

    await pumpRow(tester, message: row, ceremony: false);

    expect(find.text(l10n.messageWaitingTapCalmLine), findsOneWidget);
    expect(find.text(l10n.messageRetrySend), findsNothing);
  });

  testWidgets('once the line is gone the row is an ordinary failed row', (
    tester,
  ) async {
    await writeDuringHold(tester);
    await tester.runAsync(() async {
      h.provider.onFriendshipEnded(2);
      await h.pump();
    });

    await pumpRow(tester, message: h.provider.messages.single);

    expect(find.text(l10n.messageWaitingTapCalmLine), findsNothing);
    expect(find.text(l10n.messageWaitingToSend), findsNothing);
    expect(find.text(l10n.messageRetrySend), findsOneWidget);
  });

  testWidgets('a row refused for a key change names the refusal, not the '
      'wait', (tester) async {
    final row = (await writeDuringHold(tester)).copyWith(waitingToSend: false);
    h.provider.markSendRefusedForIdentityForTest(row.tempId!);

    await pumpRow(tester, message: row);

    expect(find.text(l10n.messageSendBlockedKeysChanged), findsOneWidget);
    expect(find.text(l10n.messageWaitingTapCalmLine), findsNothing);
  });
}
