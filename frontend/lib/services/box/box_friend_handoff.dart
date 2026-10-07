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
/// kept across connects) — sooner once it is heard from ([friendHeard]). No
/// queue is created for a friend with no device to hand it to. A pass makes
/// its queues first, subscribes the new ones in ONE frame, and only then
/// hands them: a queue the box does not follow yet is never handed.
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

  /// This account's device list as its authorization record, carried
  /// outside Signal on every request-queue frame (slice (e), decision 50):
  /// a newly linked device announces itself to a friend whose list predates
  /// it. Null, or answering null (not enrolled, not verifiable now): the
  /// frame carries none.
  Future<Map<String, dynamic>?> Function()? ownDeviceList;

  /// The device ids a friend's VERIFIED list names REVOKED (slice
  /// (e), E50e); null or empty: none known.
  Future<Set<int>?> Function(int userId)? revokedDevices;

  /// Each friend device's request queue as the last friends list named it,
  /// by friend and device. Replaced whole by every list.
  Map<int, Map<int, ContactOutbound>> _requestQueues = const {};

  /// `user:device:sid` handed this connect.
  final Set<String> _handed = {};

  /// `user:device` handed our queue again because it was heard from, this
  /// session ([friendHeard]).
  final Set<String> _heard = {};

  /// `user:device:listVersion` our own list was announced to (E50d).
  final Set<String> _announced = {};

  /// `user:device:stage:code` already in the durable log this session.
  final Set<String> _failures = {};

  /// Queues a pass made that the box has not taken a subscribe for yet, by
  /// rid. None is handed until it has: every later pass asks again first.
  final Map<String, BoxQueueAuth> _unsubscribed = {};

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
      if (user case {
        'id': final int userId,
        'devices': final List<Object?> devices,
      }) {
        queues[userId] = {
          for (final device in devices)
            if (device
                case {
                  'deviceId': final int deviceId,
                  'requestSid': final String sid,
                  'sealPub': final String sealPub,
                }
                when boxB64Decode(sid, kBoxSidBytes) != null &&
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

  /// A message from friend [userId]'s device [deviceId] was read
  /// ([BoxFriendLink.friendHeard]): a device that has not acknowledged our
  /// queue, was handed it on an earlier connect and still talks to us lost
  /// that handoff, so it gets it again now rather than a day later — once
  /// per device per session.
  void friendHeard(int userId, int deviceId) {
    if (_disposed) return;
    final record = _store.byUserId(userId);
    final queue = record?.queues.firstOrNull;
    if (record?.state != ContactState.friend ||
        queue == null ||
        queue.ackedBy.contains(deviceId) ||
        !queue.handedAt.containsKey(deviceId) ||
        _handed.contains('$userId:$deviceId:${queue.sid}') ||
        !_heard.add('$userId:$deviceId')) {
      return;
    }
    unawaited(
      _store
          .update(userId, (current) {
            final i =
                current?.queues.indexWhere((q) => q.sid == queue.sid) ?? -1;
            if (current == null || i < 0) return null;
            return current.copyWith(
              queues: [...current.queues]
                ..[i] = current.queues[i].withoutHanded(deviceId),
            );
          })
          .then((_) => friendChanged(userId)),
    );
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
  /// else its request queue (account-bearing) — as the friends list names
  /// it, or, for a friendship made over the box that no server list names,
  /// as the search answer did ([ContactBoxOrigin.addresses], slice (f)).
  /// Null: nowhere yet.
  ({ContactOutbound to, bool viaRequest})? targetOf(int userId, int deviceId) {
    final record = _store.byUserId(userId);
    final held = record?.outbound
        .where((o) => o.peerDeviceId == deviceId)
        .firstOrNull;
    if (held != null) return (to: held, viaRequest: false);
    final request =
        _requestQueues[userId]?[deviceId] ??
        record?.boxOrigin?.addresses
            .where((a) => a.peerDeviceId == deviceId)
            .firstOrNull;
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
    String? list;
    if (target.viaRequest) {
      final auth = await ownDeviceList?.call();
      final json = auth == null ? null : jsonEncode(auth);
      if (json != null && BoxFrame.carriedListFits(json, frame.signal.length)) {
        list = json;
      } else if (json != null) {
        // A device history too long for the frame: the handoff goes out
        // without it, and the friend learns this device from the answer our
        // other devices give its next frame's stale view (E50f).
        E2eDiagLog.add('BOX_OWN_LIST_TOO_LONG', {'chars': json.length});
      }
    }
    if (_disposed) return null;
    final body = target.viaRequest
        ? BoxFrame(
            kind: frame.kind,
            senderDeviceId: frame.senderDeviceId,
            senderUserId: own,
            signal: frame.signal,
            carriedList: list,
          ).encode()
        : frame.encode();
    final blob = await _seal.seal(sealPub, body);
    if (blob == null || _disposed) return null;
    // A handoff carries no message: quiet, so it never wakes the friend's
    // closed device with an empty "new message" card (decision 91).
    return _box.send(sid, blob, mode: BoxSendMode.quiet);
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
                (_requestQueues[record.userId]?.isNotEmpty ?? false) ||
                (record.boxOrigin?.addresses.isNotEmpty ?? false)))
          record.userId,
    ];
    // Every lookup starts in this one turn, so a connect's lists leave as
    // one batched frame (E20a).
    final lists = await Future.wait([for (final f in friends) lookup(f)]);
    // Every queue the pass hands is made first, so its new ones go out in
    // ONE subscribe frame (chunked by the client past 256): the box counts
    // subscribe frames, 60 per 15 min per IP.
    final plans = <({int userId, ContactQueue queue, Map<int, _Target> to})>[];
    for (var i = 0; i < friends.length; i++) {
      if (_disposed || !_accountReady) return;
      final live = lists[i];
      if (live == null) continue;
      final userId = friends[i];
      // Slice (e): a device the friend revoked loses its address here and,
      // when it held our queue, our queue moves on without it (E50e).
      final revoked = await revokedDevices?.call(userId);
      if (revoked != null && revoked.isNotEmpty) {
        await _rotateAwayFromRevoked(userId, revoked);
      }
      await _retireExpired(userId);
      final targets = {for (final d in live) d: ?targetOf(userId, d)};
      if (targets.isEmpty) continue;
      final hadQueue = _store.byUserId(userId)?.queues.isNotEmpty ?? false;
      switch (await _keys.ensureInbound(userId, subscribe: false)) {
        case InboundQueueCreated(:final queue):
          if (!hadQueue) {
            if (QueueKeys.authOf(queue) case final auth?) {
              _unsubscribed[queue.rid] = auth;
            }
            // A new queue gets its push notifier (E9) like every contact
            // queue.
            _queueCreated();
          }
          plans.add((userId: userId, queue: queue, to: targets));
        case InboundQueueNotCreated(:final answer):
          if (!_refused(answer, 'create', userId: userId)) return;
        case InboundQueueNotStored():
          continue;
      }
    }
    // A handoff invites that device to write into the queue: it goes out
    // only once the box follows the queue, or what the device writes is not
    // read before the next connect. A queue an earlier pass could not
    // subscribe is asked for again here.
    if (_unsubscribed.isNotEmpty) {
      if (_disposed) return;
      final asked = {..._unsubscribed};
      final answer = await _box.subscribe(asked.values);
      if (answer is BoxOk) {
        _unsubscribed.removeWhere((rid, _) => asked.containsKey(rid));
      } else if (!_refused(
        answer,
        'subscribe',
        extra: {'queues': asked.length},
      )) {
        return;
      }
    }
    for (final plan in plans) {
      if (_disposed || !_accountReady) return;
      if (_unsubscribed.containsKey(plan.queue.rid)) continue;
      if (!await _handTo(plan.userId, plan.queue, plan.to)) return;
    }
  }

  /// Slice (e), E50e, for friend [userId] whose verified list names the
  /// devices [revoked] REVOKED:
  ///  * the address of a revoked device is dropped (E7's rule);
  ///  * when our current queue was handed to (or acked by) one, it ROTATES:
  ///    a new queue leads, subscribed with this pass's others and handed
  ///    below to the live devices; the old one retires — still read, so what
  ///    a live device sent before it learned the new one arrives — and is
  ///    deleted once the box TTL has passed since
  ///    ([QueueKeys.retireInbound]).
  /// Only a device the list NAMES revoked counts, never one it merely does
  /// not name: another tab of this device may have adopted a newer list
  /// (a new device's handoff) that this tab's list predates.
  Future<void> _rotateAwayFromRevoked(int userId, Set<int> revoked) async {
    final record = _store.byUserId(userId);
    if (record == null) return;
    if (record.outbound.any((o) => revoked.contains(o.peerDeviceId))) {
      await _store.update(userId, (current) {
        if (current == null) return null;
        final kept = [
          for (final o in current.outbound)
            if (!revoked.contains(o.peerDeviceId)) o,
        ];
        return kept.length == current.outbound.length
            ? null
            : current.copyWith(outbound: kept);
      });
    }
    final lead = record.queues.firstOrNull;
    if (lead != null &&
        lead.retiredAt == null &&
        {...lead.ackedBy, ...lead.handedAt.keys}.any(revoked.contains)) {
      final next = await _keys.rotateInbound(userId, lead, now: _now());
      if (next != null) {
        if (QueueKeys.authOf(next) case final auth?) {
          _unsubscribed[next.rid] = auth;
        }
        _queueCreated();
        E2eDiagLog.add('BOX_FRIEND_QUEUE_ROTATED', {'peer': userId});
      }
    }
  }

  /// Deletes friend [userId]'s queues retired more than the box TTL ago
  /// (E50e): nothing a live device sent there can still arrive.
  Future<void> _retireExpired(int userId) async {
    final queues = _store.byUserId(userId)?.queues ?? const <ContactQueue>[];
    for (final queue in queues.skip(1)) {
      final at = queue.retiredAt;
      if (at != null && _now().difference(at) > kBoxRedeliveryWindow) {
        await _keys.retireInbound(userId, queue);
      }
    }
  }

  /// Sends [auth] — this account's device list — as a `list_update` to
  /// every live device of every friend this device holds an address for
  /// (E50d: a revoke, sent by every surviving device). True only when the
  /// box took every frame; a live device with no address is skipped (a
  /// request queue reads only handoffs; its own next handoff to us, or
  /// the stale-view answer of E50f, carries our list instead). A device
  /// that took this version is not sent it again by a retry in this
  /// process: one friend that cannot be reached must not cost every other
  /// friend a blob per connect.
  Future<bool> announceOwnList(Map<String, dynamic> auth) async {
    final lookup = liveDevices;
    final seal = encrypt;
    if (_disposed ||
        lookup == null ||
        seal == null ||
        _box.state != BoxState.ready ||
        !_store.isOpen) {
      return false;
    }
    final version = auth['listVersion'];
    final json = jsonEncode(E2eEnvelope.buildListUpdate(auth));
    var all = true;
    for (final record in _store.all) {
      if (record.state != ContactState.friend || record.outbound.isEmpty) {
        continue;
      }
      final live = await lookup(record.userId);
      if (live == null) {
        all = false;
        continue;
      }
      for (final to in record.outbound) {
        if (!live.contains(to.peerDeviceId)) continue;
        final key = '${record.userId}:${to.peerDeviceId}:$version';
        if (_announced.contains(key)) continue;
        final frame = await seal(record.userId, to.peerDeviceId, json);
        final answer = frame == null
            ? null
            : await send((to: to, viaRequest: false), frame);
        if (answer is BoxOk) {
          _announced.add(key);
        } else {
          all = false;
          _failed(
            'announce',
            _codeOf(answer),
            userId: record.userId,
            device: to.peerDeviceId,
          );
        }
      }
    }
    E2eDiagLog.add('BOX_OWN_LIST_ANNOUNCED', {'all': all});
    return all;
  }

  /// Hands [queue], our queue for [userId], to each device in [targets]
  /// that has not acknowledged it, at most once per connect and once per
  /// [kFriendHandoffResend]. False to stop the pass (rate limited: a retry
  /// is armed).
  Future<bool> _handTo(
    int userId,
    ContactQueue queue,
    Map<int, _Target> targets,
  ) async {
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
        _failed('encrypt', 'no_frame', userId: userId, device: device);
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
        return _refused(answer, 'send', userId: userId, device: device);
      }
      _failed('send', _codeOf(answer), userId: userId, device: device);
    }
    return true;
  }

  /// A refusal while handing off: a rate limit stops the pass and arms a
  /// retry; anything else is logged and the pass goes on.
  bool _refused(
    BoxResult<Object?> answer,
    String stage, {
    int? userId,
    int? device,
    Map<String, Object?> extra = const {},
  }) {
    _failed(
      stage,
      _codeOf(answer),
      userId: userId,
      device: device,
      extra: extra,
    );
    if (answer is! BoxRefused<Object?> || answer.code != BoxCode.rateLimited) {
      return true;
    }
    _retry?.cancel();
    _retry = Timer(answer.retryAfter ?? kFriendHandoffRetry, () {
      _retry = null;
      run();
    });
    return false;
  }

  /// Logs a failed step durably once per friend device, stage and code per
  /// session: a pass repeats on every connect and friends list, and the
  /// durable log keeps only [E2ePersistentDiag.kMaxEntries] lines. A repeat
  /// goes to the in-memory ring only.
  void _failed(
    String stage,
    String code, {
    int? userId,
    int? device,
    Map<String, Object?> extra = const {},
  }) {
    final data = {
      'device': ?device,
      'stage': stage,
      'code': code,
      ...extra,
    };
    if (_failures.add('${userId ?? '-'}:${device ?? '-'}:$stage:$code')) {
      E2ePersistentDiag.record('BOX_FRIEND_HANDOFF_FAILED', data);
    } else {
      E2eDiagLog.add('BOX_FRIEND_HANDOFF_FAILED', data);
    }
  }

  /// A box answer as the log names it; null is a blob that could not be
  /// sealed.
  static String _codeOf(BoxResult<Object?>? answer) => switch (answer) {
    BoxRefused<Object?>(:final code) => code.wire,
    BoxUnknown<Object?>(:final reason) => reason.name,
    _ => 'seal',
  };
}

typedef _Target = ({ContactOutbound to, bool viaRequest});
