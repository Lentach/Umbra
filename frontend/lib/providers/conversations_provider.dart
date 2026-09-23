import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/conversation_model.dart';
import '../models/message_model.dart';
import '../services/contacts/contact_record.dart';
import '../services/contacts/contact_store.dart';
import '../utils/e2e_diag_log.dart';
import '../utils/message_expiry.dart';
import '../utils/reply_preview_helper.dart';
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
  final Map<int, MessageModel> _lastMessages = {};
  int? _pendingOpenConversationId;

  /// Open this conversation from a notification tap (consumed by [MainShell], not socket flows).
  int? _pendingNotificationConversationId;

  /// True when our active conversation was removed from list (e.g. other user deleted).
  bool _activeConversationDeletedByOther = false;
  String? _errorMessage;

  /// App/window foreground — server skips push when this chat is already open.
  bool _clientVisible = true;

  /// True once a server conversations snapshot has been processed this session.
  /// [UnreadBadgeSync] gates on this: before the first snapshot the local
  /// unread map is empty, and writing that "0" would wipe a legitimate badge
  /// set by the push SW while the app was closed.
  bool _conversationsListReceivedOnce = false;

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

  /// Rebuilds the conversation list from the contact store when no server
  /// snapshot has arrived this session. One row per FRIEND record that still
  /// carries a legacy `conversationId` — the id the rest of the app addresses
  /// messages by until Phase 4 — with this account as `userOne`. Idempotent;
  /// a no-op once [onConversationsList] ran or while the store is closed.
  void hydrateFromStore() {
    final store = _store;
    if (store == null) return;
    if (_conversationsListReceivedOnce || _conversations.isNotEmpty) return;
    final self = store.self;
    if (self == null) return;
    final rows = <ConversationModel>[
      for (final r in store.all)
        if (r.state == ContactState.friend && r.legacy.conversationId != null)
          ConversationModel(
            id: r.legacy.conversationId!,
            userOne: self,
            userTwo: r.toUser(),
            createdAt: r.legacy.conversationCreatedAt ??
                DateTime.fromMillisecondsSinceEpoch(0),
            disappearingTimer: r.settings.disappearingTimer,
            pinnedMessageId: r.settings.pinnedMessageId,
            muted: r.settings.muted,
            mutedUntil: r.settings.mutedUntil,
          ),
    ];
    if (rows.isEmpty) return;
    _conversations = rows;
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
        (record) =>
            record?.copyWith(settings: mutate(record.settings)),
      ),
    );
  }

  /// Store write for a conversation the server dropped (delete, unfriend,
  /// block): the legacy id and its settings go, the contact stays — whether
  /// the RELATIONSHIP survives is the friends path's call. A peer with no
  /// record (removed by a queued sweep meanwhile) is left alone.
  void _storeConversationGone(Iterable<int> peers) {
    final store = _store;
    if (store == null) return;
    unawaited(store.reconcile(peers, (_, record) => _withoutChat(record)));
  }

  static ContactRecord? _withoutChat(ContactRecord? record) {
    if (record == null || record.legacy.conversationId == null) return null;
    return record.copyWith(
      settings: const ContactSettings(),
      legacy: record.legacy.copyWith(clearConversation: true),
    );
  }

  /// Store write for a server `conversationsList`: this account's own profile
  /// (the list is the one place the server names us), then per row the
  /// peer's settings + legacy id. A peer with no record yet is created as a
  /// friend — the server serves a conversation only between friends who have
  /// not blocked each other (`handleGetConversations` filters both
  /// directions), and the friends list that follows corrects the state
  /// either way. In the SAME lock, decided on disk state, every record whose
  /// chat the NON-EMPTY list no longer carries loses its legacy id, exactly
  /// as the RAM list drops it; an empty list changes the store not at all.
  void _storeConversationsList(List<ConversationModel> convs) {
    final store = _store;
    if (store == null) return;
    final byPeer = <int, ConversationModel>{};
    UserModel? self;
    for (final c in convs) {
      self ??= c.userOne.id == _currentUserId ? c.userOne : c.userTwo;
      byPeer[getOtherUserId(c)] = c;
    }
    if (self != null) unawaited(store.setSelf(self));
    unawaited(
      store.reconcile(
        byPeer.keys,
        (peerId, record) {
          final c = byPeer[peerId]!;
          final peer = getOtherUser(c)!;
          final base =
              record ?? ContactRecord.fromUser(peer, ContactState.friend);
          return base.withProfile(peer).copyWith(
                settings: ContactSettings(
                  disappearingTimer: c.disappearingTimer,
                  muted: c.muted,
                  mutedUntil: c.mutedUntil,
                  pinnedMessageId: c.pinnedMessageId,
                ),
                legacy: base.legacy.copyWith(
                  conversationId: c.id,
                  conversationCreatedAt: c.createdAt,
                ),
              );
        },
        sweep: convs.isEmpty ? null : (r) => _withoutChat(r) ?? r,
      ),
    );
  }

  /// Re-applies the current server snapshot to a store that was closed and
  /// re-opened underneath a live socket (passcode re-lock → unlock): events
  /// that arrived while it was closed were not written through, so the RAM
  /// list is the freshest truth. A no-op before the first snapshot — the RAM
  /// list is then the store's own hydration.
  void rewriteStore() {
    if (!_conversationsListReceivedOnce) return;
    _storeConversationsList(_conversations);
  }

  final _notificationCleaner = createNotificationCleaner();

  /// Push-SW channel (web only; no-op elsewhere) for the focused-conversation
  /// notification guard.
  final PushSwChannel _pushSwChannel;

  /// [pushSwChannel] is injectable for tests; production uses the real push-SW
  /// channel (web) or a no-op (other platforms).
  ConversationsProvider({PushSwChannel? pushSwChannel})
    : _pushSwChannel = pushSwChannel ?? createPushSwChannel();

  // ---------- Emit Callback ----------

  /// Callback to emit socket events. Set by [ConnectionProvider] via [setEmitCallback].
  void Function(String event, dynamic data)? _emit;

  /// Wire the socket emit callback so ConversationsProvider can send events
  /// without depending on SocketService directly.
  void setEmitCallback(void Function(String event, dynamic data) emit) {
    _emit = emit;
  }

  /// Foreground truth for gating client-side effects (e.g. read receipts).
  bool get isClientVisible => _clientVisible;

  /// Called from [MainShell] lifecycle / tab visibility so backend can suppress redundant pushes.
  void setClientVisible(bool visible) {
    if (_clientVisible == visible) return;
    _clientVisible = visible;
    reemitPushClientState();
  }

  /// Re-sends the visibility (to the server) and the open chat (to the push
  /// SW) without changing state.
  ///
  /// Socket.IO reconnects create a fresh server-side socket, so `client.data`
  /// loses the previous `pushClientState`. Use this after socketReady/resume
  /// even when nothing changed.
  void reemitPushClientState() {
    _emit?.call('pushClientState', {'clientVisible': _clientVisible});
    _postActiveConversationToSw();
  }

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
  bool get hasLoadedConversationsOnce => _conversationsListReceivedOnce;
  bool get activeConversationDeletedByOther =>
      _activeConversationDeletedByOther;
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

  /// Call when user navigates back from a chat that was deleted by the other user.
  void clearActiveIfDeletedByOther() {
    if (_activeConversationDeletedByOther) {
      _activeConversationDeletedByOther = false;
      _activeConversationId = null;
      notifyListeners();
      _postActiveConversationToSw();
    }
  }

  // ---------- Conversation Helpers ----------

  String getOtherUserUsername(ConversationModel conv) =>
      conv_helpers.getOtherUserUsername(conv, _currentUserId);

  int getOtherUserId(ConversationModel conv) =>
      conv_helpers.getOtherUserId(conv, _currentUserId);

  UserModel? getOtherUser(ConversationModel conv) =>
      conv_helpers.getOtherUser(conv, _currentUserId);

  // ---------- Event Handlers (called by socket events) ----------

  /// Handle 'conversationsList' event from backend.
  void onConversationsList(dynamic data) {
    final list = data as List<dynamic>;
    final firstSnapshot = !_conversationsListReceivedOnce;
    _conversationsListReceivedOnce = true;
    final newConvs = list
        .map((c) => ConversationModel.fromJson(c as Map<String, dynamic>))
        .toList();

    // Reconnect / network handoff: ignore empty snapshots that would wipe a populated
    // local list (stale response, throttled handler, or race before auth was ready).
    // The FIRST snapshot of a session is exempt: before it the list can only
    // hold contact-store hydration, and an empty first answer is the server's
    // truth (every conversation deleted from another device), not a hiccup.
    if (newConvs.isEmpty && _conversations.isNotEmpty && !firstSnapshot) {
      E2eDiagLog.add('CONV_LIST', {
        'count': 0,
        'ignoredEmpty': true,
        'localCount': _conversations.length,
      });
      debugPrint(
        '[ConversationsProvider] Ignoring empty conversationsList (${_conversations.length} local conversations preserved)',
      );
      return;
    }
    E2eDiagLog.add('CONV_LIST', {'count': newConvs.length});

    // If our active conv is no longer in list (e.g. other user deleted), mark it
    if (_activeConversationId != null &&
        !newConvs.any((c) => c.id == _activeConversationId)) {
      _activeConversationDeletedByOther = true;
    }

    _conversations = newConvs;
    _storeConversationsList(newConvs);
    _unreadCounts.clear();
    // The server list is AUTHORITATIVE over any optimistic pin still waiting
    // for its answer, so every pre-pin snapshot is now superseded. Keeping one
    // is how a refusal much later reverts a conversation to state that predates
    // this refresh — reachable when the settling event never arrives at all
    // (a socket drop between the server's commit and its emit, or a non-throttle
    // pin rejection, which rides the bare `error` event that no pin code reads).
    _prePinState.clear();
    _preDisappearingTimerState.clear();

    for (final c in list) {
      final m = c as Map<String, dynamic>;
      final convId = m['id'] as int;
      final serverUnread = (m['unreadCount'] as num?)?.toInt() ?? 0;
      // The open conversation is fully read (0). For every other conversation
      // trust the server snapshot so a read-driven decrease actually lowers the
      // badge — replacing the old max() merge, which could only raise counts and
      // left a badge permanently stuck after the conversation was read. Tradeoff:
      // a stale snapshot can briefly reset a just-incremented local count, but the
      // next snapshot restores it (and the message is already in the loaded list).
      _unreadCounts[convId] = convId == _activeConversationId
          ? 0
          : serverUnread;

      // Update last message from backend data. An E2E row keeps its
      // `[encrypted]` sentinel: the list decides how to show it (amendment
      // (lxxxviii) A1), and relabelling it here made a row this install can
      // never read look readable to that decision.
      final lastMsgData = m['lastMessage'];
      if (lastMsgData != null) {
        try {
          _lastMessages[convId] = MessageModel.fromJson(
            lastMsgData as Map<String, dynamic>,
          );
        } catch (e) {
          debugPrint(
            '[ConversationsProvider] Failed to parse lastMessage for conversation $convId: $e',
          );
        }
      }
    }

    // Sweep push notifications for conversations that are no longer unread.
    final unreadConvIds = _unreadCounts.entries
        .where((e) => e.value > 0)
        .map((e) => e.key)
        .toSet();
    final totalUnread = _unreadCounts.values.fold(0, (sum, v) => sum + v);
    _notificationCleaner.sweepNotificationsKeepUnread(
      unreadConvIds,
      totalUnread,
    );

    notifyListeners();
  }

  /// Handle 'openConversation' event — store pending ID for screen navigation.
  void onOpenConversation(dynamic data) {
    final convId = (data as Map<String, dynamic>)['conversationId'] as int;
    _pendingOpenConversationId = convId;
    notifyListeners();
  }

  /// Handle 'conversationDeleted' event — remove from list, handle active.
  void onConversationDeleted(dynamic data) {
    final convId = data['conversationId'] as int;
    _storeConversationGone([
      for (final c in _conversations)
        if (c.id == convId) getOtherUserId(c),
    ]);
    _removeConversationById(convId);
    notifyListeners();
  }

  /// Handle 'disappearingTimerUpdated' event — update conversation timer.
  void onDisappearingTimerUpdated(dynamic data) {
    final m = data as Map<String, dynamic>;
    final conversationId = m['conversationId'] as int;
    final seconds = m['seconds'] as int?;

    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index != -1) {
      final oldConv = _conversations[index];
      _conversations[index] = oldConv.copyWith(
        disappearingTimer: seconds,
        clearDisappearingTimer: seconds == null,
      );
    }
    // Settled authoritatively: nothing left to undo, and keeping the snapshot
    // would let a LATER unrelated refusal revert to stale state.
    _preDisappearingTimerState.remove(conversationId);
    _storeSettings(
      conversationId,
      (s) => s.copyWith(
        disappearingTimer: seconds,
        clearDisappearingTimer: seconds == null,
      ),
    );

    notifyListeners();
  }

  /// The timer each conversation showed BEFORE an optimistic change overwrote
  /// it.
  ///
  /// Same shape and same reason as [_prePinState]: the throttle guard refuses
  /// `setDisappearingTimer` BEFORE the handler runs, so the refusal knows only
  /// what was asked for, never what it displaced. Without this the refused
  /// device kept showing a timer the server and the peer never had — messages
  /// this user believes will vanish, and which will not.
  ///
  /// `null` is a real entry meaning "no timer before", so the map is consulted
  /// with `containsKey`, never with a null check.
  final Map<int, int?> _preDisappearingTimerState = {};

  /// Handle 'disappearingTimerFailed' — the change was refused, so restore what
  /// the optimistic apply overwrote.
  ///
  /// With no snapshot there is nothing to undo: either this device never made
  /// the change, or a previous answer already settled it. Guessing a value here
  /// would destroy state the server still holds.
  void onDisappearingTimerFailed(dynamic data) {
    final conversationId =
        (data as Map<String, dynamic>)['conversationId'] as int?;
    if (conversationId == null) return;
    if (!_preDisappearingTimerState.containsKey(conversationId)) return;
    final restored = _preDisappearingTimerState.remove(conversationId);
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index != -1) {
      final oldConv = _conversations[index];
      _conversations[index] = oldConv.copyWith(
        disappearingTimer: restored,
        clearDisappearingTimer: restored == null,
      );
    }
    notifyListeners();
  }

  /// The pin each conversation showed BEFORE an optimistic pin overwrote it.
  ///
  /// A refusal cannot carry the prior state — the server refuses a throttled
  /// `pinMessage` before its handler ever runs, so it knows only what was
  /// asked for (spec §12 (xxxvii)). Only the pinning device knows what it
  /// overwrote, so it has to remember. `null` is a real entry, meaning "this
  /// conversation was UNPINNED before" — which is why the map is consulted with
  /// `containsKey` and never with a null check.
  final Map<int, ({int? messageId, MessageModel? preview})> _prePinState = {};

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
    // revert would restore a pin the server never accepted either.
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

  /// Handle 'messagePinFailed' — the pin was refused, so restore what the
  /// optimistic apply overwrote (spec §12 (xxxvii)).
  ///
  /// With no snapshot there is nothing to undo: either this device never
  /// applied the pin optimistically (the message was not local), or an
  /// authoritative event already settled it. Doing nothing is then correct —
  /// clearing the pin here would destroy state the server still holds.
  void onPinMessageFailed(dynamic data) {
    final conversationId =
        (data as Map<String, dynamic>)['conversationId'] as int?;
    if (conversationId == null) return;
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

  /// Handle 'messagePinned' event — update pin id and preview snapshot.
  void onMessagePinned(dynamic data, {MessageModel? localPinnedMessage}) {
    final m = data as Map<String, dynamic>;
    final conversationId = m['conversationId'] as int;
    final pinnedMessageId = m['pinnedMessageId'] as int?;
    MessageModel? preview;
    final previewData = m['pinnedMessage'];
    if (previewData != null) {
      final serverPreview = MessageModel.fromJson(
        previewData as Map<String, dynamic>,
      );
      preview = resolvePinnedPreviewMessage(
        serverPreview: serverPreview,
        localMessage: localPinnedMessage,
      );
    } else if (localPinnedMessage != null && pinnedMessageId != null) {
      preview = localPinnedMessage;
    }

    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index != -1) {
      final oldConv = _conversations[index];
      _conversations[index] = oldConv.copyWith(
        pinnedMessageId: pinnedMessageId,
        clearPinnedMessageId: pinnedMessageId == null,
        pinnedMessagePreview: preview,
        clearPinnedMessagePreview: preview == null,
      );
    }
    // Settled authoritatively: the snapshot has nothing left to undo, and
    // keeping it would let a LATER unrelated refusal revert to stale state.
    _prePinState.remove(conversationId);
    _storeSettings(
      conversationId,
      (s) => s.copyWith(
        pinnedMessageId: pinnedMessageId,
        clearPinnedMessageId: pinnedMessageId == null,
      ),
    );
    notifyListeners();
  }

  /// Handle 'messageUnpinned' event — clear pin fields.
  void onMessageUnpinned(dynamic data) {
    final conversationId =
        (data as Map<String, dynamic>)['conversationId'] as int;
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index != -1) {
      final oldConv = _conversations[index];
      _conversations[index] = oldConv.copyWith(
        clearPinnedMessageId: true,
        clearPinnedMessagePreview: true,
      );
    }
    _prePinState.remove(conversationId);
    _storeSettings(conversationId, (s) => s.copyWith(clearPinnedMessageId: true));
    notifyListeners();
  }

  // ---------- Action Methods ----------

  /// Emit getConversations socket event.
  void getConversations() {
    _emit?.call('getConversations', null);
  }

  /// Emit startConversation socket event.
  void startConversation(int recipientId) {
    _emit?.call('startConversation', {'recipientId': recipientId});
  }

  /// Removes the conversation locally immediately, then emits deleteConversationOnly.
  ///
  /// Swipe [Dismissible] must remove the row from the list in the same frame as
  /// [onDismissed]; otherwise the tile stays in the tree while the dismiss
  /// animation completes and the widget can rebuild with a stuck red background.
  void deleteConversation(int conversationId) {
    _removeConversationById(conversationId);
    notifyListeners();
    _emit?.call('deleteConversationOnly', {'conversationId': conversationId});
  }

  /// Emit setDisappearingTimer socket event (optimistic local update).
  void setDisappearingTimer(int conversationId, int? timer) {
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index != -1) {
      final oldConv = _conversations[index];
      // Remember what is being overwritten BEFORE overwriting it, so a refusal
      // can put it back. putIfAbsent: with two changes in flight the FIRST
      // snapshot is the last server-confirmed state, and a revert to the
      // second would restore a timer the server never accepted either.
      _preDisappearingTimerState.putIfAbsent(
        conversationId,
        () => oldConv.disappearingTimer,
      );
      _conversations[index] = oldConv.copyWith(
        disappearingTimer: timer,
        clearDisappearingTimer: timer == null,
      );
      notifyListeners();
    }
    _emit?.call('setDisappearingTimer', {
      'conversationId': conversationId,
      'seconds': timer,
    });
  }

  void setConversationMute(int conversationId, String duration) {
    _emit?.call('setConversationMute', {
      'conversationId': conversationId,
      'duration': duration,
    });
  }

  void onConversationMuteUpdated(dynamic data) {
    final payload = data as Map<String, dynamic>;
    final conversationId = payload['conversationId'] as int;
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index == -1) return;
    final old = _conversations[index];
    final muted = payload['muted'] as bool;
    final mutedUntilRaw = payload['mutedUntil'] as String?;
    final mutedUntil = mutedUntilRaw == null
        ? null
        : DateTime.tryParse(mutedUntilRaw);
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
    _activeConversationDeletedByOther = false;
    if (conversationId != null) {
      _unreadCounts[conversationId] = 0;
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
    _activeConversationDeletedByOther = false;
    _unreadCounts[conversationId] = 0;
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

  /// Remove all conversations involving a user (called by FriendsProvider on unfriend/block).
  /// Pass userId=-1 to remove conversations for a set of blocked users (caller provides IDs).
  ///
  /// Returns the ids of the conversations actually removed. This provider does
  /// not own message state, and the decrypted plaintext for those messages has
  /// to be destroyed by whoever does — so the caller needs to know which
  /// conversations went away, not just that some did.
  Set<int> removeConversationsForUser(int userId, {Set<int>? blockedIds}) {
    final removed = <int>{};
    final gone = <ConversationModel>[];
    _conversations.removeWhere((c) {
      final matches = userId == -1 && blockedIds != null
          ? blockedIds.contains(c.userOne.id) ||
                blockedIds.contains(c.userTwo.id)
          : c.userOne.id == userId || c.userTwo.id == userId;
      if (matches) {
        removed.add(c.id);
        gone.add(c);
      }
      return matches;
    });
    _storeConversationGone(gone.map(getOtherUserId));
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

  /// Update the unread count for a conversation (called by MessagingProvider).
  void updateUnreadCount(int conversationId, int count) {
    _unreadCounts[conversationId] = count;
    notifyListeners();
  }

  /// Increment the unread count for a conversation by 1.
  void incrementUnreadCount(int conversationId) {
    _unreadCounts[conversationId] = (_unreadCounts[conversationId] ?? 0) + 1;
    notifyListeners();
  }

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
      _prePinState.clear();
      _preDisappearingTimerState.clear();
      _pendingOpenConversationId = null;
      _pendingNotificationConversationId = null;
      _activeConversationDeletedByOther = false;
      _errorMessage = null;
      _clientVisible = true;
      _conversationsListReceivedOnce = false;
    } else {
      // Reconnect (same user): keep conversations and active chat to avoid flicker.
      _pendingOpenConversationId = null;
      _activeConversationDeletedByOther = false;
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
    _prePinState.clear();
    _preDisappearingTimerState.clear();
    _pendingOpenConversationId = null;
    _pendingNotificationConversationId = null;
    _activeConversationDeletedByOther = false;
    _errorMessage = null;
    _clientVisible = true;
    _conversationsListReceivedOnce = false;
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
    if (_activeConversationId == convId) {
      _activeConversationId = null;
      _activeConversationDeletedByOther = false;
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
