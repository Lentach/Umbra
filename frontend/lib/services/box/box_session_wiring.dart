part of 'box_session.dart';

/// What the app wires into a [BoxSession] (`MessagingProvider`,
/// `ConnectionProvider`): the inbox reader and the lookups its parts ask.
extension BoxSessionWiring on BoxSession {
  /// The app's reader of box deliveries (`MessagingProvider`). Wiring one
  /// offers it everything that landed in the journal meanwhile.
  BoxInboxConsumer? get consumer => _inbox.consumer;

  set consumer(BoxInboxConsumer? read) {
    _inbox.consumer = read;
    if (read != null) unawaited(_inbox.drain());
  }

  /// Called when the inbox has read everything queued so far (slice (g),
  /// E61d: one delivered receipt per drain).
  void Function()? get onReadsIdle => _inbox.onReadsIdle;

  set onReadsIdle(void Function()? idle) => _inbox.onReadsIdle = idle;

  /// Offers the journal again — the reader may be able to read what it
  /// refused (E2E just became ready).
  void drainInbox() {
    if (!_disposed) unawaited(_inbox.drain());
  }

  /// [drainInbox], completing once everything it offered has been read.
  Future<void> drainInboxSettled() async {
    if (_disposed) return;
    await _inbox.drain();
    await _inbox.idle;
  }

  /// The Signal side of the sibling swap (`MessagingProvider`).
  OwnDeviceEncrypt? get encryptForOwnDevice => _swap.encrypt;

  set encryptForOwnDevice(OwnDeviceEncrypt? encrypt) {
    _swap
      ..encrypt = encrypt
      ..run();
  }

  /// The own verified list, for the rotation on revoke (`MessagingProvider`).
  OwnLiveDevices? get ownLiveDevices => _rotation.liveDevices;

  set ownLiveDevices(OwnLiveDevices? lookup) {
    _rotation
      ..liveDevices = lookup
      ..run();
  }

  /// The Signal side of the friend handoff (`MessagingProvider`).
  FriendEncrypt? get encryptForFriend => _friends.encrypt;

  set encryptForFriend(FriendEncrypt? encrypt) {
    _friends
      ..encrypt = encrypt
      ..run();
  }

  /// Friends' verified lists, for the friend handoff (`MessagingProvider`).
  FriendLiveDevices? get friendLiveDevices => _friends.liveDevices;

  set friendLiveDevices(FriendLiveDevices? lookup) {
    _friends
      ..liveDevices = lookup
      ..run();
  }

  /// Friends' lists from the HELD list only, and whether a device can be
  /// sealed for with no fetch: what the upgrade one-shot's quiet pass reads
  /// (review 3, P2-1; `MessagingProvider`).
  FriendLiveDevices? get cachedFriendLiveDevices => _friends.cachedLiveDevices;

  set cachedFriendLiveDevices(FriendLiveDevices? lookup) {
    _friends.cachedLiveDevices = lookup;
  }

  Future<bool> Function(int userId, int device)? get friendSessionUsable =>
      _friends.sessionUsable;

  set friendSessionUsable(Future<bool> Function(int userId, int device)? f) {
    _friends.sessionUsable = f;
  }

  /// This account's device list, carried on request-queue frames to
  /// friends (slice (e), decision 50; `MessagingProvider`).
  Future<Map<String, dynamic>?> Function()? get ownDeviceList =>
      _friends.ownDeviceList;

  set ownDeviceList(Future<Map<String, dynamic>?> Function()? lookup) {
    _friends.ownDeviceList = lookup;
  }

  /// The devices friends' verified lists name revoked, for the rotation
  /// (slice (e), E50e; `MessagingProvider`).
  Future<Set<int>?> Function(int userId)? get friendRevokedDevices =>
      _friends.revokedDevices;

  set friendRevokedDevices(Future<Set<int>?> Function(int userId)? lookup) {
    _friends.revokedDevices = lookup;
  }

  /// Whether a friend's device has answered this device's Signal session
  /// with it (issue #208; `EncryptionProvider.friendAnsweredSession`): a
  /// handoff over no answered session goes to that device's request queue.
  SessionAnswered? get friendAnswered => _friends.answered;

  set friendAnswered(SessionAnswered? check) => _friends.answered = check;

  /// One handle lookup of a friend, for the request queues of its devices
  /// (E114b; `MessagingProvider.lookupFriendAddresses`): the answer reaches
  /// [takeServedAddresses].
  Future<bool> Function(int userId)? get friendAddressLookup =>
      _friends.addressLookup;

  set friendAddressLookup(Future<bool> Function(int userId)? lookup) {
    _friends.addressLookup = lookup;
  }
}
