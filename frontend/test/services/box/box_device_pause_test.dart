import 'package:clock/clock.dart';
import 'package:fireplace/services/box/box_device_pause.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a full device is probed after 1 h, then after a wait that doubles up '
    'to 24 h and stays there (E93a)',
    () {
      var now = DateTime.utc(2026, 10, 5, 12);
      withClock(Clock(() => now), () {
        final pause = BoxDevicePause();
        expect(pause.full(1, 3), isTrue);

        // Each probe spent while the queue stays full: the wait before it.
        final waits = <Duration>[];
        var waited = Duration.zero;
        while (waits.length < 8) {
          now = now.add(const Duration(minutes: 1));
          waited += const Duration(minutes: 1);
          if (!pause.admit(1, 3)) continue;
          waits.add(waited);
          waited = Duration.zero;
          expect(pause.admit(1, 3), isFalse, reason: 'one probe per wait');
          expect(pause.full(1, 3), isFalse, reason: 'the pause goes on');
        }
        expect(waits, [
          for (final h in [1, 2, 4, 8, 16, 24, 24, 24]) Duration(hours: h),
        ]);
        expect(pause.admit(2, 3), isTrue, reason: 'paused per account');
        expect(pause.resume(1, 3), isTrue);
        expect(pause.admit(1, 3), isTrue);
        expect(pause.resume(1, 3), isFalse);
      });
    },
  );
}
