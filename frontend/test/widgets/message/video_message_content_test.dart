import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/widgets/message/inline_video_arbiter.dart';
import 'package:fireplace/widgets/message/video_message_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

/// Counts slot traffic so tests can assert the bubble's arbiter behaviour
/// without a live [VideoPlayerController].
class _RecordingArbiter extends InlineVideoArbiter {
  _RecordingArbiter() : super.forTest();

  int requests = 0;

  /// `(priority, granted)` per request, in order.
  final List<(int, bool)> log = [];

  @override
  bool request(Object owner, VoidCallback onRevoke, {required int priority}) {
    requests++;
    final granted = super.request(owner, onRevoke, priority: priority);
    log.add((priority, granted));
    return granted;
  }
}

MessageModel _videoMessage({
  String? mediaUrl,
  bool keyed = true,
  int id = 7,
  DateTime? createdAt,
  int? duration = 12,
}) =>
    MessageModel(
      id: id,
      content: '',
      senderId: 1,
      senderUsername: 'alice',
      conversationId: 10,
      deliveryStatus: MessageDeliveryStatus.read,
      messageType: MessageType.video,
      createdAt: createdAt ?? DateTime(2026, 1, 1, 14, 30),
      mediaUrl: mediaUrl,
      mediaKey: keyed ? 'k' : null,
      mediaIv: keyed ? 'iv' : null,
      mediaDuration: duration,
      mediaWidth: 360,
      mediaHeight: 480,
      encryptedContent: 'cipher',
    );

Future<void> _pumpBubble(
  WidgetTester tester,
  MessageModel message, {
  SettingsProvider? settings,
  InlineVideoArbiter? arbiter,
}) {
  final app = MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: VideoMessageContent(message: message, arbiter: arbiter),
        ),
      ),
    ),
  );
  return tester.pumpWidget(
    settings == null
        ? app
        : ChangeNotifierProvider<SettingsProvider>.value(
            value: settings,
            child: app,
          ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('without a SettingsProvider the bubble is a static poster', (
    tester,
  ) async {
    final arbiter = _RecordingArbiter();
    await _pumpBubble(tester, _videoMessage(mediaUrl: 'https://x/v.bin'),
        arbiter: arbiter);
    await tester.pump();

    // No provider in the tree means autoplay OFF — poster + play badge, no
    // inline player, no mute control, and the arbiter is never bothered.
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('video_inline_mute_toggle')), findsNothing);
    expect(find.byType(VideoPlayer), findsNothing);
    expect(arbiter.requests, 0);
  });

  testWidgets(
    'autoplay ON but still-sending (no uploaded blob) never requests the slot',
    (tester) async {
      final arbiter = _RecordingArbiter();
      await _pumpBubble(
        tester,
        _videoMessage(mediaUrl: null),
        settings: SettingsProvider(), // autoplayVideos defaults true
        arbiter: arbiter,
      );
      await tester.pump();
      await tester.pump();

      expect(arbiter.requests, 0);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byType(VideoPlayer), findsNothing);
    },
  );

  testWidgets(
    'visible autoplay bubble requests the slot; a failed load falls back to '
    'the poster silently and releases it',
    (tester) async {
      final arbiter = _RecordingArbiter();
      await _pumpBubble(
        tester,
        _videoMessage(mediaUrl: 'https://example.com/media/msgs/v.bin'),
        settings: SettingsProvider(),
        arbiter: arbiter,
      );
      // Post-frame visibility check → arbiter request → load; test HTTP is
      // stubbed to fail, so the load lands in the silent-fallback branch.
      await tester.pump();
      await tester.pumpAndSettle();

      expect(arbiter.requests, 1);
      // Silent fallback: poster restored, slot given back, no error copy.
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byType(VideoPlayer), findsNothing);
      expect(find.text('Video failed to load'), findsNothing);
      expect(
        find.byKey(const ValueKey('video_inline_mute_toggle')),
        findsNothing,
      );
      expect(arbiter.holds(tester.state(find.byType(VideoMessageContent))),
          isFalse);
    },
  );

  testWidgets(
    'two visible clips: the NEWER message holds the slot even when the older '
    'bubble mounts after it, and the denied one retries once the slot frees',
    (tester) async {
      // Owner, 2026-09-06: on chat open the second-to-last video played and
      // the last sat blurred — "latest requester wins" was mount order.
      final arbiter = _RecordingArbiter();
      final newer = _videoMessage(
        id: 2,
        createdAt: DateTime(2026, 1, 1, 14, 31),
        mediaUrl: 'https://example.com/media/msgs/new.bin',
      );
      final older = _videoMessage(
        id: 1,
        createdAt: DateTime(2026, 1, 1, 14, 30),
        mediaUrl: 'https://example.com/media/msgs/old.bin',
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: SettingsProvider(),
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: Column(
                children: [
                  // Newer first in the tree, so its post-frame request runs
                  // FIRST and the older bubble's request is the later one.
                  SizedBox(
                    height: 200,
                    child: VideoMessageContent(message: newer, arbiter: arbiter),
                  ),
                  SizedBox(
                    height: 200,
                    child: VideoMessageContent(message: older, arbiter: arbiter),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final newerP = newer.createdAt.millisecondsSinceEpoch;
      final olderP = older.createdAt.millisecondsSinceEpoch;
      expect(arbiter.log.take(2), [(newerP, true), (olderP, false)]);

      // The newer clip's (stubbed) load fails and releases the slot; the
      // denied older bubble must re-request on that release, without any
      // scroll, and get it — and the failed newer bubble must NOT retry on
      // its own release (that would loop, and hammer the server).
      await tester.pumpAndSettle();
      final afterOpen = arbiter.log.skip(2).toList();
      expect(afterOpen.where((e) => e.$1 == newerP), isEmpty);
      expect(afterOpen.last, (olderP, true));
    },
  );

  testWidgets(
    'a history row without its media keys never requests the slot, and '
    'requests it once the decrypt pass supplies them',
    (tester) async {
      // The server row carries the plaintext mediaUrl column before the
      // Signal pass reaches it. Loading then only fetches a blob it cannot
      // decrypt; and the row is rebuilt IN PLACE when the keys land, with no
      // scroll — so the update itself must re-evaluate.
      final arbiter = _RecordingArbiter();
      final settings = SettingsProvider();
      await _pumpBubble(
        tester,
        _videoMessage(mediaUrl: 'https://example.com/media/msgs/v.bin',
            keyed: false),
        settings: settings,
        arbiter: arbiter,
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(arbiter.requests, 0);
      final stateBefore = tester.state(find.byType(VideoMessageContent));

      await _pumpBubble(
        tester,
        _videoMessage(mediaUrl: 'https://example.com/media/msgs/v.bin'),
        settings: settings,
        arbiter: arbiter,
      );
      await tester.pump();
      await tester.pumpAndSettle();
      // Same State: the request came from didUpdateWidget, not from a fresh
      // initState — otherwise this test would pass without the fix.
      expect(
        identical(tester.state(find.byType(VideoMessageContent)), stateBefore),
        isTrue,
      );
      expect(arbiter.requests, 1);
    },
  );

  testWidgets(
    'a route pushed over the chat stops inline requests; popping it '
    're-requests without a scroll',
    (tester) async {
      // The chat page stays laid out under an opaque route, so localToGlobal
      // still reports the bubble on screen — without the route check a
      // decrypted blob would keep playing behind Settings, and nothing else
      // re-evaluates on the way back (no scroll, no settings flip).
      final arbiter = _RecordingArbiter();
      final settings = SettingsProvider();
      await _pumpBubble(
        tester,
        _videoMessage(mediaUrl: 'https://example.com/media/msgs/v.bin'),
        settings: settings,
        arbiter: arbiter,
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(arbiter.requests, 1);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      expect(arbiter.requests, 1, reason: 'covered: must not request');

      navigator.pop();
      await tester.pumpAndSettle();
      expect(arbiter.requests, 2, reason: 'current again: re-request');
    },
  );

  // The `m:ss` on the poster's duration chip (the bubble is a static poster
  // here: no SettingsProvider, so autoplay is off and the chip shows).
  final shownDurations = <int, String>{
    1: '0:01',
    9: '0:09',
    59: '0:59',
    60: '1:00',
    61: '1:01',
    600: '10:00',
    3725: '62:05', // minutes are not wrapped at the hour
  };
  for (final MapEntry(key: seconds, value: label) in shownDurations.entries) {
    testWidgets('a $seconds s clip shows "$label" on its chip', (tester) async {
      await _pumpBubble(
        tester,
        _videoMessage(mediaUrl: 'https://x/v.bin', duration: seconds),
      );
      await tester.pump();

      expect(find.text(label), findsOneWidget);
    });
  }

  for (final seconds in <int?>[0, -5, null]) {
    testWidgets('a clip of $seconds s has no duration chip', (tester) async {
      await _pumpBubble(
        tester,
        _videoMessage(mediaUrl: 'https://x/v.bin', duration: seconds),
      );
      await tester.pump();

      expect(find.textContaining(RegExp(r'^\d+:\d\d$')), findsNothing);
    });
  }
}
