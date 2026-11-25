import 'dart:async';
import 'dart:io';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/message_ids.dart';
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

  /// A note whose recording could not be read: it failed before its
  /// encrypted file was held, so the first Retry branch (held bytes) is not
  /// the one that runs.
  Future<String> sendVoiceWithoutFile(WidgetTester tester) async {
    final path = '${recording.parent.path}/later.m4a';
    await tester.runAsync(() async {
      await h.provider.sendVoiceMessage(
        recipientId: 2,
        duration: 7,
        conversationId: 10,
        localAudioPath: path,
      );
      await h.pump();
    });
    expect(voiceRow().deliveryStatus, MessageDeliveryStatus.failed);
    return path;
  }

  Future<void> retryAndWait(WidgetTester tester, String tempId) async {
    unawaited(h.provider.retryFailedMessage(tempId));
    for (var i = 0; i < 100; i++) {
      if (voiceRow().deliveryStatus != MessageDeliveryStatus.sending) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  List<MessageModel> voiceRows() => [
    for (final m in h.provider.messages)
      if (m.messageType == MessageType.voice) m,
  ];

  testWidgets('Retry on a note whose recording is on disk again sends the '
      'same row', (tester) async {
    final path = await sendVoiceWithoutFile(tester);
    final tempId = voiceRow().tempId!;
    File(path).writeAsBytesSync([1, 2, 3, 4]);

    await retryAndWait(tester, tempId);

    expect(voiceRows(), hasLength(1), reason: 'one row, not a second bubble');
    expect(voiceRows().single.tempId, tempId);
    expect(voiceRows().single.deliveryStatus, MessageDeliveryStatus.sent);
    expect(outbox.delivered, hasLength(1));
  });

  testWidgets('Retry on a note whose recording is gone fails the same row '
      'again', (tester) async {
    await sendVoiceWithoutFile(tester);
    final tempId = voiceRow().tempId!;

    await retryAndWait(tester, tempId);
    await retryAndWait(tester, tempId);

    expect(voiceRows(), hasLength(1), reason: 'never a second row');
    expect(voiceRows().single.tempId, tempId);
    expect(voiceRows().single.deliveryStatus, MessageDeliveryStatus.failed);
    expect(outbox.delivered, isEmpty);
  });

  testWidgets('Retry keeps the note on its own reply target and leaves the '
      "composer's reply alone", (tester) async {
    final quoted = MessageModel(
      id: kFirstLocalMessageId + 1,
      content: 'first',
      senderId: 2,
      senderUsername: 'bob',
      conversationId: 10,
      createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
    );
    final other = MessageModel(
      id: kFirstLocalMessageId + 2,
      content: 'second',
      senderId: 2,
      senderUsername: 'bob',
      conversationId: 10,
      createdAt: DateTime.now().subtract(const Duration(minutes: 4)),
    );
    h.provider.seedMessagesForTest(10, [quoted, other]);
    h.provider.setReplyingTo(quoted);
    final path = await sendVoiceWithoutFile(tester);
    final row = voiceRow();
    expect(row.replyToMessageId, quoted.id);
    expect(h.provider.replyingToMessage, isNull);
    File(path).writeAsBytesSync([1, 2, 3, 4]);

    // The user has since begun a reply to another message.
    h.provider.setReplyingTo(other);
    await retryAndWait(tester, row.tempId!);

    expect(h.provider.replyingToMessage?.id, other.id);
    expect(voiceRows(), hasLength(1));
    expect(voiceRows().single.replyTo?.id, quoted.id);
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
