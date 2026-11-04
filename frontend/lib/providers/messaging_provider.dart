import 'dart:async';
import 'dart:convert';
import 'package:clock/clock.dart';
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
import '../services/box/box_catch_up.dart';
import '../services/box/box_device_list_refresh.dart';
import '../services/box/box_device_pause.dart';
import '../services/box/box_envelope.dart';
import '../services/box/box_first_contact.dart';
import '../services/box/box_frame.dart';
import '../services/box/box_friends.dart';
import '../services/box/box_media_fetcher.dart';
import '../services/box/box_media_frame.dart';
import '../services/box/box_media_url.dart';
import '../services/box/box_outbox.dart';
import '../services/box/box_sibling_alive.dart';
import '../services/box/box_siblings.dart';
import '../services/box/box_wire.dart';
import '../services/box_hidden_notifier.dart';
import '../services/contacts/contact_record.dart';
import '../services/contacts/contact_store.dart';
import '../services/device_list/device_list_cache.dart';
import '../services/device_list/sender_list_info.dart';
import '../services/media_crypto_service.dart';
import '../services/encryption/prekey_identity.dart'
    show FriendFrameIdentity, friendFrameIdentity;
import '../services/encryption_service.dart';
import '../services/incoming_message_sound_service.dart';
import '../services/link_preview_service.dart';
import '../services/plaintext_record_codec.dart';
import '../utils/anti_quantum_note_link.dart';
import '../utils/decryption_failure_policy.dart';
import '../utils/e2e_diag_log.dart';
import '../utils/e2e_envelope.dart';
import '../utils/media_preview_metadata.dart';
import '../utils/e2e_persistent_diag.dart';
import '../utils/message_edit_eligibility.dart';
import '../utils/message_expiry.dart';
import '../utils/message_ids.dart';
import '../utils/message_length.dart';
import '../utils/reply_preview_helper.dart';
import 'conversation_helpers.dart' as conv_helpers;
import 'conversations_provider.dart';
import 'encryption_provider.dart';

part 'messaging/messaging_provider.box.dart';
part 'messaging/messaging_provider.box_alive.dart';
part 'messaging/messaging_provider.box_actions.dart';
part 'messaging/messaging_provider.box_receipts.dart';
part 'messaging/messaging_provider.box_relay.dart';
part 'messaging/messaging_provider.box_sync.dart';
part 'messaging/messaging_provider.history.dart';
part 'messaging/messaging_provider.events.dart';
part 'messaging/messaging_provider.send.dart';
part 'messaging/messaging_provider.decrypt.dart';
part 'messaging/messaging_provider.actions.dart';
part 'messaging/messaging_provider.first_contact.dart';

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
  MediaCryptoService _mediaCrypto = MediaCryptoService();

  @visibleForTesting
  void setMediaCryptoForTest(MediaCryptoService crypto) {
    _mediaCrypto = crypto;
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

  // ---------- E2E Encryption ----------

  /// Single delayed retry for a failed message after a timeout (e.g. the
  /// device-list lookup the box route waits on).
  Timer? _delayedRetryTimer;
  String? _delayedRetryTempId;

  /// Peers already told to re-key after our identity reset (once per session).
  final Set<int> _identityResetRebuildNotified = {};

  /// Peers we already sent `requestSessionRebuild` to. Cleared per peer when a
  /// decrypt from them succeeds; cleared wholesale on fresh connect/logout.
  /// Without this, every failed read re-asked the peer to re-key (the
  /// SESSION_RESET loop), forcing rebuild churn on every send.
  final Set<int> _rebuildRequestedPeers = {};

  /// tempIds whose send attempt is running or has gone out — a second
  /// attempt for the same optimistic message would advance the ratchet again
  /// and hand the recipient an undecryptable duplicate. Released on send
  /// failure (so user retry works); cleared on connect/logout.
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

  /// The `sendToken` minted per tempId: the message's wire id (spec §5.4).
  ///
  /// One token per SEND, deliberately REUSED by a retry of the same optimistic
  /// message, so a device already holding the message drops the repeat by wire
  /// id. Cleared on a fresh connect and sign-out; a reconnect keeps the box
  /// sends' (see [_boxTempIds]).
  final Map<String, String> _sendTokenByTempId = {};

  /// TempIds a box send has handed at least one frame to (PR3.1 slice (c)).
  /// Their wire id survives a same-user reconnect: the box may already have
  /// delivered the message to some devices, and only the box reader drops a
  /// copy by wire id.
  final Set<String> _boxTempIds = {};

  /// TempIds whose box send is running now: nothing else may fail or resend
  /// them until the box has answered.
  final Set<String> _boxInFlight = {};

  /// TempIds this device keeps as box messages that did not go out
  /// (decision 104): kept by this session's send or restored with their
  /// chat. Only these rows are deleted on the device alone.
  final Set<String> _boxUnsentTempIds = {};

  /// A revoke announcement is running (E50d): one at a time.
  bool _announcingOwnList = false;

  /// `peer:device:ownVersion` this session already answered with our list
  /// because its frame showed a stale view of it (E50f).
  final Set<String> _staleViewsAnswered = {};

  /// This connect's lookups of every device list a box send reads (decision
  /// 21): each box-covered peer's, plus the account's own once any peer is
  /// covered — each followed by the session pre-build for that user's
  /// box-covered devices (decision 38). Run by [refreshBoxDeviceLists], only
  /// awaited by a box send. Reset on every connect and on logout.
  ///
  /// Decision 51: a peer's list is asked of the server only when none is
  /// held, or when this device was off the box longer than the box TTL (an
  /// announcement may have expired unread, E50c); otherwise the held one —
  /// kept across restarts, moved by E2E announcements — stands. The own
  /// list is looked up every time (it names only the caller) and is what
  /// a revoke announcement is decided on (E50d).
  late final BoxDeviceListRefresh _boxLists = BoxDeviceListRefresh(
    users: () {
      final covered = boxOutbox?.coveredPeers().toList() ?? const <int>[];
      final own = _currentUserId;
      return [if (covered.isNotEmpty && own != null) own, ...covered];
    },
    // The OWN list is asked by id (it names only the caller). A covered
    // peer is always a friend, whose list is the one held or one handle
    // lookup (decision 114, E114a): never named to the server by id.
    fetch: (user) async {
      final enc = _encryptionProvider;
      if (enc == null) throw StateError('no encryption provider');
      if (user == _currentUserId) {
        await enc.getVerifiedDeviceList(user, forceRefresh: true);
        _markBoxListsReady(enc);
        unawaited(_announceOwnListIfRevoked());
        return;
      }
      try {
        await enc.getVerifiedDeviceList(
          user,
          forceRefresh: enc.peerListOwedByServer(user),
        );
      } finally {
        // Every answer — a refused list throws but still counts as answered
        // (E50c) — may be the last owed one that lets the stamp be written.
        _markBoxListsReady(enc);
      }
    },
    prebuild: _prebuildBoxSessions,
    // A chat shown before this connect's lookups landed had no route for
    // its read receipt (slice (g), E61d).
    onReady: (_) => _reportShownBoxChatRead(),
  );

  /// E50c's "box-ready" stamp, written only while this device is on the box
  /// (its request queue is published): an account socket that keeps
  /// reconnecting while the box stays unreachable must not keep the stamp
  /// fresh.
  void _markBoxListsReady(EncryptionProvider enc) {
    if (boxFriends?.onBox ?? false) {
      enc.markBoxListsReady(boxOutbox?.coveredPeers() ?? const <int>[]);
    }
  }

  /// Looks up every device list a box send reads, unless this connect
  /// already verified it. Called when E2E or the account socket becomes
  /// ready and when the contact store opens late — never by a send
  /// (decision 21). A lookup before E2E is ready fails locally, emits
  /// nothing, and is looked up again when E2E-ready calls this.
  ///
  /// Box ready or reconnected: every box action a device still owes is
  /// sent again now (E19l).
  void refreshBoxDeviceLists() {
    _boxLists.refresh();
    _retryBoxActionsNow();
    // Decision 103: the daily `alive` to each live sibling.
    unawaited(_siblingAlivePass());
    // Decision 102: an absence that just ended asks a sibling to catch up.
    unawaited(catchUpTick());
  }

  /// The E2E layer dropped [userId]'s verified list (a rebuild request, an
  /// identity change, the own account's `deviceListChanged`): a box send
  /// that reads it waits for a fresh lookup.
  void onDeviceListInvalidated(int userId) {
    _boxLists.invalidate(userId);
    // The own list moved (a link, a revoke): the unlink line is re-judged.
    if (userId == _currentUserId) unawaited(_siblingAlivePass());
  }

  /// Serializes box reads per sender so Signal ratchet order is preserved.
  final Map<int, Future<void>> _decryptChainBySender = {};

  // Monotonic counter for temporary negative message IDs — prevents collision
  // if two messages are sent within the same millisecond.
  static int _tempIdSeq = 0;

  // Per-process counter in every tempId: `temp_<millis>_<userId>` alone was
  // shared by two sends started in the same millisecond, and the second was
  // dropped as SEND_DUPLICATE_BLOCKED.
  static int _tempIdMint = 0;

  /// A new optimistic-send id. Opaque everywhere: the server only echoes it
  /// and the wire id takes it as a prefix (`_sendTokenFor`, ≤ 64 chars).
  String _newTempId() =>
      'temp_${clock.now().millisecondsSinceEpoch}_${++_tempIdMint}_'
      '$_currentUserId';

  // ---------- Message State ----------

  List<MessageModel> _messages = [];

  /// The chat [getMessages] last opened (-1 = none): where a box message is
  /// shown while [ConversationsProvider] names no active chat yet.
  int _openConversationId = -1;

  /// Per-conversation message cache for the current session.
  /// Populated/updated by [getMessages] and all mutation handlers.
  /// Survives back-navigation (clearMessages) and socket reconnects (onConnect).
  /// Cleared only on logout (clearAll).
  final Map<int, List<MessageModel>> _conversationCache = {};

  /// IDs of messages deleted on this device or for everyone: a later read of
  /// a stored record must not show them again.
  final Set<int> _deletedMessageIds = {};

  /// Message being replied to (set when user taps Reply in bubble bottom sheet).
  MessageModel? _replyingToMessage;

  /// Message currently being edited (set when the user taps Edit in the context
  /// menu; cleared on send/cancel). Drives the composer "editing" banner.
  MessageModel? _editingMessage;

  /// Pre-edit row kept per messageId so a box edit no device took can
  /// restore the optimistic in-place update verbatim (copyWith can't reset
  /// editedAt to null, so we keep the whole row).
  final Map<int, MessageModel> _pendingEdits = {};

  bool _showPingEffect = false;

  /// Message ids whose ping effect already fired this provider lifetime.
  /// Transient event-dedup only (NOT a persisted played-ids cache): a
  /// redelivered box frame for a ping still reaches the reader, so this
  /// guarantees the effect flips at most once per id. Cleared on
  /// fresh-connect with the rest of the transient state.
  final Set<int> _pingEffectFiredIds = {};

  /// Box messages shown whose plaintext record has not been PROVEN stored
  /// yet, by local id (`messaging_provider.box.dart`): the only copy until
  /// the journal's next offer stores it.
  final Map<int, MessageModel> _boxUnsaved = {};

  /// Where a message goes: the box, the only path. `ConnectionProvider`
  /// wires the account session's one. Null = no route: every send fails.
  BoxOutbox? boxOutbox;

  /// This account's own devices over the box (PR3.1 sibling queues): where a
  /// sibling's handoff is stored and its ack sent. `ConnectionProvider`
  /// wires the account session's one; null = sibling entries wait.
  BoxSiblingLink? boxSiblings;

  /// When each own sibling was last heard, the daily `alive` this device
  /// owes it and the user's "Keep" (decisions 101 B, 103).
  /// `ConnectionProvider` wires one over the account's contact store; null =
  /// nothing is stamped, sent or asked.
  BoxSiblingAlive? boxAlive;

  /// Friendships moving onto the box (item 5, decision 47): where a friend's
  /// queue handoff is stored and acknowledged, and whether this device is on
  /// the box at all. `ConnectionProvider` wires the account session's one;
  /// null = friend handoffs wait and no composer notice shows.
  BoxFriendLink? boxFriends;

  /// First contact over the box (slice (f), decisions 52–55): the records a
  /// request makes and the queue it offers. `ConnectionProvider` wires the
  /// account session's one; null = every request fails.
  BoxFirstContactLink? boxFirstContact;

  /// One `searchUsers` of a handle and its raw answer (null: none came) —
  /// the accept-time check of decision 53 and a box friend's list lookup
  /// (E15h). `ConnectionProvider` wires `FriendsProvider.lookupHandle`.
  Future<List<Object?>?> Function(String handle)? lookupHandle;

  /// A record made over the box changed (a request kept, sent, declined or
  /// accepted): the friends lists re-read the store.
  void Function()? onBoxContactsChanged;

  /// A friendship over the box began — `outgoing` when this account asked.
  void Function(int userId, {required bool outgoing})? onBoxFriendshipMade;

  /// A friendship over the box ended from another device (a friend's
  /// `goodbye`, a sibling's copy of ours, E15j): its chat and history go.
  void Function(int userId)? onBoxFriendshipEnded;

  /// This account's box attachment copies (item 3 / media wiring, decision
  /// 40): kept on send and arrival, read to display. `ConnectionProvider`
  /// wires the one owned beside the account's box session; null = box
  /// attachments neither download nor show.
  BoxMediaFetcher? boxMedia;

  /// Box attachments encrypted but not yet uploaded, by tempId (E17b): a
  /// retry uploads the SAME ciphertext, key and IV — `MediaCryptoService`
  /// takes no caller key, so re-encrypting would mint new ones. Held from a
  /// failed route lookup on, too, so that send retries like any other. Gone
  /// with a successful upload; a restart loses them, and the row stays
  /// failed for the user to send again.
  final Map<String, _BoxMediaBody> _boxMediaBodies = {};

  /// Box message actions NO device took (item 4, E19h/E19l), for the chat
  /// screen.
  final StreamController<BoxActionFailure> _boxActionFailures =
      StreamController<BoxActionFailure>.broadcast();

  /// Box actions some device took and some did not (item 4, E19l), by
  /// [_boxActionKey]: the frames still owed, sent again until taken or
  /// 30 d. RAM only (decision 19: no persisted outbox).
  final Map<String, _BoxActionRetry> _boxActionRetries = {};

  /// The newest box action send some device took, per [_boxActionKey]: an
  /// older send settling after it leaves no retry (E19l).
  final Map<String, int> _boxActionSends = {};
  int _boxActionSendSeq = 0;

  /// Devices whose box queue is full (E93a): no frame is sealed to them
  /// but a probe now and then, until one is taken or they send to us.
  final BoxDevicePause _boxPaused = BoxDevicePause();

  /// Each pin, edit or delete-for-everyone of a box message that NO device
  /// took; its optimistic state is already undone.
  Stream<BoxActionFailure> get boxActionFailures => _boxActionFailures.stream;

  // ---------- Box receipts and typing (slice (g), decisions 61–62) ----------

  /// The device-local switch (E61c), read live: `ConversationsScreen` wires
  /// `SettingsProvider.receiptsAndTyping`. OFF: no `rcpt`/`typ` is sent and
  /// every one received is ignored.
  bool Function() receiptsAndTyping = () => false;

  /// Wire ids of each peer's box messages this device took since the inbox
  /// last went idle: the next `rcpt d` to that peer (E61d).
  final Map<int, Set<String>> _boxDeliveredOwed = {};

  /// `peer|wire` of every peer box message named in a `rcpt r` this
  /// process, in flight or taken: never named twice at once, and left out
  /// of the drain's `rcpt d` (E61d). One no device took leaves the set; one
  /// taken is `read` in its record for every later launch.
  final Set<String> _boxReadReported = {};

  /// Per chat, the seen mark this session last wrote (decision 73, E73a):
  /// a show that moves nothing writes nothing.
  final Map<int, int> _boxSeenMarked = {};

  /// When this device last sent typing `on` into each chat (E61e).
  final Map<int, DateTime> _boxTypingSentAt = {};

  /// Per chat, while this device records a voice note: `typ v on` again
  /// every 5 s (E61e).
  final Map<int, Timer> _boxVoiceResends = {};

  /// Per chat, when the peer's voice indicator expires without an `off`.
  final Map<int, Timer> _boxVoiceTimers = {};

  /// Set in [dispose]; lets the overlay's dispose-scheduled onComplete
  /// microtask no-op instead of notifying a disposed ChangeNotifier.
  bool _pingEffectConsumerDisposed = false;
  final IncomingMessageSoundService _incomingSound =
      IncomingMessageSoundService();

  /// H1 (decision R81): the native app's hidden-arrival card; replaced in
  /// tests.
  @visibleForTesting
  BoxHiddenNotifier boxHiddenNotifier = BoxHiddenNotifier();

  /// Decision 102: this device's catch-up state (presence stamp, heartbeat,
  /// the blob's crypto); replaced in tests.
  @visibleForTesting
  BoxCatchUp boxCatchUp = BoxCatchUp();

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

  /// The rows of the open chat, oldest first.
  List<MessageModel> get messages => _messages;

  MessageModel? get replyingToMessage => _replyingToMessage;
  MessageModel? get editingMessage => _editingMessage;
  bool get showPingEffect => _showPingEffect;
  int? get currentUserId => _currentUserId;

  /// Test-only: seed the cache directly without going through [getMessages].
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
      // What a box reply names the quoted message by (E18a).
      wireId: rt.wireId,
      senderId: rt.senderId,
      quotedDisappears:
          rt.disappearAfterSeconds != null || rt.expiresAt != null,
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
    // A destroyed box record takes this device's copy of its attachment.
    ep.onBoxMediaDestroyed = _forgetBoxMedia;
  }

  void _forgetBoxMedia(List<String> urls) {
    final media = boxMedia;
    final user = _currentUserId;
    if (media == null || user == null) return;
    for (final url in urls) {
      final id = boxMediaIdOf(url);
      if (id != null) media.forget(user, id).ignore();
    }
  }

  /// The unframed ciphertext of box attachment [url] for the widgets that
  /// show it (`loadDecryptedMediaBytes`' `BoxCiphertextSource`): this
  /// device's copy, else a download. Null when there is none.
  Future<Uint8List?> boxMediaCiphertext(String url) async {
    final media = boxMedia;
    final user = _currentUserId;
    final id = boxMediaIdOf(url);
    if (media == null || user == null || id == null) return null;
    return media.ciphertextFor(user, id);
  }

  /// Wire the ConversationsProvider for lastMessage/unread updates.
  void setConversationsProvider(ConversationsProvider cp) {
    _conversationsProvider = cp;
    // The app is looked at again: the chat on screen is read now (slice
    // (g), E61d).
    cp.onClientVisible = _reportShownBoxChatRead;
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
    if (!isReconnect) {
      // Fresh connect or switch user: clear ALL message state
      _messages = [];
      _deletedMessageIds.clear();
      _typingStatus.clear();
      for (final t in _typingTimers.values) {
        t.cancel();
      }
      _typingTimers.clear();
      _cancelBoxVoiceTimers();
      _partnerRecordingVoice.clear();
      _replyingToMessage = null;
      _editingMessage = null;
      _pendingEdits.clear();
      _emittedSendTempIds.clear();
      _identityRefusedSendTempIds.clear();
      _sendTokenByTempId.clear();
      _boxTempIds.clear();
      _boxUnsentTempIds.clear();
      _boxMediaBodies.clear();
      _boxLists.reset();
      _staleViewsAnswered.clear();
      _boxDeliveredOwed.clear();
      _boxReadReported.clear();
      _boxSeenMarked.clear();
      _boxTypingSentAt.clear();
      _identityResetRebuildNotified.clear();
      _rebuildRequestedPeers.clear();
      // Fresh connect / user switch: forget which pings already fired.
      // (Reconnect deliberately KEEPS it so resync redelivery stays silent.)
      _pingEffectFiredIds.clear();
      // Local ids restart at the same base for every account: an unsaved
      // row of the previous session must never be stored into this one.
      _boxUnsaved.clear();
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
      _cancelBoxVoiceTimers();
      _partnerRecordingVoice.clear();
      _replyingToMessage = null;
      _editingMessage = null;
      _pendingEdits.clear();
      _emittedSendTempIds.clear();
      _identityRefusedSendTempIds.clear();
      // A box send's retry must reuse its wire id, or a device the failed
      // attempt reached shows the message twice.
      _sendTokenByTempId.removeWhere(
        (tempId, _) => !_boxTempIds.contains(tempId),
      );
      _boxLists.reset();
      _cancelDelayedRetryIfAny();
    }

    notifyListeners();
  }

  /// Called on socket disconnect. Cancels timers.
  void onDisconnect() {
    _cancelDelayedRetryIfAny();
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    _typingTimers.clear();
    _cancelBoxVoiceTimers();
  }

  /// Full reset — called on logout / account deletion.
  void clearAll() {
    _messages = [];
    _conversationCache.clear();
    _deletedMessageIds.clear();
    _typingStatus.clear();
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    _typingTimers.clear();
    _cancelBoxVoiceTimers();
    _partnerRecordingVoice.clear();
    _replyingToMessage = null;
    _editingMessage = null;
    _pendingEdits.clear();
    _showPingEffect = false;
    _decryptChainBySender.clear();
    _identityResetRebuildNotified.clear();
    _rebuildRequestedPeers.clear();
    _pingEffectFiredIds.clear();
    _boxUnsaved.clear();
    _emittedSendTempIds.clear();
    _identityRefusedSendTempIds.clear();
    _sendTokenByTempId.clear();
    _boxTempIds.clear();
    _boxUnsentTempIds.clear();
    // A message nobody sent must not wait on this device for the next
    // sign-in (decision 104).
    final signedOut = _currentUserId;
    if (signedOut != null) {
      _encryptionProvider?.clearBoxUnsent(signedOut).ignore();
    }
    _boxMediaBodies.clear();
    _boxLists.reset();
    _staleViewsAnswered.clear();
    _boxDeliveredOwed.clear();
    _boxReadReported.clear();
    _boxSeenMarked.clear();
    _boxTypingSentAt.clear();
    _cancelDelayedRetryIfAny();
    _dropBoxActionRetries();
    _boxPaused.clear();
    boxCatchUp.reset();
    _currentUserId = null;
    _tokenForReconnect = null;
    notifyListeners();
  }

  /// Clear messages for the active conversation (used when clearing active chat).
  void clearMessages() {
    _messages = [];
    _openConversationId = -1;
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
    _dropBoxActionRetries();
    _boxPaused.clear();
    boxCatchUp.reset();
    _incomingSound.dispose();
    countdownTickNotifier.dispose();
    _boxActionFailures.close().ignore();
    super.dispose();
  }
}
