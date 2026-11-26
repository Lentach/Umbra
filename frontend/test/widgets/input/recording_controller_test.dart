import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/widgets/input/recording_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

// Helper: pump a RecordingController with localization AND the providers it
// reads from context (stopAndSend/cancelRecording call context.read<...>()).
// activeConversationId stays null, so _emitRecordingVoiceToRecipient no-ops.
Future<RecordingControllerState> _pumpController(
  WidgetTester tester, {
  required Future<void> Function({
    required int duration,
    int? conversationId,
    String? localAudioPath,
    Uint8List? audioBytes,
  }) onVoiceSent,
  required void Function(bool) onRecordingStateChanged,
}) async {
  final key = GlobalKey<RecordingControllerState>();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ConnectionProvider()),
        ChangeNotifierProvider(create: (_) => ConversationsProvider()),
        ChangeNotifierProvider(create: (_) => MessagingProvider()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RecordingController(
            key: key,
            onVoiceSent: onVoiceSent,
            onRecordingStateChanged: onRecordingStateChanged,
            onMicTap: () {},
            isSendingVoice: false,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return key.currentState!;
}

void main() {

  group('resolveSupportedEncoder', () {
    test('returns the first supported candidate', () async {
      final result = await resolveSupportedEncoder(
        const [AudioEncoder.aacLc, AudioEncoder.opus, AudioEncoder.wav],
        (e) async => e == AudioEncoder.opus, // aac unsupported, opus supported
      );
      expect(result, AudioEncoder.opus);
    });

    test('prefers the earliest candidate when several are supported', () async {
      final result = await resolveSupportedEncoder(
        const [AudioEncoder.aacLc, AudioEncoder.opus, AudioEncoder.wav],
        (e) async => true,
      );
      expect(result, AudioEncoder.aacLc);
    });

    test('falls back to the last candidate when none are supported', () async {
      final result = await resolveSupportedEncoder(
        const [AudioEncoder.aacLc, AudioEncoder.opus, AudioEncoder.wav],
        (e) async => false,
      );
      expect(result, AudioEncoder.wav);
    });
  });

  group('classifyRecordingStartError', () {
    test('NotFoundError maps to noMicrophone', () {
      expect(
        classifyRecordingStartError(
          'NotFoundError: Requested device not found',
        ),
        RecordingStartFailure.noMicrophone,
      );
    });

    test('NotAllowedError maps to permissionDenied', () {
      expect(
        classifyRecordingStartError('NotAllowedError: Permission denied'),
        RecordingStartFailure.permissionDenied,
      );
    });

    test('an unrecognised error maps to generic', () {
      expect(
        classifyRecordingStartError('SomeOtherError: boom'),
        RecordingStartFailure.generic,
      );
    });
  });

  group('RecordingController tap model', () {
    testWidgets('stopAndSend after >=500ms calls onVoiceSent once',
        (tester) async {
      var sent = 0;
      int? sentDuration;
      final state = await _pumpController(
        tester,
        onVoiceSent:
            ({
              required duration,
              conversationId,
              localAudioPath,
              audioBytes,
            }) async {
          sent++;
          sentDuration = duration;
        },
        onRecordingStateChanged: (_) {},
      );
      state.testSkipHardware = true;
      state.simulateRecordingForTest(elapsed: const Duration(seconds: 3));
      await tester.pump();

      await state.stopAndSend();
      await tester.pump();

      expect(sent, 1);
      // Duration uses ceiling rounding ((ms+999)~/1000); wall-clock between
      // simulate and stop pushes elapsed just past 3000ms, so it rounds to 4.
      expect(sentDuration, greaterThanOrEqualTo(3));
      expect(state.isRecording, isFalse);
    });

    testWidgets('a teardown mid-send still delivers the recording',
        (tester) async {
      var sent = 0;
      late RecordingControllerState state;
      state = await _pumpController(
        tester,
        onVoiceSent:
            ({
              required duration,
              conversationId,
              localAudioPath,
              audioBytes,
            }) async {
          sent++;
          // Back navigation, or ChatDetailScreen's unfriend/block auto-pop,
          // landing while the send is in flight. Before the mounted guards this
          // threw on the next setState and the voice note vanished silently.
          await tester.pumpWidget(const SizedBox.shrink());
        },
        onRecordingStateChanged: (_) {},
      );
      state.testSkipHardware = true;
      state.simulateRecordingForTest(elapsed: const Duration(seconds: 3));
      await tester.pump();

      await state.stopAndSend();

      expect(sent, 1);
    });

    testWidgets('stopAndSend under 500ms discards silently (no onVoiceSent)',
        (tester) async {
      var sent = 0;
      final state = await _pumpController(
        tester,
        onVoiceSent:
            ({
              required duration,
              conversationId,
              localAudioPath,
              audioBytes,
            }) async {
          sent++;
        },
        onRecordingStateChanged: (_) {},
      );
      state.testSkipHardware = true;
      state.simulateRecordingForTest(elapsed: Duration.zero);
      await tester.pump();

      await state.stopAndSend();
      await tester.pump();

      expect(sent, 0);
      expect(state.isRecording, isFalse);
    });

    testWidgets('cancelRecording discards, no onVoiceSent', (tester) async {
      var sent = 0;
      final state = await _pumpController(
        tester,
        onVoiceSent:
            ({
              required duration,
              conversationId,
              localAudioPath,
              audioBytes,
            }) async {
          sent++;
        },
        onRecordingStateChanged: (_) {},
      );
      state.testSkipHardware = true;
      state.simulateRecordingForTest(elapsed: const Duration(seconds: 3));
      await tester.pump();

      await state.cancelRecording();
      // cancelRecording shows a top snackbar (Future.delayed 2500ms auto-dismiss);
      // pump past it so no timer is pending at teardown.
      await tester.pump(const Duration(milliseconds: 2600));

      expect(sent, 0);
      expect(state.isRecording, isFalse);
    });

    testWidgets('stopAndSend then immediate cancel sends exactly once',
        (tester) async {
      var sent = 0;
      final state = await _pumpController(
        tester,
        onVoiceSent:
            ({
              required duration,
              conversationId,
              localAudioPath,
              audioBytes,
            }) async {
          sent++;
        },
        onRecordingStateChanged: (_) {},
      );
      state.testSkipHardware = true;
      state.simulateRecordingForTest(elapsed: const Duration(seconds: 3));
      await tester.pump();

      final f1 = state.stopAndSend();
      final f2 = state.cancelRecording();
      await Future.wait([f1, f2]);
      await tester.pump();

      expect(sent, 1);
      expect(state.isRecording, isFalse);
    });

    testWidgets('startRecording is a no-op while already starting',
        (tester) async {
      final state = await _pumpController(
        tester,
        onVoiceSent:
            ({
              required duration,
              conversationId,
              localAudioPath,
              audioBytes,
            }) async {},
        onRecordingStateChanged: (_) {},
      );
      state.debugSetStartingForTest(true);
      await state.startRecording(); // must return immediately
      expect(state.isRecording, isFalse);
    });
  });

  // A3-CMP-04 (owner 2026-11-26): a recording is DISCARDED when the app goes
  // to the background, never sent on return.
  group('RecordingController app lifecycle', () {
    tearDown(() {
      TestWidgetsFlutterBinding.instance
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    Future<({RecordingControllerState state, List<int> sent})> pumpRecording(
      WidgetTester tester,
    ) async {
      final sent = <int>[];
      final state = await _pumpController(
        tester,
        onVoiceSent:
            ({
              required duration,
              conversationId,
              localAudioPath,
              audioBytes,
            }) async {
          sent.add(duration);
        },
        onRecordingStateChanged: (_) {},
      );
      state.testSkipHardware = true;
      state.simulateRecordingForTest(elapsed: const Duration(seconds: 3));
      await tester.pump();
      return (state: state, sent: sent);
    }

    for (final away in [AppLifecycleState.paused, AppLifecycleState.hidden]) {
      testWidgets('${away.name} discards the recording with its notice and '
          'nothing is sent on return', (tester) async {
        final r = await pumpRecording(tester);
        final binding = TestWidgetsFlutterBinding.instance;

        // inactive precedes hidden/paused on every platform.
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(away);
        await tester.pump();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();

        expect(r.state.isRecording, isFalse);
        expect(
          find.text(AppLocalizations.of(tester.element(find.byType(Scaffold)))
              .snackbarVoiceRecordingCanceled),
          findsOneWidget,
        );
        await r.state.stopAndSend(); // a late auto-stop finds nothing
        await tester.pump(const Duration(milliseconds: 2600));
        expect(r.sent, isEmpty);
      });
    }

    testWidgets('inactive alone (a web tab losing focus, a dialog) keeps '
        'the recording', (tester) async {
      final r = await pumpRecording(tester);

      TestWidgetsFlutterBinding.instance
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();

      expect(r.state.isRecording, isTrue);
      await r.state.cancelRecording();
      await tester.pump(const Duration(milliseconds: 2600));
    });

    // The tests below drive the REAL startRecording. Off Android/iOS the mic
    // permission step is skipped, so what runs is the temp-dir lookup and the
    // recorder plugin (create / start / stop / dispose), both faked at their
    // platform channels. `start` parks on [startGate].
    ({List<String> calls, Completer<void> startGate}) fakeRecorderPlatform(
      WidgetTester tester,
    ) {
      final messenger = tester.binding.defaultBinaryMessenger;
      const recordChannel = MethodChannel('com.llfbandit.record/messages');
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      final calls = <String>[];
      final startGate = Completer<void>();
      messenger.setMockMethodCallHandler(recordChannel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'create':
            final id = (call.arguments as Map)['recorderId'] as String;
            messenger.setMockStreamHandler(
              EventChannel('com.llfbandit.record/events/$id'),
              MockStreamHandler.inline(onListen: (_, _) {}),
            );
          case 'start':
            await startGate.future;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(
        pathChannel,
        (call) async => Directory.systemTemp.path,
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(recordChannel, null);
        messenger.setMockMethodCallHandler(pathChannel, null);
      });
      return (calls: calls, startGate: startGate);
    }

    // Platform replies and file IO complete in the real zone, the widget's
    // continuations in the fake one: alternate real turns with pumps.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    Future<({RecordingControllerState state, List<int> sent, List<bool> ui})>
    pumpIdle(WidgetTester tester) async {
      final sent = <int>[];
      final ui = <bool>[];
      final state = await _pumpController(
        tester,
        onVoiceSent:
            ({
              required duration,
              conversationId,
              localAudioPath,
              audioBytes,
            }) async {
          sent.add(duration);
        },
        onRecordingStateChanged: ui.add,
      );
      return (state: state, sent: sent, ui: ui);
    }

    String canceledNotice(WidgetTester tester) =>
        AppLocalizations.of(tester.element(find.byType(Scaffold)))
            .snackbarVoiceRecordingCanceled;

    testWidgets('paused while the recorder is starting: the recording is '
        'discarded before it goes live, never armed, never sent',
        (tester) async {
      final platform = fakeRecorderPlatform(tester);
      final r = await pumpIdle(tester);
      final binding = TestWidgetsFlutterBinding.instance;

      final started = r.state.startRecording();
      await settle(tester);
      expect(platform.calls, contains('start'));
      expect(r.state.isStarting, isTrue);

      // The user presses Home / the power key while the recorder is opening.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      platform.startGate.complete();
      await settle(tester);
      await started;

      expect(r.state.isRecording, isFalse);
      expect(r.ui, isNot(contains(true)));
      expect(platform.calls, containsAll(['stop', 'dispose']));
      await tester.pump(const Duration(seconds: 121));
      expect(r.sent, isEmpty);
    });

    testWidgets('inactive while the recorder is starting (the permission '
        'prompt) keeps the recording that starts', (tester) async {
      final platform = fakeRecorderPlatform(tester);
      final r = await pumpIdle(tester);

      final started = r.state.startRecording();
      await settle(tester);
      TestWidgetsFlutterBinding.instance
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      platform.startGate.complete();
      await settle(tester);
      await started;

      expect(r.state.isRecording, isTrue);
      expect(platform.calls, isNot(contains('stop')));
      final canceled = r.state.cancelRecording();
      await settle(tester);
      await canceled;
      await tester.pump(const Duration(milliseconds: 2600));
    });

    testWidgets('a paused that is already over (resumed) when the recorder '
        'finishes starting keeps the recording', (tester) async {
      final platform = fakeRecorderPlatform(tester);
      final r = await pumpIdle(tester);
      final binding = TestWidgetsFlutterBinding.instance;

      final started = r.state.startRecording();
      await settle(tester);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      platform.startGate.complete();
      await settle(tester);
      await started;

      expect(r.state.isRecording, isTrue);
      final canceled = r.state.cancelRecording();
      await settle(tester);
      await canceled;
      await tester.pump(const Duration(milliseconds: 2600));
    });

    // N1: the toast lives 2.5 s, so one shown while the app is away expires
    // unseen. The notice waits for the app to be resumed.
    testWidgets('the canceled notice shows when the app is resumed, not '
        'while it is away', (tester) async {
      final r = await pumpIdle(tester);
      r.state.testSkipHardware = true;
      r.state.simulateRecordingForTest(elapsed: const Duration(seconds: 3));
      await tester.pump();
      final binding = TestWidgetsFlutterBinding.instance;

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 3));
      expect(r.state.isRecording, isFalse);
      expect(find.text(canceledNotice(tester)), findsNothing);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text(canceledNotice(tester)), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2600));
      expect(r.sent, isEmpty);
    });

    testWidgets('a discard while away is announced once, not on every '
        'later resume', (tester) async {
      final r = await pumpIdle(tester);
      r.state.testSkipHardware = true;
      r.state.simulateRecordingForTest(elapsed: const Duration(seconds: 3));
      await tester.pump();
      final binding = TestWidgetsFlutterBinding.instance;

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 2600));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(find.text(canceledNotice(tester)), findsNothing);
    });
  });
}
