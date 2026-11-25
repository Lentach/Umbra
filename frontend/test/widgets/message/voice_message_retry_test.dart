import 'dart:io';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/message/chat_message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/box_send_harness.dart';
import '../../support/l10n.dart';

/// A voice note whose send failed is offered the same 'Ponów' as every other
/// bubble: the row is a real one, failed by the real send path (the box
/// refused the upload), and the tap runs the real `retryFailedMessage`.
void main() {
  late BoxSendHarness h;
  late ScriptedSendOutbox outbox;
  late File recording;

  setUp(() async {
    outbox = ScriptedSendOutbox();
    h = await BoxSendHarness.create(outbox: outbox);
    final dir = Directory.systemTemp.createTempSync('voice_retry_');
    addTearDown(() => dir.deleteSync(recursive: true));
    recording = File('${dir.path}/rec.m4a')..writeAsBytesSync([1, 2, 3, 4]);
    h.bob([1]);
  });
  tearDown(() => h.dispose());

  MessageModel voiceRow() =>
      h.provider.messages.lastWhere((m) => m.messageType == MessageType.voice);

  Future<void> sendFailedVoice(WidgetTester tester) async {
    outbox.uploadAnswer = const BoxRefused(BoxCode.quotaExceeded);
    await tester.runAsync(() async {
      await h.provider.sendVoiceMessage(
        recipientId: 2,
        duration: 7,
        conversationId: 10,
        localAudioPath: recording.path,
      );
      await h.pump();
    });
    expect(voiceRow().deliveryStatus, MessageDeliveryStatus.failed);
  }

  Future<void> pumpBubble(
    WidgetTester tester, {
    bool isMine = true,
    bool peerRefusedIdentity = false,
    MessageModel? message,
  }) {
    return tester.pumpWidget(
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
                  message: message ?? voiceRow(),
                  isMine: isMine,
                  peerRefusedIdentity: peerRefusedIdentity,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a failed voice note offers Retry, and the tap sends it again', (
    tester,
  ) async {
    await sendFailedVoice(tester);
    await pumpBubble(tester);

    final retry = find.text(l10n.messageRetrySend);
    expect(retry, findsOneWidget);

    outbox.uploadAnswer = null;
    await tester.tap(retry);
    // The retry reads the recording from disk: real IO, whose continuations
    // run in the test zone, so alternate real waits with pumps and wait on
    // the row, not on a fixed number of turns.
    for (var i = 0; i < 100; i++) {
      if (voiceRow().deliveryStatus != MessageDeliveryStatus.sending) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }

    expect(voiceRow().deliveryStatus, MessageDeliveryStatus.sent);
    expect(outbox.delivered, hasLength(1));
    expect(
      h.provider.messages.where((m) => m.messageType == MessageType.voice),
      hasLength(1),
      reason: 'the retry is the same row, not a second bubble',
    );
  });

  testWidgets('a failed voice note refused for a changed key says so, as '
      'every other bubble does', (tester) async {
    await sendFailedVoice(tester);
    h.provider.markSendRefusedForIdentityForTest(voiceRow().tempId!);
    await pumpBubble(tester, peerRefusedIdentity: true);

    expect(find.text(l10n.messageSendBlockedKeysChanged), findsOneWidget);
    expect(find.text(l10n.messageRetrySend), findsOneWidget);
  });

  testWidgets('a voice note that did not fail has no Retry', (tester) async {
    await sendFailedVoice(tester);
    final sent = voiceRow().copyWith(
      deliveryStatus: MessageDeliveryStatus.sent,
    );
    await pumpBubble(tester, message: sent);

    expect(find.text(l10n.messageRetrySend), findsNothing);
  });

  testWidgets("a peer's voice note never has Retry", (tester) async {
    await sendFailedVoice(tester);
    await pumpBubble(tester, isMine: false);

    expect(find.text(l10n.messageRetrySend), findsNothing);
  });
}
