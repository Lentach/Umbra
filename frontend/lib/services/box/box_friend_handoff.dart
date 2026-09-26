import 'dart:async';
import 'dart:convert';

import '../../utils/e2e_diag_log.dart';
import '../../utils/e2e_envelope.dart';
import '../../utils/e2e_persistent_diag.dart';
import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_client.dart';
import 'box_frame.dart';
import 'box_friends.dart';
import 'box_wire.dart';
import 'queue_keys.dart';
import 'queue_seal.dart';

/// How long a pass waits after a refusal that named no `retryAfter`.
const Duration kFriendHandoffRetry = Duration(seconds: 30);

/// How long a device that has not acknowledged a handoff waits before it is
/// handed the same queue again. Every handoff is one more blob in that
/// device's queue until it reads it — a friend away for weeks would
/// otherwise collect one per reconnect of ours (review).
const Duration kFriendHandoffResend = Duration(hours: 24);

/// Moves every existing friendship onto the box (metadata-privacy item 5,
/// slice (d), owner decision 47): this device's inbound queue for each
/// friend is handed, as an E2E `queue_handoff`, to every live device of that
/// friend that has not acknowledged it.
///
/// Where a handoff goes: the queue that friend's device handed US, when we
/// hold one (a normal frame, E20c); otherwise that device's public REQUEST
/// queue as the friends list names it (`friendsList` `devices`, an
/// account-bearing frame). A device on an app that predates the box
/// publishes no request queue and gets nothing: an old app never sees a
/// handoff. The later side to update hands off first, and the earlier one
/// hands back on receipt ([BoxFriendLink.takeFriendHandoff]), so neither
/// side needs to reconnect.
///
/// A pass runs once the account socket, E2E, the box and the store are all
/// ready on this connect (the sibling swap's gate, E3), again when a friends
/// list arrives and when a friend's device list changes. A device is handed
/// a given queue at most once per connect, and again only
/// [kFriendHandoffResend] after the last time ([ContactQueue.handedAt],
/// kept across connects). No queue is created for a friend with no device
/// to hand it to; a pass's new queues are subscribed in one frame.
/// `rate_limited` stops the pass and runs it again after `retryAfter`.
class BoxFriendHandoff {
  BoxFriendHandoff({
    required BoxClient box,
    required ContactStore store,
    required QueueKeys keys,
    required QueueSeal seal,
    required void Function() queueCreated,
    DateTime Function()? now,
  }) : _box = box,
       _store = store,
       _keys = keys,
       _seal = seal,
       _queueCreated = queueCreated,
       _now = now ?? DateTime.now;

  final BoxClient _box;
  final ContactStore _store;
  final QueueKeys _keys;
  final QueueSeal _seal;
  final void Function() _queueCreated;
  final DateTime Function() _now;

  /// The Signal side and the verified lists; nothing is handed until both
  /// are wired.
  FriendEncrypt? encrypt;
  FriendLiveDevices? liveDevices;

  /// Each friend device's request queue as the last friends list named it,
  /// by friend and device. Replaced whole by every list.
  Map<int, Map<int, ContactOutbound>> _requestQueues = const {};

  /// `user:device:sid` handed this connect.
  final Set<String> _handed = {};

  bool _accountReady = false;
  bool _e2eReady = false;
  bool _running = false;
  bool _again = false;
  bool _disposed = false;
  Timer? _retry;

  void accountReady() {
    _accountReady = true;
    _handed.clear();
    run();
  }

  /// The account socket dropped; E2E readiness is per connect.
  void accountLost() {
    _accountReady = false;
    _e2eReady = false;
    _retry?.cancel();
    _retry = null;
  }

  void e2eReady() {
    _e2eReady = true;
    run();
  }

  /// `friendsList`: a list of users, each with `devices: [{deviceId,
  /// requestSid, sealPub}]` (wire.md "Friends' request queues"). A device
  /// whose address is null or not spelled as the box spells a 32-byte id is
  /// left out: it has not published one (an app that predates the box).
  ///
  /// The pass runs once the contact store has settled: the same list is
  /// what writes a friend first named here into the store (`FriendsProvider`
  /// queues that write just before), and a pass that reads the store before
  /// it lands skips that friend until the next connect (found live: a
  /// friendship made while this device was away).
  void takeFriendsList(Object? data) {
    if (data is! List) return;
    final queues = <int, Map<int, ContactOutbound>>{};
    for (final user in data) {
      if (user case {'id': final int userId, 'devices': final List<Object?> devices}) {
        queues[userId] = {
          for (final device in devices)
            if (device case {
              'deviceId': final int deviceId,
              'requestSid': final String sid,
              'sealPub': final String sealPub,
            } when boxB64Decode(sid, kBoxSidBytes) != null &&
                boxB64Decode(sealPub, 32) != null)
              deviceId: ContactOutbound(
                peerDeviceId: deviceId,
                sid: sid,
                sealPub: sealPub,
              ),
        };
      }
    }
    _requestQueues = queues;
    unawaited(_store.settled.then((_) => run()));
  }

  /// [userId]'s devices may have changed, or it must be handed our queue
  /// again now ([BoxFriendLink.handOffTo]).
  void friendChanged(int userId) {
    _handed.removeWhere((key) => key.startsWith('$userId:'));
    run();
  }

  /// Records that [userId]'s [deviceId] was handed [sid] outside a pass (a
  /// hand-back on receipt, a re-key), so no pass repeats it this connect or
  /// before [kFriendHandoffResend].
  void noteHanded(int userId, int deviceId, String sid) {
    _handed.add('$userId:$deviceId:$sid');
    unawaited(_markHanded(userId, deviceId, sid));
  }

  Future<void> _markHanded(int userId, int deviceId, String sid) {
    final at = _now();
    return _store.update(userId, (current) {
      if (current == null) return null;
      final i = current.queues.indexWhere((q) => q.sid == sid);
      if (i < 0) return null;
      return current.copyWith(
        queues: [...current.queues]
          ..[i] = current.queues[i].withHanded(deviceId, at),
      );
    });
  }

  /// Where [userId]'s [deviceId] takes a handoff: the queue it handed us,
  /// else its request queue (account-bearing). Null: nowhere yet.
  ({ContactOutbound to, bool viaRequest})? targetOf(int userId, int deviceId) {
    final held = _store
        .byUserId(userId)
        ?.outbound
        .where((o) => o.peerDeviceId == deviceId)
        .firstOrNull;
    if (held != null) return (to: held, viaRequest: false);
    final request = _requestQueues[userId]?[deviceId];
    return request == null ? null : (to: request, viaRequest: true);
  }

  /// Seals [frame] to [target] — as an account-bearing frame of this
  /// account on a request queue — and sends it; the box's answer.
  Future<BoxResult<void>?> send(
    ({ContactOutbound to, bool viaRequest}) target,
    BoxFrame frame,
  ) async {
    final own = _store.userId;
    final sid = boxB64Decode(target.to.sid, kBoxSidBytes);
    final sealPub = boxB64Decode(target.to.sealPub, 32);
    if (own == null || sid == null || sealPub == null) return null;
    final body = target.viaRequest
        ? BoxFrame(
            kind: frame.kind,
            senderDeviceId: frame.senderDeviceId,
            senderUserId: own,
            signal: frame.signal,
          ).encode()
        : frame.encode();
    final blob = await _seal.seal(sealPub, body);
    if (blob == null || _disposed) return null;
    return _box.send(sid, blob);
  }

  /// Runs a pass once every gate is open; one at a time, and a request made
  /// meanwhile runs another after it.
  void run() {
    if (_disposed ||
        !_accountReady ||
        !_e2eReady ||
        encrypt == null ||
        liveDevices == null ||
        _box.state != BoxState.ready ||
        !_store.isOpen) {
      return;
    }
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    unawaited(
      _pass().whenComplete(() {
        _running = false;
        if (_again && !_disposed) {
          _again = false;
          run();
        }
      }),
    );
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
  }

  Future<void> _pass() async {
    final lookup = liveDevices;
    if (lookup == null) return;
    final friends = [
      for (final record in _store.all)
        if (record.state == ContactState.friend &&
            (record.outbound.isNotEmpty ||
                (_requestQueues[record.userId]?.isNotEmpty ?? false)))
          record.userId,
    ];
    // Every lookup starts in this one turn, so a connect's lists leave as
    // one batched frame (E20a).
    final lists = await Future.wait([for (final f in friends) lookup(f)]);
    final created = <BoxQueueAuth>[];
    try {
      for (var i = 0; i < friends.length; i++) {
        if (_disposed || !_accountReady) return;
        final live = lists[i];
        if (live == null) continue;
        if (!await _handTo(friends[i], live, created)) return;
      }
    } finally {
      // One frame for the whole pass (chunked by the client past 256): the
      // box counts subscribe frames, 60 per 15 min per IP. A refused frame
      // leaves the rids in the client's set for its next reconnect.
      if (created.isNotEmpty && !_disposed) {
        final answer = await _box.subscribe(created);
        if (answer is! BoxOk) {
          E2ePersistentDiag.record('BOX_FRIEND_HANDOFF_FAILED', {
            'stage': 'subscribe',
            'queues': created.length,
          });
        }
      }
    }
  }

  /// Hands our queue for [userId] to each of its [live] devices that has a
  /// target and has not acknowledged it; a queue made for it goes into
  /// [created], to be subscribed with the rest of the pass. False to stop
  /// the pass (rate limited: a retry is armed).
  Future<bool> _handTo(
    int userId,
    Set<int> live,
    List<BoxQueueAuth> created,
  ) async {
    final targets = {
      for (final d in live) d: ?targetOf(userId, d),
    };
    if (targets.isEmpty) return true;
    final hadQueue = _store.byUserId(userId)?.queues.isNotEmpty ?? false;
    final ensured = await _keys.ensureInbound(userId, subscribe: false);
    final ContactQueue queue;
    switch (ensured) {
      case InboundQueueCreated(queue: final q):
        queue = q;
      case InboundQueueNotCreated(:final answer):
        return _refused(answer, 'create');
      case InboundQueueNotStored():
        return true;
    }
    if (!hadQueue) {
      if (QueueKeys.authOf(queue) case final auth?) created.add(auth);
      // A new queue gets its push notifier (E9) like every contact queue.
      _queueCreated();
    }
    final handoff = jsonEncode(
      E2eEnvelope.buildQueueHandoff(sid: queue.sid, sealPub: queue.sealPub),
    );
    for (final MapEntry(key: device, value: target) in targets.entries) {
      if (queue.ackedBy.contains(device)) continue;
      final key = '$userId:$device:${queue.sid}';
      if (_handed.contains(key)) continue;
      final last = queue.handedAt[device];
      if (last != null && _now().difference(last) < kFriendHandoffResend) {
        continue;
      }
      final seal = encrypt;
      if (_disposed || seal == null) return false;
      final frame = await seal(userId, device, handoff);
      if (frame == null) {
        E2ePersistentDiag.record('BOX_FRIEND_HANDOFF_FAILED', {
          'device': device,
          'stage': 'encrypt',
        });
        continue;
      }
      final answer = await send(target, frame);
      if (answer is BoxOk) {
        _handed.add(key);
        await _markHanded(userId, device, queue.sid);
        E2eDiagLog.add('BOX_FRIEND_HANDOFF_SENT', {
          'device': device,
          'viaRequest': target.viaRequest,
        });
        continue;
      }
      if (answer is BoxRefused<void> && answer.code == BoxCode.rateLimited) {
        return _refused(answer, 'send');
      }
      E2ePersistentDiag.record('BOX_FRIEND_HANDOFF_FAILED', {
        'device': device,
        'stage': 'send',
        'answer': switch (answer) {
          BoxRefused<void>(:final code) => code.wire,
          BoxUnknown<void>(:final reason) => reason.name,
          _ => 'seal',
        },
      });
    }
    return true;
  }

  /// A refusal while handing off: a rate limit stops the pass and arms a
  /// retry; anything else is recorded and the pass goes on.
  bool _refused(BoxResult<Object?> answer, String stage) {
    final limited = answer is BoxRefused<Object?> &&
        answer.code == BoxCode.rateLimited;
    E2ePersistentDiag.record('BOX_FRIEND_HANDOFF_FAILED', {
      'stage': stage,
      if (limited) 'rateLimited': true,
    });
    if (answer is! BoxRefused<Object?> || !limited) return true;
    _retry?.cancel();
    _retry = Timer(answer.retryAfter ?? kFriendHandoffRetry, () {
      _retry = null;
      run();
    });
    return false;
  }
}
