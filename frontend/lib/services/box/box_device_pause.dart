import 'dart:math' as math;

import 'package:clock/clock.dart';

/// The wait before a paused device is tried again, doubled after each try
/// up to [kBoxPauseMaxProbeWait] (E93a).
const Duration kBoxPauseFirstProbeWait = Duration(hours: 1);
const Duration kBoxPauseMaxProbeWait = Duration(hours: 24);

/// Devices whose box queue answered `queue_full` (E93a), by (user, device):
/// one of OUR other devices, or a friend's, that has not read its queue for
/// a while.
///
/// A paused device gets no frame sealed to it, because every frame sealed
/// moves its Signal sending chain ahead whether the box takes it or not, and
/// a receiver refuses a message more than 2000 steps ahead
/// (`session_cipher.dart`). It is tried again once per probe wait: the
/// first frame sealed after the wait is the probe, and the wait doubles.
/// A frame the box takes from it, or any frame that arrives from it, ends
/// the pause.
///
/// RAM only (decision 19): after a restart the first send finds the queue
/// full again, which costs one chain step.
class BoxDevicePause {
  final Map<(int, int), _Pause> _paused = {};

  /// Whether [deviceId] of [userId] is paused, spending nothing: receipts
  /// and typing skip a paused device and never carry its probe.
  bool isPaused(int userId, int deviceId) =>
      _paused.containsKey((userId, deviceId));

  /// Whether a frame may be sealed to [deviceId] of [userId] now. Answering
  /// yes for a paused device spends its probe: the next one is a doubled
  /// wait away.
  bool admit(int userId, int deviceId) {
    final pause = _paused[(userId, deviceId)];
    if (pause == null) return true;
    final now = clock.now();
    if (now.isBefore(pause.probeAt)) return false;
    pause.spendProbe(now);
    return true;
  }

  /// [deviceId] of [userId] answered `queue_full`. True when that starts a
  /// pause; an answer to a probe keeps the pause and its doubled wait.
  bool full(int userId, int deviceId) {
    final key = (userId, deviceId);
    if (_paused.containsKey(key)) return false;
    _paused[key] = _Pause(clock.now().add(kBoxPauseFirstProbeWait));
    return true;
  }

  /// [deviceId] of [userId] took a frame or sent one: it reads its queue.
  /// True when that ended a pause.
  bool resume(int userId, int deviceId) =>
      _paused.remove((userId, deviceId)) != null;

  /// Logout, dispose.
  void clear() => _paused.clear();
}

class _Pause {
  _Pause(this.probeAt);

  DateTime probeAt;
  Duration wait = kBoxPauseFirstProbeWait;

  /// The probe went out at [now]: the next one waits twice as long.
  void spendProbe(DateTime now) {
    wait = Duration(
      microseconds: math.min(
        wait.inMicroseconds * 2,
        kBoxPauseMaxProbeWait.inMicroseconds,
      ),
    );
    probeAt = now.add(wait);
  }
}
