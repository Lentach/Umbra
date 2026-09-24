import 'dart:async';
import 'dart:typed_data';

import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_client.dart';
import 'box_inbox.dart';
import 'box_outbox.dart';
import 'box_wire.dart';
import 'queue_keys.dart';
import 'queue_seal.dart';

/// One account session's link to the box (metadata-privacy PR3.1 slice (a)):
/// owns the [BoxClient] and keeps this device's REQUEST queue published on
/// the account socket (`setRequestQueue`, wire.md "First contact").
///
/// Two independent connections meet here — the box socket (no account on
/// its path, I1) and the account socket (JWT) — so publishing waits for
/// both: the queue exists only once the box has answered, and the server
/// files it under the device the account socket's JWT names.
///
/// Published at most once per (device id, sid) per SESSION — the dedupe
/// lives in RAM, so every launch, tab and reload publishes again (the
/// server overwrites the same value; the event is throttled at 30 / 15 min).
/// A new device id — a §6.2 reset re-homes the account — or a replaced queue
/// publishes again; a refused or unanswered publish is re-sent on the next
/// ready, a rate-limited one after `retryAfterMs`.
///
/// It also RECEIVES (slice (b)): once the box is ready and the store is
/// open, every contact's inbound queue is subscribed, and its [BoxInbox]
/// journals, acks and offers each delivery to [consumer].
///
/// And it SENDS (slice (c)): as the [BoxOutbox], it hands the messaging send
/// path a friend's addresses and seals each frame into its queue.
class BoxSession implements BoxOutbox {
  BoxSession({
    required BoxClient box,
    required ContactStore store,
    required void Function(String event, Object? data) emit,
    QueueSeal? seal,
  }) : _box = box,
       _store = store,
       _keys = QueueKeys(box: box, store: store),
       _seal = seal ?? QueueSeal(),
       _emit = emit {
    _inbox = BoxInbox(box: box, store: store, seal: _seal);
  }

  final BoxClient _box;
  final ContactStore _store;
  final QueueKeys _keys;
  final QueueSeal _seal;
  late final BoxInbox _inbox;
  final void Function(String event, Object? data) _emit;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  ContactQueue? _request;
  bool _ensuring = false;

  /// Null until the account socket is ready; the device id it names (null
  /// from a server that predates the field — the server still files it).
  ({int? deviceId})? _account;
  String? _published;
  String? _inFlight;
  Timer? _retry;
  bool _disposed = false;

  /// The app's reader of box deliveries (`MessagingProvider`). Wiring one
  /// offers it everything that landed in the journal meanwhile.
  BoxInboxConsumer? get consumer => _inbox.consumer;

  set consumer(BoxInboxConsumer? read) {
    _inbox.consumer = read;
    if (read != null) unawaited(_inbox.drain());
  }

  /// Offers the journal again — the reader may be able to read what it
  /// refused (E2E just became ready).
  void drainInbox() {
    if (!_disposed) unawaited(_inbox.drain());
  }

  /// Connects the box and starts following it.
  void start() {
    _inbox.start();
    _subscriptions
      ..add(
        _box.states.listen((state) {
          if (state != BoxState.ready) return;
          if (_request == null) unawaited(_ensure());
          unawaited(_receive());
        }),
      )
      ..add(_box.lostQueues.listen(_onLost));
    _box.connect();
  }

  /// Reconnects the box after [close] (the account reconnected).
  void resume() {
    if (!_disposed) _box.connect();
  }

  /// Drops the box connection; [resume] brings it back.
  void close() => _box.close();

  /// The account socket is ready (`socketReady`) as [deviceId].
  void accountReady(int? deviceId) {
    _account = (deviceId: deviceId);
    _inFlight = null;
    if (_request == null) {
      unawaited(_ensure());
    } else {
      _publish();
    }
  }

  /// The contact store (re)opened — a web vault that booted locked was just
  /// unlocked, or a slow open landed after the budget. Every earlier attempt
  /// found it closed, and neither socket will say "ready" again on its own.
  void storeOpened() {
    if (_request == null) unawaited(_ensure());
    unawaited(_receive());
  }

  /// The account socket dropped: an answer still owed will never come.
  void accountLost() {
    _account = null;
    _inFlight = null;
    _retry?.cancel();
  }

  /// `requestQueueSet { success, error?, retryAfterMs? }`.
  void onRequestQueueSet(Object? data) {
    final sent = _inFlight;
    _inFlight = null;
    if (sent == null || data is! Map) return;
    if (data['success'] == true) {
      _published = sent;
      return;
    }
    final retryMs = data['retryAfterMs'];
    if (data['error'] == 'rate_limited' && retryMs is int) {
      _retry?.cancel();
      _retry = Timer(Duration(milliseconds: retryMs), _publish);
    }
  }

  @override
  Map<int, ContactOutbound> addressesFor(int peerUserId) {
    // Answered whatever the box's state: a peer the box covers must FAIL a
    // send while it is down (decision 19), never fall back to the old path
    // and leave a server row naming the pair (decision 15). A closed store
    // holds no records, so `byUserId` answers null below.
    if (_disposed) return const {};
    final peer = _store.byUserId(peerUserId);
    if (peer == null || peer.state != ContactState.friend) return const {};
    return {for (final to in peer.outbound) to.peerDeviceId: to};
  }

  @override
  Future<bool> deliver(ContactOutbound to, Uint8List body) async {
    final sid = boxB64Decode(to.sid, kBoxSidBytes);
    final sealPub = boxB64Decode(to.sealPub, 32);
    if (_disposed || sid == null || sealPub == null) return false;
    final blob = await _seal.seal(sealPub, body);
    if (blob == null || _disposed) return false;
    return await _box.send(sid, blob) is BoxOk;
  }

  @override
  Future<int?> nextLocalId() => _store.allocateLocalId();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retry?.cancel();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _inbox.dispose();
    _box.dispose();
  }

  /// Subscribes every contact queue the box is not already following, then
  /// offers what the journal holds. The box keeps the set and re-signs it on
  /// every reconnect, so each queue is subscribed here once per session.
  Future<void> _receive() async {
    if (_disposed || _box.state != BoxState.ready || !_store.isOpen) return;
    final following = {for (final rid in _box.subscribed) boxB64(rid)};
    final missing = [
      for (final queue in _keys.inbound())
        if (!following.contains(boxB64(queue.rid))) queue,
    ];
    if (missing.isNotEmpty) await _box.subscribe(missing);
    if (!_disposed) await _inbox.drain();
  }

  Future<void> _ensure() async {
    if (_ensuring || _disposed || _box.state != BoxState.ready) return;
    _ensuring = true;
    try {
      final queue = await _keys.ensureRequest();
      if (_disposed || queue == null) return;
      _request = queue;
      _publish();
    } finally {
      _ensuring = false;
    }
  }

  /// A reconnect's subscribe refused the request queue: it is gone for good.
  /// Forgotten here; the `ready` that follows the resubscribe runs
  /// [QueueKeys.ensureRequest], which sees the same refusal, drops the stored
  /// row and creates a replacement.
  void _onLost(BoxRefusal refusal) {
    if (boxB64(refusal.rid) == _request?.rid) _request = null;
  }

  void _publish() {
    final account = _account;
    final queue = _request;
    if (_disposed || account == null || queue == null) return;
    final key = '${account.deviceId}:${queue.sid}';
    if (key == _published || key == _inFlight) return;
    _inFlight = key;
    _emit('setRequestQueue', {'sid': queue.sid, 'sealPub': queue.sealPub});
  }
}
