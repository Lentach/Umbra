part of 'box_session.dart';

/// This device's OWN queues in a [BoxSession]: the request queue (ensured,
/// then published on the account socket) and the self-queue.
extension BoxSessionQueues on BoxSession {
  /// The self-queue to hand a sibling: the one the ROW holds, once this
  /// session ensured one. Any write re-reads the row, and another tab of
  /// this device may have rotated it meanwhile (E6): that queue is followed
  /// — subscribed here too — and the one this session ensured, now
  /// retiring, is never handed out again.
  ContactQueue? _currentSelf() {
    final ensured = _self;
    final current = _store.selfQueue;
    if (ensured == null || current == null || current.rid == ensured.rid) {
      return ensured;
    }
    final owned = QueueKeys.authOf(current);
    if (owned == null) return ensured;
    _self = current;
    unawaited(_box.subscribe([owned]));
    return current;
  }

  /// `requestQueueSet { success, error?, retryAfterMs? }`.
  void onRequestQueueSet(Object? data) {
    final sent = _inFlight;
    _inFlight = null;
    if (sent == null || data is! Map) return;
    if (data['success'] == true) {
      final first = _published == null;
      _published = sent;
      if (first) onBoxReady?.call();
      return;
    }
    final error = data['error'];
    final retryMs = data['retryAfterMs'];
    // `invalid_payload` and `unknown_device` are verdicts on this very
    // publish: the same one would be refused again, so it waits for the next
    // ready. Anything else (`internal`) is the server's own failure.
    if (error == 'invalid_payload' || error == 'unknown_device') return;
    _retry?.cancel();
    _retry = Timer(
      error == 'rate_limited' && retryMs is int
          ? Duration(milliseconds: retryMs)
          : kRequestQueueRetry,
      _publish,
    );
  }

  Future<void> _ensure() async {
    if (_ensuring || _disposed || _revoked || _box.state != BoxState.ready) {
      return;
    }
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

  Future<void> _ensureSelf() async {
    if (_ensuringSelf || _disposed || _revoked) return;
    if (_box.state != BoxState.ready) return;
    _ensuringSelf = true;
    try {
      final queue = await _keys.ensureSelf();
      if (_disposed || queue == null) return;
      // A rotation that landed while this ran is followed on the next read
      // ([_currentSelf]).
      _self = queue;
      _swap.run();
    } finally {
      _ensuringSelf = false;
    }
  }

  /// A reconnect's subscribe refused the request queue or the self-queue:
  /// it is gone for good. Forgotten here; the `ready` that follows the
  /// resubscribe ensures it again, which sees the same refusal, drops the
  /// stored row and creates a replacement.
  void _onLost(BoxRefusal refusal) {
    final rid = boxB64(refusal.rid);
    if (rid == _request?.rid) _request = null;
    if (rid == _self?.rid) _self = null;
  }

  void _publish() {
    final account = _account;
    final queue = _request;
    if (_disposed || !_e2eReady || account == null || queue == null) return;
    final key = '${account.deviceId}:${queue.sid}';
    if (key == _published || key == _inFlight) return;
    _inFlight = key;
    _emit('setRequestQueue', {'sid': queue.sid, 'sealPub': queue.sealPub});
  }
}
