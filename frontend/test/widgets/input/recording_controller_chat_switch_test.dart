import 'dart:convert';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/widgets/input/recording_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/box_send_harness.dart';
import '../../support/chat_seed.dart';
import '../../support/l10n.dart';

/// The desktop split view keeps ONE composer (and so one recorder) mounted
/// while the chat beside it changes. A recording belongs to the chat it
/// started in: it is never sent to the chat opened afterwards.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BoxSendHarness h;
  late ConversationsProvider conversations;
  late MessagingProvider messaging;
  late List<({int? conversationId, int duration})> sent;
  late List<bool> recordingStates;
  late RecordingControllerState recorder;

  setUp(() async {
    h = await BoxSendHarness.create();
    conversations = h.conversations;
    messaging = h.provider;
    seedConversations(conversations, [
      boxSendConversation(),
      {
        'id': 11,
        'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
        'userTwo': {'id': 3, 'username': 'carol', 'tag': '0003'},
        'createdAt': '2026-01-01T00:00:00.000Z',
        'unreadCount': 0,
        'lastMessage': null,
      },
    ]);
    h.encryption.lists[2] = enrolledList([1]);
    h.outbox.addresses[2] = {1: boxAddress(1)};
    messaging
      ..receiptsAndTyping = (() => true)
      ..refreshBoxDeviceLists();
    await h.pump();
    sent = [];
    recordingStates = [];
  });

  tearDown(() async {
    await h.pump();
    h.dispose();
  });

  Future<void> pumpRecorder(WidgetTester tester) async {
    final key = GlobalKey<RecordingControllerState>();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ConnectionProvider()),
          ChangeNotifierProvider.value(value: conversations),
          ChangeNotifierProvider.value(value: messaging),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: RecordingController(
              key: key,
              onVoiceSent:
                  ({
                    required duration,
                    conversationId,
                    localAudioPath,
                    audioBytes,
                  }) async {
                    sent.add((
                      conversationId: conversationId,
                      duration: duration,
                    ));
                  },
              onRecordingStateChanged: recordingStates.add,
              onMicTap: () {},
              isSendingVoice: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    recorder = key.currentState!..testSkipHardware = true;
  }

  /// A voice recording runs in the chat open now (what a started recording
  /// records), 3 s in.
  Future<void> recordInChat10(WidgetTester tester) async {
    await pumpRecorder(tester);
    recorder.simulateRecordingForTest(elapsed: const Duration(seconds: 3));
    await tester.pump();
  }

  /// Lets the signal's store work (real async) and the zone's microtasks
  /// (fake async) both run.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump();
    }
  }

  /// The desktop sidebar tap: the chat beside the composer becomes [id].
  Future<void> switchTo(WidgetTester tester, int id) async {
    conversations.openConversation(id);
    await tester.pump();
    await settle(tester);
  }

  /// The `typ` frames the box was handed for Bob (chat 10): voice on/off.
  List<bool> voiceSignalsToBob() => [
    for (final (to, frame) in h.outbox.delivered)
      if (to.sid == 'sid-1')
        (jsonDecode(utf8.decode(frame.signal))
                as Map<String, dynamic>)['on']
            as bool,
  ];

  testWidgets('sending inside the chat it started in: the note goes there and '
      'the recording signal stops there', (tester) async {
    await recordInChat10(tester);

    await recorder.stopAndSend();
    await settle(tester);

    expect(sent, hasLength(1));
    expect(sent.single.conversationId, 10);
    expect(recorder.isRecording, isFalse);
    expect(messaging.isRecordingVoice, isFalse);
    expect(voiceSignalsToBob(), [false]);
  });

  testWidgets('switching chats while recording discards the note: nothing is '
      'sent, the bar is idle, and the original chat is told it stopped', (
    tester,
  ) async {
    await recordInChat10(tester);

    await switchTo(tester, 11);

    expect(sent, isEmpty);
    expect(recorder.isRecording, isFalse);
    expect(recordingStates.last, isFalse);
    expect(messaging.isRecordingVoice, isFalse);
    expect(voiceSignalsToBob(), [false]);
    expect(find.text(l10n.snackbarVoiceRecordingCanceled), findsOneWidget);

    // A tap on send afterwards finds nothing to send.
    await recorder.stopAndSend();
    await settle(tester);
    expect(sent, isEmpty);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the 120 s auto-send follows the same rule: it reaches '
      'stopAndSend with no switch seen, and still sends nothing to the new '
      'chat', (tester) async {
    await recordInChat10(tester);
    // The active chat moved without the recorder being told (no notify).
    conversations.openConversation(11, notify: false);

    await recorder.stopAndSend();
    await settle(tester);

    expect(sent, isEmpty);
    expect(recorder.isRecording, isFalse);
    expect(voiceSignalsToBob(), [false]);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a recording that started with no chat open survives a chat '
      'opening (the resume reassert): it is not discarded, and the note goes '
      'to the chat open at stop', (tester) async {
    conversations.closeConversation();
    await recordInChat10(tester);
    expect(recorder.isRecording, isTrue);

    await switchTo(tester, 10);

    expect(recorder.isRecording, isTrue);
    expect(find.text(l10n.snackbarVoiceRecordingCanceled), findsNothing);

    await recorder.stopAndSend();
    await settle(tester);

    expect(sent, hasLength(1));
    expect(sent.single.conversationId, 10);
    expect(recorder.isRecording, isFalse);
    expect(find.text(l10n.snackbarVoiceRecordingCanceled), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });
}
