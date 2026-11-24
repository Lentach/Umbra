part of '../connection_provider.dart';

// Extension methods on ConnectionProvider's own state: notifyListeners() is legitimate here.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// The box session's teardown paths: a revoked device's or install's queues,
/// a previous device life's, and releasing the account's state.
extension ConnectionBox on ConnectionProvider {
  /// Looks up the device lists a box send reads once E2E AND the account
  /// socket are both ready this connect — whichever comes last triggers it.
  void _refreshBoxDeviceLists() {
    if (_accountReady) _messagingProvider?.refreshBoxDeviceLists();
  }

  /// THIS device was revoked (spec §5.5 + amendment (xxvi)).
  ///
  /// Stops the reconnect loop FIRST: the server is about to drop the socket,
  /// and without this the backoff would keep retrying a session the connect
  /// gate now refuses, ending on a generic "Connection lost" banner instead of
  /// the real reason. The actual logout is delegated, because only the auth
  /// layer owns session state — and only the widget layer holds the locale for
  /// the notice.
  void _onOwnDeviceRevoked(Object? data) {
    final deviceId = data is Map ? data['deviceId'] : null;
    final reason = data is Map && data['reason'] is String
        ? data['reason'] as String
        : null;
    E2eDiagLog.add('DEVICE_REVOKED', {'deviceId': deviceId, 'reason': reason});
    _intentionalDisconnect = true;
    _reconnectManager.resetAttempts();
    _socketService.disconnect();
    _isConnected = false;
    // A §6.2 reset or a restore moves the recovering install off its old id
    // and evicts that id (`rehomed`) from every socket but the recovering
    // one: another tab of that install still sits on it with the same store,
    // so its queues are the recovering tab's. Every other revoked id deletes.
    // The connect gate says neither, so a tab that missed the live eviction
    // is told apart by the stored session (shared by every tab): a rebind
    // moved it to the new id, a revoke left it on the revoked one. Read
    // BEFORE the logout below clears it.
    final rehomed = data is Map && data['rehomed'] == true;
    if (!rehomed && deviceId is int) {
      _retireOwnQueues(
        (_encryptionProvider?.storedSessionDeviceId() ?? Future.value()).then(
          (stored) => stored == deviceId,
        ),
      );
    }
    notifyListeners();
    onDeviceRevoked?.call(reason);
  }

  /// Issue #205/#208: this device's queues go with it — when [stillThisDevice]
  /// says the install holds no newer session. Taken out of the providers
  /// first, so nothing sends or subscribes through it meanwhile; the logout
  /// or fresh device life that follows finds no box to close. Whatever is not
  /// deleted within [wait] stays owed in `boxgone_v1`.
  void _retireOwnQueues(
    Future<bool> stillThisDevice, {
    Duration wait = BoxSession.kRetireWait,
  }) {
    final box = _box;
    if (box == null) return;
    _box = null;
    _boxUserId = null;
    _unwireBox();
    final retiring = box.retireRevokedDevice(
      proceed: stillThisDevice,
      wait: wait,
    );
    _boxRetiring = retiring;
    unawaited(
      retiring.whenComplete(() {
        if (identical(_boxRetiring, retiring)) _boxRetiring = null;
      }),
    );
  }

  /// Issue #234: the server refused this install's session as `Device
  /// revoked` over REST (the boot's refresh) — no account socket ever said
  /// `deviceRevoked`, so nothing retired the queues (#205). With this
  /// account's box in hand, they go the #205 way. Without one (a cold start
  /// gets no session at all), the queues are deleted from the store alone:
  /// it holds their keys, and the box needs no account. A store that cannot
  /// open (a locked web vault) deletes nothing; a delete the box does not
  /// confirm stays owed in `boxgone_v1`, as #205's.
  void retireRevokedInstall(
    int userId, {
    required String baseUrl,
    required ContactStore Function() store,
    required BoxClient Function(String baseUrl) box,
  }) {
    if (_box != null && _boxUserId == userId) {
      _retireOwnQueues(Future.value(true));
      return;
    }
    if (_box != null || _installRetiring != null) return;
    final contacts = store();
    final session = BoxSession(
      box: box(baseUrl),
      store: contacts,
      emit: (_, _) {},
    );
    Future<void> retire() async {
      try {
        await contacts.open(userId);
      } on ContactStoreUnavailable catch (e) {
        E2eDiagLog.add('BOX_REVOKED_RETIRE_SKIPPED', {'stage': e.stage});
        session.dispose();
        return;
      }
      await session.retireRevokedDevice(proceed: Future.value(true));
    }

    final retiring = retire().whenComplete(contacts.close);
    _installRetiring = retiring;
    unawaited(
      retiring.whenComplete(() {
        if (identical(_installRetiring, retiring)) _installRetiring = null;
      }),
    );
  }

  /// Takes the box, its media and the chat lists out of the app and closes
  /// the contact store — after a revoked box that is still deleting its
  /// queues ([_boxRetiring], issue #205): the store holds their keys.
  /// Completes once the store is closed; [mayClose], asked when the delete
  /// ends, keeps it open for a session that started meanwhile.
  Future<void> _releaseAccountState({bool Function()? mayClose}) {
    _friendsProvider?.clearAll();
    _conversationsProvider?.clearAll();
    _messagingProvider?.clearAll();
    _box?.dispose();
    _box = null;
    _boxUserId = null;
    unawaited(BoxPushNids.clear());
    _boxMedia?.dispose();
    _boxMedia = null;
    ProfilePhotoCache.shared.unbind();
    _unwireBox();
    final store = _contactStore;
    final retiring = _boxRetiring;
    if (retiring == null) {
      store?.close();
      return Future.value();
    }
    return retiring.whenComplete(() {
      if (mayClose?.call() ?? true) store?.close();
    });
  }

  /// Issue #208: this install is a previous device life of the account (the
  /// stale link gate) and the device it was is revoked: every way out of the
  /// gate — a link, a stale restore, a reset — starts a new device life, so
  /// the old life's queues are deleted NOW rather than at the link. While
  /// they exist a friend whose list still names the old device fills them
  /// and wakes this device with pushes nobody can read. A live secondary
  /// that signed out and back in keeps them: its phrase restore keeps its
  /// history, and a link retires them ([_startFreshDeviceLife]). The served
  /// list is read once the account socket is ready; no answer keeps them
  /// for the link. The stamp is re-read BEFORE the box is taken: the
  /// reconnect right after a link still sees the cached verdict, and
  /// retiring on it would stop the new life's box. A delete the box does not
  /// confirm stays owed in `boxgone_v1`.
  Future<void> _retirePreviousLifeQueues() async {
    final encryption = _encryptionProvider;
    final userId = _currentUserId;
    final box = _box;
    if (encryption == null || userId == null || box == null) return;
    if (!_accountReady) return;
    if (!await encryption.stillPreviousDeviceLife(userId)) return;
    if (await encryption.stampedDeviceRevoked(userId) != true) return;
    if (!identical(_box, box) || _currentUserId != userId) return;
    E2eDiagLog.add('BOX_PREVIOUS_LIFE_RETIRE', const {});
    _retireOwnQueues(encryption.stillPreviousDeviceLife(userId));
  }

  /// Takes the box out of the messaging provider: nothing sends, fetches or
  /// subscribes through it any more.
  void _unwireBox() {
    _messagingProvider
      ?..boxOutbox = null
      ..boxSiblings = null
      ..boxFriends = null
      ..boxFirstContact = null
      ..boxMedia = null
      ..profilePhotos = null;
  }
}
