import 'package:fireplace/services/wake_up_mute.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final now = DateTime.utc(2026, 11, 23, 12);
  ({bool muted, DateTime? until}) chat({bool muted = true, DateTime? until}) =>
      (muted: muted, until: until);

  group('allChatsMutedUntil (decision 149)', () {
    test('no chat at all is not "every chat muted"', () {
      expect(allChatsMutedUntil(const [], now), isNull);
    });

    test('one chat that is not muted keeps wake-ups audible', () {
      expect(
        allChatsMutedUntil([chat(), chat(muted: false), chat()], now),
        isNull,
      );
    });

    test('a mute that already ran out counts as not muted', () {
      expect(
        allChatsMutedUntil([
          chat(),
          chat(until: now.subtract(const Duration(minutes: 1))),
        ], now),
        isNull,
      );
    });

    test('every chat muted forever', () {
      expect(allChatsMutedUntil([chat(), chat()], now), kWakeUpMutedForever);
    });

    test('timed mutes: silent until the FIRST one runs out', () {
      final soon = now.add(const Duration(hours: 1));
      expect(
        allChatsMutedUntil([
          chat(until: now.add(const Duration(days: 7))),
          chat(),
          chat(until: soon),
        ], now),
        soon.toIso8601String(),
      );
    });
  });

  group('wakeUpIsSilenced', () {
    test('nothing stored, or something unreadable, is audible', () {
      expect(wakeUpIsSilenced(null, now), isFalse);
      expect(wakeUpIsSilenced('garbage', now), isFalse);
    });

    test('forever is silent', () {
      expect(wakeUpIsSilenced(kWakeUpMutedForever, now), isTrue);
    });

    test('a stored time is silent before it and audible from it on', () {
      final until = now.add(const Duration(hours: 1));
      final stored = until.toIso8601String();
      expect(wakeUpIsSilenced(stored, now), isTrue);
      expect(wakeUpIsSilenced(stored, until), isFalse);
      expect(
        wakeUpIsSilenced(stored, until.add(const Duration(seconds: 1))),
        isFalse,
      );
    });
  });

  test('what the app writes is what the wake-up handler reads; null clears it',
      () async {
    SharedPreferences.setMockInitialValues({});

    await writeWakeUpMute(kWakeUpMutedForever);
    expect(await readWakeUpMuteFresh(), kWakeUpMutedForever);

    await writeWakeUpMute(null);
    expect(await readWakeUpMuteFresh(), isNull);
  });
}
