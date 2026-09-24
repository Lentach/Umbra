import 'dart:async';

import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_client.dart';
import 'box_wire.dart';
import 'queue_keys.dart';

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
class BoxSession {
  BoxSession({
    required BoxClient box,
    required ContactStore store,
    required void Function(String event, Object? data) emit,
  }) : _box = box,
       _keys = QueueKeys(box: box, store: store),
       _emit = emit;

  final BoxClient _box;
  final QueueKeys _keys;
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

  /// Connects the box and starts following it.
  void start() {
    _subscriptions
      ..add(
        _box.states.listen((state) {
          if (state == BoxState.ready && _request == null) unawaited(_ensure());
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

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retry?.cancel();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _box.dispose();
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
