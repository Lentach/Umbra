import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../constants/app_constants.dart';
import '../services/box/box_catch_up.dart';
import '../services/box/box_client.dart';
import '../services/box/box_media_fetcher.dart';
import '../services/box/box_media_store.dart';
import '../services/box/box_push_nids.dart';
import '../services/box/box_session.dart';
import '../services/box/box_sibling_alive.dart';
import '../services/contacts/contact_backup.dart';
import '../services/contacts/contact_backup_service.dart';
import '../services/contacts/contact_record.dart';
import '../services/contacts/contact_store.dart';
import '../services/push_box_source.dart';
import '../services/push_service.dart';
import '../services/device_link/dak_store.dart';
import '../services/device_link/link_ceremony_controller.dart'
    show ProvisioningEventSink, linkPlatformLabel;
import '../services/device_list/device_authority_engine.dart';
import '../services/profile/profile_photo_cache.dart';
import '../services/profile/profile_photos.dart';
import '../services/server_clock.dart';
import '../services/socket_service.dart';
import '../utils/e2e_diag_log.dart';
import '../utils/e2e_persistent_diag.dart';
import '../utils/message_ids.dart';
import 'chat_reconnect_manager.dart';
import 'conversations_provider.dart';
import 'encryption_provider.dart';
import 'friends_provider.dart';
import 'messaging_provider.dart';

part 'connection/connection_provider.box.dart';
part 'connection/connection_provider.contacts.dart';
part 'connection/connection_provider.events.dart';
part 'connection/connection_provider.lifecycle.dart';
part 'connection/connection_provider.plaintext_sweep.dart';
part 'connection/connection_provider.reset_rebind.dart';
part 'connection/connection_provider.resume.dart';

/// ConnectionProvider — owns socket lifecycle, reconnection, and coordinates
/// all sub-providers. This is the central coordinator replacing the socket
/// management portion previously in the monolithic chat provider.
class ConnectionProvider extends ChangeNotifier {
  // ---------- Core State ----------

  final SocketService _socketService;

  ConnectionProvider({
    SocketService? socketService,
    int? coldStartConversationId,
  }) : _socketService = socketService ?? SocketService(),
       _coldStartConversationId = coldStartConversationId;
  final ChatReconnectManager _reconnectManager = ChatReconnectManager();
  late final PushService _pushService = PushService();
  bool _pushInitialized = false;

  int? _coldStartConversationId;
  DateTime? _lastConnectStartedAt;
  Timer? _debouncedConnectTimer;

  /// Bumped on every `serverTime` response — liveness signal for the resume
  /// probe (zombie-socket detection, see [ensureReconnectIfNeeded]): it is the
  /// one answer the probe itself asks for.
  int _serverResponseCounter = 0;
  Timer? _resumeProbeTimer;

  /// When the last [ensureReconnectIfNeeded] that did work ran, and the socket
  /// claim it saw: the pair that lets a second report of the same resume be
  /// dropped. [web-only: retire with §7] — only web reports one resume twice;
  /// the guard itself runs everywhere.
  DateTime? _lastResumeCheckAt;
  bool? _lastResumeCheckClaimed;

  Timer? _socketReadyWatchdog;

  Timer? _plaintextSweepTimer;
  DateTime? _serverTimeRequestedAt;

  int? _currentUserId;
  bool _isConnected = false;
  bool _intentionalDisconnect = false;
  String? _errorMessage;

  // ---------- Sub-Provider References ----------

  EncryptionProvider? _encryptionProvider;
  FriendsProvider? _friendsProvider;
  ConversationsProvider? _conversationsProvider;
  MessagingProvider? _messagingProvider;

  /// The client-owned contact list (`services/contacts/`). Opened for the
  /// account inside [connect] BEFORE the socket, so a device with no network
  /// still lists its contacts; null when the owning widget wired none.
  ContactStore? _contactStore;

  /// The server-held mirror of that store (PR2.4), owned by `AuthProvider`
  /// because only a credential door ever holds the password. Null when the
  /// owning widget wired none.
  ContactBackupService? _contactBackup;

  /// Builds the box client for a server's base URL (metadata-privacy PR3.1).
  /// Null when the owning widget wired none — then no box is ever opened.
  BoxClient Function(String baseUrl)? _boxClient;

  /// The box link of the signed-in account's session; replaced when another
  /// account connects, disposed on logout.
  BoxSession? _box;
  int? _boxUserId;

  /// That account's box attachment copies and downloads (item 3 / media
  /// wiring, decision 40): made with its session, gone with it.
  BoxMediaFetcher? _boxMedia;

  /// Whether this connect's account socket has seen `socketReady`. The box
  /// device-list refresh (decision 21) waits for it: a `getDeviceList` sent
  /// before the server finished auth is never answered.
  bool _accountReady = false;

  /// Why the contact store could not open this session, or null when it did
  /// (or none is wired). Read through [contactStoreFailed].
  String? _contactStoreUnavailable;
  String? get contactStoreUnavailableStage => _contactStoreUnavailable;

  ProvisioningEventSink? _provisioningSink;

  /// Invoked when the server reports that THIS device was revoked (spec §5.5).
  /// Set by the widget that owns both this provider and the auth session — the
  /// notice text needs a locale, and only the auth layer may end a session.
  /// [reason] is the server's rider: `'restored'` means a (lxxviii) phrase
  /// restore elsewhere signed this device out — a different sentence than a
  /// deliberate revocation.
  void Function(String? reason)? onDeviceRevoked;

  /// Invoked when a §6.2 reset teardown re-homes this account onto a NEWLY
  /// allocated device and hands back the session bound to it. Set by the
  /// widget that owns both this provider and the auth session — only the auth
  /// layer may write a session, exactly as for [onDeviceRevoked].
  ///
  /// MUST complete before the recovering device publishes any key material:
  /// see `_adoptReboundSession`.
  Future<void> Function(Map<String, dynamic> tokens)? onSessionRebound;

  /// Asked when the account socket went away before it ever turned ready: the
  /// only thing the server says to a device whose account was deleted
  /// elsewhere is to drop its next handshake silently. Set by the widget that
  /// owns the auth session, which verifies the session and, when the account
  /// is gone, ends it and wipes this device. Runs at most once per
  /// [kSessionProbeSpacing] and never twice at the same time.
  Future<void> Function()? onSessionRejected;
  DateTime? _lastSessionProbeAt;
  bool _sessionProbeRunning = false;
  static const Duration kSessionProbeSpacing = Duration(seconds: 30);
  // ---------- Public Getters ----------

  int? get currentUserId => _currentUserId;
  bool get isConnected => _isConnected;
  SocketService get socketService => _socketService;
  String? get errorMessage => _errorMessage;

  // ---------- Provider Wiring ----------

  /// Wire all sub-provider references. Called once before connect().
  void setProviders({
    required EncryptionProvider encryption,
    required FriendsProvider friends,
    required ConversationsProvider conversations,
    required MessagingProvider messaging,
    ContactStore? contactStore,
    ContactBackupService? contactBackup,
    BoxClient Function(String baseUrl)? boxClient,
  }) {
    _contactStore = contactStore;
    _contactBackup = contactBackup;
    _boxClient = boxClient;
    if (contactStore != null) contactBackup?.attach(contactStore);
    // Issue #208: an install on the link gate is not a live device; its store
    // is the view of the device it used to be.
    contactBackup?.mayPublish = () => !encryption.needsDeviceLink;
    friends.contactStore = contactStore;
    conversations.contactStore = contactStore;
    _encryptionProvider = encryption;
    _friendsProvider = friends;
    _conversationsProvider = conversations;
    _messagingProvider = messaging;
    // (lxxviii): the restore machine's post-rebind `requestSessionRebuild`
    // sweep needs the conversation peers, and a provider must not read
    // another provider directly.
    encryption
      ..onFreshDeviceLife = _startFreshDeviceLife
      ..onPreviousDeviceLife = () {
        unawaited(_retirePreviousLifeQueues());
      }
      ..sessionRebuildPeers = () {
        final uid = _currentUserId;
        if (uid == null) return const <int>[];
        final convs = _conversationsProvider?.conversations ?? const [];
        return [
          for (final c in convs)
            // A chat made over the box (decision 52): the server does not
            // know the pair, and `requestSessionRebuild` would name it.
            if (!isLocalConversationId(c.id))
              c.userOne.id == uid ? c.userTwo.id : c.userOne.id,
        ];
      }
      // A mid-session passcode re-lock revokes the content store; the contact
      // store holds a reference to it plus a plaintext copy of the graph, so
      // it forgets both in the same teardown and re-opens after the unlock
      // (without which every later write-through would silently return false).
      ..onPasscodeLockRevoke = () {
        _contactStore?.close();
      }
      ..onPasscodeLockRestore = _reopenContactStore
      // PR2.4: a phrase the user just enrolled gets a second wrap of the
      // contact-backup content key, so a device that lost its storage AND
      // its password can still open the backup. Fire-and-forget and
      // deliberately unreported: the password wrap already opens it, and a
      // refusal here must not colour the phrase ceremony's own result.
      ..onRecoveryPhraseEnrolled = (phrase) {
        unawaited(
          contactBackup?.addWrap(
                kind: ContactWrapKind.phrase,
                secret: phrase,
              ) ??
              Future<bool>.value(false),
        );
      };
  }

  Future<void>? _contactStoreRetry;

  /// True when [work] settles within [budget]; the timer is cancelled the
  /// moment it does, so a prompt open leaves no pending timer behind.
  static Future<bool> _withinBudget(Future<void> work, Duration budget) {
    final done = Completer<bool>();
    final timer = Timer(budget, () {
      if (!done.isCompleted) done.complete(false);
    });
    unawaited(
      work.whenComplete(() {
        timer.cancel();
        if (!done.isCompleted) done.complete(true);
      }),
    );
    return done.future;
  }

  /// How long [connect] waits for the contact store before connecting the
  /// socket regardless. Same order as the passcode store's 6 s read budget
  /// (`passcode-lock.md` §10b) — a Keystore first-read is not a 250 ms
  /// operation — but shorter, because here the cost of waiting is a delayed
  /// socket, not a lockout.
  static const Duration kContactStoreOpenBudget = Duration(seconds: 4);

  /// How long [connect] waits for the PR2.4 backup resolve before starting
  /// the socket — and ONLY when the local store came up empty, which is the
  /// state the backup exists to repair.
  ///
  /// Longer than [kContactStoreOpenBudget] on purpose: that budget bounds a
  /// local open, this one covers a network GET plus a PBKDF2-600k unwrap
  /// (1-2 s on a phone). Overshooting costs a few seconds of skeleton on a
  /// device that just lost everything; undershooting shows that device "no
  /// contacts", which is the outcome this whole PR exists to prevent.
  static const Duration kContactBackupRestoreBudget = Duration(seconds: 8);

  /// Issue #208: how long a new device life waits for the old life's queues
  /// to be deleted before the wipe takes their keys; what is left by then
  /// stays owed in `boxgone_v1`, which the wipe keeps. Bounded because the
  /// link ceremony waits on it.
  static const Duration kFreshLifeQueueDeleteBudget = Duration(seconds: 10);

  /// Bumped by every [connect] that gets past the cooldown; a connect that
  /// suspended on the store open compares it afterwards and yields to any
  /// newer call — SAME user included, which `_currentUserId` cannot tell.
  int _connectGeneration = 0;

  /// Registers the screen-scoped §5.1 ceremony controller as the receiver of
  /// provisioning + device-list events. ONE sink at a time by design — the
  /// ceremony surface is a single navigation stack, and routing through this
  /// provider keeps [_registerEventListeners] the only event-routing seam.
  void registerProvisioningSink(ProvisioningEventSink sink) {
    _provisioningSink = sink;
  }

  /// Unregisters [sink] if it is still the active one (a later screen may
  /// have replaced it before this dispose ran).
  void unregisterProvisioningSink(ProvisioningEventSink sink) {
    if (identical(_provisioningSink, sink)) {
      _provisioningSink = null;
    }
  }

  // ---------- Emit ----------

  /// Emit a socket event. Used by sub-providers via their emit callbacks.
  void emit(String event, dynamic data) {
    _socketService.socket?.emit(event, data);
  }

  // ---------- Connect ----------

  /// [immediate] skips the reconnect debounce. Only the §6.2 recovery rebind
  /// uses it, and it must: the debounce defers the work to a timer and returns
  /// straight away, so an awaited call would resolve BEFORE the socket carries
  /// the new device — which is precisely the window the rebind exists to close.
  /// It is rate-limited by the ceremony itself, not by this cooldown.
  Future<void> connect(
    int userId,
    String token,
    String baseUrl, {
    bool immediate = false,
  }) async {
    // clock.now() (package:clock), not DateTime.now(): fake_async patches the
    // former, so the cooldown is deterministic under test — else a test's
    // forced reconnect inside the window is deferred forever, unseen.
    final now = clock.now();
    if (!immediate && _lastConnectStartedAt != null) {
      final since = now.difference(_lastConnectStartedAt!);
      if (since < AppConstants.reconnectConnectCooldown) {
        final wait = AppConstants.reconnectConnectCooldown - since;
        _debouncedConnectTimer?.cancel();
        _debouncedConnectTimer = Timer(wait, () {
          // A JWT refresh inside the cooldown lands in the reconnect manager,
          // not in this closure: read it at fire time, but only for the same
          // account (another account's call brings its own token).
          final newest = _reconnectManager.tokenForReconnect;
          connect(
            userId,
            userId == _currentUserId && newest != null ? newest : token,
            baseUrl,
          );
        });
        return;
      }
    }
    _debouncedConnectTimer?.cancel();
    _lastConnectStartedAt = now;
    final generation = ++_connectGeneration;

    // 1. Cancel any pending reconnect timer, and the resume probe: it judges
    // the socket it was armed on, which this connect is about to replace.
    _reconnectManager.cancel();
    _resumeProbeTimer?.cancel();
    _intentionalDisconnect = false;
    _reconnectManager.tokenForReconnect = token;

    // 2. Determine if this is a reconnect (same user)
    final bool isReconnect = (_currentUserId == userId);

    _currentUserId = userId;

    // 3. If not reconnect, clear all sub-provider state
    if (!isReconnect) {
      _encryptionProvider?.clearAll();
      _friendsProvider?.clearAll();
      _conversationsProvider?.clearAll();
      _messagingProvider?.clearAll();
    }

    _accountReady = false;

    // 4. Notify sub-providers of connect lifecycle
    _encryptionProvider?.onConnect(isReconnect);
    _friendsProvider?.onConnect(isReconnect);
    _friendsProvider?.setCurrentUserId(userId);
    _conversationsProvider?.onConnect(isReconnect);
    _conversationsProvider?.setCurrentUserId(userId);
    _messagingProvider?.onConnect(isReconnect);
    _messagingProvider?.setCurrentUserId(userId);
    _messagingProvider?.setToken(token);

    // 4b. Local contacts BEFORE the socket: the lists were just cleared (a
    // fresh account) and the server's answers are seconds away at best,
    // never at worst. Waited for ONLY up to [kContactStoreOpenBudget] — the
    // open chain (Keystore read, SQLCipher open, web inventory + arm) has no
    // timeout of its own, and a store that hangs must not take the socket
    // down with it; a late open still hydrates if no server list beat it.
    // A reconnect finds the store already open and its lists populated.
    // Issue #234: a revoked install's queue delete reads the same store
    // through a store object of its own; one at a time.
    final installRetiring = _installRetiring;
    if (installRetiring != null) {
      await installRetiring;
      if (_connectGeneration != generation) return;
    }
    if (_contactStore != null) {
      if (_contactStore!.userId != userId) {
        final opened = _openContactStore(userId);
        final inTime = await _withinBudget(opened, kContactStoreOpenBudget);
        // A newer connect() ran while we waited — another account, a §6.2
        // rebind with `immediate: true`, or a plain same-user re-entry; it
        // owns the socket now, so this call must not replace it with an
        // older token.
        if (_connectGeneration != generation) return;
        if (!inTime) {
          E2ePersistentDiag.record('CONTACT_STORE_OPEN_TIMEOUT', {
            'budgetMs': kContactStoreOpenBudget.inMilliseconds,
          });
          unawaited(
            opened.then((_) {
              if (_connectGeneration != generation) return;
              _friendsProvider?.onContactsChanged();
              _conversationsProvider?.hydrateFromStore();
              _box?.storeOpened();
              _refreshBoxDeviceLists();
            }),
          );
        }
      }
    }
    _friendsProvider?.onContactsChanged();
    _conversationsProvider?.hydrateFromStore();

    // 4c. PR2.4: drain the server-held backup into the store. This runs on
    // EVERY session with an open store, not only an empty one — `_adopt`
    // latches `_pendingRestore` on every session that opens the blob, and
    // `ContactBackupService.uploadNow` refuses to publish while that latch is
    // set (it would delete rows the blob still holds). So skipping the drain
    // on a populated store froze that account's backup for the whole session:
    // every later graph change parked in `_dirty` and no PUT ever went out,
    // silently, which is the one failure this PR exists to prevent (G2 review
    // B1, 2026-09-21; the device drive missed it because every case it drove
    // was a WIPED device, i.e. the only branch that used to reach here).
    //
    // The WAIT is still spent only on an empty store: an ordinary launch
    // already has its contacts on disk, so the socket is never delayed by a
    // PBKDF2 the common path does not even run.
    //
    // `applyRestore` is upgrade-only (it writes only peers the store has no
    // record for) and this block still runs BEFORE the socket starts, so on a
    // populated store it normally writes nothing at all.
    final backup = _contactBackup;
    final store = _contactStore;
    // Re-arm the store hook on EVERY session, not just at wire-up.
    // `AuthProvider.logout` calls `ContactBackupService.clear`, which drops
    // `_store` and nulls `store.onChanged`; logging back in only calls
    // `onSession`, and `attach` is otherwise reached ONLY from `setProviders`
    // above, which runs once when the widget tree is built. So a logout ->
    // login inside one app instance left the service holding no store:
    // `uploadNow` bailed on its `store == null` guard and every mutation
    // notified nobody, freezing that account's backup until the app was
    // restarted. Same silent-freeze class as B1, on the ordinary path a user
    // takes (found on the 2026-09-22 iOS drive: a mute published, then a
    // logout, a login and an unmute published nothing).
    //
    // Deliberately OUTSIDE the `isOpen` gate below: `attach` only wires
    // `onChanged`, it never reads the store, and a store that is still
    // opening will notify through the same hook the moment it lands. Gating
    // it would re-introduce the freeze on exactly the slow open the budget
    // above already tolerates. `attach` is idempotent, so the common path
    // pays one identity comparison.
    if (backup != null && store != null) backup.attach(store);
    if (backup != null && store != null && store.isOpen) {
      if (store.all.isEmpty) {
        final inTime = await _withinBudget(
          backup.ready,
          kContactBackupRestoreBudget,
        );
        if (_connectGeneration != generation) return;
        if (!inTime) {
          E2ePersistentDiag.record('CONTACT_BACKUP_RESTORE_TIMEOUT', {
            'budgetMs': kContactBackupRestoreBudget.inMilliseconds,
          });
        }
      }
      _settleContactBackup(generation);
    }

    // 4d. The box (PR3.1): its own socket, no account on its path. One
    // session per account — a reconnect of the same account only resumes it,
    // so its published request queue and subscriptions carry over.
    final boxClient = _boxClient;
    final contacts = _contactStore;
    if (boxClient != null && contacts != null) {
      // Decision 51, E114a: a friend's verified list is kept across restarts
      // — every friend (its list was looked up by handle once), and any
      // contact this device holds a queue for, or an address of, or met over
      // the box (slice (f): no lookup may name that pair again).
      bool isFriend(int peer) =>
          contacts.byUserId(peer)?.state == ContactState.friend;
      _encryptionProvider
        ?..keepsDeviceListFor = (peer) {
          final record = contacts.byUserId(peer);
          return record != null &&
              (record.state == ContactState.friend ||
                  record.queues.isNotEmpty ||
                  record.outbound.isNotEmpty ||
                  record.boxOrigin != null);
        }
        // Decision 114, E114a: a friend's list is never asked of the server
        // by id, whoever made the friendship.
        ..listsByHandle = isFriend
        // Slice (f), decision 52: a friendship or request made over the box
        // is never named to the server by a lookup of this device.
        ..isBoxOnlyPeer = ((peer) => contacts.byUserId(peer)?.boxOrigin != null)
        ..servedBundleFor = ((peer, device) =>
            contacts.byUserId(peer)?.boxOrigin?.bundles[device]);
      if (_box == null || _boxUserId != userId) {
        _box?.dispose();
        _boxMedia?.dispose();
        // Another account's chats must not outlive it in the push worker.
        if (_box != null) unawaited(BoxPushNids.clear());
        _boxUserId = userId;
        // Started only once E2E is ready (issue #205): a device on the link
        // gate holds no identity of its own, so whatever its queues take it
        // can never show — and taking it is what empties them.
        _box = BoxSession(
          box: boxClient(baseUrl),
          store: contacts,
          emit: emit,
          // E9: box push registration on every contact queue.
          push: PushBoxSource(),
        );
        // Issue #206: no queue is subscribed before this connect's account
        // socket confirmed the session (`socketReady`); the connect gate
        // answers a device revoked while it was away `deviceRevoked`
        // instead. Released by `accountReady`, held again by `accountLost`,
        // and by every lost box connection ([_confirmSessionForBox]).
        final session = _box!
          ..holdSubscribes()
          ..confirmSessionWith(_confirmSessionForBox);
        final mediaStore = BoxMediaStore.device();
        _boxMedia = BoxMediaFetcher(
          store: mediaStore,
          download: session.downloadMedia,
        );
        // Decision 138: the profile photos read the same device copies the
        // box attachments do, and show decrypted from memory.
        ProfilePhotoCache.shared.bind(store: mediaStore, userId: userId);
        // Slice (b): every box delivery is read by the messaging provider,
        // which knows the peer only through the contact record. Slice (c):
        // it sends through the same session. Sibling queues: it encrypts
        // the address handoffs, stores what a sibling hands over and — part
        // B — tells the rotation on revoke which own devices are live.
        final messaging = _messagingProvider;
        if (messaging != null) {
          _box!.consumer = (entry) => messaging.consumeBoxEntry(
            entry,
            contacts.byUserId(entry.peerUserId),
          );
          _box!
            ..encryptForOwnDevice = messaging.encryptForOwnDevice
            ..ownLiveDevices = messaging.ownLiveDevices
            // Item 5: existing friendships move onto the box.
            ..encryptForFriend = messaging.encryptForFriend
            ..friendLiveDevices = messaging.friendLiveDevices
            // E114b: a friend's request queues come from a handle lookup.
            ..friendAddressLookup = messaging.lookupFriendAddresses
            // Slice (e): a new device's handoff carries its account's list.
            ..ownDeviceList = messaging.ownDeviceList
            ..friendRevokedDevices = messaging.friendRevokedDevices
            // Issue #208: a handoff the friend never answered takes a
            // request queue.
            ..friendAnswered = ((user, device) async =>
                await _encryptionProvider?.friendAnsweredSession(
                  user,
                  deviceId: device,
                ) ??
                false)
            ..onBoxReady = messaging.onBoxReady
            // Slice (g): one delivered receipt per drain (E61d).
            ..onReadsIdle = messaging.onBoxReadsIdle
            // Slice (f): a pending request that expired left the store.
            ..onFirstContactsChanged = () {
              _friendsProvider?.onContactsChanged();
              _conversationsProvider?.refreshChats();
            };
          messaging
            ..boxOutbox = _box
            ..boxSiblings = _box
            ..boxFriends = _box
            ..boxFirstContact = _box
            ..boxMedia = _boxMedia
            // Decision 138: the own photo and the friends'.
            ..profilePhotos = ProfilePhotos(
              store: contacts,
              outbox: session,
              media: _boxMedia!,
            )
            // Decisions 101 B / 103: siblings heard, `alive`, "Keep".
            ..boxAlive = BoxSiblingAlive(store: contacts);
          _encryptionProvider?.lookupBoxPeerList = messaging.lookupBoxPeerList;
        }
        if (_encryptionProvider?.isE2EReady == true) {
          _box!
            ..start()
            ..e2eReady();
        }
      } else {
        _box!.resume();
      }
    }

    // 5. Set up emit callbacks so sub-providers can send socket events
    _encryptionProvider?.setEmitCallback((event, data) => emit(event, data));
    _friendsProvider?.setEmitCallback((event, data) => emit(event, data));
    _messagingProvider?.setEmitCallback((event, data) => emit(event, data));
    _encryptionProvider?.onE2EReady = () {
      // The chat list's last box message and box unread per chat: no server
      // list names one. Reads the records once per session, not per connect.
      unawaited(_messagingProvider?.applyStoredBoxLastMessages());
      // The chat on screen: a launch with no network opened it before this
      // connect's initialize set the record store's user, so it read none;
      // only a resume read it again.
      unawaited(_messagingProvider?.rereadOpenChat());
      // A box delivery refused because E2E was not ready waits in the
      // journal; nothing else would offer it again before a reconnect.
      _box?.drainInbox();
      // Issue #205: the box is followed from the first E2E-ready on; a
      // device on the link gate never gets here. Sibling queues: a handoff
      // can be encrypted now.
      _box
        ?..start()
        ..e2eReady();
      // Decision 21: the device lists a box send reads are looked up here,
      // once per connect — never by a send.
      _refreshBoxDeviceLists();
    };
    // B3 (decision 143): a friend's frames held under a changed identity are
    // read again the moment the user accepts it.
    _encryptionProvider?.onHeldFramesReleased = (_) => _box?.drainInbox();
    _encryptionProvider?.onDeviceListInvalidated = (invalidated) {
      _messagingProvider?.onDeviceListInvalidated(invalidated);
      // The own list changed (a device linked or revoked): the siblings may
      // have, so the address swap asks again.
      if (invalidated == _boxUserId) {
        _box?.ownDevicesChanged();
      } else {
        // A friend's devices may have changed: its handoff runs again.
        _box?.friendDevicesChanged(invalidated);
      }
    };
    // 6. Wire cross-provider callbacks (friends -> conversations)
    // Slice (f): first contact over the box, between the friends lists,
    // the chats and the messaging side (which holds the box session).
    final messaging = _messagingProvider;
    final friends = _friendsProvider;
    if (messaging != null && friends != null) {
      friends
        ..boxSendRequest = messaging.sendBoxFriendRequest
        ..boxAcceptRequest = messaging.acceptBoxFriendRequest
        ..boxDeclineRequest = messaging.declineBoxFriendRequest
        ..boxEndFriendship = messaging.endBoxFriendship;
      messaging
        ..lookupHandle = friends.lookupHandle
        ..onBoxContactsChanged = friends.onContactsChanged
        ..onBoxFriendshipMade = friends.onBoxFriendshipMade
        ..onBoxFriendshipEnded = friends.onBoxFriendshipEnded;
      _conversationsProvider?.onLocalChatTimerChanged = (peer, seconds, at) =>
          unawaited(messaging.sendBoxChatTimer(peer, seconds, at));
    }
    _friendsProvider?.onRemoveConversationsForUser = (uid) {
      final removed = _conversationsProvider?.removeConversationsForUser(uid);
      // The permanent accepted-key-change lines go with the contact's history.
      _encryptionProvider?.forgetKeyChangeLog(peerId: uid).ignore();
      // A frame waiting calmly for a tap goes with the friendship.
      _messagingProvider?.onFriendshipEnded(uid);
      // Removing a contact must also destroy their decrypted history on this
      // device. Nothing did that before: the conversation vanished from the
      // list while every message stayed in memory and on disk, readable.
      if (removed != null && removed.isNotEmpty) {
        _messagingProvider?.onConversationsRemovedForUser(removed);
      }
    };
    // 7. Replace socket (enableForceNew). Suppress reconnect from the old socket's
    // disconnect event — otherwise WiFi/cellular handoff + connect() races schedule
    // extra connect() calls that can clear lists (non-reconnect) or use a stale JWT.
    // The old socket stayed live across the awaits above; if it dropped there
    // its handler armed a backoff timer that would tear this session down.
    _reconnectManager.cancel();
    _intentionalDisconnect = true;
    _socketService.disconnect();
    // Every lookup still waiting left on the socket just torn down, so its
    // answer can never come. Fail them now: a later lookup would otherwise
    // join a dead request instead of sending a fresh one (0.2.66: a box send
    // waited on it forever, "sending" with no error).
    _encryptionProvider?.onDisconnect();
    _provisioningSink?.onSessionLost();
    _socketService.connect(baseUrl: baseUrl, token: token);

    // 8. Register socket event listeners (routed to sub-providers)
    _registerEventListeners();

    // 9. Transport connect + socketReady (authenticated fetches only on ready)
    _socketService.onConnect(() => _onSocketTransportConnect(userId));
    _socketService.on('socketReady', (data) {
      // The freshest server clock this app ever sees. Observed BEFORE the
      // ready work so anything downstream that gates on it — above all the
      // expiry purge, which destroys the only copy of a message — runs against
      // a current observation rather than a stale one or none at all.
      ServerClock.instance.observeIso(data is Map ? data['serverTime'] : null);
      // Which device this session is (spec §5.3). The client cannot derive it
      // — the id lives in the JWT the server validated — and a fan-out send
      // needs it to address every OTHER own device for self-sync while never
      // addressing its own origin device.
      //
      // A server predating the field sends nothing, and we deliberately do NOT
      // treat that as "device 1 confirmed" (amendment (xii)): a real device 2
      // against such a server would then believe it is device 1 and hand its
      // own ciphertext to the ratchet. Unconfirmed already behaves as device 1
      // for every send, and it keeps own rows out of the decrypt pass, so the
      // silence costs nothing and the wrong claim could cost a message.
      final readyDeviceId = data is Map ? data['deviceId'] : null;
      if (readyDeviceId is int) {
        _encryptionProvider?.setOwnDeviceId(readyDeviceId);
      }
      // E2E init emits (`checkOwnKeyBundle`, `uploadKeyBundle`), and the server
      // drops every such event until its auth lookups have set the socket's
      // user — which is exactly what `socketReady` announces. Started at the
      // transport connect it could lose that race and stay down all session.
      _encryptionProvider?.initializeE2E(userId);
      _onSocketReady();
      _box?.accountReady(readyDeviceId is int ? readyDeviceId : null);
      _accountReady = true;
      _refreshBoxDeviceLists();
      // Issue #208: the retire's revocation check needs the account socket.
      if (_encryptionProvider?.previousDeviceLife == true) {
        unawaited(_retirePreviousLifeQueues());
      }
    });

    // 10. On 'disconnect': handle reconnect
    _socketService.onDisconnect((_) {
      // A socket that goes away before it ever turned ready never completed
      // the server's handshake. For an account deleted elsewhere that is all
      // the server ever says: it drops the connection without an event.
      final neverReady = !_accountReady;
      E2eDiagLog.add('SOCKET_DISCONNECT', {
        'intentional': _intentionalDisconnect,
      });
      _isConnected = false;
      _accountReady = false;
      _box?.accountLost();
      _provisioningSink?.onSessionLost();
      notifyListeners();

      if (!_intentionalDisconnect) {
        _reconnectManager.onDisconnect(_reconnectWithStoredCredentials, (msg) {
          _errorMessage = msg;
          notifyListeners();
        });
        if (neverReady) _probeRejectedSession();
      }
      _socketReadyWatchdog?.cancel();
      _socketReadyWatchdog = null;
    });
  }

  /// True while a recovery rebind is running.
  ///
  /// Re-entrancy is guarded rather than assumed: the server consumes the reset
  /// row so it cannot legitimately answer twice, but that invariant lives three
  /// layers away, and a second pass here would reconnect underneath an
  /// in-flight one. Cleared when the rebind settles — a later ceremony in the
  /// same session is a legitimate second rebind, not a duplicate.
  bool _reboundInFlight = false;

  /// When the last recovery rebind started.
  ///
  /// The latch above only stops CONCURRENT rebinds. This ack is entirely
  /// server-driven and its rebind bypasses the reconnect cooldown, so without a
  /// floor a flapping or hostile server could drive unbounded socket churn and
  /// token rewrites just by repeating the answer. It grants no new authority —
  /// that server issues the tokens anyway — but the churn is worth denying.
  DateTime? _lastReboundAt;

  /// In-flight §6.2 re-enrollment ack ((xlv) clause 1).
  ///
  /// The recovery runs at login, when no DevicesScreen is mounted and
  /// `_provisioningSink` is therefore null — so the recovery must consume its
  /// own `deviceAuthorityEnrolled` answer rather than route it to a sink that
  /// does not exist. That null sink is exactly why this re-enrollment could
  /// not simply live on the ceremony controller.
  Completer<Map<String, dynamic>>? _resetEnrollAck;

  /// Whether a §6.2 re-enrollment pass is already running ((lxxxv), closing
  /// the (lxiv) residual 8).
  ///
  /// The owed-enrollment offer rides EVERY authenticated `keyBundleUploaded`
  /// and the listener fires the pass unawaited, so two passes could overlap
  /// inside the 20 s ack window: each minted its own DAK, the second overwrote
  /// the pending slot and the [_resetEnrollAck] the first was waiting on, and
  /// then the FIRST pass's `finally` cleared the survivor's ack — so the
  /// server's answer had nowhere to land and both passes timed out, leaving the
  /// account addressable by nobody. Mirrors [_reboundInFlight]: cleared when
  /// the pass settles, because a later offer is a legitimate second attempt.
  bool _reenrollInFlight = false;

  /// The box delete of a revoked device's queues still running, if any.
  Future<void>? _boxRetiring;

  /// Issue #234's queue delete, still running, if any: [connect] waits for
  /// it before opening the store it reads.
  Future<void>? _installRetiring;

  /// Issue #208: the link adopt, a stale restore or a reset's disposal is
  /// about to wipe the account's storage on this install, which becomes a
  /// NEW device. The old life's queues are deleted first (unless the gate
  /// already did, [_retirePreviousLifeQueues]) — the store about to go holds
  /// the only keys to them; a delete the box does not confirm in time is
  /// kept in the store's `boxgone_v1` row, which the wipe keeps, and the
  /// new life's box finishes it. Then the
  /// box stops, the contact store closes, the chat lists empty and the box
  /// catch-up mark goes (it would ask a sibling for the old life's
  /// messages), so the reconnect that follows opens an empty store and
  /// hydrates it the way a fresh install does. The contact backup resolves
  /// again last: its restore was already applied to the store being wiped,
  /// and until it is re-armed no upload may replace the server's copy with
  /// an empty view. Throws when the catch-up mark stays: the wipe must not
  /// run then.
  Future<void> _startFreshDeviceLife() async {
    final userId = _currentUserId;
    _retireOwnQueues(Future.value(true), wait: kFreshLifeQueueDeleteBudget);
    await _releaseAccountState();
    if (userId != null && !await BoxCatchUp.forget(userId)) {
      throw StateError('fresh device life: catch-up mark kept');
    }
    final backup = _contactBackup;
    if (backup != null) {
      await _withinBudget(
        backup.restartForEmptiedStore(),
        kContactBackupRestoreBudget,
      );
    }
    notifyListeners();
  }

  // ---------- Dispose ----------

  @override
  void dispose() {
    _connectGeneration++;
    _debouncedConnectTimer?.cancel();
    _plaintextSweepTimer?.cancel();
    _resumeProbeTimer?.cancel();
    _socketReadyWatchdog?.cancel();
    _reconnectManager.cancel();
    _socketService.disconnect();
    _box?.dispose();
    _boxMedia?.dispose();
    super.dispose();
  }
}
