import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../utils/e2e_diag_log.dart';
import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_client.dart';
import 'box_wire.dart';
import 'queue_keys.dart';

/// This device's push address as the box takes it: an FCM token, or a Web
/// Push subscription as `PushSubscription.toJSON()` (wire.md, box bullet).
typedef BoxPushTarget = ({NotifierPlatform platform, String token});

/// What notifier registration needs from the platform push layer.
abstract interface class BoxPushSource {
  /// Null when this device cannot take a challenge NOW: push unsupported or
  /// not permitted, no token yet, or the app is not in the foreground (the
  /// challenge code reaches the running app only).
  Future<BoxPushTarget?> target();

  /// The token or subscription changed (FCM rotation, a new subscription).
  Stream<void> get targetChanged;

  /// The code of every `notifier_challenge` push, decoded ([kBoxCodeBytes]).
  Stream<Uint8List> get challengeCodes;
}

enum _Step { registered, skipped, stop }

/// Box push registration (metadata-privacy E9, owner decisions 2, 23, 32,
/// D6): a notifier on every NORMAL inbound contact queue this device owns —
/// never on its request queue (decision 2) or its self-queue (decision 32),
/// which live outside the contact records — so a box message wakes a closed
/// app with a bare `{type:'new_message'}`.
///
/// Registration is the box's two-step challenge (wire.md): step 1 makes the
/// box push a code to the target, step 2 brings the code back signed by the
/// queue key. The pushed code does not name its queue, so queues are
/// registered ONE AT A TIME; a code that fails to activate is a stray from
/// an earlier challenge, and the next one is awaited. A code that never
/// comes ends the pass — push does not reach this app now — and so does a
/// target the box refuses (`invalid_payload`: every queue would get the same
/// answer). Either way that target RESTS for `park` (15 min) before it is tried
/// again: every further challenge would only spend the 30 / 15 min budget,
/// shared by every device behind the same IP, and a web page re-runs on
/// every return to the screen. A new target goes ahead at once.
///
/// What was activated, and under which target, is kept in the store's
/// `boxntf_v1` row, so a queue is challenged once per push target, not once
/// per launch. A new target (token rotation) re-registers every queue.
class BoxNotifiers {
  BoxNotifiers({
    required BoxClient box,
    required ContactStore store,
    required BoxPushSource push,
    Duration codeWait = const Duration(seconds: 30),
    Duration park = const Duration(minutes: 15),
  }) : _box = box,
       _store = store,
       _push = push,
       _codeWait = codeWait,
       _parkFor = park;

  final BoxClient _box;
  final ContactStore _store;
  final BoxPushSource _push;
  final Duration _codeWait;
  final Duration _parkFor;

  StreamSubscription<void>? _changes;
  Timer? _retry;

  /// A target resting after it failed (see the class doc).
  String? _parked;
  bool _running = false;
  bool _again = false;
  bool _disposed = false;

  /// The target as the `boxntf_v1` row records it: the same
  /// SHA-256(platform 0x00 token) the step-1 signature covers.
  static String targetId(BoxPushTarget target) => boxB64(
    sha256
        .convert(utf8.encode('${target.platform.name}\x00${target.token}'))
        .bytes,
  );

  /// Follows target changes.
  void start() {
    _changes ??= _push.targetChanged.listen((_) => run());
  }

  /// Registers every queue still owed. Overlapping triggers run one pass,
  /// then one more if any came in meanwhile.
  void run() {
    if (_disposed) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    unawaited(_loop());
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    unawaited(_changes?.cancel());
  }

  bool get _live => !_disposed && _store.isOpen;

  Future<void> _loop() async {
    try {
      do {
        _again = false;
        await _pass();
      } while (_again);
    } on Object catch (e) {
      E2eDiagLog.add('BOX_NOTIFIER_FAILED', {'error': e.runtimeType.toString()});
    } finally {
      _running = false;
    }
  }

  Future<void> _pass() async {
    if (_store.notifiersUnsupported) return;
    final target = await _push.target();
    if (target == null) return;
    final id = targetId(target);
    if (id == _parked) return;
    var registered = 0;
    for (final record in _store.all) {
      for (final queue in record.queues) {
        if (!_live) return;
        if (_store.notifierActive(queue.nid, id)) continue;
        switch (await _register(queue, target, id)) {
          case _Step.registered:
            registered++;
          case _Step.skipped:
            break;
          case _Step.stop:
            E2eDiagLog.add('BOX_NOTIFIERS', {
              'registered': registered,
              'stopped': true,
            });
            return;
        }
      }
    }
    if (registered > 0) {
      E2eDiagLog.add('BOX_NOTIFIERS', {'registered': registered});
    }
  }

  Future<_Step> _register(
    ContactQueue queue,
    BoxPushTarget target,
    String id,
  ) async {
    final auth = QueueKeys.authOf(queue);
    final nid = boxB64Decode(queue.nid, kBoxNidBytes);
    if (auth == null || nid == null) return _Step.skipped;
    // Listening BEFORE the challenge — the push may beat its ack — into a
    // buffer: a StreamIterator alone subscribes only on its first moveNext.
    final inbox = StreamController<Uint8List>();
    final listening = _push.challengeCodes.listen(inbox.add);
    final codes = StreamIterator(inbox.stream);
    try {
      final asked = await _box.challengeNotifier(
        auth,
        nid,
        target.platform,
        target.token,
      );
      switch (asked) {
        case BoxOk():
          break;
        case BoxRefused(code: BoxCode.rateLimited, :final retryAfter):
          _later(retryAfter);
          return _Step.stop;
        case BoxRefused(code: BoxCode.invalidPayload):
          _park(id);
          return _Step.stop;
        case BoxRefused():
          // The box does not take this queue's key (gone, reaped): there is
          // nothing to wake.
          return _Step.skipped;
        case BoxUnknown():
          return _Step.stop;
      }
      final clock = Stopwatch()..start();
      while (true) {
        final left = _codeWait - clock.elapsed;
        final got =
            left > Duration.zero &&
            await codes.moveNext().timeout(left, onTimeout: () => false);
        if (!got) {
          E2eDiagLog.add('BOX_NOTIFIER_NO_CODE', {
            'platform': target.platform.name,
          });
          _park(id);
          return _Step.stop;
        }
        switch (await _box.activateNotifier(auth, nid, codes.current)) {
          case BoxOk():
            await _store.markNotifier(queue.nid, id);
            return _Step.registered;
          case BoxRefused(code: BoxCode.authFailed):
            continue;
          case BoxRefused(code: BoxCode.rateLimited, :final retryAfter):
            _later(retryAfter);
            return _Step.stop;
          case BoxRefused() || BoxUnknown():
            return _Step.stop;
        }
      }
    } finally {
      await listening.cancel();
      await codes.cancel();
      // Never awaited: a buffer nobody listened to (a refused challenge)
      // completes its close only once listened to — that is, never.
      unawaited(inbox.close());
    }
  }

  void _later(Duration? retryAfter) {
    _retry?.cancel();
    _retry = Timer(retryAfter ?? const Duration(minutes: 1), run);
  }

  void _park(String id) {
    _parked = id;
    _retry?.cancel();
    _retry = Timer(_parkFor, () {
      _parked = null;
      run();
    });
  }
}
