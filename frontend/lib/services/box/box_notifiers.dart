import 'dart:async';
import 'dart:convert';
import 'dart:math';
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

/// A queue owed a notifier: its record entry, its key, its nid bytes.
typedef _Owed = ({ContactQueue queue, BoxQueueAuth auth, Uint8List nid});

/// Box push registration (metadata-privacy E9, owner decisions 2, 23, 32,
/// 34, 35, D6): a notifier on every NORMAL inbound contact queue this device
/// owns — never on its request queue (decision 2) or its self-queues, current
/// or retiring (decision 32), which live outside the contact records, and
/// never on a `blocked` or `former` contact's queue (decision 35: the box
/// cannot know a block, and a blocked peer holding the sid could ring an
/// offline device) — so a box message wakes a closed app with a bare
/// `{type:'new_message'}`. A contact blocked AFTER its notifier was
/// activated keeps it until the queue is deleted (accepted residual).
///
/// Registration is the box's two-step challenge, one per TOKEN (wire.md,
/// decision 34): step 1 makes the box push a code to the target, step 2
/// brings the code back with every owed queue, each entry signed by its own
/// queue key, [kBoxNotifierBatchMax] to a frame. A code the box refuses
/// whole is a stray from an earlier challenge, and the next one is awaited.
/// A code that never comes ends the pass — push does not reach this app now
/// — and so does a target the box refuses (`invalid_payload`). Either way
/// that target RESTS for `park` (15 min) before it is tried again: every
/// further challenge would only spend the 30 / 15 min budget, shared by
/// every device behind the same IP, and a web page re-runs on every return
/// to the screen. A new target goes ahead at once. A queue the box refuses
/// in a batch is gone; it is not offered again by this instance, since each
/// offer costs a push to the device.
///
/// What was activated, and under which target, is kept in the store's
/// `boxntf_v1` row, so a queue is activated once per push target, not once
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

  /// Nids the box refused in a batch: their queues are gone.
  final Set<String> _gone = {};
  bool _running = false;
  bool _again = false;
  bool _disposed = false;

  /// The target as the `boxntf_v1` row records it: SHA-256(platform 0x00
  /// token).
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
      E2eDiagLog.add('BOX_NOTIFIER_FAILED', {
        'error': e.runtimeType.toString(),
      });
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
    final owed = <_Owed>[
      for (final record in _store.all)
        if (record.state != ContactState.blocked &&
            record.state != ContactState.former)
          for (final queue in record.queues)
            if (!_gone.contains(queue.nid) &&
                !_store.notifierActive(queue.nid, id))
              if ((
                QueueKeys.authOf(queue),
                boxB64Decode(queue.nid, kBoxNidBytes),
              ) case (final BoxQueueAuth auth, final Uint8List nid))
                (queue: queue, auth: auth, nid: nid),
    ];
    if (owed.isEmpty || !_live) return;
    // Listening BEFORE the challenge — the push may beat its ack — into a
    // buffer: a StreamIterator alone subscribes only on its first moveNext.
    final inbox = StreamController<Uint8List>();
    final listening = _push.challengeCodes.listen(inbox.add);
    final codes = StreamIterator(inbox.stream);
    try {
      switch (await _box.challengeNotifier(target.platform, target.token)) {
        case BoxOk():
          break;
        case BoxRefused(code: BoxCode.rateLimited, :final retryAfter):
          _later(retryAfter);
          return;
        case BoxRefused(code: BoxCode.invalidPayload):
          // The box refuses the TARGET: every retry would get the same.
          _park(id);
          return;
        case BoxRefused() || BoxUnknown():
          return;
      }
      final clock = Stopwatch()..start();
      while (_live) {
        final left = _codeWait - clock.elapsed;
        final got =
            left > Duration.zero &&
            await codes.moveNext().timeout(left, onTimeout: () => false);
        if (!got) {
          E2eDiagLog.add('BOX_NOTIFIER_NO_CODE', {
            'platform': target.platform.name,
          });
          _park(id);
          return;
        }
        // A stray code (an earlier challenge's) is refused whole on the first
        // frame; then the next code is awaited.
        if (await _activate(owed, codes.current, id) != BoxCode.authFailed) {
          return;
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

  /// Activates [owed] with [code], a frame at a time, recording each frame's
  /// accepted nids as it lands. Null when every frame answered; else the
  /// refusal that ended it (`auth_failed` on the first frame = a stray code).
  Future<BoxCode?> _activate(
    List<_Owed> owed,
    Uint8List code,
    String target,
  ) async {
    var registered = 0;
    try {
      for (var start = 0; start < owed.length; start += kBoxNotifierBatchMax) {
        if (!_live) return null;
        final chunk = owed.sublist(
          start,
          min(start + kBoxNotifierBatchMax, owed.length),
        );
        final result = await _box.activateNotifiers(code, [
          for (final o in chunk) (queue: o.auth, nid: o.nid),
        ]);
        switch (result) {
          case BoxOk(value: final refused):
            final gone = {for (final nid in refused) boxB64(nid)};
            _gone.addAll(gone);
            final active = [
              for (final o in chunk)
                if (!gone.contains(o.queue.nid)) o.queue.nid,
            ];
            if (active.isNotEmpty &&
                !await _store.markNotifiers(active, target)) {
              return null;
            }
            registered += active.length;
          case BoxRefused(code: BoxCode.rateLimited, :final retryAfter):
            _later(retryAfter);
            return BoxCode.rateLimited;
          case BoxRefused(:final code):
            // Past the first frame the code was good: not a stray.
            return start == 0 ? code : null;
          case BoxUnknown():
            return null;
        }
      }
      return null;
    } finally {
      if (registered > 0) {
        E2eDiagLog.add('BOX_NOTIFIERS', {
          'registered': registered,
          'owed': owed.length,
        });
      }
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
