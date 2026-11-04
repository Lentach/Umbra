import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/conversation_model.dart';
import '../models/message_model.dart';
import '../services/contacts/contact_record.dart';
import '../services/contacts/contact_store.dart';
import '../utils/message_expiry.dart';
import '../utils/message_ids.dart';
import 'conversation_helpers.dart' as conv_helpers;
import '../models/user_model.dart';
import '../services/notification_cleaner_stub.dart'
    if (dart.library.html) '../services/notification_cleaner_web.dart'
    if (dart.library.io) '../services/notification_cleaner_io.dart';
import '../services/push_sw_channel_stub.dart'
    if (dart.library.html) '../services/push_sw_channel_web.dart';

/// ConversationsProvider — owns conversation list state, active conversation,
/// unread counts, and pending-open navigation pattern.
/// [ConnectionProvider] coordinates; this provider holds conversation list and active chat.
class ConversationsProvider extends ChangeNotifier {
  // ---------- State ----------
  List<ConversationModel> _conversations = [];
  int? _activeConversationId;
  final Map<int, int> _unreadCounts = {}; // conversationId -> count

  /// Unread box messages (local ids, decision 14) per chat, by id: counted
  /// live ([incrementUnreadCount]) or, once per session, from the stored
  /// rows ([seedBoxUnread], decision 73). The count is this device's alone.
  /// Opening the chat clears them. By id, so a row counted both ways counts
  /// once.
  final Map<int, Set<int>> _boxUnread = {};

  /// The session's stored-row pass (`MessagingBox.applyStoredBoxLastMessages`)
  /// has started: it rebuilds state only a fresh connect or [clearAll] drops,
  /// and a reconnect keeps (live messages maintain it).
  bool _storedBoxPassClaimed = false;
  final Map<int, MessageModel> _lastMessages = {};
  int? _pendingOpenConversationId;

  /// Open this conversation from a notification tap (consumed by [MainShell], not socket flows).
  int? _pendingNotificationConversationId;

  String? _errorMessage;

  /// App/window foreground: gates the hidden-arrival card and tells the push
  /// SW whether a chat is open.
  bool _clientVisible = true;

  /// The contact store was read (or found closed) this session. The chat-list
  /// skeleton, the notification-tap navigation and the unread badge flush wait
  /// on it ([hasLoadedConversations]); before it the local unread map is empty
  /// and writing that "0" would wipe a legitimate badge set by the push SW
  /// while the app was closed.
  bool _hydrated = false;

  int? _currentUserId;

  /// The client-owned contact list, when this session could open it. The
  /// conversation row's settings (timer, mute, pin) and its legacy server id
  /// live on the peer's record; see [hydrateFromStore].
  ContactStore? contactStore;

  ContactStore? get _store {
    final store = contactStore;
    if (store == null || !store.isOpen || store.userId != _currentUserId) {
      return null;
    }
    return store;
  }

  /// Reads the chat list from the contact store: one row per friend record
  /// that has a chat id — a pre-box friend keeps the legacy conversation id
  /// its history is filed under, a friend made over the box has the local id
  /// — unless the chat was deleted on this device
  /// ([ContactSettings.chatHidden]). Idempotent. A closed or absent store
  /// leaves the list as it is; the session still counts as loaded
  /// ([hasLoadedConversations]).
  void hydrateFromStore() {
    final firstRead = !_hydrated;
    _hydrated = true;
    if (_rebuildChats() || firstRead) notifyListeners();
  }

  static ConversationModel _chatOf(ContactRecord r, UserModel self) =>
      ConversationModel(
        id: r.chatId!,
        userOne: self,
        userTwo: r.toUser(),
        createdAt:
            r.legacy.conversationCreatedAt ??
            r.boxOrigin?.at ??
            DateTime.fromMillisecondsSinceEpoch(0),
        disappearingTimer: r.settings.disappearingTimer,
        pinnedMessageId: r.settings.pinnedMessageId,
        muted: r.settings.muted,
        mutedUntil: r.settings.mutedUntil,
      );

  /// The chat [conversationId] shows again after a delete on this device: its
  /// next message arrived, or the user opened it.
  void revealChat(int conversationId) {
    final store = _store;
    if (store == null) return;
    final peer = store.all
        .where((r) => r.chatId == conversationId)
        .firstOrNull;
    if (peer == null || !peer.settings.chatHidden) return;
    unawaited(
      store
          .update(
            peer.userId,
            (record) => record?.settings.chatHidden ?? false
                ? record!.copyWith(
                    settings: record.settings.copyWith(chatHidden: false),
                  )
                : null,
          )
          .then((_) => refreshChats()),
    );
  }

  /// A friendship began or ended, or a chat was revealed: the chat list takes
  /// the store's chats again.
  void refreshChats() {
    if (_rebuildChats()) notifyListeners();
  }

  /// Replaces [_conversations] with the store's chats when the set of chats
  /// differs; a chat already shown keeps its row (pin preview, a setting
  /// whose store write is still queued). False when nothing changed or the
  /// store is closed.
  bool _rebuildChats() {
    final store = _store;
    final self = store?.self;
    if (store == null || self == null) return false;
    final records = [
      for (final r in store.all)
        if (r.state == ContactState.friend &&
            r.chatId != null &&
            !r.settings.chatHidden)
          r,
    ];
    final held = {for (final c in _conversations) c.id: c};
    final ids = {for (final r in records) r.chatId!};
    if (held.length == ids.length && ids.every(held.containsKey)) return false;
    _conversations = [
      for (final r in records)
        held[r.chatId!] ?? _withBoxPinShown(_chatOf(r, self)),
    ];
    return true;
  }

  /// Installs [conversations] with their unread counts and last messages as
  /// a store hydration would. Tests only.
  @visibleForTesting
  void debugSeed(
    List<ConversationModel> conversations, {
    Map<int, int> unread = const {},
    Map<int, MessageModel> lastMessages = const {},
  }) {
    _hydrated = true;
    _conversations = [for (final c in conversations) _withBoxPinShown(c)];
    _unreadCounts
      ..clear()
      ..addAll(unread);
    _lastMessages
      ..clear()
      ..addAll(lastMessages);
    notifyListeners();
  }

  /// Store write for one settled conversation event: finds the peer by
  /// legacy id in the CURRENT list and rewrites the settings half of the
  /// record. Membership is never changed here — that is the friends path.
  void _storeSettings(
    int conversationId,
    ContactSettings Function(ContactSettings current) mutate,
  ) {
    final store = _store;
    if (store == null) return;
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index == -1) return;
    final peerId = getOtherUserId(_conversations[index]);
    unawaited(
      store.update(
        peerId,
        (record) => record?.copyWith(settings: mutate(record.settings)),
      ),
    );
  }

  final _notificationCleaner = createNotificationCleaner();

  /// Push-SW channel (web only; no-op elsewhere) for the focused-conversation
  /// notification guard.
  final PushSwChannel _pushSwChannel;

  /// [pushSwChannel] is injectable for tests; production uses the real push-SW
  /// channel (web) or a no-op (other platforms).
  ConversationsProvider({PushSwChannel? pushSwChannel})
    : _pushSwChannel = pushSwChannel ?? createPushSwChannel();

  /// Foreground truth for gating client-side effects (e.g. read receipts).
  bool get isClientVisible => _clientVisible;

  /// Called from [MainShell] lifecycle / tab visibility so backend can suppress redundant pushes.
  void setClientVisible(bool visible) {
    if (_clientVisible == visible) return;
    _clientVisible = visible;
    if (visible) _hiddenArrivals.clear();
    _postActiveConversationToSw();
    if (visible) onClientVisible?.call();
  }

  /// Box messages that reached this page per chat since it was last
  /// visible: the count a hidden app's card shows when the chat's own unread
  /// is not counting (the open chat's never is).
  final Map<int, int> _hiddenArrivals = {};

  /// A box message for [conversationId] reached this page while it is
  /// HIDDEN (owner decision 76): the socket is still alive, so the box sent
  /// no push, and nothing else would tell the user. Asks the push SW — the
  /// single tray writer — for a card titled "Umbra" (decision 78) tagged
  /// like the old path's, so a read or a sweep clears it. A muted chat gets
  /// none. No effect off web (the native app is woken by FCM) and none while
  /// visible (decision 80: badge only).
  void postHiddenArrivalCard(int conversationId) {
    if (_clientVisible) return;
    if (getConversationById(conversationId)?.isNotificationMuted ?? false) {
      return;
    }
    final arrived = (_hiddenArrivals[conversationId] ?? 0) + 1;
    _hiddenArrivals[conversationId] = arrived;
    final unread = getUnreadCount(conversationId);
    unawaited(
      _pushSwChannel.postMessage({
        'type': 'local-card',
        'conversationId': conversationId,
        'count': arrived > unread ? arrived : unread,
      }),
    );
  }

  /// Told when the app becomes visible again (`MessagingProvider`: the chat
  /// on screen owes its box read receipt, metadata-privacy slice (g)).
  void Function()? onClientVisible;

  /// Re-posts the open chat to the push SW without changing state: a worker
  /// the browser restarted holds none, so a resume or a reconnect says it
  /// again.
  void repostActiveConversationToSw() => _postActiveConversationToSw();

  /// Defense-in-depth for the PWA: tell the push SW which chat is open so it
  /// suppresses a banner for a conversation the user is already viewing, even
  /// if the server-side skip races a socket reconnect. Backgrounded → null so
  /// notifications still show. Device-local: the SERVER is never told which
  /// chat is open (metadata privacy PR0.2) — only whether the app is visible.
  void _postActiveConversationToSw() {
    _pushSwChannel.postMessage({
      'type': 'active-conversation',
      'conversationId': _clientVisible ? _activeConversationId : null,
    }).ignore();
  }

  // ---------- Public Getters ----------

  List<ConversationModel> get conversations => _conversations;

  /// Conversations sorted by newest message first (for list display).
  List<ConversationModel> get sortedConversations {
    final list = List<ConversationModel>.from(_conversations);
    list.sort((a, b) {
      final aTime = _lastMessages[a.id]?.createdAt ?? a.createdAt;
      final bTime = _lastMessages[b.id]?.createdAt ?? b.createdAt;
      return bTime.compareTo(aTime);
    });
    return list;
  }

  int? get activeConversationId => _activeConversationId;
  int? get currentUserId => _currentUserId;
  String? get errorMessage => _errorMessage;
  Map<int, MessageModel> get lastMessages => _lastMessages;
  int? get pendingOpenConversationId => _pendingOpenConversationId;
  int? get pendingNotificationConversationId =>
      _pendingNotificationConversationId;

  /// Whether the contact store was read this session (a closed or absent
  /// store counts: there is nothing to wait for). The chat-list skeleton, the
  /// notification-tap navigation and the unread badge flush read this.
  bool get hasLoadedConversations => _hydrated;

  Map<int, int> get unreadCounts => _unreadCounts;

  int getUnreadCount(int conversationId) => _unreadCounts[conversationId] ?? 0;

  /// Returns conversation by id, or null if not found.
  ConversationModel? getConversationById(int id) =>
      _conversations.where((c) => c.id == id).firstOrNull;

  /// Returns the disappearing timer for the active conversation, or null.
  int? get conversationDisappearingTimer {
    if (_activeConversationId == null) return null;
    final conv = _conversations
        .where((c) => c.id == _activeConversationId)
        .firstOrNull;
    return conv?.disappearingTimer;
  }

  // ---------- Consume Patterns ----------

  /// Returns and clears pending open conversation ID. Used by screens to navigate.
  int? consumePendingOpen() {
    final id = _pendingOpenConversationId;
    _pendingOpenConversationId = null;
    return id;
  }

  /// Queue navigation from Android notification tap / FCM open — [MainShell] consumes.
  void requestNavigateToConversationFromNotification(int conversationId) {
    if (_pendingNotificationConversationId == conversationId) return;
    _pendingNotificationConversationId = conversationId;
    notifyListeners();
  }

  int? consumePendingNotificationConversationId() {
    final id = _pendingNotificationConversationId;
    _pendingNotificationConversationId = null;
    return id;
  }

  // ---------- Conversation Helpers ----------

  String getOtherUserUsername(ConversationModel conv) =>
      conv_helpers.getOtherUserUsername(conv, _currentUserId);

  int getOtherUserId(ConversationModel conv) =>
      conv_helpers.getOtherUserId(conv, _currentUserId);

  UserModel? getOtherUser(ConversationModel conv) =>
      conv_helpers.getOtherUser(conv, _currentUserId);

  /// The E2E pin register of each chat this session wrote or read (item 4,
  /// E19f); the contact record holds it across launches.
  final Map<int, BoxPin> _boxPins = {};

  /// The message each E2E pin shows — THIS device's copy, found by the
  /// messaging side ([applyBoxPin]) — kept over every rebuild of the list.
  final Map<int, MessageModel> _boxPinShown = {};

  /// The pin each chat showed BEFORE an optimistic pin or unpin overwrote it,
  /// so a box action that did not go out ([revertOptimisticPin]) puts it back.
  /// `null` is a real entry, meaning "this chat was UNPINNED before" — which
  /// is why the map is consulted with `containsKey` and never with a null
  /// check.
  final Map<int, ({int? messageId, MessageModel? preview})> _prePinState = {};

  /// [conversationId]'s E2E pin register: this session's, else the one the
  /// peer's contact record kept. Null = never written.
  BoxPin? boxPinOf(int conversationId) {
    final held = _boxPins[conversationId];
    if (held != null) return held;
    final conv = getConversationById(conversationId);
    if (conv == null) return null;
    return _store?.byUserId(getOtherUserId(conv))?.settings.boxPin;
  }

  /// Sets [conversationId]'s E2E pin register to [pin] (the caller decided
  /// it wins, [BoxPin.supersedes]) and keeps it on the contact record. A pin
  /// shows [shown]; an unpin takes an E2E pin off the banner. Settles any
  /// optimistic pin of this chat.
  void applyBoxPin(int conversationId, BoxPin pin, {MessageModel? shown}) {
    _boxPins[conversationId] = pin;
    _prePinState.remove(conversationId);
    final show = pin.pinned ? shown : null;
    if (show != null) {
      _boxPinShown[conversationId] = show;
    } else {
      _boxPinShown.remove(conversationId);
    }
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index != -1) {
      final conv = _conversations[index];
      final shownId = conv.pinnedMessageId;
      if (show != null) {
        _conversations[index] = conv.copyWith(
          pinnedMessageId: show.id,
          pinnedMessagePreview: show,
        );
      } else if (shownId != null && isLocalMessageId(shownId)) {
        _conversations[index] = conv.copyWith(
          clearPinnedMessageId: true,
          clearPinnedMessagePreview: true,
        );
      }
    }
    _storeSettings(conversationId, (s) => s.copyWith(boxPin: pin));
    notifyListeners();
  }

  ConversationModel _withBoxPinShown(ConversationModel conv) {
    final shown = _boxPinShown[conv.id];
    if (shown == null || !(_boxPins[conv.id]?.pinned ?? false)) return conv;
    return conv.copyWith(
      pinnedMessageId: shown.id,
      pinnedMessagePreview: shown,
    );
  }

  /// Optimistic pin preview from the open chat row (keeps pinner plaintext for own E2E).
  void setPinnedPreviewOptimistic(
    int conversationId,
    int messageId,
    MessageModel localPreview,
  ) {
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index == -1) return;
    final oldConv = _conversations[index];
    // Snapshot BEFORE the overwrite, and only for the first unsettled pin of a
    // conversation: a second optimistic pin before the first settles must not
    // replace the snapshot with the first pin's own (optimistic) state, or the
    // revert would restore a pin that never went out either.
    _prePinState.putIfAbsent(
      conversationId,
      () => (
        messageId: oldConv.pinnedMessageId,
        preview: oldConv.pinnedMessagePreview,
      ),
    );
    _conversations[index] = oldConv.copyWith(
      pinnedMessageId: messageId,
      pinnedMessagePreview: localPreview,
    );
    notifyListeners();
  }

  /// Takes an E2E pin off the banner before its unpin was sent, keeping
  /// what it showed for [revertOptimisticPin].
  void setUnpinnedOptimistic(int conversationId) {
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index == -1) return;
    final conv = _conversations[index];
    _prePinState.putIfAbsent(
      conversationId,
      () => (
        messageId: conv.pinnedMessageId,
        preview: conv.pinnedMessagePreview,
      ),
    );
    _conversations[index] = conv.copyWith(
      clearPinnedMessageId: true,
      clearPinnedMessagePreview: true,
    );
    notifyListeners();
  }

  /// The pin or unpin did not go out: restore what the optimistic apply
  /// overwrote. With no snapshot there is nothing to undo — an authoritative
  /// [applyBoxPin] already settled it.
  void revertOptimisticPin(int conversationId) {
    final restored = _prePinState.remove(conversationId);
    if (restored == null) return;
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index != -1) {
      _conversations[index] = _conversations[index].copyWith(
        pinnedMessageId: restored.messageId,
        clearPinnedMessageId: restored.messageId == null,
        pinnedMessagePreview: restored.preview,
        clearPinnedMessagePreview: restored.preview == null,
      );
    }
    notifyListeners();
  }

  // ---------- Action Methods ----------

  /// Opens the chat with friend [recipientId]: it shows again if it was
  /// deleted on this device, and [consumePendingOpen] names it. A record that
  /// is no friend, or has no chat, opens nothing.
  void startConversation(int recipientId) {
    final record = _store?.byUserId(recipientId);
    if (record == null || record.state != ContactState.friend) return;
    final id = record.chatId;
    if (id == null) return;
    revealChat(id);
    final self = _store?.self;
    if (self != null && !_conversations.any((c) => c.id == id)) {
      _conversations = [
        ..._conversations,
        _withBoxPinShown(_chatOf(record, self)),
      ];
    }
    _pendingOpenConversationId = id;
    notifyListeners();
  }

  /// Removes the chat locally immediately: this device's row and history go,
  /// the friendship stays, and the row is kept out of the list
  /// ([ContactSettings.chatHidden]) until it is revealed ([revealChat]).
  ///
  /// Swipe [Dismissible] must remove the row from the list in the same frame as
  /// [onDismissed]; otherwise the tile stays in the tree while the dismiss
  /// animation completes and the widget can rebuild with a stuck red background.
  void deleteConversation(int conversationId) {
    _storeSettings(conversationId, (s) => s.copyWith(chatHidden: true));
    _removeConversationById(conversationId);
    notifyListeners();
  }

  /// A local chat's timer was set here at `at` (slice (f), E15k): the
  /// peer's devices and our siblings are told over the box. Wired by the
  /// box layer.
  void Function(int peerUserId, int? seconds, DateTime at)?
  onLocalChatTimerChanged;

  /// Sets the chat's disappearing timer: shown at once, kept on the contact
  /// record with the time it was set (E15k's `timerAt`), and — when the box
  /// carries the friend (`ContactRecord.onBoxRoute`) — told to the friend's
  /// devices and our siblings by [onLocalChatTimerChanged]. The server is never
  /// told (decision 125's step 5 cutover).
  void setDisappearingTimer(int conversationId, int? timer) {
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index == -1) return;
    final peer = getOtherUserId(_conversations[index]);
    _conversations[index] = _conversations[index].copyWith(
      disappearingTimer: timer,
      clearDisappearingTimer: timer == null,
    );
    notifyListeners();
    final at = DateTime.now().toUtc();
    _storeSettings(
      conversationId,
      (s) => s.copyWith(
        disappearingTimer: timer,
        clearDisappearingTimer: timer == null,
        timerAt: at,
      ),
    );
    if (_store?.byUserId(peer)?.onBoxRoute ?? false) {
      onLocalChatTimerChanged?.call(peer, timer, at);
    }
  }

  /// The timer of the chat with [peerUserId] as another device set it at
  /// [at] — the friend, or a sibling of ours (E15k): taken only when newer
  /// than the one held, decided on the stored record, so every device ends
  /// on the latest write. Any chat the box carries (decision 107), keyed by
  /// the record's chat id.
  Future<void> applyLocalChatTimer(
    int peerUserId,
    int? seconds,
    DateTime at,
  ) async {
    final store = _store;
    if (store == null) return;
    int? chat;
    await store.update(peerUserId, (record) {
      final held = record?.settings.timerAt;
      if (record == null ||
          !record.onBoxRoute ||
          (held != null && !at.isAfter(held))) {
        return null;
      }
      chat = record.chatId;
      return record.copyWith(
        settings: record.settings.copyWith(
          disappearingTimer: seconds,
          clearDisappearingTimer: seconds == null,
          timerAt: at,
        ),
      );
    });
    if (chat == null) return;
    final index = _conversations.indexWhere((c) => c.id == chat);
    if (index == -1) return;
    _conversations[index] = _conversations[index].copyWith(
      disappearingTimer: seconds,
      clearDisappearingTimer: seconds == null,
    );
    notifyListeners();
  }

  /// A chat mutes on this device only (owner decision 52, E15k), for the
  /// durations the sheet offers (`1h`, `8h`, `1w`, `off`; anything else is
  /// until further notice).
  void setConversationMute(int conversationId, String duration) {
    final span = switch (duration) {
      '1h' => const Duration(hours: 1),
      '8h' => const Duration(hours: 8),
      '1w' => const Duration(days: 7),
      _ => null,
    };
    _applyMute(
      conversationId,
      muted: duration != 'off',
      mutedUntil: span == null ? null : DateTime.now().add(span),
    );
  }

  void _applyMute(
    int conversationId, {
    required bool muted,
    required DateTime? mutedUntil,
  }) {
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index == -1) return;
    final old = _conversations[index];
    _conversations[index] = old.copyWith(
      muted: muted,
      mutedUntil: mutedUntil,
      clearMutedUntil: mutedUntil == null,
    );
    _storeSettings(
      conversationId,
      (s) => s.copyWith(
        muted: muted,
        mutedUntil: mutedUntil,
        clearMutedUntil: mutedUntil == null,
      ),
    );
    notifyListeners();
  }

  /// Sets active conversation ID and clears unread count.
  ///
  /// [notify] defaults to true. Pass `notify: false` when called from
  /// [Widget.initState] (e.g. [ChatDetailScreen]) and call
  /// [notifyActiveConversationChanged] in a post-frame callback — synchronous
  /// [notifyListeners] during build throws and can race [messageHistory].
  void openConversation(int? conversationId, {bool notify = true}) {
    _activeConversationId = conversationId;
    if (conversationId != null) {
      _unreadCounts[conversationId] = 0;
      _boxUnread.remove(conversationId);
    }
    _postActiveConversationToSw();
    if (notify) {
      notifyListeners();
    }
  }

  /// Rebuilds UI after [openConversation] with `notify: false` (active id already set).
  void notifyActiveConversationChanged() {
    notifyListeners();
  }

  /// Sets active conversation without fetching messages. Use when ChatDetailScreen
  /// will call openConversation (avoids double getMessages on desktop).
  void setActiveConversation(int conversationId) {
    _activeConversationId = conversationId;
    _unreadCounts[conversationId] = 0;
    _boxUnread.remove(conversationId);
    notifyListeners();
    _postActiveConversationToSw();
  }

  /// Clears the active conversation.
  ///
  /// [notify] defaults to true. Pass `notify: false` from [Widget.dispose] and call
  /// [notifyActiveConversationChanged] in a post-frame callback (same pattern as
  /// [openConversation]).
  void closeConversation({bool notify = true}) {
    _activeConversationId = null;
    _postActiveConversationToSw();
    if (notify) {
      notifyListeners();
    }
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  // ---------- Inter-Provider Interface ----------

  /// Set the current user ID (called during connect).
  void setCurrentUserId(int userId) {
    _currentUserId = userId;
  }

  /// Remove the chat with a user (called by FriendsProvider on unfriend/block).
  ///
  /// Returns the ids of the conversations actually removed. This provider does
  /// not own message state, and the decrypted plaintext for those messages has
  /// to be destroyed by whoever does — so the caller needs to know which
  /// conversations went away, not just that some did.
  Set<int> removeConversationsForUser(int userId) {
    final removed = <int>{};
    _conversations.removeWhere((c) {
      final matches = c.userOne.id == userId || c.userTwo.id == userId;
      if (matches) removed.add(c.id);
      return matches;
    });
    _clearActiveIfRemoved();
    notifyListeners();
    _postActiveConversationToSw();
    return removed;
  }

  /// Update the last message for a conversation (called by MessagingProvider).
  void updateLastMessage(int conversationId, MessageModel? message) {
    if (message != null) {
      _lastMessages[conversationId] = message;
    } else {
      _lastMessages.remove(conversationId);
    }
    notifyListeners();
  }

  /// Each of [rows] (chat id → a message) becomes its chat's last message
  /// unless the one held is as new or newer: the box messages a launch
  /// finds stored, which no server snapshot names (decision 14).
  void applyNewerLastMessages(Map<int, MessageModel> rows) {
    var changed = false;
    for (final MapEntry(key: id, value: row) in rows.entries) {
      final held = _lastMessages[id];
      if (held != null && !row.createdAt.isAfter(held.createdAt)) continue;
      _lastMessages[id] = row;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Update the unread count for a conversation (called by MessagingProvider).
  void updateUnreadCount(int conversationId, int count) {
    _unreadCounts[conversationId] = count;
    notifyListeners();
  }

  /// Increment the unread count for a conversation by 1. [boxId]: the
  /// message is a box message ([_boxUnread]), counted once.
  void incrementUnreadCount(int conversationId, {int? boxId}) {
    if (boxId != null && !(_boxUnread[conversationId] ??= {}).add(boxId)) {
      return;
    }
    _unreadCounts[conversationId] = (_unreadCounts[conversationId] ?? 0) + 1;
    notifyListeners();
  }

  /// Claims this session's stored-row pass: true once until a fresh
  /// connect or [clearAll] (decision 73). A reconnect keeps the state it
  /// built, so re-reading every record then is pure cost.
  bool claimStoredBoxPass() {
    if (_storedBoxPassClaimed) return false;
    return _storedBoxPassClaimed = true;
  }

  /// The stored peer box messages not shown here yet, per chat (decision
  /// 73, at the session's first E2E ready): each one not counted yet adds
  /// to its chat's badge. Never the chat on screen, nor a chat made over
  /// the box that was deleted here (it comes back with its next message).
  void seedBoxUnread(Map<int, Set<int>> unread) {
    var changed = false;
    for (final MapEntry(key: id, value: ids) in unread.entries) {
      if (id == _activeConversationId || _hiddenLocalChat(id)) continue;
      final held = _boxUnread[id] ??= {};
      final added = ids.where(held.add).length;
      if (added == 0) continue;
      _unreadCounts[id] = (_unreadCounts[id] ?? 0) + added;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  bool _hiddenLocalChat(int conversationId) =>
      _store?.all.any(
        (r) => r.chatId == conversationId && r.settings.chatHidden,
      ) ??
      false;

  /// Remove expired messages from [lastMessages]. Does not notify listeners.
  void removeExpiredLastMessages() {
    final now = DateTime.now();
    _lastMessages.removeWhere((_, m) => isMessageExpired(m, now));
  }

  /// Prunes expired [lastMessages] and notifies listeners when the map changes.
  void pruneExpiredLastMessages() {
    final before = _lastMessages.length;
    removeExpiredLastMessages();
    if (_lastMessages.length != before) {
      notifyListeners();
    }
  }

  // ---------- Lifecycle ----------

  /// Called on socket connect. Fresh: clear all; reconnect: preserve (NO FLICKER).
  void onConnect(bool isReconnect) {
    if (!isReconnect) {
      _conversations = [];
      _activeConversationId = null;
      _lastMessages.clear();
      _unreadCounts.clear();
      _boxUnread.clear();
      _hiddenArrivals.clear();
      _storedBoxPassClaimed = false;
      _boxPins.clear();
      _boxPinShown.clear();
      _prePinState.clear();
      _pendingOpenConversationId = null;
      _pendingNotificationConversationId = null;
      _errorMessage = null;
      _clientVisible = true;
      _hydrated = false;
    } else {
      // Reconnect (same user): keep conversations and active chat to avoid flicker.
      _pendingOpenConversationId = null;
      _errorMessage = null;
    }
    notifyListeners();
    _postActiveConversationToSw();
  }

  /// Called on socket disconnect. Minimal cleanup.
  void onDisconnect() {
    // Minimal — state preserved for potential reconnect.
  }

  /// Full reset — called on logout or user switch.
  void clearAll() {
    _conversations = [];
    _activeConversationId = null;
    _currentUserId = null;
    _lastMessages.clear();
    _unreadCounts.clear();
    _boxUnread.clear();
    _hiddenArrivals.clear();
    _storedBoxPassClaimed = false;
    _boxPins.clear();
    _boxPinShown.clear();
    _prePinState.clear();
    _pendingOpenConversationId = null;
    _pendingNotificationConversationId = null;
    _errorMessage = null;
    _clientVisible = true;
    _hydrated = false;
    // Clear all push notifications on logout.
    _notificationCleaner.sweepNotificationsKeepUnread(const {}, 0);
    notifyListeners();
    _postActiveConversationToSw();
  }

  // ---------- Private Helpers ----------

  void _removeConversationById(int convId) {
    _conversations.removeWhere((c) => c.id == convId);
    _lastMessages.remove(convId);
    _unreadCounts.remove(convId);
    _boxUnread.remove(convId);
    if (_activeConversationId == convId) {
      _activeConversationId = null;
    }
    _postActiveConversationToSw();
  }

  /// Clears active conversation if it was removed from the list.
  void _clearActiveIfRemoved() {
    if (_activeConversationId == null) return;
    final exists = _conversations.any((c) => c.id == _activeConversationId);
    if (!exists) {
      _activeConversationId = null;
    }
  }
}
