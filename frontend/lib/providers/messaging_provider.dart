import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:webcrypto/webcrypto.dart';
import '../utils/file_utils_stub.dart'
    if (dart.library.io) '../utils/file_utils_io.dart'
    as file_utils;

import '../config/app_config.dart';
import '../models/conversation_model.dart';
import '../models/message_model.dart';
import '../services/api_service.dart';
import '../services/box/box_device_list_refresh.dart';
import '../services/box/box_envelope.dart';
import '../services/box/box_frame.dart';
import '../services/box/box_outbox.dart';
import '../services/box/box_siblings.dart';
import '../services/contacts/contact_record.dart';
import '../services/contacts/contact_store.dart';
import '../services/device_list/device_list_cache.dart';
import '../services/device_list/sender_list_info.dart';
import '../services/media_crypto_service.dart';
import '../services/encrypted_media_upload_service.dart';
import '../services/encryption_service.dart';
import '../services/incoming_message_sound_service.dart';
import '../services/link_preview_service.dart';
import '../services/plaintext_record_codec.dart';
import '../services/reactions/reaction_display.dart';
import '../services/reactions/reaction_key_service.dart';
import '../utils/anti_quantum_note_link.dart';
import '../utils/decryption_failure_policy.dart';
import '../utils/e2e_diag_log.dart';
import '../utils/e2e_envelope.dart';
import '../utils/media_preview_metadata.dart';
import '../utils/e2e_persistent_diag.dart';
import '../utils/message_expiry.dart';
import '../utils/message_ids.dart';
import '../utils/reply_preview_helper.dart';
import 'conversation_helpers.dart' as conv_helpers;
import 'conversations_provider.dart';
import 'encryption_provider.dart';

part 'messaging/messaging_provider.box.dart';
part 'messaging/messaging_provider.history.dart';
part 'messaging/messaging_provider.events.dart';
part 'messaging/messaging_provider.send.dart';
part 'messaging/messaging_provider.decrypt.dart';
part 'messaging/messaging_provider.actions.dart';

// ---------- Library-private top-level helpers ----------
// Hoisted from MessagingProvider statics so the part-file extensions can
// reference them by bare name (an extension cannot see a class's statics).

void _e2eFlowLog(String step, [Map<String, dynamic>? data]) {
  E2eDiagLog.add(step, data ?? {});
  if (kDebugMode) debugPrint('[E2E-FLOW] $step | ${data ?? {}}');
}

int _deliveryStatusRank(MessageDeliveryStatus status) {
  switch (status) {
    case MessageDeliveryStatus.sending:
    case MessageDeliveryStatus.failed:
      return 0;
    case MessageDeliveryStatus.sent:
      return 1;
    case MessageDeliveryStatus.delivered:
      return 2;
    case MessageDeliveryStatus.read:
      return 3;
  }
}

const int _pageSize = 50;
const String kDecryptionFailedLabel = '[Decryption failed]';
const String kEncryptedPlaceholderLabel = '[encrypted]';
const String kRetiredMessageLabel = '[Message no longer stored on this device]';

/// Written when a send is attempted with no E2E stack ready. A sentinel like
/// the three above, so it gets a named constant like them — matching it by
/// hand is what let it reach a bubble raw (live QA 2026-08-31).
const String kEncryptionNotInitializedLabel = '[Encryption not initialized]';

/// A row the server marked `none_for_device` (spec §5.3 + §12 amendment
/// (viii)): it predates this device's link, so no envelope exists for it and
/// nothing can be decrypted. Distinct from `[Decryption failed]` on purpose —
/// nothing failed here.
const String kNotLinkedYetMessageLabel = '[Sent before this device was linked]';

/// MessagingProvider — owns all message state, send/receive handlers,
/// encryption orchestration, typing/recording indicators, and reactions.
/// Wired by [ConnectionProvider] and ConversationsScreen (setEncryptionProvider, setConversationsProvider).
class MessagingProvider extends ChangeNotifier {
  // ---------- Dependencies ----------

  late final ApiService _api = ApiService(baseUrl: AppConfig.baseUrl);
  final MediaCryptoService _mediaCrypto = MediaCryptoService();

  late final EncryptedMediaUploadService _mediaUploadDefault =
      EncryptedMediaUploadService(api: _api, crypto: _mediaCrypto);

  /// Test override for the media upload service. Null in production.
  /// Mirrors `_activeConversationIdOverrideForTest`.
  EncryptedMediaUploadService? _mediaUploadOverrideForTest;

  /// Effective media upload service — test override if set, else the default.
  EncryptedMediaUploadService get _mediaUpload =>
      _mediaUploadOverrideForTest ?? _mediaUploadDefault;

  @visibleForTesting
  void setMediaUploadServiceForTest(EncryptedMediaUploadService service) {
    _mediaUploadOverrideForTest = service;
  }

  /// Callback to emit socket events. Set by the wiring layer.
  void Function(String event, dynamic data)? _emit;

  /// Cross-provider references, set by the wiring layer.
  EncryptionProvider? _encryptionProvider;
  ConversationsProvider? _conversationsProvider;

  /// Auth token for REST calls (media upload, link preview).
  String? _tokenForReconnect;

  int? _currentUserId;

  /// Active conversation ID — uses test override if set, otherwise reads from ConversationsProvider.
  int? get _effectiveActiveConversationId =>
      _activeConversationIdOverrideForTest ??
      _conversationsProvider?.activeConversationId;

  /// Test-only override for activeConversationId.
  int? _activeConversationIdOverrideForTest;

  // ---------- Reaction keys (docs/design/reaction-privacy.md) ----------

  /// Built on first use, because it needs [_encryptionProvider] — which the
  /// wiring layer sets after construction.
  ReactionKeyService? _reactionKeys;

  /// Pending `fetchReactionKey` round trips, keyed by conversation id — the
  /// one field the answer carries back, and the only thing that makes two
  /// concurrent fetches distinguishable.
  final Map<int, Completer<Map<String, dynamic>?>> _reactionKeyFetches = {};

  /// The pending `uploadReactionKey`, if any.
  ///
  /// Only ONE at a time: a second caller is refused outright rather than
  /// risking a mis-correlated answer. An upload happens at most once per
  /// conversation and is triggered by a tap, so the collision needs two taps
  /// in two chats inside one round trip.
  Completer<Map<String, dynamic>?>? _reactionKeyUpload;

  /// The conversation [_reactionKeyUpload] is waiting for, so a late answer
  /// naming a different one is discarded instead of completing this slot.
  int? _reactionKeyUploadConversationId;

  /// Matches `_servedIdRequestTimeout`: a socket answer that never arrives
  /// must fail the acquisition rather than pin a completer forever.
  static const Duration _reactionKeyRequestTimeout = Duration(seconds: 20);

  /// Conversations whose key this session has already tried and failed to
  /// fetch, so a chat full of unreadable chips asks ONCE instead of once per
  /// rendered row.
  final Set<int> _reactionKeyAttempted = {};

  // ---------- E2E Encryption ----------

  /// Single delayed retry for a failed text message (e.g. recipient had no key bundle, then came online).
  Timer? _delayedRetryTimer;
  String? _delayedRetryTempId;
  bool _decryptingHistory = false;

  /// Peers whose messages failed during the current history decrypt pass.
  Set<int>? _historyDecryptFailedPeers;

  /// Dedupes session-rebuild emits within one history decrypt pass.
  Set<int>? _historySessionRebuildRequested;

  /// Peers whose live decrypt failed; retried after a short debounce (no per-message SESSION_RESET).
  final Set<int> _liveDecryptFailedPeers = {};
  Timer? _liveDecryptRetryTimer;

  /// Peers already told to re-key after our identity reset (once per session).
  final Set<int> _identityResetRebuildNotified = {};

  /// Peers we already sent `requestSessionRebuild` to. Cleared per peer when a
  /// decrypt from them succeeds; cleared wholesale on fresh connect/logout.
  /// Without this, every history pass re-asked the peer to re-key (the
  /// SESSION_RESET{historyRetry} loop), forcing rebuild churn on every send.
  final Set<int> _rebuildRequestedPeers = {};

  /// True when a peer's in-band `senderListInfo` showed that OUR OWN devices
  /// disagree about our own device list (spec §12 amendment (xvii)). Benign by
  /// definition — our devices have not converged — so the UI shows a calm
  /// "syncing devices" note and NEVER the identity-changed surface. Cleared as
  /// soon as a claim agrees with what we hold.
  bool _devicesSyncing = false;

  bool get devicesSyncing => _devicesSyncing;

  /// One device-list re-fetch in flight per account, and one per cooldown —
  /// the rate limit amendment (xvi) requires, so a bogus claim attached to
  /// every inbound message cannot become a fetch storm.
  final SenderListInfoRefreshLimiter _listRefreshLimiter =
      SenderListInfoRefreshLimiter();

  /// Message ids the accept-side revocation gate WITHHELD (spec §12 amendments
  /// (e)/(xxvii)): either the sender's verified list shows the origin device
  /// revoked/absent, or we hold no verified list for that sender yet.
  ///
  /// Load-bearing: without it the post-retry sweep would stamp
  /// `[Decryption failed]` over a row nothing has failed on, and the recovery
  /// pass would ask the peer to re-key a session that is perfectly healthy.
  final Set<int> _acceptGateWithheldIds = {};

  /// tempIds whose `sendMessage` emit already happened — a second emit for the
  /// same optimistic message would advance the ratchet again and hand the
  /// recipient an undecryptable duplicate. Released on send failure (so user
  /// retry works); cleared on connect/logout with [_pendingSendContent].
  final Set<String> _emittedSendTempIds = {};

  /// tempIds whose LAST send attempt was refused by the account-anchor gate
  /// (`AccountIdentityMismatch`, amendments (xxxix)/(lv)).
  ///
  /// Per-ROW on purpose. The peer-level `peersRefusedIdentity` answers "is a
  /// ceremony outstanding for this chat", which is NOT the same question as
  /// "is THIS row the one that bounced on it": a timeout, a dropped socket or
  /// an "Image too large" refusal in the same chat would otherwise be
  /// explained to the user as a key change. Rewritten on every attempt for
  /// that tempId, so a retry that fails differently re-labels itself.
  final Set<String> _identityRefusedSendTempIds = {};

  /// True when [tempId]'s last send attempt was refused by the account-anchor
  /// gate. Read by the failed bubble to decide whether it may name the cause.
  bool sendRefusedForIdentity(String? tempId) =>
      tempId != null && _identityRefusedSendTempIds.contains(tempId);

  /// Test-only: record the same per-row verdict the send path writes when
  /// `ensureSession` throws `AccountIdentityMismatch` (`_encryptAndSend`'s
  /// catch). This drives the RENDER decision from a SCREEN test, which cannot
  /// reach that throw without a full E2E stack.
  ///
  /// It does NOT stand in for the classification: that is driven through the
  /// real send path in `messaging_provider_race_test.dart` ("an anchor refusal
  /// marks THAT row, a timeout does not"), which goes red if the
  /// `AccountIdentityMismatch` branch is removed.
  @visibleForTesting
  void markSendRefusedForIdentityForTest(String tempId) =>
      _identityRefusedSendTempIds.add(tempId);

  /// The `sendToken` minted per tempId (spec §5.4 + §12 amendment (ix)).
  ///
  /// One token per SEND, deliberately REUSED by a retry of the same optimistic
  /// message: the server enforces per-sender uniqueness, so a retry that
  /// reuses it re-acks the row already committed instead of duplicating the
  /// message. It is also the lost-ack reconcile key, because a new-model row
  /// carries no ciphertext for its own origin device. Cleared with
  /// [_pendingSendContent].
  final Map<String, String> _sendTokenByTempId = {};

  /// TempIds a box send has handed at least one frame to (PR3.1 slice (c)).
  /// Their wire id survives a same-user reconnect and a retry never falls
  /// back to the old path: the box may already have delivered the message
  /// to some devices, and only the box reader drops a copy by wire id.
  final Set<String> _boxTempIds = {};

  /// TempIds whose box send is running now: nothing else may fail or resend
  /// them until the box has answered.
  final Set<String> _boxInFlight = {};

  /// This connect's lookups of every device list a box send reads (decision
  /// 21): each box-covered peer's, plus the account's own once any peer is
  /// covered — each followed by the session pre-build for that user's
  /// box-covered devices (decision 38). Run by [refreshBoxDeviceLists], only
  /// awaited by a box send. Reset on every connect and on logout.
  late final BoxDeviceListRefresh _boxLists = BoxDeviceListRefresh(
    users: () {
      final covered = boxOutbox?.coveredPeers().toList() ?? const <int>[];
      final own = _currentUserId;
      return [if (covered.isNotEmpty && own != null) own, ...covered];
    },
    fetch: (user) async {
      final enc = _encryptionProvider;
      if (enc == null) throw StateError('no encryption provider');
      await enc.getVerifiedDeviceList(user, forceRefresh: true);
    },
    prebuild: _prebuildBoxSessions,
  );

  /// Looks up every device list a box send reads, unless this connect
  /// already verified it. Called when E2E or the account socket becomes
  /// ready and when the contact store opens late — never by a send
  /// (decision 21). A lookup before E2E is ready fails locally, emits
  /// nothing, and is looked up again when E2E-ready calls this.
  void refreshBoxDeviceLists() => _boxLists.refresh();

  /// The E2E layer dropped [userId]'s verified list (a rebuild request, an
  /// identity change, the own account's `deviceListChanged`): a box send
  /// that reads it waits for a fresh lookup.
  void onDeviceListInvalidated(int userId) => _boxLists.invalidate(userId);

  /// Stale-list resend attempts per tempId (spec §5.2 cap of 3, then a
  /// surfaced failure). Cleared with [_pendingSendContent].
  final Map<String, int> _staleResendAttempts = {};

  /// tempIds currently being resent after a `deviceListStale` refusal. The row
  /// is still SENDING (never flashed as failed), so [retryFailedMessage] needs
  /// this to know the resend is legitimate.
  final Set<String> _staleResendTempIds = {};

  /// Incremented on each new messageHistory to cancel stale in-flight decrypt loops.
  /// Each loop captures its generation at start and exits when the counter changes.
  int _decryptHistoryGeneration = 0;
  final List<Map<String, dynamic>> _incomingMessageQueue = [];

  /// Serializes live decrypt per sender so Signal ratchet order is preserved.
  final Map<int, Future<void>> _decryptChainBySender = {};

  /// Plaintext content + link preview + type/media keyed by tempId — survives
  /// _messages list overwrites (e.g. when messageHistory arrives before messageSent).
  /// Value: {'content': String, 'messageType'?: String, 'mediaUrl'?: String,
  ///         'mediaDuration'?: int, 'linkPreviewUrl'?: String, ...}
  final Map<String, Map<String, dynamic>> _pendingSendContent = {};

  // Monotonic counter for temporary negative message IDs — prevents collision
  // if two messages are sent within the same millisecond.
  static int _tempIdSeq = 0;

  // ---------- Message State ----------

  List<MessageModel> _messages = [];
  bool _isLoadingMore = false;
  bool _hasMore = false;
  int _paginationConversationId = -1;
  int _paginationOffset = 0;
  bool _isPaginationLoad = false;
  Completer<void>? _paginationCompleter;

  /// Monotonic id per [getMessages] emit; paired FIFO in [_pendingHistoryFetchSeq].
  int _historyFetchSeq = 0;
  final Map<int, List<int>> _pendingHistoryFetchSeq = {};

  /// Per-conversation message cache for the current session.
  /// Populated/updated by onMessageHistory (after decryption) and all mutation handlers.
  /// Survives back-navigation (clearMessages) and socket reconnects (onConnect).
  /// Cleared only on logout (clearAll).
  final Map<int, List<MessageModel>> _conversationCache = {};

  /// IDs of messages we were told were deleted (messageDeleted). Used so a late
  /// messageHistory response doesn't re-add them.
  final Set<int> _deletedMessageIds = {};

  /// Message being replied to (set when user taps Reply in bubble bottom sheet).
  MessageModel? _replyingToMessage;

  /// Message currently being edited (set when the user taps Edit in the context
  /// menu; cleared on send/cancel). Drives the composer "editing" banner.
  MessageModel? _editingMessage;

  /// Pre-edit row kept per messageId so a server reject (`editMessageFailed`) or
  /// an encrypt failure can restore the optimistic in-place update verbatim
  /// (copyWith can't reset editedAt to null, so we keep the whole row).
  final Map<int, MessageModel> _pendingEdits = {};

  bool _showPingEffect = false;

  /// Message ids whose ping effect already fired this provider lifetime.
  /// Transient event-dedup only (NOT a persisted played-ids cache): a
  /// redelivered/duplicate `newMessage` for a ping still reaches live decrypt,
  /// so this guarantees the effect flips at most once per id. Cleared on
  /// disconnect/fresh-connect with the rest of the transient decrypt state.
  final Set<int> _pingEffectFiredIds = {};

  /// Box messages shown whose plaintext record has not been PROVEN stored
  /// yet, by local id (`messaging_provider.box.dart`): the only copy until
  /// the journal's next offer stores it.
  final Map<int, MessageModel> _boxUnsaved = {};

  /// Fired after every history decrypt pass (`ConnectionProvider` drains the
  /// box journal): a box message refused for "no session" may decrypt now.
  void Function()? onHistoryDecryptPassFinished;

  /// Where a text goes when it can go over the box (PR3.1 slice (c));
  /// `ConnectionProvider` wires the account session's one. Null = old path.
  BoxOutbox? boxOutbox;

  /// This account's own devices over the box (PR3.1 sibling queues): where a
  /// sibling's handoff is stored and its ack sent. `ConnectionProvider`
  /// wires the account session's one; null = sibling entries wait.
  BoxSiblingLink? boxSiblings;

  /// Set in [dispose]; lets the overlay's dispose-scheduled onComplete
  /// microtask no-op instead of notifying a disposed ChangeNotifier.
  bool _pingEffectConsumerDisposed = false;
  final IncomingMessageSoundService _incomingSound =
      IncomingMessageSoundService();

  // ---------- Typing / Recording Indicators ----------

  final Map<int, bool> _typingStatus = {};
  final Map<int, Timer> _typingTimers = {};
  final Map<int, bool> _partnerRecordingVoice =
      {}; // conversationId -> isRecording

  /// Ticks every second for countdown display. Bubbles use ValueListenableBuilder
  /// so only they rebuild, not the whole screen. Prevents recording timer freeze.
  final ValueNotifier<int> countdownTickNotifier = ValueNotifier(0);

  /// True while user holds mic to record. Countdown timer skips ticks to avoid
  /// starving the recording timer callback (progressive freeze).
  bool isRecordingVoice = false;

  // ---------- Public Getters ----------

  /// The rows the UI shows. Rows that predate this device are omitted here and
  /// ONLY here: pre-link rows (content == [kNotLinkedYetMessageLabel], spec §12
  /// amendment (lxxxi)), and UNREADABLE rows the server stamped before this
  /// install's identity became the account's (amendment (lxxxvi), boundary =
  /// [EncryptionProvider.ownIdentitySince]). They stay in [_messages] and in
  /// storage, are never destroyed on the marker, and the decrypt/reconcile
  /// passes keep seeing them. The screen renders one divider for the whole run
  /// instead ([hiddenPreLinkCount]).
  ///
  /// Rebuilt lazily after every [notifyListeners] — every mutation of
  /// [_messages] ends in one, so a consumer never reads a stale view — or when
  /// the boundary moved, and returns [_messages] itself when nothing is
  /// hidden, so the common case allocates nothing.
  List<MessageModel> get messages {
    final since = _encryptionProvider?.ownIdentitySince;
    final cached = _visibleMessages;
    if (cached != null &&
        identical(_visibleSource, _messages) &&
        _visibleSince == since) {
      return cached;
    }
    _visibleSource = _messages;
    _visibleSince = since;
    var hidden = 0;
    for (final m in _messages) {
      if (_predatesThisDevice(m, since)) hidden++;
    }
    _hiddenPreLinkCount = hidden;
    return _visibleMessages = hidden == 0
        ? _messages
        : List.unmodifiable(
            _messages.where((m) => !_predatesThisDevice(m, since)),
          );
  }

  /// The row the chat list draws [lastMessage]'s preview from, or null for NO
  /// preview text (amendment (lxxxviii) A1).
  ///
  /// The server's `conversationsList` serves every E2E row as `[encrypted]`
  /// and only a LIVE event replaces it, so after any restart every chat's last
  /// message arrives that way. For such a row:
  ///   1. the plaintext this install holds for that id (the decrypt cache, else
  ///      the persisted copy) → that row, so the real text or media label;
  ///   2. else a PEER row that is still unread ([unreadCount] > 0) and does
  ///      not predate this device → [lastMessage] itself, which the tile shows
  ///      as "New message" — even when its decrypt failed here, because the
  ///      thread shows that row and the list must not blank it;
  ///   3. else null: a read row, an OWN row, or a row that predates this
  ///      device must not claim to be new.
  /// While the persisted copy is still being read the answer is null too — an
  /// empty line, never a false "New message" over a chat already read.
  ///
  /// Any other row keeps its own content unless this install can never read
  /// it (the verdict [messages] hides a row on), which gets no text either.
  MessageModel? listPreviewFor(
    MessageModel lastMessage, {
    required int unreadCount,
  }) {
    final since = _encryptionProvider?.ownIdentitySince;
    if (lastMessage.content != kEncryptedPlaceholderLabel ||
        _hasUsableDecryptedContent(lastMessage)) {
      return _predatesThisDevice(lastMessage, since) ? null : lastMessage;
    }
    final cached = _encryptionProvider?.getCachedDecryption(lastMessage.id);
    if (cached != null &&
        _hasUsableDecryptedContent(cached) &&
        !_isEditStale(lastMessage.editedAt, cached.editedAt)) {
      return cached;
    }
    if (!_listPlaintext.containsKey(lastMessage.id)) {
      _readListPlaintext(lastMessage).ignore();
      return null;
    }
    final stored = _listPlaintext[lastMessage.id];
    if (stored != null) return stored;
    final isNew =
        lastMessage.senderId != _currentUserId &&
        unreadCount > 0 &&
        !_predatesThisDevice(lastMessage, since);
    return isNew ? lastMessage : null;
  }

  /// The persisted plaintext looked up for [listPreviewFor], by message id:
  /// the restored row, or null when this install holds none. An absent key
  /// means "not answered yet". Cleared on logout.
  final Map<int, MessageModel?> _listPlaintext = {};

  /// Ids whose [_listPlaintext] read is in flight, so a list rebuilt while it
  /// runs does not start a second one.
  final Set<int> _listPlaintextReads = {};

  /// Reads the persisted plaintext for a chat-list row, then re-notifies so
  /// the list redraws. Waits for the E2E layer: before it is up the store is
  /// not bound to the user and every read would look like a miss. The screen
  /// rebuilds the list when it comes up, which asks again.
  Future<void> _readListPlaintext(MessageModel row) async {
    final enc = _encryptionProvider;
    if (enc == null || !enc.isE2EReady || !_listPlaintextReads.add(row.id)) {
      return;
    }
    final user = _currentUserId;
    MessageModel? held;
    try {
      final payload = await enc.getDecryptedContent(row.id);
      final storedEditedAt = DateTime.tryParse(
        payload?['editedAt'] as String? ?? '',
      );
      if (payload != null &&
          payload['content'] != kDecryptionFailedLabel &&
          !_isEditStale(row.editedAt, storedEditedAt)) {
        final restored = _restoreFromPersistedPayload(row, payload);
        if (_hasUsableDecryptedContent(restored)) held = restored;
      }
    } finally {
      _listPlaintextReads.remove(row.id);
    }
    if (_isDisposed || user != _currentUserId) return;
    _listPlaintext[row.id] = held;
    notifyListeners();
  }

  /// How many rows of the loaded history [messages] hides because they predate
  /// this device — its link, or its identity. Non-zero → the thread shows one
  /// "earlier messages aren't available on this device" divider at its oldest
  /// end.
  int get hiddenPreLinkCount {
    messages; // refresh the cache
    return _hiddenPreLinkCount;
  }

  List<MessageModel>? _visibleMessages;
  List<MessageModel>? _visibleSource;
  DateTime? _visibleSince;
  int _hiddenPreLinkCount = 0;

  @override
  void notifyListeners() {
    _visibleMessages = null;
    super.notifyListeners();
  }

  MessageModel? get replyingToMessage => _replyingToMessage;
  MessageModel? get editingMessage => _editingMessage;
  bool get showPingEffect => _showPingEffect;
  bool get isDecryptingHistory => _decryptingHistory;
  int? get currentUserId => _currentUserId;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMoreMessages => _hasMore;

  /// Test-only: seed the cache directly without going through onMessageHistory.
  @visibleForTesting
  void seedCacheForTest(int conversationId, List<MessageModel> messages) {
    _conversationCache[conversationId] = List.from(messages);
  }

  /// Test-only: the loaded rows INCLUDING the ones [messages] hides, so a test
  /// can prove a hidden row still exists (I8: a marker never destroys).
  @visibleForTesting
  List<MessageModel> get loadedMessagesForTest => List.unmodifiable(_messages);

  @visibleForTesting
  MessageModel? cacheMessageForTest(int conversationId, int messageId) {
    final list = _conversationCache[conversationId];
    if (list == null) return null;
    for (final m in list) {
      if (m.id == messageId) return m;
    }
    return null;
  }

  /// Loaded row for the open chat (oldest-first), if present.
  MessageModel? messageById(int messageId) {
    for (final m in _messages) {
      if (m.id == messageId) return m;
    }
    return null;
  }

  MessageModel _enrichReplyPreview(MessageModel msg) {
    return enrichMessageReplyPreview(
      msg,
      encryption: _encryptionProvider,
      messagesForLookup: _messages,
    );
  }

  void _reEnrichAllReplyQuotes() {
    for (var i = 0; i < _messages.length; i++) {
      final enriched = _enrichReplyPreview(_messages[i]);
      if (enriched != _messages[i]) {
        _messages[i] = enriched;
      }
    }
  }

  ReplyToPreview? _buildReplyPreviewFromReplyingTo() {
    final rt = _replyingToMessage;
    if (rt == null) return null;
    const labels = kReplyPreviewLabels;
    return ReplyToPreview(
      id: rt.id,
      content: replyPreviewForMessageModel(
        rt,
        encryption: _encryptionProvider,
        encryptedMessageLabel: labels.encryptedMessageLabel,
        voiceMessageLabel: labels.voiceMessageLabel,
        imageLabel: labels.imageLabel,
        gifLabel: labels.gifLabel,
        documentLabel: labels.documentLabel,
        pingLabel: labels.pingLabel,
        videoLabel: labels.videoLabel,
      ),
      senderUsername: rt.senderUsername,
      messageType: rt.messageType,
    );
  }

  void _clearReplyingToAfterSendStart() {
    if (_replyingToMessage != null) {
      _replyingToMessage = null;
      notifyListeners();
    }
  }

  /// Builds the optimistic (SENDING) message shown immediately for a media
  /// send, before encrypt/upload. Centralizes the fields every media path
  /// shares; per-type extras (voice `mediaUrl`/`mediaDuration`) are passed in.
  MessageModel _buildOptimisticMediaMessage({
    required String tempId,
    required int conversationId,
    required MessageType messageType,
    required String content,
    required int? effectiveExpiresIn,
    required int? effectiveReplyToId,
    String? mediaUrl,
    int? mediaDuration,
    int? mediaWidth,
    int? mediaHeight,
    String? mediaThumbHash,
  }) {
    return MessageModel(
      id: -(++MessagingProvider._tempIdSeq),
      content: content,
      senderId: _currentUserId!,
      senderUsername: '',
      conversationId: conversationId,
      createdAt: DateTime.now(),
      deliveryStatus: MessageDeliveryStatus.sending,
      messageType: messageType,
      mediaUrl: mediaUrl,
      mediaDuration: mediaDuration,
      mediaWidth: mediaWidth,
      mediaHeight: mediaHeight,
      mediaThumbHash: mediaThumbHash,
      disappearAfterSeconds: effectiveExpiresIn,
      expiresAt: null,
      tempId: tempId,
      replyToMessageId: effectiveReplyToId,
      replyTo: _buildReplyPreviewFromReplyingTo(),
    );
  }

  Future<void> _waitForE2EReady({int maxAttempts = 100}) async {
    for (var i = 0; i < maxAttempts; i++) {
      if (_encryptionProvider?.isE2EReady ?? false) return;
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<T> _runDecryptSerialized<T>(
    int senderId,
    Future<T> Function() action,
  ) {
    final previous = _decryptChainBySender[senderId] ?? Future<void>.value();
    final result = previous.then((_) => action());
    _decryptChainBySender[senderId] = result.then<void>(
      (_) {},
      onError: (_) {},
    );
    return result;
  }

  /// Test-only: set the active conversation ID (replaces ConversationsProvider wiring).
  @visibleForTesting
  void setActiveConversationIdForTest(int? id) {
    _activeConversationIdOverrideForTest = id;
  }

  @visibleForTesting
  void setIncomingMessageSoundEnabledForTest(bool enabled) {
    _incomingSound.setEnabledForTest(enabled);
  }

  @visibleForTesting
  int get incomingSoundRequestsForTest => _incomingSound.requests;

  bool isPartnerTyping(int conversationId) =>
      _typingStatus[conversationId] ?? false;

  bool isPartnerRecordingVoice(int conversationId) =>
      _partnerRecordingVoice[conversationId] ?? false;

  /// Update recording state and notify listeners. Called from ChatInputBar widget.
  void setIsRecordingVoice(bool value) {
    isRecordingVoice = value;
    notifyListeners();
  }

  // ---------- Dependency Wiring ----------

  /// Wire the EncryptionProvider for E2E operations.
  void setEncryptionProvider(EncryptionProvider ep) {
    _encryptionProvider = ep;
  }

  /// Wire the ConversationsProvider for lastMessage/unread updates.
  void setConversationsProvider(ConversationsProvider cp) {
    _conversationsProvider = cp;
  }

  /// Wire the socket emit callback so MessagingProvider can send events
  /// without depending on SocketService directly.
  void setEmitCallback(void Function(String event, dynamic data) emit) {
    _emit = emit;
  }

  /// Set the current user ID and auth token. Called on connect.
  void setCurrentUserId(int userId) {
    _currentUserId = userId;
  }

  /// Set auth token for REST calls (media upload, link preview proxy).
  void setToken(String? token) {
    _tokenForReconnect = token;
  }

  // ---------- Reaction keys ----------

  /// The reaction-key service, built on first use.
  ///
  /// Null until the E2E stack is wired: without it there is no session to
  /// wrap a key to and nothing to store it in, so callers fall back to
  /// rendering placeholders rather than pretending.
  ReactionKeyService? get _reactionKeyService {
    final encryption = _encryptionProvider;
    if (encryption == null) return null;
    return _reactionKeys ??= ReactionKeyService(
      store: encryption.encryptionService,
      request: _reactionKeyRequest,
      resolveTargets: _reactionKeyTargets,
      encryptFor: (userId, deviceId, plaintext) async {
        await encryption.ensureSession(userId, deviceId: deviceId);
        return encryption.encrypt(userId, plaintext, deviceId: deviceId);
      },
      // No `messageId`: this ciphertext is not a message row, so it has no
      // durable replay record to bind to.
      decryptFrom: (senderUserId, senderDeviceId, ciphertext) => encryption
          .decrypt(senderUserId, ciphertext, deviceId: senderDeviceId),
    );
  }

  /// Every device of the two participants that a wrapped key must reach.
  ///
  /// RESOLVES the device lists rather than reading the send path's cache.
  /// The send path may fall back to "device 1" because the SERVER refuses a
  /// legacy send whenever either party is enrolled (`deviceListStale`), so a
  /// bad guess there costs one refused send. `uploadReactionKey` has no such
  /// gate: a guess that misses a live device publishes an epoch that device
  /// can never obtain a key for, and the epoch-0 rule then forbids it from
  /// healing itself. So a guess here is permanent damage, and this fails
  /// CLOSED instead — an empty list makes the create refuse and the tap show
  /// its snackbar.
  ///
  /// `getVerifiedDeviceList` answers affirmatively for both shapes: an
  /// enrolled account's signed list, or the synthesized single device 1 for a
  /// non-enrolled one. Own other devices are always included; the send path
  /// adds them only when fanning out, which is exactly the case this must not
  /// inherit.
  Future<List<ReactionKeyTarget>> _reactionKeyTargets(int peerUserId) async {
    final encryption = _encryptionProvider;
    final ownUserId = _currentUserId;
    if (encryption == null || ownUserId == null) return const [];
    final VerifiedDeviceList peerList;
    final VerifiedDeviceList ownList;
    try {
      peerList = await encryption.getVerifiedDeviceList(peerUserId);
      ownList = await encryption.getVerifiedDeviceList(ownUserId);
    } on Object catch (_) {
      // Fail closed: `getVerifiedDeviceList` throws on a timeout, a missing
      // TOFU identity or a failed chain, and none of those license a guess.
      return const [];
    }
    final ownDeviceId = encryption.ownDeviceId;
    return [
      for (final deviceId in peerList.liveDeviceIds)
        (userId: peerUserId, deviceId: deviceId),
      for (final deviceId in ownList.liveDeviceIds)
        // Never this device: it stores the key directly, and the server
        // refuses a self-addressed envelope for the origin device.
        if (deviceId != ownDeviceId) (userId: ownUserId, deviceId: deviceId),
    ];
  }

  /// One socket request/response round trip for the reaction-key protocol.
  ///
  /// Returns null when there is no answer to be had (no socket, a collision
  /// on the single upload slot, or a timeout). The caller reads that as a
  /// refusal, which is the safe reading: nothing is created and no chip is
  /// claimed to be readable.
  Future<Map<String, dynamic>?> _reactionKeyRequest(
    String event,
    Map<String, dynamic> payload,
  ) async {
    final emit = _emit;
    if (emit == null) return null;

    if (event == 'fetchReactionKey') {
      final conversationId = payload['conversationId'] as int;
      // A fetch already in flight for this conversation IS this fetch: the
      // answer is addressed by conversation id, so both callers want the same
      // one and a second emit would only race the first.
      final existing = _reactionKeyFetches[conversationId];
      // The timeout is applied to the SHARED future too. Returning the bare
      // completer future handed the piggybacking caller a future that only
      // the originator's `finally` could ever release: when the answer never
      // came, the originator timed out and dropped the map entry while the
      // second caller awaited a completer nobody would complete — and since
      // that caller's acquisition was itself registered as in-flight, every
      // later one queued behind it forever.
      if (existing != null) {
        return existing.future.timeout(
          _reactionKeyRequestTimeout,
          onTimeout: () => null,
        );
      }
      final pending = Completer<Map<String, dynamic>?>();
      _reactionKeyFetches[conversationId] = pending;
      emit(event, payload);
      return _awaitReactionKeyAnswer(
        pending,
        () => _reactionKeyFetches.remove(conversationId),
      );
    }

    if (_reactionKeyUpload != null) return null;
    final pending = Completer<Map<String, dynamic>?>();
    _reactionKeyUpload = pending;
    // Remembered so a late answer for a DIFFERENT conversation cannot be read
    // as this one's: the two are otherwise indistinguishable, and mistaking
    // them persists a key the server never accepted.
    _reactionKeyUploadConversationId = payload['conversationId'] as int?;
    emit(event, payload);
    return _awaitReactionKeyAnswer(pending, () {
      _reactionKeyUpload = null;
      _reactionKeyUploadConversationId = null;
    });
  }

  Future<Map<String, dynamic>?> _awaitReactionKeyAnswer(
    Completer<Map<String, dynamic>?> pending,
    void Function() release,
  ) async {
    try {
      return await pending.future.timeout(_reactionKeyRequestTimeout);
    } on TimeoutException {
      return null;
    } finally {
      // Always released: a slot held by a dead request would refuse every
      // later upload for the life of the process.
      release();
    }
  }

  /// Server answer to `uploadReactionKey`.
  ///
  /// Dropped unless it names the conversation the pending upload was for. The
  /// slot is released on timeout, so without this check a slow answer for
  /// conversation A could complete a later upload for conversation B — and
  /// `_create` would persist B's key under A's epoch, a key no peer device
  /// ever received and which `loadReactionKey` would then serve forever.
  void onReactionKeyUploaded(dynamic data) {
    final pending = _reactionKeyUpload;
    if (pending == null || pending.isCompleted) return;
    final map = data is Map<String, dynamic> ? data : null;
    final answeredFor = map?['conversationId'];
    final expected = _reactionKeyUploadConversationId;
    if (answeredFor is int && expected != null && answeredFor != expected) {
      return;
    }
    pending.complete(map);
  }

  /// Server answer to `fetchReactionKey`.
  void onReactionKeyResponse(dynamic data) {
    final map = data is Map<String, dynamic> ? data : null;
    final conversationId = map?['conversationId'];
    if (conversationId is int) {
      final pending = _reactionKeyFetches[conversationId];
      if (pending != null && !pending.isCompleted) pending.complete(map);
      return;
    }
    // `invalid_payload` answers with a null conversation id when the request
    // carried no usable one. Nothing can be correlated, so every waiter is
    // told — a refusal is the right answer for all of them, and leaving them
    // to time out would stall each acquisition for 20s.
    for (final pending in _reactionKeyFetches.values.toList()) {
      if (!pending.isCompleted) pending.complete(map);
    }
  }

  /// Turns a wire reaction map into the one the UI renders.
  ///
  /// Applied where reactions ENTER (history, new message, `reactionUpdated`)
  /// rather than at render time, so every downstream reader — chips, the
  /// context menu's own-reaction check, the toggle — sees one shape and needs
  /// no codec of its own.
  Map<String, List<int>> _renderableReactions(
    int conversationId,
    Map<String, List<int>> wire,
  ) {
    if (wire.isEmpty) return wire;
    final resolved = resolveReactionKeys(
      wire,
      _reactionKeys?.cachedCodec(conversationId),
    );
    if (resolved.keys.any(isUnresolvedReactionKey)) {
      _fetchReactionKeyOnce(conversationId);
    }
    return resolved;
  }

  MessageModel _withRenderableReactions(MessageModel msg) =>
      msg.reactions.isEmpty
      ? msg
      : msg.copyWith(
          reactions: _renderableReactions(msg.conversationId, msg.reactions),
        );

  /// Starts at most one background key acquisition per conversation.
  ///
  /// A chat can render fifty unreadable chips; it must ask the server once.
  /// Never creates a key: this runs without the user asking for anything, and
  /// creating one advances the epoch.
  void _fetchReactionKeyOnce(int conversationId) {
    if (!_reactionKeyAttempted.add(conversationId)) return;
    final service = _reactionKeyService;
    final peerUserId = _peerUserIdFor(conversationId);
    if (service == null || peerUserId == null) {
      _reactionKeyAttempted.remove(conversationId);
      return;
    }
    unawaited(
      service
          .ensureCodec(conversationId, peerUserId: peerUserId)
          .then((result) {
            if (result.codec != null) {
              _reRenderReactions(conversationId);
              return;
            }
            // TRANSIENT failures release the latch so the next message in
            // this chat tries again. `refused` is transient too and used not
            // to be: it is what a dead socket, a 20s timeout and the fetch
            // throttle all produce, so treating it as terminal latched a
            // whole conversation into placeholder chips until app restart,
            // long after the socket recovered.
            //
            // Only `noKeyYet` (this device is not in the mailbox at this
            // epoch) and `undecryptable` (the row was already spent) stay
            // latched — nothing this device does makes those resolve, and
            // re-pulling would only burn ratchet steps.
            if (result.failure == ReactionKeyFailure.unavailable ||
                result.failure == ReactionKeyFailure.refused) {
              _reactionKeyAttempted.remove(conversationId);
            }
          })
          .catchError((Object _) {
            // A throw here would otherwise surface as an unhandled zone
            // error; the chat simply keeps its placeholders and may retry.
            _reactionKeyAttempted.remove(conversationId);
          }),
    );
  }

  /// Re-maps already-stored reactions for [conversationId] once its key lands.
  ///
  /// Safe to run repeatedly: an already-resolved emoji key passes through
  /// untouched, so this only ever turns tokens into emoji.
  void _reRenderReactions(int conversationId) {
    var changed = false;
    for (var i = 0; i < _messages.length; i++) {
      final msg = _messages[i];
      if (msg.conversationId != conversationId || msg.reactions.isEmpty) {
        continue;
      }
      if (!msg.reactions.keys.any(isUnresolvedReactionKey)) continue;
      _messages[i] = _withRenderableReactions(msg);
      changed = true;
    }
    final cached = _conversationCache[conversationId];
    if (cached != null) {
      for (var i = 0; i < cached.length; i++) {
        final msg = cached[i];
        if (msg.reactions.isEmpty) continue;
        if (!msg.reactions.keys.any(isUnresolvedReactionKey)) continue;
        cached[i] = _withRenderableReactions(msg);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// The wire value a reaction must be sent as, or null if this device cannot
  /// produce one.
  ///
  /// Null is NEVER downgraded to the plain emoji: that would put the reaction
  /// back on the server in the clear, which is the entire thing this change
  /// removes. The caller reports the failure instead.
  Future<String?> _reactionWireKey(int conversationId, String emoji) async {
    // Already a token (the user tapped an existing chip that this device could
    // not name): it is unnameable here, so it cannot be toggled here either.
    if (isUnresolvedReactionKey(emoji)) return null;
    final service = _reactionKeyService;
    final peerUserId = _peerUserIdFor(conversationId);
    if (service == null || peerUserId == null) return null;
    final result = await service.ensureCodec(
      conversationId,
      peerUserId: peerUserId,
      // A tap is the deliberate act that may mint the conversation's first
      // key. The service still refuses to re-key an existing epoch.
      mayCreate: true,
    );
    final codec = result.codec;
    if (codec == null) return null;
    // A key just arrived: chips rendered as placeholders can be named now.
    _reRenderReactions(conversationId);
    return codec.tokenFor(emoji);
  }

  int? _peerUserIdFor(int conversationId) {
    final conv = _conversationsProvider?.conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    if (conv == null) return null;
    return conv_helpers.getOtherUserId(conv, _currentUserId);
  }

  // ---------- Reply-To ----------

  VoidCallback? _composerFocusRequest;

  /// Registered by [ChatInputBar] so reply gestures can focus the composer in the
  /// same user-gesture turn (required for iOS Safari PWA keyboard).
  void setComposerFocusRequest(VoidCallback? request) {
    _composerFocusRequest = request;
  }

  void setReplyingTo(MessageModel? msg) {
    _replyingToMessage = msg;
    if (msg != null) {
      _composerFocusRequest?.call();
    }
    notifyListeners();
  }

  void clearReplyingTo() {
    if (_replyingToMessage != null) {
      _replyingToMessage = null;
      notifyListeners();
    }
  }

  /// Enter edit mode for [msg]; the composer prefills its text and routes send
  /// to [editMessage]. Focuses the composer like reply.
  void beginEditMessage(MessageModel msg) {
    _editingMessage = msg;
    _replyingToMessage = null;
    _composerFocusRequest?.call();
    notifyListeners();
  }

  /// Leave edit mode without sending.
  void cancelEditMessage() {
    if (_editingMessage != null) {
      _editingMessage = null;
      notifyListeners();
    }
  }

  // ---------- Ping Effect ----------

  void clearPingEffect() {
    // May arrive via PingEffectOverlay's dispose-scheduled microtask AFTER
    // this provider was disposed (full app teardown mid-animation) —
    // notifyListeners on a disposed ChangeNotifier is a debug assert.
    if (_pingEffectConsumerDisposed) return;
    _showPingEffect = false;
    notifyListeners();
  }

  // ---------- Internal Helpers ----------

  /// Parse a message type string from envelope/persisted data into MessageType enum.
  MessageType? _parseMessageTypeString(String? type) {
    switch (type) {
      case 'TEXT':
        return MessageType.text;
      case 'PING':
        return MessageType.ping;
      case 'VOICE':
        return MessageType.voice;
      case 'IMAGE':
        return MessageType.image;
      case 'GIF':
        return MessageType.gif;
      case 'FILE':
        return MessageType.file;
      case 'VIDEO':
        return MessageType.video;
      default:
        return null;
    }
  }

  // ---------- Lifecycle ----------

  /// Called on socket connect. Clears message state for fresh connect,
  /// preserves for reconnect (same user).
  void onConnect(bool isReconnect) {
    _decryptHistoryGeneration++; // cancel any in-flight history decrypt
    _pendingHistoryFetchSeq.clear();

    if (!isReconnect) {
      // Fresh connect or switch user: clear ALL message state
      _messages = [];
      _deletedMessageIds.clear();
      _typingStatus.clear();
      for (final t in _typingTimers.values) {
        t.cancel();
      }
      _typingTimers.clear();
      _partnerRecordingVoice.clear();
      _replyingToMessage = null;
      _editingMessage = null;
      _pendingEdits.clear();
      _pendingSendContent.clear();
      _emittedSendTempIds.clear();
      _identityRefusedSendTempIds.clear();
      _sendTokenByTempId.clear();
      _boxTempIds.clear();
      _boxLists.reset();
      _staleResendAttempts.clear();
      _staleResendTempIds.clear();
      _incomingMessageQueue.clear();
      _identityResetRebuildNotified.clear();
      _rebuildRequestedPeers.clear();
      // Fresh connect / user switch: forget which pings already fired.
      // (Reconnect deliberately KEEPS it so resync redelivery stays silent.)
      _pingEffectFiredIds.clear();
      // Local ids restart at the same base for every account: an unsaved
      // row of the previous session must never be stored into this one.
      _boxUnsaved.clear();
      // A different user (or the same user, freshly signed in) must not
      // inherit either the cached `K_react` codecs or the per-conversation
      // "already asked" latch: the codecs are key material for an account
      // that is no longer signed in, and the latch would keep a healthy chat
      // on placeholder chips.
      _resetReactionKeyState();
      _cancelDelayedRetryIfAny();
    } else {
      // Reconnect (same user): keep messages to avoid flicker.
      // Clear typing/recording indicators (stale after reconnect).
      // NOTE: _rebuildRequestedPeers is deliberately KEPT on reconnect —
      // reconnect storms were exactly what re-fired the rebuild-request loop.
      _typingStatus.clear();
      for (final t in _typingTimers.values) {
        t.cancel();
      }
      _typingTimers.clear();
      _partnerRecordingVoice.clear();
      _replyingToMessage = null;
      _editingMessage = null;
      _pendingEdits.clear();
      _pendingSendContent
          .clear(); // retry was cancelled; orphaned entries serve no purpose
      _emittedSendTempIds.clear();
      _identityRefusedSendTempIds.clear();
      // A box send's retry must reuse its wire id, or a device the failed
      // attempt reached shows the message twice.
      _sendTokenByTempId.removeWhere(
        (tempId, _) => !_boxTempIds.contains(tempId),
      );
      _boxLists.reset();
      _staleResendAttempts.clear();
      _staleResendTempIds.clear();
      // Same user, so the codecs stay valid — but every conversation gets
      // another chance to fetch: the latch was most likely set BY the
      // disconnect that caused this reconnect.
      _reactionKeyAttempted.clear();
      _reactionKeyFetches.clear();
      _reactionKeyUpload = null;
      _reactionKeyUploadConversationId = null;
      _cancelDelayedRetryIfAny();
    }

    notifyListeners();
  }

  /// Drops every trace of reaction-key state (fresh connect, user switch,
  /// logout). Key material in RAM must not outlive the session that fetched
  /// it, and a pending round trip must not complete into the next one.
  void _resetReactionKeyState() {
    _reactionKeys?.clear();
    _reactionKeys = null;
    _reactionKeyAttempted.clear();
    _reactionKeyFetches.clear();
    _reactionKeyUpload = null;
    _reactionKeyUploadConversationId = null;
  }

  /// Called on socket disconnect. Cancels timers.
  void onDisconnect() {
    _cancelDelayedRetryIfAny();
    _liveDecryptRetryTimer?.cancel();
    _liveDecryptRetryTimer = null;
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    _typingTimers.clear();
  }

  /// Full reset — called on logout / account deletion.
  void clearAll() {
    _messages = [];
    _conversationCache.clear();
    _pendingHistoryFetchSeq.clear();
    _deletedMessageIds.clear();
    _typingStatus.clear();
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    _typingTimers.clear();
    _partnerRecordingVoice.clear();
    _replyingToMessage = null;
    _editingMessage = null;
    _pendingEdits.clear();
    _showPingEffect = false;
    _pendingSendContent.clear();
    _incomingMessageQueue.clear();
    _decryptChainBySender.clear();
    _decryptingHistory = false;
    _decryptHistoryGeneration++;
    _liveDecryptRetryTimer?.cancel();
    _liveDecryptRetryTimer = null;
    _liveDecryptFailedPeers.clear();
    _listPlaintext.clear();
    _listPlaintextReads.clear();
    _identityResetRebuildNotified.clear();
    _rebuildRequestedPeers.clear();
    _pingEffectFiredIds.clear();
    _boxUnsaved.clear();
    _emittedSendTempIds.clear();
    _identityRefusedSendTempIds.clear();
    _sendTokenByTempId.clear();
    _boxTempIds.clear();
    _boxLists.reset();
    _staleResendAttempts.clear();
    _staleResendTempIds.clear();
    // Logout: `K_react` for every visited conversation is in RAM here.
    _resetReactionKeyState();
    _cancelDelayedRetryIfAny();
    _currentUserId = null;
    _tokenForReconnect = null;
    notifyListeners();
  }

  /// Clear messages for the active conversation (used when clearing active chat).
  void clearMessages() {
    _finishPaginationLoad();
    _messages = [];
    _hasMore = false;
    _paginationOffset = 0;
    _paginationConversationId = -1;
    notifyListeners();
  }

  /// True once [dispose] ran. Deferred (post-frame) callers that outlive the
  /// provider — e.g. ChatDetailScreen's teardown-deferred [clearMessages] —
  /// must check this instead of notifying a disposed ChangeNotifier.
  bool get isDisposed => _isDisposed;
  bool _isDisposed = false;

  @override
  void dispose() {
    _isDisposed = true;
    _pingEffectConsumerDisposed = true;
    // Mirror onDisconnect: none of onDisconnect / onConnect / clearAll is
    // guaranteed to run before teardown, so a pending typing / delayed-retry /
    // live-decrypt-retry timer would fire past super.dispose() and notify a
    // disposed ChangeNotifier.
    onDisconnect();
    _boxLists.reset();
    _incomingSound.dispose();
    countdownTickNotifier.dispose();
    super.dispose();
  }
}
