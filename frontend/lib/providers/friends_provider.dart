import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/friend_request_model.dart';
import '../models/invitation_state.dart';
import '../models/user_model.dart';
import '../services/box/box_first_contact.dart';
import '../services/contacts/contact_record.dart';
import '../services/contacts/contact_store.dart';
import '../utils/e2e_persistent_diag.dart';
import '../utils/message_ids.dart';

/// FriendsProvider — friends, requests, blocked users and user search.
/// [ConnectionProvider] coordinates. The contact store is the ONLY source of
/// every list below (the server keeps no friend, request or block row since
/// Phase 4 step 5): the getters read it on each call, and a change to it is
/// told to the screens by [onContactsChanged] or by the action that made it.
class FriendsProvider extends ChangeNotifier {
  // ---------- State ----------
  final Map<int, InvitationActionStatus> _requestActions = {};
  final Map<int, InvitationActionStatus> _sendActions = {};
  final Map<int, InvitationOutcome> _acceptedOutcomes = {};
  InvitationFailure? _lastInvitationFailure;
  PendingFriendAccepted? _pendingFriendAccepted;

  /// A dropped accept/decline/send step used to strand the row: the in-flight
  /// entry is cleared only by the step's own end. Bounded here so a box step
  /// that never answers frees the row and reports a failure.
  static const Duration _kInvitationAckTimeout = Duration(seconds: 20);
  final Map<int, Timer> _requestActionTimers = {};
  final Map<int, Timer> _sendActionTimers = {};
  List<UserModel>? _searchResults;

  /// The raw entries of the answer [_searchResults] shows, by user id: what a
  /// first contact over the box needs (devices, request addresses, the signed
  /// list), which [UserModel] drops.
  Map<int, Map<String, dynamic>> _searchEntries = const {};

  /// Every `searchUsers` still owed an answer, oldest first (see
  /// [onSearchUsersResult] for how an answer is attributed).
  final List<_SearchWaiter> _searchWaiters = [];

  /// Set by [dispose]; an awaited box step must not notify afterwards.
  bool _disposed = false;

  int? _currentUserId;

  /// The client-owned contact list, when this session could open it. Every
  /// list below is read from it; while it is closed or absent they are empty.
  ContactStore? contactStore;

  ContactStore? get _store {
    final store = contactStore;
    if (store == null || !store.isOpen || store.userId != _currentUserId) {
      return null;
    }
    return store;
  }

  // ---------- Emit Callback ----------

  /// Callback to emit socket events (`searchUsers` only). Set by
  /// [ConnectionProvider] via [setEmitCallback].
  void Function(String event, dynamic data)? _emit;

  /// Wire the socket emit callback so FriendsProvider can send events
  /// without depending on SocketService directly.
  void setEmitCallback(void Function(String event, dynamic data) emit) {
    _emit = emit;
  }

  // ---------- Cross-Provider Callbacks ----------

  /// Called when conversations for a user should be removed (unfriend, block).
  /// Wired by the wiring layer when [ConversationsProvider] exists.
  void Function(int userId)? onRemoveConversationsForUser;

  // ---------- Box first contact (owner decision 52) ----------
  //
  // Wired by the messaging side. A NEGATIVE request id always names the box
  // request of user `-id`.

  /// Sends a first contact over the box to the account `searchEntry` (the raw
  /// `searchUsersResult` entry) describes.
  Future<FirstContactSend> Function(Map<String, dynamic> searchEntry)?
  boxSendRequest;

  /// Accepts the box request of `userId` (E15d, decision 53).
  Future<FirstContactAccept> Function(int userId)? boxAcceptRequest;

  /// Declines the box request of `userId`; the requester is told nothing
  /// (decision 54).
  Future<void> Function(int userId)? boxDeclineRequest;

  /// Ends a friendship the box carries (or a pending box request, for a
  /// block) (E15j): the peer is told `goodbye`, the record goes or turns
  /// `blocked`.
  Future<void> Function(int userId, {required bool block})? boxEndFriendship;

  // ---------- Public Getters ----------

  List<UserModel> get friends => _peers(ContactState.friend);
  List<UserModel> get blockedUsers => _peers(ContactState.blocked);
  List<FriendRequestModel> get friendRequests =>
      _requests(ContactState.pendingIn);
  List<FriendRequestModel> get sentRequests =>
      _requests(ContactState.pendingOut);
  int get pendingRequestsCount =>
      _store?.all.where((r) => _isBoxRequest(r, ContactState.pendingIn)).length ??
      0;
  List<UserModel>? get searchResults => _searchResults;

  /// The raw entry for [userId] in the answer [searchResults] shows; null
  /// once the results are cleared.
  Map<String, dynamic>? searchEntryFor(int userId) => _searchEntries[userId];
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

  bool isFriend(int userId) =>
      _store?.byUserId(userId)?.state == ContactState.friend;

  /// A pending request over the box: no server row stands behind any.
  static bool _isBoxRequest(ContactRecord record, ContactState state) =>
      record.state == state && record.boxOrigin != null;

  List<UserModel> _peers(ContactState state) {
    final store = _store;
    if (store == null) return const [];
    return List.unmodifiable([
      for (final r in store.all)
        if (r.state == state) r.toUser(),
    ]);
  }

  /// Each box request in [state] as id `-userId`, newest first — while it is
  /// still shown (decision 54: 30 d; a sent one's record outlives that,
  /// `BoxFirstContact.sentLifetime`).
  List<FriendRequestModel> _requests(ContactState state) {
    final store = _store;
    if (store == null) return const [];
    final incoming = state == ContactState.pendingIn;
    final now = DateTime.now().toUtc();
    final box = [
      for (final r in store.all)
        if (_isBoxRequest(r, state) && BoxFirstContact.shownPending(r, now)) r,
    ];
    if (box.isEmpty) return const [];
    box.sort((a, b) => b.boxOrigin!.at.compareTo(a.boxOrigin!.at));
    // Only the peer side of a request is ever shown; a store without the
    // self profile must not hide the request.
    final self =
        store.self ?? UserModel(id: store.userId!, username: '', tag: '0000');
    return List.unmodifiable([
      for (final r in box)
        FriendRequestModel(
          id: -r.userId,
          sender: incoming ? r.toUser() : self,
          receiver: incoming ? self : r.toUser(),
          status: 'pending',
          createdAt: r.boxOrigin!.at,
        ),
    ]);
  }

  // ---------- Event Handlers (called by the messaging side and the connection) ----------

  /// A contact record changed in the store (a request arrived, expired, was
  /// taken by a sibling; the store opened or a backup restored into it): the
  /// getters read the store, so only redraw.
  void onContactsChanged() => notifyListeners();

  /// A friendship over the box was made: [outgoing] = our request was
  /// accepted, else we accepted theirs. The messaging side wrote the record;
  /// this records the outcome the invitations screen and the shell show.
  void onBoxFriendshipMade(int userId, {required bool outgoing}) {
    _clearSendAction(userId);
    _clearRequestAction(-userId);
    final record = _store?.byUserId(userId);
    if (record != null) {
      final conversationId = localConversationIdFor(userId);
      _acceptedOutcomes[userId] = InvitationOutcome(
        peerUserId: userId,
        direction: outgoing
            ? InvitationDirection.outgoing
            : InvitationDirection.incoming,
        peer: record.toUser(),
        requestId: -userId,
        conversationId: conversationId,
      );
      if (outgoing) {
        _pendingFriendAccepted = PendingFriendAccepted(
          name: record.username,
          peerUserId: userId,
          conversationId: conversationId,
        );
      }
    }
    notifyListeners();
  }

  /// A friend said `goodbye` (E15j); the messaging side removed the record.
  /// Our own id is refused: it would purge every chat.
  void onBoxFriendshipEnded(int userId) {
    if (_currentUserId != null && userId == _currentUserId) {
      E2ePersistentDiag.record('BOX_GOODBYE_SELF_IGNORED');
      return;
    }
    onRemoveConversationsForUser?.call(userId);
    notifyListeners();
  }

  /// A `searchUsersResult`, kept RAW: the server answers a friend like anyone
  /// (owner decision 4), and the invitations view hides known contacts. The
  /// raw entries stay readable through [searchEntryFor].
  ///
  /// The answer carries no correlation id. The server answers in emit order
  /// per socket, `[]` for an unknown handle or self, and an `error` INSTEAD
  /// when a search fails, so an answer can go missing ([_takeSearchWaiter]).
  void onSearchUsersResult(dynamic data) {
    final list = data as List<dynamic>;
    final waiter = _takeSearchWaiter(list);
    if (waiter?.lookup != null) {
      waiter!.finish(List<Object?>.unmodifiable(list));
      return;
    }
    // An empty answer nobody claims (nobody is waiting) is a timed-out
    // lookup's, and must not read as "user not found". An unclaimed
    // non-empty one is shown as before: the view hides a known contact,
    // which is all a lookup ever names.
    if (waiter == null && list.isEmpty) return;
    final entries = [for (final u in list) u as Map<String, dynamic>];
    _searchResults = [for (final e in entries) UserModel.fromJson(e)];
    _searchEntries = {for (final e in entries) e['id'] as int: e};
    notifyListeners();
  }

  /// Removes and returns the waiter [answer] belongs to. A non-empty answer
  /// belongs to the oldest waiter asking for its `username#tag`, and every
  /// waiter queued before that one lost its answer (a lookup completes null,
  /// a UI search is dropped). An empty answer goes to the oldest waiter.
  /// Null when nobody is waiting, or a non-empty answer names no pending
  /// handle: then it is the late answer of a lookup that timed out, or of a
  /// search from before a reset, and consumes no waiter.
  _SearchWaiter? _takeSearchWaiter(List<dynamic> answer) {
    if (_searchWaiters.isEmpty) return null;
    var index = 0;
    if (answer.isNotEmpty) {
      final entry = answer.first as Map<String, dynamic>;
      final handle = _handleKey('${entry['username']}#${entry['tag']}');
      index = _searchWaiters.indexWhere((w) => w.handle == handle);
      if (index < 0) return null;
    }
    final lost = _searchWaiters.sublist(0, index);
    final waiter = _searchWaiters[index];
    _searchWaiters.removeRange(0, index + 1);
    for (final w in lost) {
      w.finish(null);
    }
    return waiter;
  }

  static String _handleKey(String handle) => handle.trim().toLowerCase();

  void _abandonSearchWaiters() {
    final waiters = List.of(_searchWaiters);
    _searchWaiters.clear();
    for (final w in waiters) {
      w.finish(null);
    }
  }

  // ---------- Action Methods ----------

  void searchUsers(String handle) {
    _searchResults = null;
    _searchEntries = const {};
    notifyListeners();
    final emit = _emit;
    if (emit == null) return;
    _searchWaiters.add(_SearchWaiter(_handleKey(handle)));
    emit('searchUsers', {'handle': handle});
  }

  /// One `searchUsers` for [handle] whose answer goes to the caller only
  /// (the accept-time check of decision 53, a box peer's list refresh): the
  /// raw answer list, `[]` for an unknown handle, null when no answer came
  /// within [timeout] (or the session reset first). [searchResults] and the
  /// listeners are never touched.
  Future<List<Object?>?> lookupHandle(
    String handle, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    final emit = _emit;
    if (emit == null) return Future.value();
    final waiter = _SearchWaiter(_handleKey(handle), lookup: Completer());
    waiter.timeout = Timer(timeout, () {
      _searchWaiters.remove(waiter);
      waiter.finish(null);
    });
    _searchWaiters.add(waiter);
    emit('searchUsers', {'handle': handle});
    return waiter.lookup!.future;
  }

  void clearSearchResults() {
    _searchResults = null;
    _searchEntries = const {};
    notifyListeners();
  }

  /// Bounds an in-flight invitation action. On expiry the row's buttons come
  /// back and the existing failure surface reports it, so the user can retry.
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

  /// A stranger found by this session's search is sent a request over the
  /// box; with no box wired or no raw search entry the send fails, as when
  /// the box cannot take it.
  void sendFriendRequest(int userId) {
    _sendActions[userId] = InvitationActionStatus.inFlight;
    _armSendActionTimeout(userId);
    notifyListeners();
    final boxSend = boxSendRequest;
    final entry = searchEntryFor(userId);
    if (boxSend == null || entry == null) {
      _failSend(userId);
      return;
    }
    unawaited(_sendOverBox(boxSend, userId, entry));
  }

  Future<void> _sendOverBox(
    Future<FirstContactSend> Function(Map<String, dynamic>) boxSend,
    int userId,
    Map<String, dynamic> entry,
  ) async {
    final account = _currentUserId;
    FirstContactSend result;
    try {
      result = await boxSend(entry);
    } on Object catch (e) {
      E2ePersistentDiag.record('BOX_FRIEND_SEND_THREW', {
        'error': e.runtimeType.toString(),
      });
      result = FirstContactSend.failed;
    }
    if (!_isLiveFor(account)) return;
    switch (result) {
      case FirstContactSend.sent:
        // The record is `pendingOut` in the store already: the getters show it.
        _clearSendAction(userId);
        notifyListeners();
      case FirstContactSend.failed:
        _failSend(userId);
    }
  }

  /// A send the ack timeout already released was reported already.
  void _failSend(int userId) {
    final held = _sendActions.containsKey(userId);
    _clearSendAction(userId);
    if (held) {
      _lastInvitationFailure = InvitationFailure(
        action: InvitationAction.send,
        requestId: null,
        recipientId: userId,
        reason: 'send_failed',
      );
    }
    notifyListeners();
  }

  /// Accepts the box request [requestId] (`-userId`).
  void acceptFriendRequest(int requestId) {
    _requestActions[requestId] = InvitationActionStatus.inFlight;
    _armRequestActionTimeout(requestId, InvitationAction.accept);
    notifyListeners();
    unawaited(_acceptOverBox(requestId));
  }

  /// The accept of box request [requestId] (`-userId`). Success is reported
  /// by [onBoxFriendshipMade]; this only releases the row.
  Future<void> _acceptOverBox(int requestId) async {
    final account = _currentUserId;
    final accept = boxAcceptRequest;
    var result = FirstContactAccept.failed;
    if (accept != null) {
      try {
        result = await accept(-requestId);
      } on Object catch (e) {
        E2ePersistentDiag.record('BOX_FRIEND_ACCEPT_THREW', {
          'error': e.runtimeType.toString(),
        });
      }
    }
    if (!_isLiveFor(account)) return;
    final held = _requestActions.containsKey(requestId);
    _clearRequestAction(requestId);
    final reason = switch (result) {
      FirstContactAccept.accepted => null,
      FirstContactAccept.unverified => 'unverified',
      FirstContactAccept.failed => 'accept_failed',
    };
    if (reason != null && held) {
      _lastInvitationFailure = InvitationFailure(
        action: InvitationAction.accept,
        requestId: requestId,
        recipientId: null,
        reason: reason,
      );
    }
    notifyListeners();
  }

  /// Declines the box request [requestId] (`-userId`).
  void rejectFriendRequest(int requestId) {
    _requestActions[requestId] = InvitationActionStatus.inFlight;
    _armRequestActionTimeout(requestId, InvitationAction.decline);
    notifyListeners();
    unawaited(_declineOverBox(requestId));
  }

  /// The decline of box request [requestId] (`-userId`): the requester is
  /// told nothing (decision 54).
  Future<void> _declineOverBox(int requestId) async {
    final account = _currentUserId;
    final decline = boxDeclineRequest;
    var declined = false;
    if (decline != null) {
      try {
        await decline(-requestId);
        declined = true;
      } on Object catch (e) {
        E2ePersistentDiag.record('BOX_FRIEND_DECLINE_THREW', {
          'error': e.runtimeType.toString(),
        });
      }
    }
    if (!_isLiveFor(account)) return;
    final held = _requestActions.containsKey(requestId);
    _clearRequestAction(requestId);
    if (!declined && held) {
      _lastInvitationFailure = InvitationFailure(
        action: InvitationAction.decline,
        requestId: requestId,
        recipientId: null,
        reason: 'reject_failed',
      );
    }
    notifyListeners();
  }

  /// An async box step finished for the account and provider it started on.
  bool _isLiveFor(int? account) => !_disposed && _currentUserId == account;

  void clearAcceptedOutcome(int peerUserId) {
    if (_acceptedOutcomes.remove(peerUserId) != null) {
      notifyListeners();
    }
  }

  /// Ends the friendship with [userId] on this device and, for a friend the
  /// box carries, over the box (decision 126; the server holds no row). False
  /// when a friendship the box carries could not end — our other devices
  /// could not be told, so nothing was ended or sent (E15j); the caller tells
  /// the user to retry.
  Future<bool> unfriend(int userId) => _end(userId, block: false);

  /// Blocks [userId]; false as for [unfriend].
  Future<bool> blockUser(int userId) => _end(userId, block: true);

  /// A contact the box carries (`ContactRecord.onBoxRoute`: made there, or a
  /// friendship from before the box that holds queue material) ends over the
  /// box: `goodbye` to its devices, our siblings told first, the record goes
  /// or turns `blocked`. A friend with no route has nobody to tell and ends
  /// here: its record goes, or turns `blocked` (the contact backup carries
  /// the block, as it carries a box friend's). A block also ends a request
  /// pending over the box.
  Future<bool> _end(int userId, {required bool block}) async {
    final store = _store;
    final record = store?.byUserId(userId);
    if (store == null || record == null) return true;
    final end = boxEndFriendship;
    final overBox =
        record.onBoxRoute &&
        (record.state == ContactState.friend ||
            block &&
                (_isBoxRequest(record, ContactState.pendingIn) ||
                    _isBoxRequest(record, ContactState.pendingOut)));
    if (overBox && end != null) {
      return _endOverBox(end, userId, block: block);
    }
    final account = _currentUserId;
    // The chat goes first, while its row still names the peer.
    onRemoveConversationsForUser?.call(userId);
    if (block) {
      await store.update(
        userId,
        (current) => current == null
            ? null
            : ContactRecord(
                userId: userId,
                username: current.username,
                tag: current.tag,
                avatarUrl: current.avatarUrl,
                state: ContactState.blocked,
              ),
      );
    } else {
      await store.remove(userId);
    }
    if (_isLiveFor(account)) notifyListeners();
    return true;
  }

  Future<bool> _endOverBox(
    Future<void> Function(int userId, {required bool block}) end,
    int userId, {
    required bool block,
  }) async {
    final account = _currentUserId;
    try {
      await end(userId, block: block);
    } on Object catch (e) {
      E2ePersistentDiag.record('BOX_FRIEND_END_THREW', {
        'error': e.runtimeType.toString(),
      });
      return false;
    }
    if (!_isLiveFor(account)) return true;
    onRemoveConversationsForUser?.call(userId);
    notifyListeners();
    return true;
  }

  /// A blocked record exists on the devices only: unblocking deletes it —
  /// unless it still holds a queue the box has not confirmed deleted (the
  /// record holds its only auth key): then it turns `former`, hidden, and the
  /// next expiry pass deletes the queue and the record.
  void unblockUser(int userId) {
    final store = _store;
    final record = store?.byUserId(userId);
    if (store == null || record?.state != ContactState.blocked) return;
    final account = _currentUserId;
    final done = record!.queues.isEmpty
        ? store.remove(userId)
        : store.update(
            userId,
            (r) => r?.state == ContactState.blocked
                ? r!.copyWith(state: ContactState.former)
                : null,
          );
    unawaited(
      done.then((_) {
        if (_isLiveFor(account)) notifyListeners();
      }),
    );
  }

  // ---------- Lifecycle ----------

  /// Called on socket connect. A fresh connect clears the accepted outcomes;
  /// a reconnect keeps them to avoid UI flicker.
  void onConnect(bool isReconnect) {
    _currentUserId = null; // will be set by setCurrentUserId
    _cancelAllInvitationActionTimers();
    _requestActions.clear();
    _sendActions.clear();
    _lastInvitationFailure = null;
    _pendingFriendAccepted = null;
    _searchResults = null;
    _searchEntries = const {};
    // A new socket answers none of the old one's searches.
    _abandonSearchWaiters();
    if (!isReconnect) _acceptedOutcomes.clear();
    notifyListeners();
  }

  /// Set the current user ID (the store is read only for this account).
  void setCurrentUserId(int userId) {
    _currentUserId = userId;
  }

  /// Called on socket disconnect. Minimal cleanup.
  void onDisconnect() {
    // No state cleared on disconnect — reconnect will restore
  }

  /// Full reset of all state.
  void clearAll() {
    _cancelAllInvitationActionTimers();
    _requestActions.clear();
    _sendActions.clear();
    _acceptedOutcomes.clear();
    _lastInvitationFailure = null;
    _pendingFriendAccepted = null;
    _searchResults = null;
    _searchEntries = const {};
    _abandonSearchWaiters();
    _currentUserId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelAllInvitationActionTimers();
    _abandonSearchWaiters();
    super.dispose();
  }
}

/// One `searchUsers` still owed a `searchUsersResult`: a UI search
/// ([lookup] null) or a [FriendsProvider.lookupHandle].
final class _SearchWaiter {
  _SearchWaiter(this.handle, {this.lookup});

  /// The searched `username#tag`, trimmed and lower-cased.
  final String handle;
  final Completer<List<Object?>?>? lookup;
  Timer? timeout;

  void finish(List<Object?>? answer) {
    timeout?.cancel();
    final lookup = this.lookup;
    if (lookup != null && !lookup.isCompleted) lookup.complete(answer);
  }
}
