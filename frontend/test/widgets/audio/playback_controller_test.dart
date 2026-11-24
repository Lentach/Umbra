import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/services/voice_audio_coordinator.dart';
import 'package:fireplace/widgets/audio/playback_controller.dart';
import 'package:fireplace/widgets/audio/voice_player.dart';

/// In-memory [VoicePlayer] so the controller's play/pause/seek/speed wiring can
/// be tested without just_audio or the Web Audio DOM. Reports a known duration
/// so a play tap skips the network/decrypt load path.
class FakeVoicePlayer implements VoicePlayer {
  FakeVoicePlayer({Duration? duration}) : _duration = duration;

  final _state = StreamController<VoicePlayerState>.broadcast();
  final _pos = StreamController<Duration>.broadcast();
  final _dur = StreamController<Duration?>.broadcast();
  final Duration? _duration;

  final List<String> calls = <String>[];
  final List<double> speedCalls = <double>[];
  Duration? lastSeek;

  void emitPlaying(bool playing) =>
      _state.add(VoicePlayerState(playing: playing, completed: false));

  void emitCompleted() =>
      _state.add(VoicePlayerState(playing: false, completed: true));

  @override
  Stream<VoicePlayerState> get stateStream => _state.stream;
  @override
  Stream<Duration> get positionStream => _pos.stream;
  @override
  Stream<Duration?> get durationStream => _dur.stream;
  @override
  Duration? get duration => _duration;

  @override
  Future<void> setFilePath(String path) async => calls.add('setFilePath');
  @override
  Future<void> setUrl(String url) async => calls.add('setUrl');
  @override
  Future<void> setAudioBytes(Uint8List bytes) async => calls.add('setAudioBytes');
  @override
  Future<void> play() async {
    calls.add('play');
    emitPlaying(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    emitPlaying(false);
  }

  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seek(Duration position) async {
    calls.add('seek');
    lastSeek = position;
  }

  @override
  Future<void> setSpeed(double speed) async {
    calls.add('setSpeed');
    speedCalls.add(speed);
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    _state.close();
    _pos.close();
    _dur.close();
  }
}

MessageModel _voiceMessage({
  String? mediaUrl = 'https://example.test/media/msgs/x.bin',
}) => MessageModel(
      id: 1,
      content: '',
      senderId: 2,
      senderUsername: 'alice',
      conversationId: 7,
      createdAt: DateTime(2026, 1, 1),
      messageType: MessageType.voice,
      mediaUrl: mediaUrl,
      mediaDuration: 10,
    );

/// A voice note already in the audio cache, held in memory: every file under
/// [dir] exists and reads as [bytes] (a legacy plain note, so no content
/// store is needed to open it). Keeps the load path off the real disk, whose
/// futures would not complete under `testWidgets`.
base class _CachedNoteIo extends IOOverrides {
  _CachedNoteIo(this.dir, this.bytes);

  final String dir;
  final Uint8List bytes;

  @override
  File createFile(String path) =>
      path.startsWith(dir) ? _CachedNote(path, bytes) : super.createFile(path);
}

class _CachedNote implements File {
  _CachedNote(this.path, this.bytes);

  @override
  final String path;
  final Uint8List bytes;

  @override
  bool existsSync() => true;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

int _count(FakeVoicePlayer fake, String call) =>
    fake.calls.where((c) => c == call).length;

Widget _host(FakeVoicePlayer fake, MessageModel msg) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: PlaybackController(
        message: msg,
        playerFactory: () => fake,
        builder: (context, isPlaying, isLoading, position, duration, speed,
            togglePlayPause, seekFromWaveform, toggleSpeed) {
          return Column(
            children: [
              Text('playing:$isPlaying', key: const Key('playing')),
              Text('loading:$isLoading', key: const Key('loading')),
              Text('speed:$speed', key: const Key('speed')),
              Text('pos:${position.inMilliseconds}', key: const Key('pos')),
              Text('dur:${duration.inMilliseconds}', key: const Key('dur')),
              TextButton(onPressed: togglePlayPause, child: const Text('toggle')),
              TextButton(onPressed: toggleSpeed, child: const Text('speedbtn')),
              TextButton(
                  onPressed: () => seekFromWaveform(50, 100),
                  child: const Text('seek')),
            ],
          );
        },
      ),
    ),
  );
}

void main() {
  setUp(() => VoiceAudioCoordinator.instance.resetForTest());
  tearDown(() => VoiceAudioCoordinator.instance.resetForTest());

  testWidgets('play tap calls player.play and reflects isPlaying',
      (tester) async {
    final fake = FakeVoicePlayer(duration: const Duration(seconds: 10));
    await tester.pumpWidget(_host(fake, _voiceMessage()));

    await tester.tap(find.text('toggle'));
    await tester.pump();

    expect(fake.calls, contains('play'));
    expect(find.text('playing:true'), findsOneWidget);
  });

  testWidgets('second tap pauses', (tester) async {
    final fake = FakeVoicePlayer(duration: const Duration(seconds: 10));
    await tester.pumpWidget(_host(fake, _voiceMessage()));

    await tester.tap(find.text('toggle'));
    await tester.pump();
    await tester.tap(find.text('toggle'));
    await tester.pump();

    expect(fake.calls, containsAllInOrder(['play', 'pause']));
    expect(find.text('playing:false'), findsOneWidget);
  });

  testWidgets('speed toggle cycles 1x -> 1.5x -> 2x -> 1x', (tester) async {
    final fake = FakeVoicePlayer(duration: const Duration(seconds: 10));
    await tester.pumpWidget(_host(fake, _voiceMessage()));

    await tester.tap(find.text('speedbtn'));
    await tester.pump();
    await tester.tap(find.text('speedbtn'));
    await tester.pump();
    await tester.tap(find.text('speedbtn'));
    await tester.pump();

    expect(fake.speedCalls, [1.5, 2.0, 1.0]);
    expect(find.text('speed:1.0'), findsOneWidget);
  });

  testWidgets('waveform seek maps tap fraction to duration', (tester) async {
    final fake = FakeVoicePlayer(duration: const Duration(seconds: 10));
    await tester.pumpWidget(_host(fake, _voiceMessage()));

    await tester.tap(find.text('seek'));
    await tester.pump();

    // localX/width = 50/100 = 0.5 of a 10s clip = 5s.
    expect(fake.lastSeek, const Duration(seconds: 5));
  });

  testWidgets('coordinator pauses a previously-playing controller',
      (tester) async {
    final fake1 = FakeVoicePlayer(duration: const Duration(seconds: 10));
    final fake2 = FakeVoicePlayer(duration: const Duration(seconds: 10));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(height: 100, child: _PlaybackHarness(fake1, 'a')),
              SizedBox(height: 100, child: _PlaybackHarness(fake2, 'b')),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('toggle-a'));
    await tester.pump();
    await tester.tap(find.text('toggle-b'));
    await tester.pump();

    // Starting b must pause a via the coordinator.
    expect(fake1.calls, contains('pause'));
  });

  testWidgets('completion resets isPlaying and rewinds to zero',
      (tester) async {
    final fake = FakeVoicePlayer(duration: const Duration(seconds: 10));
    await tester.pumpWidget(_host(fake, _voiceMessage()));

    await tester.tap(find.text('toggle'));
    await tester.pump();
    expect(find.text('playing:true'), findsOneWidget);

    fake.emitCompleted();
    // First pump processes the state event; a second lets the post-frame
    // callback run stop()+seek(zero).
    await tester.pump();
    await tester.pump();

    expect(find.text('playing:false'), findsOneWidget);
    expect(fake.calls, contains('stop'));
    expect(fake.lastSeek, Duration.zero);
  });

  testWidgets(
      'a load cancelled by a tap stays cancelled when play is tapped again',
      (tester) async {
    // Each load first asks path_provider for the cache directory: holding
    // that answer holds the load in flight.
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    const cacheRoot = '/voice-cache-test';
    final inFlight = <Completer<String>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) {
      final gate = Completer<String>();
      inFlight.add(gate);
      return gate.future;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    IOOverrides.global = _CachedNoteIo(
      cacheRoot,
      Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
    );
    addTearDown(() => IOOverrides.global = null);

    final fake = FakeVoicePlayer();
    await tester.pumpWidget(_host(fake, _voiceMessage()));

    // Play: the first load is in flight.
    await tester.tap(find.text('toggle'));
    await tester.pump();
    expect(find.text('loading:true'), findsOneWidget);
    expect(inFlight, hasLength(1));

    // Tap again: cancelled.
    await tester.tap(find.text('toggle'));
    await tester.pump();
    expect(find.text('loading:false'), findsOneWidget);

    // Play again while the first load is still in flight.
    await tester.tap(find.text('toggle'));
    await tester.pump();
    expect(find.text('loading:true'), findsOneWidget);
    expect(inFlight, hasLength(2));

    // The cancelled load finishes first: it must not play, and the second
    // load is still loading.
    inFlight[0].complete(cacheRoot);
    await tester.pump();
    await tester.pump();
    expect(fake.calls, isNot(contains('play')));
    expect(fake.calls, isNot(contains('setAudioBytes')));
    expect(find.text('loading:true'), findsOneWidget);

    inFlight[1].complete(cacheRoot);
    await tester.pump();
    await tester.pump();
    expect(_count(fake, 'setAudioBytes'), 1);
    expect(_count(fake, 'play'), 1);
    expect(find.text('loading:false'), findsOneWidget);
    expect(find.text('playing:true'), findsOneWidget);
  });

  testWidgets('a voice note with no media URL says it failed to load',
      (tester) async {
    final fake = FakeVoicePlayer();
    await tester.pumpWidget(_host(fake, _voiceMessage(mediaUrl: null)));

    await tester.tap(find.text('toggle'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Failed to load audio'), findsOneWidget);
    expect(find.text('loading:false'), findsOneWidget);
    expect(fake.calls, isNot(contains('play')));

    // Let the toast leave.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}

class _PlaybackHarness extends StatelessWidget {
  const _PlaybackHarness(this.fake, this.tag);
  final FakeVoicePlayer fake;
  final String tag;

  @override
  Widget build(BuildContext context) {
    return PlaybackController(
      message: _voiceMessage(),
      playerFactory: () => fake,
      builder: (context, isPlaying, isLoading, position, duration, speed,
          togglePlayPause, seekFromWaveform, toggleSpeed) {
        return TextButton(onPressed: togglePlayPause, child: Text('toggle-$tag'));
      },
    );
  }
}
