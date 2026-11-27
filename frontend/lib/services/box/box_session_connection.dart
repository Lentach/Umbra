part of 'box_session.dart';

/// The connection half of a [BoxSession]: the box socket's start, resume
/// and close, what the account socket tells it (ready, answered, lost, E2E
/// ready), and the subscribe of the contact queues on a ready box.
extension BoxSessionConnection on BoxSession {
  /// E2E is ready on this connect: the request queue may be published, a
  /// handoff encrypted and the own list read now.
  void e2eReady() {
    if (_disposed) return;
    _e2eReady = true;
    _publish();
    _swap.e2eReady();
    _rotation.run();
    _friends.e2eReady();
    // The one migration runs BEFORE anything judges an address: the journal
    // drain, every probe and (through the gate) every permit wait for it.
    // On a closed store it does nothing and [storeOpened] runs it again.
    unawaited(
      _label().then((_) {
        if (_disposed) return;
        _probe.runAll(ProbeTrigger.connect);
        // The journal is judged by the first drain after E2E ready, the empty
        // one included and with no box connection (the write gate's clause).
        unawaited(_inbox.drain());
      }),
    );
  }

  /// Tags every untagged address with the anchor pinned now
  /// ([ContactStore.tagUntaggedAddresses]) on an OPEN store; one run at a
  /// time. Completes without error: a closed store or a failed write leaves
  /// the gate closed and the next trigger (E2E ready, box or account ready,
  /// store opened) runs it again. The first success kicks what waited.
  Future<void> _label() {
    // The anchors are loaded at E2E init: before it the mirror knows none and
    // a "labelling" would tag nothing yet count as done. A closed store has
    // nothing to label ([storeOpened] runs it again).
    if (_labelled || _disposed || !_e2eReady || !_store.isOpen) {
      return Future.value();
    }
    return _labelling ??= _runLabel().whenComplete(() => _labelling = null);
  }

  Future<void> _runLabel() async {
    try {
      final anchorOf = _anchorOf;
      if (anchorOf != null && !await _store.tagUntaggedAddresses(anchorOf)) {
        return;
      }
    } on Object catch (error) {
      E2eDiagLog.add('BOX_LABELLING_FAILED', {'error': error.runtimeType});
      return;
    }
    if (_disposed || !_store.isOpen) return;
    _labelled = true;
    onAddressesLabelled?.call();
    _probe.runAll(ProbeTrigger.connect);
  }

  /// The own verified device list was dropped (a device linked or revoked).
  void ownDevicesChanged() {
    if (_disposed) return;
    _swap.ownDevicesChanged();
    _rotation.run();
  }

  /// `ownRequestQueues { success, devices?, error?, retryAfterMs? }`.
  void onOwnRequestQueues(Object? data) {
    if (!_disposed) unawaited(_swap.onOwnRequestQueues(data));
  }

  /// Connects the box and starts following it. Only for a device that does
  /// E2E duty under its session (`ConnectionProvider` calls it once E2E is
  /// ready): a device on the link gate would subscribe the queues it holds
  /// and take messages it can never show (issue #205). Idempotent.
  void start() {
    if (_started || _disposed || _revoked) return;
    _started = true;
    _inbox.start();
    _notifiers?.start();
    _subscriptions
      ..add(
        _box.states.listen((state) {
          if (state != BoxState.ready || _revoked) return;
          if (_request == null) unawaited(_ensure());
          if (_self == null) unawaited(_ensureSelf());
          unawaited(_receive());
          unawaited(_deleteOwedQueues());
          _swap.run();
          _rotation.run();
          _registerPush();
          _friends.run();
          unawaited(_label());
          _probe.runAll(ProbeTrigger.connect);
        }),
      )
      ..add(_box.lostQueues.listen(_onLost));
    _box.connect();
  }

  /// Reconnects the box after [close] (the account reconnected); a box
  /// never [start]ed stays closed.
  void resume() {
    if (!_disposed && _started && !_revoked) _box.connect();
  }

  /// The app came back from the background
  /// (`ConnectionProvider.ensureReconnectIfNeeded`): the box connection is
  /// replaced only if it went dead meanwhile ([BoxClient.checkAlive]).
  void checkAlive() {
    if (!_disposed) _box.checkAlive();
  }

  /// Drops the box connection; [resume] brings it back.
  void close() => _box.close();

  /// Holds the box's subscribes until the account socket confirms the
  /// session (issue #206): a session made before its account socket
  /// confirmed it (`ConnectionProvider`). [accountReady] or
  /// [accountAnswered] releases.
  void holdSubscribes() => _box.holdSubscribes();

  /// Issue #206: makes every LOST box connection hold its subscribes too, and
  /// asks [confirm] once the next one is up and waiting: the account socket
  /// may claim connected while dead, this device revoked meanwhile. The owner
  /// answers with [accountAnswered] or [accountReady] (`deviceRevoked`
  /// retires the box instead).
  void confirmSessionWith(void Function() confirm) {
    _box
      ..holdOnLoss = true
      ..onHeldConnection = confirm;
  }

  /// The account socket answered (`serverTime`): the server still holds the
  /// session (a revoke closes it there), so the held subscribes go out.
  void accountAnswered() => _box.releaseSubscribes();

  /// The account socket is ready (`socketReady`) as [deviceId]: the server
  /// confirmed the session, so the queues may be subscribed (issue #206).
  void accountReady(int? deviceId) {
    _box.releaseSubscribes();
    _account = (deviceId: deviceId);
    _inFlight = null;
    if (_request == null) {
      unawaited(_ensure());
    } else {
      _publish();
    }
    _swap.accountReady(deviceId);
    // `socketReady` is what confirms this device's id for the own list.
    _rotation.run();
    if (deviceId != null) _friends.accountReady();
    unawaited(_label());
    _probe.runAll(ProbeTrigger.connect);
  }

  /// The contact store (re)opened — a web vault that booted locked was just
  /// unlocked, or a slow open landed after the budget. Every earlier attempt
  /// found it closed, and neither socket will say "ready" again on its own.
  void storeOpened() {
    if (!_started || _revoked) return;
    if (_request == null) unawaited(_ensure());
    if (_self == null) unawaited(_ensureSelf());
    if (_box.state == BoxState.ready) unawaited(_deleteOwedQueues());
    _swap.run();
    _rotation.run();
    _registerPush();
    _friends.run();
    // The migration first: the drain judges the journal and the probe reads
    // tags, neither before the store's addresses are labelled.
    unawaited(
      _label().then((_) {
        if (_disposed || _revoked) return;
        unawaited(_receive());
        _probe.runAll(ProbeTrigger.connect);
      }),
    );
  }

  /// A queue appeared, or the box is ready: every contact queue gets its
  /// push notifier (E9), and the push worker its nid → chat table (decision
  /// 77) — the worker has no other way to name the chat a wake-up is for.
  void _registerPush() {
    _nids?.sync();
    _notifiers?.run();
  }

  /// The account socket dropped: an answer still owed will never come, and
  /// no queue is subscribed until the next connect gate confirmed the
  /// session (issue #206) — a device revoked meanwhile hears
  /// `deviceRevoked` instead of `socketReady`.
  void accountLost() {
    _box.holdSubscribes();
    _account = null;
    _e2eReady = false;
    _inFlight = null;
    _retry?.cancel();
    // The sibling re-key guard ends with the connect: a sibling
    // that loses its session again on a later one is re-keyed again.
    // [_friendRekeyed] stays: decision 70 bounds what a forged frame can
    // time to one bundle fetch per friend device per session.
    _rekeyed.clear();
    _swap.accountLost();
    _friends.accountLost();
    // The next connect owes the connect probe again.
    _probe.connected();
  }

  /// Subscribes every contact queue the box is not already following, then
  /// offers what the journal holds. The box keeps the set and re-signs it on
  /// every reconnect, so each queue is subscribed here once per session.
  Future<void> _receive() async {
    if (_disposed || _revoked || _box.state != BoxState.ready) return;
    if (!_store.isOpen) return;
    final following = {for (final rid in _box.subscribed) boxB64(rid)};
    final missing = [
      for (final queue in _keys.inbound())
        if (!following.contains(boxB64(queue.rid))) queue,
    ];
    if (missing.isNotEmpty) await _box.subscribe(missing);
    if (!_disposed) await _inbox.drain();
    if (!_disposed) await _expireFirstContacts();
  }
}
