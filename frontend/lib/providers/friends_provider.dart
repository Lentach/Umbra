import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/friend_request_model.dart';
import '../models/user_model.dart';
import '../models/invitation_state.dart';
import '../services/contacts/contact_record.dart';
import '../services/contacts/contact_store.dart';

/// FriendsProvider — owns all friends, friend requests, blocking, and
/// user search state. [ConnectionProvider] coordinates; this provider holds friends/requests/blocked/search.
class FriendsProvider extends ChangeNotifier {
  // ---------- State ----------
  List<UserModel> _friends = [];
  List<FriendRequestModel> _friendRequests = [];
  List<FriendRequestModel> _sentRequests = [];
  int _pendingRequestsCount = 0;
  List<UserModel> _blockedUsers = [];
  final Set<int> _blockedByUserIds = {};
  final Map<int, InvitationActionStatus> _requestActions = {};
  final Map<int, InvitationActionStatus> _sendActions = {};
  final Map<int, InvitationOutcome> _acceptedOutcomes = {};
  InvitationFailure? _lastInvitationFailure;
  PendingFriendAccepted? _pendingFriendAccepted;
  bool _hasIncomingSnapshot = false;
  bool _hasSentSnapshot = false;

  /// True once a server `friendsList` was applied this session. Before that
  /// the list may hold [ContactStore] hydration, which the FIRST server list
  /// — even an empty one — must replace: an empty first list is the server's
  /// truth for an account whose last friend was removed elsewhere, while the
  /// empty-snapshot guard in [onFriendsList] exists only for reconnects.
  bool _hasFriendsSnapshot = false;
  bool _hasBlockedSnapshot = false;
  static int _nextInvitationSessionNonce =
      DateTime.now().microsecondsSinceEpoch & 0xffffffff;
  final String _invitationSessionNonce =
      (_nextInvitationSessionNonce++ & 0xffffffff)
          .toRadixString(16)
          .padLeft(8, '0');
  int _invitationCorrelationCounter = 0;

  /// A dropped accept/decline/send ack used to strand the row: the in-flight
  /// entry is cleared only by the matching socket response, and a lost frame
  /// on a socket that stays connected schedules no reconnect. Bounded here,
  /// mirroring the 20 s round-trip budget of `_askServedMessageIds`.
  static const Duration _kInvitationAckTimeout = Duration(seconds: 20);
  final Map<int, Timer> _requestActionTimers = {};
  final Map<int, Timer> _sendActionTimers = {};
  List<UserModel>? _searchResults;

  int? _currentUserId;

  /// The client-owned contact list, when this session could open it. Read at
  /// connect ([hydrateFromStore]) and written through by every list/event
  /// handler below; the server lists stay authoritative for the UI while the
  /// legacy path exists.
  ContactStore? contactStore;

  ContactStore? get _store {
    final store = contactStore;
    if (store == null || !store.isOpen || store.userId != _currentUserId) {
      return null;
    }
    return store;
  }

  /// Fills each list the server has not filled yet this session from the
  /// contact store. Idempotent; a no-op after the server lists arrived, and a
  /// no-op while the store is closed or belongs to another account.
  void hydrateFromStore() {
    final store = _store;
    if (store == null) return;
    final self = store.self;
    var changed = false;
    if (_friends.isEmpty && !_hasFriendsSnapshot) {
      _friends = [
        for (final r in store.all)
          if (r.state == ContactState.friend) r.toUser(),
      ];
      changed |= _friends.isNotEmpty;
    }
    if (_friendRequests.isEmpty && !_hasIncomingSnapshot && self != null) {
      _friendRequests = [
        for (final r in store.all)
          if (r.state == ContactState.pendingIn && r.legacy.requestId != null)
            _requestFromRecord(r, sender: r.toUser(), receiver: self),
      ];
      changed |= _friendRequests.isNotEmpty;
    }
    if (_sentRequests.isEmpty && !_hasSentSnapshot && self != null) {
      _sentRequests = [
        for (final r in store.all)
          if (r.state == ContactState.pendingOut && r.legacy.requestId != null)
            _requestFromRecord(r, sender: self, receiver: r.toUser()),
      ];
      changed |= _sentRequests.isNotEmpty;
    }
    if (_blockedUsers.isEmpty) {
      _blockedUsers = [
        for (final r in store.all)
          if (r.state == ContactState.blocked) r.toUser(),
      ];
      changed |= _blockedUsers.isNotEmpty;
    }
    if (changed) notifyListeners();
  }

  static FriendRequestModel _requestFromRecord(
    ContactRecord record, {
    required UserModel sender,
    required UserModel receiver,
  }) =>
      FriendRequestModel(
        id: record.legacy.requestId!,
        sender: sender,
        receiver: receiver,
        status: 'pending',
        createdAt: record.legacy.requestCreatedAt ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  /// Store write for a server list: every listed peer is upserted into
  /// [state], and — in the SAME lock, decided on disk state — every record
  /// in [state] that the list omits is swept ([_unlisted]). That state ONLY:
  /// a `friendRequestsList` never touches a friend and a `blockedList` never
  /// touches a pending request. A `former` record the list names again takes
  /// the listed state and keeps its queues.
  void _storeList(
    ContactState state,
    List<UserModel> peers, {
    Map<int, FriendRequestModel> requests = const {},
    bool prune = true,
  }) {
    final store = _store;
    if (store == null) return;
    final byId = {for (final p in peers) p.id: p};
    unawaited(
      store.reconcile(
        byId.keys,
        (id, current) {
          final peer = byId[id]!;
          final request = requests[id];
          final base = (current ?? ContactRecord.fromUser(peer, state))
              .withProfile(peer)
              .copyWith(state: state);
          return request == null
              ? base
              : base.copyWith(
                  legacy: base.legacy.copyWith(
                    requestId: request.id,
                    requestCreatedAt: request.createdAt,
                  ),
                );
        },
        sweep: prune ? (r) => r.state == state ? _unlisted(r) : r : null,
      ),
    );
  }

  /// A record a server list stopped naming. Absence from a list is INFERRED,
  /// not an event (only `unfriended`, `youWereBlocked` and a decline are):
  /// the list may be wrong, and a record holding queue material no server can
  /// re-supply — this device's queue keys, the peer's send addresses — must
  /// survive that, so it is kept as [ContactState.former]. Anything else is
  /// removed.
  static ContactRecord? _unlisted(ContactRecord record) =>
      record.queues.isEmpty && record.outbound.isEmpty
          ? null
          : record.copyWith(state: ContactState.former);

  void _storeRequest(FriendRequestModel request, ContactState state) {
    final peer = state == ContactState.pendingIn
        ? request.sender
        : request.receiver;
    _storeList(state, [peer], requests: {peer.id: request}, prune: false);
  }

  /// Re-applies the current server snapshots to a store that was closed and
  /// re-opened underneath a live socket (passcode re-lock → unlock): events
  /// that arrived while it was closed were not written through, so the RAM
  /// lists are the freshest truth. Each list is re-applied only once the
  /// server actually sent it — before that the RAM list IS the store's own
  /// hydration and a rewrite would prune nothing and prove nothing.
  void rewriteStore() {
    if (_hasFriendsSnapshot) {
      _storeList(ContactState.friend, _friends, prune: _friends.isNotEmpty);
    }
    if (_hasIncomingSnapshot) {
      _storeList(
        ContactState.pendingIn,
        [for (final r in _friendRequests) r.sender],
        requests: {for (final r in _friendRequests) r.sender.id: r},
      );
    }
    if (_hasSentSnapshot) {
      _storeList(
        ContactState.pendingOut,
        [for (final r in _sentRequests) r.receiver],
        requests: {for (final r in _sentRequests) r.receiver.id: r},
      );
    }
    _storeList(ContactState.blocked, _blockedUsers, prune: _hasBlockedSnapshot);
  }

  // ---------- Emit Callback ----------

  /// Callback to emit socket events. Set by [ConnectionProvider] via [setEmitCallback].
  void Function(String event, dynamic data)? _emit;

  /// Wire the socket emit callback so FriendsProvider can send events
  /// without depending on SocketService directly.
  void setEmitCallback(void Function(String event, dynamic data) emit) {
    _emit = emit;
  }

  // ---------- Cross-Provider Callbacks ----------

  /// Called when conversations for a user should be removed (e.g. unfriend, block).
  /// Wired by the wiring layer (e.g. ConversationsScreen) when [ConversationsProvider] exists.
  void Function(int userId)? onRemoveConversationsForUser;

  // ---------- Public Getters ----------

  List<UserModel> get friends => _friends;
  List<FriendRequestModel> get friendRequests => _friendRequests;
  List<FriendRequestModel> get sentRequests => _sentRequests;
  int get pendingRequestsCount => _pendingRequestsCount;
  List<UserModel> get blockedUsers => _blockedUsers;
  Set<int> get blockedByUserIds => Set.unmodifiable(_blockedByUserIds);
  List<UserModel>? get searchResults => _searchResults;
  int? get currentUserId => _currentUserId;

  InvitationActionStatus? invitationActionFor(int requestId) {
    return _requestActions[requestId];
  }

  InvitationActionStatus? sendActionFor(int userId) {
    return _sendActions[userId];
  }

  InvitationOutcome? acceptedOutcomeForPeer(int peerUserId) {
    return _acceptedOutcomes[peerUserId];
  }

  List<InvitationOutcome> acceptedOutcomesFor(
    InvitationDirection direction,
  ) {
    return List.unmodifiable(
      _acceptedOutcomes.values.where(
        (outcome) => outcome.direction == direction,
      ),
    );
  }

  bool get hasLoadedInvitationsOnce =>
      _hasIncomingSnapshot && _hasSentSnapshot;

  /// Whether a server `friendsList` was applied this session. The list can be
  /// non-empty BEFORE that (contact-store hydration), so "is it empty" no
  /// longer answers "has the server spoken".
  bool get hasFriendsSnapshot => _hasFriendsSnapshot;

  InvitationFailure? consumeInvitationFailure() {
    final failure = _lastInvitationFailure;
    _lastInvitationFailure = null;
    return failure;
  }

  PendingFriendAccepted? consumePendingFriendAccepted() {
    final accepted = _pendingFriendAccepted;
    _pendingFriendAccepted = null;
    return accepted;
  }

  bool isFriend(int userId) {
    return _friends.any((f) => f.id == userId);
  }

  bool _requestHasPeer(FriendRequestModel request, int peerUserId) {
    return request.sender.id == peerUserId || request.receiver.id == peerUserId;
  }

  // ---------- Event Handlers (called by socket events, routed from ConnectionProvider) ----------

  void onFriendRequestsList(dynamic data) {
    final list = data as List<dynamic>;
    _friendRequests = list
        .map((r) => FriendRequestModel.fromJson(r as Map<String, dynamic>))
        .toList();
    _hasIncomingSnapshot = true;
    _storeList(
      ContactState.pendingIn,
      [for (final r in _friendRequests) r.sender],
      requests: {for (final r in _friendRequests) r.sender.id: r},
    );
    notifyListeners();
  }

  void onSentRequestsList(dynamic data) {
    final list = data as List<dynamic>;
    _sentRequests = list
        .map((r) => FriendRequestModel.fromJson(r as Map<String, dynamic>))
        .toList();
    _hasSentSnapshot = true;
    _storeList(
      ContactState.pendingOut,
      [for (final r in _sentRequests) r.receiver],
      requests: {for (final r in _sentRequests) r.receiver.id: r},
    );
    notifyListeners();
  }

  void onNewFriendRequest(dynamic data) {
    final request = FriendRequestModel.fromJson(data as Map<String, dynamic>);
    // Dedup by id like onFriendRequestSent: a socket re-emit would otherwise
    // add a duplicate incoming row until the next full snapshot.
    _friendRequests.removeWhere((existing) => existing.id == request.id);
    _friendRequests.insert(0, request);
    _storeRequest(request, ContactState.pendingIn);
    notifyListeners();
  }

  void onFriendRequestSent(dynamic data) {
    final request = FriendRequestModel.fromJson(data as Map<String, dynamic>);
    _clearSendAction(request.receiver.id);
    _sentRequests.removeWhere((existing) => existing.id == request.id);
    _sentRequests.insert(0, request);
    _storeRequest(request, ContactState.pendingOut);
    notifyListeners();
  }

  /// CRITICAL: do NOT call getConversations or getFriends here.
  /// Backend already emits updated lists; extra calls cause race condition
  /// and overwrite with stale data.
  void onFriendRequestAccepted(dynamic data) {
    final payload = data as Map<String, dynamic>;
    final request = FriendRequestModel.fromJson(payload);
    final peer = request.sender.id == _currentUserId
        ? request.receiver
        : request.sender;
    final hasIncoming = _friendRequests.any(
      (pending) => _requestHasPeer(pending, peer.id),
    );
    final hasOutgoing = _sentRequests.any(
      (pending) => _requestHasPeer(pending, peer.id),
    );
    final direction = _sendActions.containsKey(peer.id)
        ? InvitationDirection.outgoing
        : hasIncoming
            ? InvitationDirection.incoming
            : hasOutgoing
                ? InvitationDirection.outgoing
                : request.sender.id == _currentUserId
                    ? InvitationDirection.outgoing
                    : InvitationDirection.incoming;
    final pendingForPeer = [
      ..._friendRequests.where((pending) => _requestHasPeer(pending, peer.id)),
      ..._sentRequests.where((pending) => _requestHasPeer(pending, peer.id)),
    ];
    final conversationId = payload['conversationId'] as int?;
    final chatReady = payload['chatReady'] as bool? ?? conversationId != null;

    for (final pending in pendingForPeer) {
      _clearRequestAction(pending.id);
    }
    _clearRequestAction(request.id);
    _clearSendAction(peer.id);
    _friendRequests.removeWhere((pending) => _requestHasPeer(pending, peer.id));
    _sentRequests.removeWhere((pending) => _requestHasPeer(pending, peer.id));
    _acceptedOutcomes[peer.id] = InvitationOutcome(
      peerUserId: peer.id,
      direction: direction,
      peer: peer,
      requestId: request.id,
      conversationId: conversationId,
      chatReady: chatReady,
    );
    // Gate on the LOCALLY RESOLVED direction, never on the payload's sender role.
    // In a reciprocal auto-accept the payload describes the brand-new B->A row, so
    // the original sender A reads as `receiver` and would silently lose the
    // "<name> accepted your invitation" toast even though their own invitation was
    // just accepted. Direction already knows this side sent something.
    if (direction == InvitationDirection.outgoing) {
      _pendingFriendAccepted = PendingFriendAccepted(
        name: peer.username,
        peerUserId: peer.id,
        conversationId: conversationId,
        chatReady: chatReady,
      );
    }
    final store = _store;
    if (store != null) {
      unawaited(
        store.update(peer.id, (current) {
          final base =
              current ?? ContactRecord.fromUser(peer, ContactState.friend);
          return base.withProfile(peer).copyWith(
                state: ContactState.friend,
                legacy: base.legacy.copyWith(
                  clearRequest: true,
                  conversationId: conversationId,
                ),
              );
        }),
      );
    }
    notifyListeners();
  }

  void onFriendRequestRejected(dynamic data) {
    final request = FriendRequestModel.fromJson(data as Map<String, dynamic>);
    _clearRequestAction(request.id);
    _friendRequests.removeWhere((pending) => pending.id == request.id);
    // A declined request leaves no relationship: drop the pending record.
    // A friend record (the id collided with a live friendship) is kept.
    final store = _store;
    if (store != null) {
      final peerId = request.sender.id == _currentUserId
          ? request.receiver.id
          : request.sender.id;
      final current = store.byUserId(peerId);
      if (current != null && current.state != ContactState.friend) {
        unawaited(store.remove(peerId));
      }
    }
    notifyListeners();
  }

  void onFriendRequestFailed(dynamic data) {
    final payload = data as Map<String, dynamic>;
    final requestId = payload['requestId'] as int?;
    final recipientId = payload['recipientId'] as int?;
    final InvitationAction action;
    switch (payload['action'] as String) {
      case 'send':
        action = InvitationAction.send;
        break;
      case 'accept':
        action = InvitationAction.accept;
        break;
      case 'reject':
        action = InvitationAction.decline;
        break;
      case 'ensure_chat':
        action = InvitationAction.ensureChat;
        break;
      default:
        return;
    }

    switch (action) {
      case InvitationAction.accept:
      case InvitationAction.decline:
        if (requestId != null) _clearRequestAction(requestId);
        break;
      case InvitationAction.send:
      case InvitationAction.ensureChat:
        if (recipientId != null) _clearSendAction(recipientId);
        break;
    }
    if (action == InvitationAction.ensureChat && recipientId != null) {
      final outcome = _acceptedOutcomes[recipientId];
      if (outcome != null) {
        _acceptedOutcomes[recipientId] = outcome.copyWith(
          retryToken: null,
          retrying: false,
        );
      }
    }
    _lastInvitationFailure = InvitationFailure(
      action: action,
      requestId: requestId,
      recipientId: recipientId,
      reason: payload['reason'] as String,
    );
    notifyListeners();
  }

  void onInvitationChatReady(dynamic data) {
    final payload = data as Map<String, dynamic>;
    final peerUserId = payload['peerUserId'] as int;
    final outcome = _acceptedOutcomes[peerUserId];
    if (outcome == null || outcome.retryToken != payload['correlationId']) {
      return;
    }

    _acceptedOutcomes[peerUserId] = outcome.copyWith(
      conversationId: payload['conversationId'] as int?,
      chatReady: payload['chatReady'] as bool,
      retryToken: null,
      retrying: false,
    );
    notifyListeners();
  }

  void onPendingRequestsCount(dynamic data) {
    final count = (data as Map<String, dynamic>)['count'] as int;
    _pendingRequestsCount = count;
    notifyListeners();
  }

  void onFriendsList(dynamic data) {
    final list = data as List<dynamic>;
    final incoming = list
        .map((u) => UserModel.fromJson(u as Map<String, dynamic>))
        .toList();
    if (incoming.isEmpty && _friends.isNotEmpty && _hasFriendsSnapshot) {
      debugPrint(
        '[FriendsProvider] Ignoring empty friendsList (${_friends.length} local friends preserved)',
      );
      return;
    }
    _friends = incoming;
    _hasFriendsSnapshot = true;
    // If someone is in our friends list, they cannot be blocking us — clear them from blockedByUserIds
    // so that after unblock + re-add we can write again (no stale "can't message" state).
    _blockedByUserIds.removeWhere((id) => _friends.any((f) => f.id == id));
    // The store mirrors a NON-EMPTY list's membership (a friend the server
    // no longer lists was removed from another device while this one was
    // offline, and no `unfriended` will ever arrive here). An empty list
    // changes the store not at all: it is far more often a hiccup than a
    // last-friend removal, and a wiped store would flow into the backup.
    _storeList(ContactState.friend, incoming, prune: incoming.isNotEmpty);
    notifyListeners();
  }

  void onUnfriended(dynamic data) {
    final unfriendUserId = (data as Map<String, dynamic>)['userId'] as int;
    // Fail closed on a self-addressed id. `onRemoveConversationsForUser` ends in
    // an IRREVERSIBLE purge of decrypted plaintext (the ratchet consumed the
    // message keys, so the server's ciphertext can never be re-read), and
    // `removeConversationsForUser` matches `userOne.id == id || userTwo.id == id`
    // — we are a participant in EVERY one of our conversations, so our own id
    // matches all of them and wipes the entire local history. A server that
    // echoes our id back (as prod did until 2026-08-05) must never be able to
    // trigger that, so the client refuses it here rather than trusting the wire.
    if (_currentUserId != null && unfriendUserId == _currentUserId) {
      debugPrint(
        '[FriendsProvider] Ignoring self-addressed unfriended event '
        '(userId=$unfriendUserId) — would purge all local history',
      );
      return;
    }
    _friends.removeWhere((f) => f.id == unfriendUserId);
    _friendRequests.removeWhere(
      (r) => r.sender.id == unfriendUserId || r.receiver.id == unfriendUserId,
    );
    onRemoveConversationsForUser?.call(unfriendUserId);
    final store = _store;
    if (store != null) unawaited(store.remove(unfriendUserId));
    notifyListeners();
  }

  void onBlockedList(dynamic data) {
    final list = data as List<dynamic>;
    _blockedUsers = list
        .map((u) => UserModel.fromJson(u as Map<String, dynamic>))
        .toList();
    _hasBlockedSnapshot = true;
    final blockedIds = _blockedUsers.map((u) => u.id).toSet();
    _friends.removeWhere((f) => blockedIds.contains(f.id));
    onRemoveConversationsForUser?.call(-1); // signal handled externally
    _storeList(ContactState.blocked, _blockedUsers);
    notifyListeners();
  }

  void onYouWereBlocked(dynamic data) {
    final blockerId = (data as Map<String, dynamic>)['userId'] as int;
    _blockedByUserIds.add(blockerId);
    _friends.removeWhere((f) => f.id == blockerId);
    onRemoveConversationsForUser?.call(blockerId);
    // The server drops the blocker from every list it will ever send us
    // (`friendsList` excludes both block directions), so the record would
    // otherwise outlive the friendship and hydrate a chat with them.
    final store = _store;
    if (store != null) unawaited(store.remove(blockerId));
    notifyListeners();
  }

  void onSearchUsersResult(dynamic data) {
    final list = data as List<dynamic>;
    _searchResults = list
        .map((u) => UserModel.fromJson(u as Map<String, dynamic>))
        .toList();
    notifyListeners();
  }

  // ---------- Action Methods (emit socket events) ----------

  void searchUsers(String handle) {
    _searchResults = null;
    notifyListeners();
    _emit?.call('searchUsers', {'handle': handle});
  }

  void clearSearchResults() {
    _searchResults = null;
    notifyListeners();
  }

  /// Bounds an in-flight invitation action. On expiry the row's buttons come
  /// back and the existing failure surface reports it, so the user can retry.
  /// A late ack afterwards still applies — it is server truth, not a re-apply.
  void _armRequestActionTimeout(int requestId, InvitationAction action) {
    _requestActionTimers.remove(requestId)?.cancel();
    _requestActionTimers[requestId] = Timer(_kInvitationAckTimeout, () {
      _requestActionTimers.remove(requestId);
      if (_requestActions.remove(requestId) == null) return;
      _lastInvitationFailure = InvitationFailure(
        action: action,
        requestId: requestId,
        recipientId: null,
        reason: action == InvitationAction.accept
            ? 'accept_failed'
            : 'reject_failed',
      );
      notifyListeners();
    });
  }

  void _armSendActionTimeout(int userId) {
    _sendActionTimers.remove(userId)?.cancel();
    _sendActionTimers[userId] = Timer(_kInvitationAckTimeout, () {
      _sendActionTimers.remove(userId);
      if (_sendActions.remove(userId) == null) return;
      _lastInvitationFailure = InvitationFailure(
        action: InvitationAction.send,
        requestId: null,
        recipientId: userId,
        reason: 'send_failed',
      );
      notifyListeners();
    });
  }

  void _clearRequestAction(int requestId) {
    _requestActionTimers.remove(requestId)?.cancel();
    _requestActions.remove(requestId);
  }

  void _clearSendAction(int userId) {
    _sendActionTimers.remove(userId)?.cancel();
    _sendActions.remove(userId);
  }

  void _cancelAllInvitationActionTimers() {
    for (final timer in _requestActionTimers.values) {
      timer.cancel();
    }
    _requestActionTimers.clear();
    for (final timer in _sendActionTimers.values) {
      timer.cancel();
    }
    _sendActionTimers.clear();
  }

  void sendFriendRequest(int userId) {
    _sendActions[userId] = InvitationActionStatus.inFlight;
    _armSendActionTimeout(userId);
    notifyListeners();
    _emit?.call('sendFriendRequest', {'recipientId': userId});
  }

  void acceptFriendRequest(int requestId) {
    _requestActions[requestId] = InvitationActionStatus.inFlight;
    _armRequestActionTimeout(requestId, InvitationAction.accept);
    notifyListeners();
    _emit?.call('acceptFriendRequest', {'requestId': requestId});
  }

  void rejectFriendRequest(int requestId) {
    _requestActions[requestId] = InvitationActionStatus.inFlight;
    _armRequestActionTimeout(requestId, InvitationAction.decline);
    notifyListeners();
    _emit?.call('rejectFriendRequest', {'requestId': requestId});
  }

  void clearAcceptedOutcome(int peerUserId) {
    if (_acceptedOutcomes.remove(peerUserId) != null) {
      notifyListeners();
    }
  }

  void ensureInvitationChat(int peerUserId) {
    final outcome = _acceptedOutcomes[peerUserId];
    if (outcome == null) return;

    final correlationId =
        '$_invitationSessionNonce-${++_invitationCorrelationCounter}';
    _acceptedOutcomes[peerUserId] = outcome.copyWith(
      retryToken: correlationId,
      retrying: true,
    );
    notifyListeners();
    _emit?.call('ensureInvitationChat', {
      'peerUserId': peerUserId,
      'correlationId': correlationId,
    });
  }

  void unfriend(int userId) {
    _emit?.call('unfriend', {'userId': userId});
  }

  void blockUser(int userId) {
    _emit?.call('blockUser', {'userId': userId});
  }

  void unblockUser(int userId) {
    _emit?.call('unblockUser', {'userId': userId});
  }

  void loadBlockedList() {
    _emit?.call('getBlockedList', null);
  }

  void loadFriendRequests() {
    _emit?.call('getFriendRequests', null);
  }

  void loadFriends() {
    _emit?.call('getFriends', null);
  }

  // ---------- Lifecycle ----------

  /// Called on socket connect. Fresh connect clears all state; reconnect
  /// preserves friends, blocked users, and accepted outcomes to avoid UI flicker.
  /// _blockedByUserIds is always cleared: server does not replay youWereBlocked on reconnect.
  void onConnect(bool isReconnect) {
    _currentUserId = null; // will be set by setCurrentUserId
    _blockedByUserIds.clear();
    _cancelAllInvitationActionTimers();
    _requestActions.clear();
    _sendActions.clear();
    _lastInvitationFailure = null;
    _pendingFriendAccepted = null;
    _searchResults = null;
    if (!isReconnect) {
      _friendRequests = [];
      _sentRequests = [];
      _pendingRequestsCount = 0;
      _friends = [];
      _blockedUsers = [];
      _acceptedOutcomes.clear();
      _hasIncomingSnapshot = false;
      _hasSentSnapshot = false;
      _hasFriendsSnapshot = false;
      _hasBlockedSnapshot = false;
    } else {
      _acceptedOutcomes.updateAll(
        (_, outcome) => outcome.copyWith(retryToken: null, retrying: false),
      );
    }
    notifyListeners();
  }

  /// Set the current user ID (needed for sender checks in event handlers).
  void setCurrentUserId(int userId) {
    _currentUserId = userId;
  }

  /// Called on socket disconnect. Minimal cleanup.
  void onDisconnect() {
    // No state cleared on disconnect — reconnect will restore
  }

  /// Full reset of all state.
  void clearAll() {
    _friends = [];
    _friendRequests = [];
    _sentRequests = [];
    _pendingRequestsCount = 0;
    _blockedUsers = [];
    _blockedByUserIds.clear();
    _cancelAllInvitationActionTimers();
    _requestActions.clear();
    _sendActions.clear();
    _acceptedOutcomes.clear();
    _lastInvitationFailure = null;
    _pendingFriendAccepted = null;
    _hasIncomingSnapshot = false;
    _hasSentSnapshot = false;
    _hasFriendsSnapshot = false;
    _hasBlockedSnapshot = false;
    _searchResults = null;
    _currentUserId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelAllInvitationActionTimers();
    super.dispose();
  }
}
