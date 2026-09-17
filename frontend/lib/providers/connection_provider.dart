import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../constants/app_constants.dart';
import '../services/api_service.dart';
import '../services/push_service.dart';
import '../services/device_link/dak_store.dart';
import '../services/device_link/link_ceremony_controller.dart'
    show EncryptionServiceLinkGateway, ProvisioningEventSink, linkPlatformLabel;
import '../services/device_list/device_authority_engine.dart';
import '../services/server_clock.dart';
import '../services/socket_service.dart';
import '../utils/e2e_diag_log.dart';
import '../utils/e2e_persistent_diag.dart';
import 'chat_reconnect_manager.dart';
import 'conversations_provider.dart';
import 'encryption_provider.dart';
import 'friends_provider.dart';
import 'messaging_provider.dart';

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
  late final ApiService _api = ApiService(baseUrl: AppConfig.baseUrl);
  late final PushService _pushService = PushService(_api);
  bool _pushInitialized = false;
  int? _coldStartConversationId;
  DateTime? _lastConnectStartedAt;
  Timer? _debouncedConnectTimer;

  /// Bumped on every conversationsList/messageHistory response — liveness
  /// signal for the resume probe (zombie-socket detection, see
  /// [ensureReconnectIfNeeded]).
  int _serverResponseCounter = 0;
  Timer? _resumeProbeTimer;

  /// A transport connect that never reaches `socketReady` is invisible: the
  /// socket stays "connected", so no `disconnect` event fires and no reconnect
  /// is ever scheduled, while every authenticated fetch is gated behind ready.
  /// Result is an authenticated-looking empty shell until the user force-quits.
  static const Duration _kSocketReadyWindow = Duration(seconds: 10);
  Timer? _socketReadyWatchdog;

  /// In-flight `getServedMessageIds` round trips, keyed by the id the server
  /// echoes back. Completing with null means "no usable answer".
  final Map<String, Completer<Set<int>?>> _servedIdRequests = {};
  int _servedIdRequestSeq = 0;
  static const Duration _servedIdRequestTimeout = Duration(seconds: 20);

  /// In-session expiry destruction cadence — see [_onPlaintextSweepTick].
  ///
  /// The socketReady sweep only covers reconnects; this timer covers the
  /// session that never reconnects. One minute is cheap (the sweep is a key
  /// scan over an in-memory prefs map) and adds at most a minute on top of the
  /// deliberate `kExpiryPurgeGrace`.
  static const Duration _plaintextSweepInterval = Duration(minutes: 1);

  /// Floor between `getServerTime` requests that never got an answer.
  ///
  /// An older backend without the handler answers NOTHING, so without a floor
  /// a stale clock would re-emit every tick forever. One unanswered request
  /// per this window is bounded waste; the reply handler resets it.
  static const Duration _serverTimeRetryFloor = Duration(minutes: 5);

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
  }) {
    _encryptionProvider = encryption;
    _friendsProvider = friends;
    _conversationsProvider = conversations;
    _messagingProvider = messaging;
    // (lxxviii): the restore machine's post-rebind `requestSessionRebuild`
    // sweep needs the conversation peers, and a provider must not read
    // another provider directly.
    encryption
      ..sessionRebuildPeers = () {
        final uid = _currentUserId;
        if (uid == null) return const <int>[];
        final convs = _conversationsProvider?.conversations ?? const [];
        return [
          for (final c in convs)
            c.userOne.id == uid ? c.userTwo.id : c.userOne.id,
        ];
      }
      // The reconcile destroys stored plaintext the server no longer serves;
      // the rows themselves belong to MessagingProvider, and a session that
      // was offline during the delete is still holding them in memory.
      ..onStoredPlaintextOrphaned = (ids) {
        _messagingProvider?.onStoredPlaintextOrphaned(ids);
      };
  }

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
    final now = DateTime.now();
    if (!immediate && _lastConnectStartedAt != null) {
      final since = now.difference(_lastConnectStartedAt!);
      if (since < AppConstants.reconnectConnectCooldown) {
        final wait = AppConstants.reconnectConnectCooldown - since;
        _debouncedConnectTimer?.cancel();
        _debouncedConnectTimer = Timer(wait, () {
          connect(userId, token, baseUrl);
        });
        return;
      }
    }
    _debouncedConnectTimer?.cancel();
    _lastConnectStartedAt = now;

    // 1. Cancel any pending reconnect timer
    _reconnectManager.cancel();
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

    // 4. Notify sub-providers of connect lifecycle
    _encryptionProvider?.onConnect(isReconnect);
    _friendsProvider?.onConnect(isReconnect);
    _friendsProvider?.setCurrentUserId(userId);
    _conversationsProvider?.onConnect(isReconnect);
    _conversationsProvider?.setCurrentUserId(userId);
    _messagingProvider?.onConnect(isReconnect);
    _messagingProvider?.setCurrentUserId(userId);
    _messagingProvider?.setToken(token);

    // 5. Set up emit callbacks so sub-providers can send socket events
    _encryptionProvider?.setEmitCallback((event, data) => emit(event, data));
    _friendsProvider?.setEmitCallback((event, data) => emit(event, data));
    _conversationsProvider?.setEmitCallback((event, data) => emit(event, data));
    _messagingProvider?.setEmitCallback((event, data) => emit(event, data));
    _encryptionProvider?.onE2EReady = () =>
        _messagingProvider?.retryDecryptActiveConversation();

    // 6. Wire cross-provider callbacks (friends -> conversations)
    _friendsProvider?.onRemoveConversationsForUser = (uid) {
      final removed = uid == -1
          ? _conversationsProvider?.removeConversationsForUser(
              -1,
              blockedIds: _friendsProvider!.blockedUsers
                  .map((u) => u.id)
                  .toSet(),
            )
          : _conversationsProvider?.removeConversationsForUser(uid);
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
    _intentionalDisconnect = true;
    _socketService.disconnect();
    _socketService.connect(baseUrl: baseUrl, token: token);

    // 8. Register socket event listeners (routed to sub-providers)
    _registerEventListeners();

    // 9. Transport connect + socketReady (authenticated fetches only on ready)
    _socketService.onConnect(() => _onSocketTransportConnect(userId, token));
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
      _onSocketReady();
    });

    // 10. On 'disconnect': handle reconnect
    _socketService.onDisconnect((_) {
      E2eDiagLog.add('SOCKET_DISCONNECT', {
        'intentional': _intentionalDisconnect,
      });
      _isConnected = false;
      notifyListeners();

      if (!_intentionalDisconnect) {
        _reconnectManager.onDisconnect(_scheduleReconnect, (msg) {
          _errorMessage = msg;
          notifyListeners();
        });
      }
      _socketReadyWatchdog?.cancel();
      _socketReadyWatchdog = null;
    });
  }

  void _scheduleReconnect() {
    final userId = _currentUserId;
    final token = _reconnectManager.tokenForReconnect;
    if (userId == null || token == null) return;
    connect(userId, token, AppConfig.baseUrl);
  }

  void _onSocketTransportConnect(int userId, String token) {
    E2eDiagLog.add('SOCKET_CONNECT', {'userId': userId});
    _intentionalDisconnect = false;
    _isConnected = true;
    notifyListeners();
    _armSocketReadyWatchdog();

    _encryptionProvider?.initializeE2E(userId);

    if (!_pushInitialized) {
      _pushInitialized = true;
      void onNavigateToConversation(int conversationId) {
        _conversationsProvider?.requestNavigateToConversationFromNotification(
          conversationId,
        );
      }

      _pushService
          .initialize(
            token,
            // applyRefreshedAccessToken keeps this current across rotations;
            // the FCM onTokenRefresh listener outlives many of them.
            currentJwtToken: () => _reconnectManager.tokenForReconnect,
            onNavigateToConversation: onNavigateToConversation,
          )
          .catchError((_) {});

      // Seed cold-start id from URL param (set once; subsequent reconnects skip it).
      _pushService.coldStartConversationId ??= _coldStartConversationId;
      _coldStartConversationId = null;

      // Drain cold-start notification deep-link (web: URL param; Android: handled by FCM path)
      final coldConvId = _pushService.coldStartConversationId;
      if (coldConvId != null) {
        _pushService.coldStartConversationId = null;
        onNavigateToConversation(coldConvId);
      }
    }
  }

  /// Arms the [_kSocketReadyWindow] guard for the connect attempt that has just
  /// completed its transport handshake. Cancelled by [_onSocketReady].
  void _armSocketReadyWatchdog() {
    _socketReadyWatchdog?.cancel();
    final armedAt = _serverResponseCounter;
    _socketReadyWatchdog = Timer(_kSocketReadyWindow, () {
      _socketReadyWatchdog = null;
      // Any server response since arming means the link works and ready was
      // merely slow — the same liveness signal the resume probe uses.
      if (_serverResponseCounter != armedAt) return;
      if (_intentionalDisconnect || !_isConnected) return;
      E2eDiagLog.add('SOCKET_READY_TIMEOUT', {
        'windowMs': _kSocketReadyWindow.inMilliseconds,
      });
      // Drop the transport instead of calling connect() directly: the resulting
      // `disconnect` event routes through ChatReconnectManager, so the retry
      // inherits its bounded backoff rather than looping every window.
      _socketService.disconnect();
    });
  }

  /// After JWT auth completes on the server (`socketReady` event).
  void _onSocketReady() {
    _socketReadyWatchdog?.cancel();
    _socketReadyWatchdog = null;
    final activeConvId = _conversationsProvider?.activeConversationId;
    E2eDiagLog.add('SOCKET_READY', {
      'activeConvId': activeConvId ?? -1,
      'socketConnected': _socketService.isConnected,
    });
    _reconnectManager.resetAttempts();

    // Local-plaintext maintenance, ordered deliberately. Runs HERE because the
    // socketReady listener has just observed the server clock, and the sweep
    // refuses to destroy anything without a fresh one.
    unawaited(_runLocalPlaintextMaintenance());
    _startPlaintextSweepTimer();
    _socketService.getConversations();
    _socketService.getFriendRequests();
    _socketService.getFriends();
    _socketService.getBlockedList();

    // Phase 0b: the ceremony countdown and its cancel button are in-memory
    // only, so every connect re-asks who is trying to replace this account's
    // keys. A session that was closed when the request landed opens straight
    // into the banner instead of a silent, un-cancellable delay.
    _encryptionProvider?.refreshOwnAccountStatus();
    // (lxviii) clause 1: a devices screen that is open across a reconnect —
    // above all its own ceremony's rebind — re-reads the list on the socket
    // that can actually answer.
    _provisioningSink?.onSessionReady();

    if (activeConvId != null) {
      _conversationsProvider?.reemitPushClientState();
      E2eDiagLog.add('ACTIVE_REASSERT', {
        'source': 'socketReady',
        'activeConvId': activeConvId,
        'socketConnected': _socketService.isConnected,
      });
      _socketService.getMessages(
        activeConvId,
        limit: AppConstants.messagePageSize,
      );
    }

    Future.delayed(AppConstants.conversationsRefreshDelay, () {
      if (_conversationsProvider?.conversations.isEmpty == true) {
        _socketService.getConversations();
      }
      if (_friendsProvider?.friends.isEmpty == true) {
        _socketService.getFriends();
      }
    });

    // Morning PWA resume: messageHistory may finish before or after E2E init;
    // re-run ordered decrypt for the open chat once the socket is authenticated.
    Future.delayed(const Duration(milliseconds: 900), () {
      _messagingProvider?.retryDecryptActiveConversation();
    });
  }

  /// Refresh the retired ids, drain the purge backlog, sweep, then reconcile
  /// what is left against the server.
  ///
  /// This runs UNAWAITED alongside the initial fetches, so it does NOT order
  /// itself against the first history pass — do not read the sequence below as
  /// that guarantee. The load that actually precedes every decrypt is the
  /// awaited one in `EncryptionProvider.initializeE2E`, which completes before
  /// the ready flag flips; decrypting requires E2E to be ready, so by then the
  /// set is populated. The call here is a cross-tab REFRESH: another
  /// same-origin engine may have retired ids since.
  ///
  /// Order within this method still matters:
  ///   1. refresh retired ids before the sweep can add more of them;
  ///   2. the backlog next, so a delete interrupted by a tab close or a refused
  ///      write finishes now instead of leaving plaintext behind for good;
  ///   3. the sweep, once the clock is known fresh;
  ///   4. reconciliation last. It is the only step that talks to the server,
  ///      and it should not ask about ids the three local rules above were
  ///      already going to destroy.
  Future<void> _runLocalPlaintextMaintenance() async {
    final encryption = _encryptionProvider;
    if (encryption == null) return;
    try {
      await encryption.loadRetiredIds();
      await encryption.drainPurgeBacklog();
      await encryption.sweepDestroyablePlaintext();
      await encryption.reconcileStoredPlaintext(_askServedMessageIds);
    } catch (_) {
      // Never let maintenance break connect. A failure means the residue
      // survives to the next socketReady, which is the safe direction.
    }
  }

  /// Arm (or re-arm) the in-session expiry sweep.
  ///
  /// Without this, [EncryptionProvider.sweepDestroyablePlaintext] runs ONLY at
  /// socketReady — a message expiring while the app stays connected would keep
  /// its plaintext on disk until the next reconnect, which for a long-lived
  /// PWA is unbounded. The timer makes expiry destruction happen within
  /// `kExpiryPurgeGrace` plus one tick, always.
  void _startPlaintextSweepTimer() {
    _plaintextSweepTimer?.cancel();
    _serverTimeRequestedAt = null;
    _plaintextSweepTimer = Timer.periodic(
      _plaintextSweepInterval,
      (_) => _onPlaintextSweepTick(),
    );
  }

  void _onPlaintextSweepTick() {
    if (!_socketService.isConnected) return;
    final encryption = _encryptionProvider;
    if (encryption == null) return;

    if (ServerClock.instance.estimatedNow == null) {
      // The socketReady observation aged past ServerClock.maxExtrapolation (or
      // never arrived). The sweep would silently no-op forever from here, so
      // ask for a fresh observation; the `serverTime` reply runs the sweep.
      // Floor-limited: an older backend never answers, and one dead request
      // per floor window is bounded waste while staying fail-closed.
      // clock.now() (package:clock), not DateTime.now(): fake_async patches
      // the former, so the retry floor is deterministic under test.
      final requestedAt = _serverTimeRequestedAt;
      final now = clock.now();
      if (requestedAt != null &&
          now.difference(requestedAt) < _serverTimeRetryFloor) {
        return;
      }
      _serverTimeRequestedAt = now;
      _socketService.getServerTime();
      return;
    }
    _sweepPlaintextNow(encryption);
  }

  /// `serverTime` reply — observe, then sweep against the fresh clock.
  ///
  /// A malformed stamp is ignored by [ServerClock.observeIso]; the clock stays
  /// unconfirmed and nothing is destroyed. The retry stamp is cleared only on
  /// a usable answer so garbage cannot silence the re-request path.
  void _onServerTime(dynamic data) {
    ServerClock.instance.observeIso(data is Map ? data['serverTime'] : null);
    if (ServerClock.instance.estimatedNow == null) return;
    _serverTimeRequestedAt = null;
    final encryption = _encryptionProvider;
    if (encryption == null) return;
    _sweepPlaintextNow(encryption);
  }

  void _sweepPlaintextNow(EncryptionProvider encryption) {
    // Fire-and-forget from a timer/socket handler; a failure means the residue
    // survives to the next tick, which is the safe direction.
    unawaited(encryption.sweepDestroyablePlaintext().catchError((Object _) {}));
  }

  /// One `getServedMessageIds` round trip.
  ///
  /// Returns null for EVERY failure mode — no socket, no reply in time, a
  /// malformed reply. Null means "no answer" and purges nothing; an empty set
  /// means "the server serves none of these" and destroys all of them. Those
  /// two must never be able to blur into each other, which is why nothing here
  /// falls back to an empty set.
  Future<Set<int>?> _askServedMessageIds(Set<int> batch) async {
    if (batch.isEmpty) return const <int>{};
    if (!_socketService.isConnected) return null;

    final requestId =
        's${++_servedIdRequestSeq}-${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<Set<int>?>();
    _servedIdRequests[requestId] = completer;
    try {
      _socketService.getServedMessageIds(requestId, batch.toList());
      return await completer.future.timeout(
        _servedIdRequestTimeout,
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    } finally {
      _servedIdRequests.remove(requestId);
    }
  }

  /// Resolve the round trip [_askServedMessageIds] is waiting on.
  ///
  /// Anything unreadable resolves to null rather than to the ids it managed to
  /// parse. A partially-parsed answer would silently mark the unparsed ids as
  /// "the server no longer has this" and destroy their plaintext.
  void _onServedMessageIds(dynamic data) {
    if (data is! Map) return;
    final requestId = data['requestId'];
    if (requestId is! String) return;
    final completer = _servedIdRequests.remove(requestId);
    if (completer == null || completer.isCompleted) return;

    final raw = data['messageIds'];
    if (raw is! List) {
      completer.complete(null);
      return;
    }
    final served = <int>{};
    for (final entry in raw) {
      if (entry is int) {
        served.add(entry);
      } else if (entry is num) {
        served.add(entry.toInt());
      } else {
        completer.complete(null);
        return;
      }
    }
    completer.complete(served);
  }

  /// Updates reconnect + messaging token after AuthProvider refreshes JWT (no socket reconnect).
  void applyRefreshedAccessToken(String newAccessToken) {
    _reconnectManager.tokenForReconnect = newAccessToken;
    _messagingProvider?.setToken(newAccessToken);
  }

  // ---------- Disconnect ----------

  void disconnect({bool isLogout = false}) {
    _intentionalDisconnect = true;
    _debouncedConnectTimer?.cancel();
    _resumeProbeTimer?.cancel();
    _socketReadyWatchdog?.cancel();
    _socketReadyWatchdog = null;
    _plaintextSweepTimer?.cancel();
    _plaintextSweepTimer = null;
    _reconnectManager.cancel();

    // Notify sub-providers
    _encryptionProvider?.onDisconnect();
    _friendsProvider?.onDisconnect();
    _conversationsProvider?.onDisconnect();
    _messagingProvider?.onDisconnect();

    // Socket cleanup
    _socketService.disconnect();
    _isConnected = false;
    _errorMessage = null;

    // Answer every in-flight reconcile round trip with "no answer" instead of
    // making it wait out its timeout. Null purges nothing, so an interrupted
    // pass simply leaves the residue for the next connect.
    for (final completer in _servedIdRequests.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _servedIdRequests.clear();

    if (isLogout) {
      _pushInitialized = false;
      _currentUserId = null;
      _reconnectManager.tokenForReconnect = null;
      _encryptionProvider?.clearAll();
      _friendsProvider?.clearAll();
      _conversationsProvider?.clearAll();
      _messagingProvider?.clearAll();
    }

    notifyListeners();
  }

  /// Ensure reconnected if needed (e.g. app resume from background).
  /// Test-only: seed identity so [ensureReconnectIfNeeded]'s guards pass
  /// without a full connect() (which arms the real connect cooldown).
  @visibleForTesting
  void setIdentityForTest(int userId, String token) {
    _currentUserId = userId;
    _reconnectManager.tokenForReconnect = token;
  }

  void ensureReconnectIfNeeded() {
    final claimsConnected = _socketService.isConnected;
    E2eDiagLog.add('RESUME_CHECK', {'socketConnected': claimsConnected});
    if (_currentUserId == null || _reconnectManager.tokenForReconnect == null) {
      return;
    }
    if (!claimsConnected) {
      connect(
        _currentUserId!,
        _reconnectManager.tokenForReconnect!,
        AppConfig.baseUrl,
      );
      return;
    }
    // Socket CLAIMS connected, but iOS suspends the transport in background
    // and socket.io only notices on ping timeout (zombie socket) — the resume
    // used to do nothing, leaving pushed messages invisible until a full
    // relaunch. Re-sync now and arm a liveness probe: if no server response
    // lands within the window, force a fresh connect (cheap; reconnect
    // preserves state by design).
    _resyncAfterResume();
  }

  static const _kResumeProbeWindow = Duration(seconds: 6);

  void _resyncAfterResume() {
    final probeStart = _serverResponseCounter;
    final activeConvId = _conversationsProvider?.activeConversationId;
    _socketService.getConversations();
    if (activeConvId != null) {
      _conversationsProvider?.reemitPushClientState();
      _socketService.getMessages(
        activeConvId,
        limit: AppConstants.messagePageSize,
      );
    }
    E2eDiagLog.add('RESUME_RESYNC', {
      'activeConvId': activeConvId ?? -1,
      'socketConnected': _socketService.isConnected,
    });

    _resumeProbeTimer?.cancel();
    _resumeProbeTimer = Timer(_kResumeProbeWindow, () {
      if (_serverResponseCounter != probeStart) return; // server replied: alive
      E2eDiagLog.add('RESUME_PROBE_TIMEOUT', {'forcedReconnect': true});
      final userId = _currentUserId;
      final token = _reconnectManager.tokenForReconnect;
      if (userId == null || token == null) return;
      connect(userId, token, AppConfig.baseUrl);
    });
  }

  // ---------- Event Routing ----------

  /// The deviceId-bound session a §6.2 recovery ack carries, or null when this
  /// is an ordinary key-bundle ack.
  ///
  /// The server includes the triple ONLY when a reset teardown re-homed the
  /// account, so `access_token` is the discriminator. A partial payload is
  /// treated as absent rather than half-adopted: persisting an access token
  /// with no refresh token would leave a session that cannot be renewed.
  Map<String, dynamic>? _reboundSessionFrom(dynamic data) {
    if (data is! Map) return null;
    if (data['success'] == false) return null;
    final access = data['access_token'];
    final refresh = data['refresh_token'];
    if (access is! String || access.isEmpty) return null;
    if (refresh is! String || refresh.isEmpty) return null;
    return {'access_token': access, 'refresh_token': refresh};
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

  /// Plausibility ceiling for a server-named replacement list version
  /// ((xlv) clause 1). A list version advances once per device mutation, so
  /// no real account comes near this; the bound exists only to deny a hostile
  /// server the "freeze the list at the integer ceiling" move.
  static const int _maxPlausibleListVersion = 1000000;

  /// Adopts the recovery session, reconnects under it, and only THEN delivers
  /// the ack — so the pre-key upload it triggers rides the new device id.
  ///
  /// The ack is delivered even when the rebind fails. Dropping it would strand
  /// the stashed pre-keys forever, which is strictly worse than publishing them
  /// to a namespace a later successful rebind can re-publish over; the failure
  /// is recorded so it is visible rather than inferred.
  Future<void> _adoptReboundSession(
    Map<String, dynamic> tokens,
    dynamic data,
  ) async {
    // clock.now() (package:clock), not DateTime.now(): fake_async patches the
    // former, so the rebind floor is deterministic under test.
    final now = clock.now();
    final since = _lastReboundAt == null
        ? null
        : now.difference(_lastReboundAt!);
    if (_reboundInFlight ||
        (since != null && since < AppConstants.reconnectConnectCooldown)) {
      _encryptionProvider?.onKeyBundleUploaded(data);
      return;
    }
    _reboundInFlight = true;
    _lastReboundAt = now;
    final userId = _currentUserId;
    var rebound = false;
    try {
      if (onSessionRebound == null) {
        // Only the auth layer may write the session, so an unwired app cannot
        // complete a recovery. Loud, because the symptom otherwise looks like
        // "recovered account has no pre-keys" three subsystems away.
        E2ePersistentDiag.record('RESET_REBIND_UNWIRED', {});
      } else {
        // (lxiv): the teardown re-homes this install's material onto the
        // freshly allocated device id — drop the old stamp BEFORE the
        // reconnect below, so the new session's confirm re-stamps instead of
        // tripping the material-device gate on the recovering device.
        await _encryptionProvider?.encryptionService.clearMaterialDeviceStamp();
        await onSessionRebound!(tokens);
        if (userId != null) {
          await connect(
            userId,
            tokens['access_token'] as String,
            AppConfig.baseUrl,
            immediate: true,
          );
          rebound = true;
        } else {
          // Adopted but NOT reconnected: the replenish this ack triggers would
          // ride whatever socket exists, which is a weaker form of the very
          // defect this path closes. Unreachable in a real recovery (the
          // ceremony completes on a connected session), so it is recorded
          // rather than handled — invisible is what would make it dangerous.
          E2ePersistentDiag.record('RESET_REBIND_NO_SESSION', {});
        }
      }
    } catch (error) {
      E2ePersistentDiag.record('RESET_REBIND_FAILED', {
        'error': error.runtimeType.toString(),
      });
    } finally {
      _reboundInFlight = false;
    }
    _encryptionProvider?.onKeyBundleUploaded(data);
    // Amendment (xlv) clause 1, and it runs on the REBOUND socket — the
    // enrollment must be attributed to the freshly allocated device id, and
    // the pre-reset socket is authenticated as a device this teardown just
    // revoked. Strictly after the ack for the same reason the ack is delivered
    // late: the one-time pre-key upload it triggers is the more urgent of the
    // two, and a re-enrollment that fails must not strand it.
    // (lxxviii): a RESTORED rebind keeps its DAK and E — the restore machine
    // re-signs the list via `updateDeviceList`; minting a replacement
    // enrollment here would discard the very authority the backup preserved.
    if (data is Map && data['restored'] == true) return;
    if (rebound && userId != null) {
      final deviceId = data is Map ? data['deviceId'] : null;
      final version = data is Map ? data['nextListVersion'] : null;
      if (deviceId is int && version is int) {
        await _reenrollAfterReset(
          userId: userId,
          deviceId: deviceId,
          version: version,
        );
      } else {
        // An older server that reissues a session without naming the version.
        // Recorded rather than guessed: minting at the wrong version is
        // refused as `stale_version`, and guessing 1 against a surviving row
        // would look like a rollback attempt.
        E2ePersistentDiag.record('RESET_REENROLL_NO_VERSION', {
          'deviceId': '$deviceId',
        });
      }
    }
  }

  /// Re-enrolls the device authority after a §6.2 recovery (amendment (xlv)
  /// clause 1).
  ///
  /// The teardown revoked every device the surviving list names and allocated
  /// an id it does NOT name, so peers hold a list that cannot address this
  /// account — and for an account that never enrolled they synthesize a
  /// device 1 that no longer exists. Neither is repairable with
  /// `updateDeviceList`: that needs the old DAK, whose private half died with
  /// the lost devices. Only a REPLACEMENT enrollment under a fresh DAK, signed
  /// by the new identity, restores addressability.
  ///
  /// Rider order is T3's, unchanged: mint → persist the DAK armed → ONLY THEN
  /// emit. A DAK that signed a list the server accepted but that this device
  /// failed to persist would be unrecoverable authority.
  Future<void> _reenrollAfterReset({
    required int userId,
    required int deviceId,
    required int version,
  }) async {
    final encryption = _encryptionProvider;
    if (encryption == null) {
      E2ePersistentDiag.record('RESET_REENROLL_UNWIRED', {});
      return;
    }
    // The server names this version, and an honest one names `stored + 1`.
    // Signing it unbounded would let a hostile one name a number near the
    // integer ceiling: every later DAK-signed mutation must strictly exceed
    // the stored version, so the account's device list would be frozen for
    // good — a state that survives the server becoming honest again. The
    // client cannot authenticate the number (the row it would check against is
    // the orphaned one), so the only honest defence is a plausibility ceiling:
    // list versions advance once per device mutation, so a real account never
    // approaches this.
    if (version < 1 || version > _maxPlausibleListVersion) {
      E2ePersistentDiag.record('RESET_REENROLL_IMPLAUSIBLE_VERSION', {
        'version': '$version',
      });
      return;
    }
    // Single-flight ((lxxxv)). Taken BEFORE the mint, not at the ack: two
    // concurrent passes each minted a DAK and armed a pending record, so even
    // the winner's promote was no longer bound to the enrollment the server
    // accepted. A duplicate offer must cost nothing — the one in flight is
    // already the attempt, and the offer rides every later upload anyway.
    if (_reenrollInFlight) {
      E2ePersistentDiag.record('RESET_REENROLL_INFLIGHT', {
        'deviceId': '$deviceId',
        'version': '$version',
      });
      return;
    }
    _reenrollInFlight = true;
    try {
      final identity = await EncryptionServiceLinkGateway(
        encryption.encryptionService,
      ).ownIdentityKeyPair();
      if (identity == null) {
        E2ePersistentDiag.record('RESET_REENROLL_NO_IDENTITY', {});
        return;
      }
      final engine = DeviceAuthorityEngine();
      final payload = engine.mintEnrollment(
        userId: userId,
        identity: identity,
        createdAtMs: clock.now().millisecondsSinceEpoch,
        platform: linkPlatformLabel(),
        deviceId: deviceId,
        version: version,
      );
      final exported = engine.exportDakForPersistence();
      // Amendment (liii). The candidate goes to a PENDING slot, never over the
      // live record. This offer cannot be authenticated by us — the enrollment
      // row we would check it against is the orphaned one, which is why the
      // server-named `version` above gets a plausibility ceiling rather than a
      // signature check — so a spurious offer must cost us nothing. Overwriting
      // in place meant one crafted event destroyed the account's real DAK
      // private half, and every later revoke/provision died on
      // `invalid_list_signature` with a 72 h reset as the only exit.
      //
      // Still ARMED before the emit, so an enrollment the server accepts can
      // never be one we failed to persist.
      final store = DakStore();
      await store.persistPendingArmed(
        DakRecord(
          userId: userId,
          dakPub: exported['dakPub']!,
          dakPriv: exported['dakPriv']!,
          createdAtMs: payload['createdAt'] as int,
        ),
      );
      final ack = Completer<Map<String, dynamic>>();
      _resetEnrollAck = ack;
      _socketService.enrollDeviceAuthority(payload);
      final answer = await ack.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => const {'success': false, 'error': 'timeout'},
      );
      if (answer['success'] == true) {
        await store.promotePending(userId: userId);
        E2ePersistentDiag.record('RESET_REENROLL_PROMOTED', {
          'deviceId': '$deviceId',
          'version': '$version',
        });
      } else {
        // Left visible rather than retried here: the account is still
        // reachable-by-nobody, and (xlv) clause 2 keeps peers failing CLOSED
        // meanwhile instead of silently addressing a device that cannot
        // receive.
        E2ePersistentDiag.record('RESET_REENROLL_REFUSED', {
          'error': '${answer['error']}',
          'deviceId': '$deviceId',
          'version': '$version',
        });
        // An EXPLICIT refusal means this candidate authorizes nothing, so drop
        // it. A timeout is ambiguous and deliberately leaves it: the live
        // record is intact either way, and the offer rides every later upload.
        if (answer['error'] != 'timeout') {
          await store.clearPending(userId: userId);
        }
      }
    } catch (error) {
      E2ePersistentDiag.record('RESET_REENROLL_FAILED', {
        'error': error.runtimeType.toString(),
      });
    } finally {
      _resetEnrollAck = null;
      _reenrollInFlight = false;
    }
  }

  void _registerEventListeners() {
    // --- Encryption events ---
    // A §6.2 recovery ack carries the device id the material now lives under
    // plus a session bound to it, and the client MUST adopt them BEFORE any
    // one-time pre-key upload (`chat-key-exchange.service.ts` says so at the
    // emit site). Delivering the ack first is what strands the pool: the
    // handler replenishes on `identityChanged`, and this socket is still
    // authenticated as the device the teardown just REVOKED — so the keys land
    // in the abandoned namespace, peers are served a bundle with no one-time
    // pre-key, and the next reconnect is refused by the §5.5 gate.
    _socketService.on('keyBundleUploaded', (data) {
      final rebind = _reboundSessionFrom(data);
      if (rebind != null) {
        unawaited(_adoptReboundSession(rebind, data));
        return;
      }
      _encryptionProvider?.onKeyBundleUploaded(data);
      // No rebind, but the server can still be telling us we owe it a
      // replacement enrollment ((xlv) clause 1): the recovery's own attempt
      // died with a dropped socket or a killed app, and the roster block that
      // started it runs only once, on the upload that consumed the ceremony.
      // The offer rides every authenticated upload until it is taken.
      // (lxxviii): same exemption as the rebind branch above — a RESTORED
      // upload preserved its DAK, and the restore machine re-signs the list
      // itself. A replacement enrollment would throw that authority away.
      if (data is Map && data['restored'] == true) return;
      final owedDeviceId = data is Map ? data['deviceId'] : null;
      final owedVersion = data is Map ? data['nextListVersion'] : null;
      final userId = _currentUserId;
      if (owedDeviceId is int && owedVersion is int && userId != null) {
        unawaited(
          _reenrollAfterReset(
            userId: userId,
            deviceId: owedDeviceId,
            version: owedVersion,
          ),
        );
      }
    });
    _socketService.on('oneTimePreKeysUploaded', (data) {
      _encryptionProvider?.onOneTimePreKeysUploaded(data);
    });
    _socketService.on('preKeyBundleResponse', (data) {
      _encryptionProvider?.onPreKeyBundleResponse(data);
    });
    _socketService.on('ownKeyBundleStatus', (data) {
      _encryptionProvider?.onOwnKeyBundleStatus(data);
    });
    _socketService.on('preKeysLow', (data) {
      _encryptionProvider?.onPreKeysLow(data);
    });
    _socketService.on('sessionRebuildNeeded', (data) {
      _encryptionProvider?.onSessionRebuildNeeded(data);
    });
    // Phase 0a takeover alarm (multi-device spec §6.0): another sign-in
    // replaced this account's key bundle / a peer's bundle was replaced.
    _socketService.on('ownIdentityReplaced', (data) {
      _encryptionProvider?.onOwnIdentityReplaced(data);
    });
    _socketService.on('peerIdentityChanged', (data) {
      _encryptionProvider?.onPeerIdentityChanged(data);
    });
    // Phase 0b reset ceremony (spec §6.2): every session of the account is
    // told, so any of them can cancel during the delay.
    _socketService.on('identityResetPending', (data) {
      _encryptionProvider?.onIdentityResetPending(data);
    });
    _socketService.on('identityResetCancelled', (data) {
      _encryptionProvider?.onIdentityResetCancelled(data);
    });
    _socketService.on('identityResetStatus', (data) {
      _encryptionProvider?.onIdentityResetStatus(data);
    });
    _socketService.on('identityResetCancelResult', (data) {
      _encryptionProvider?.onIdentityResetCancelResult(data);
    });
    _socketService.on('recoveryKeySet', (data) {
      _encryptionProvider?.onRecoveryKeySet(data);
    });
    // --- (lxxviii) phrase backup + restore ---
    _socketService.on('identityBackup', (data) {
      _encryptionProvider?.onIdentityBackup(data);
    });
    _socketService.on('registrationLockNonce', (data) {
      _encryptionProvider?.onRegistrationLockNonce(data);
    });
    _socketService.on('deviceListUpdated', (data) {
      _encryptionProvider?.onDeviceListUpdated(data);
      // (lxxx) clause 1: a device RENAME rides the same request, so the
      // ceremony controller hears the same answer. Each ignores one it has
      // nothing in flight for — the restore machine's completer is untouched.
      _provisioningSink?.onDeviceListUpdated(data);
    });

    // --- Device list + §5.1 provisioning ceremony (Phase 2 T3) ---
    // Forwarded to the screen-scoped ceremony controller (registered by
    // DevicesScreen for its lifetime). No controller = no listener work.
    _socketService.on('provisioningOpened', (data) {
      _provisioningSink?.onProvisioningOpened(data);
    });
    _socketService.on('provisioningHelloAck', (data) {
      _provisioningSink?.onProvisioningHelloAck(data);
    });
    _socketService.on('provisioningHello', (data) {
      _provisioningSink?.onProvisioningHelloRelay(data);
    });
    _socketService.on('provisionDeviceAck', (data) {
      _provisioningSink?.onProvisionDeviceAck(data);
    });
    _socketService.on('provisioningBlob', (data) {
      _provisioningSink?.onProvisioningBlob(data);
    });
    _socketService.on('provisioningCompleted', (data) {
      _provisioningSink?.onProvisioningCompleted(data);
    });
    _socketService.on('provisioningCancelled', (data) {
      _provisioningSink?.onProvisioningCancelled(data);
    });
    _socketService.on('deviceAuthorityEnrolled', (data) {
      // A recovery re-enrollment ((xlv) clause 1) owns its own answer: it runs
      // with no screen mounted, so there is no sink to route to. The two
      // cannot overlap — one needs DevicesScreen open, the other runs at
      // login — and the waiter is cleared as soon as it settles.
      final waiter = _resetEnrollAck;
      if (waiter != null && !waiter.isCompleted) {
        _resetEnrollAck = null;
        waiter.complete(
          data is Map
              ? data.cast<String, dynamic>()
              : const <String, dynamic>{'success': false, 'error': 'malformed'},
        );
        return;
      }
      _provisioningSink?.onDeviceAuthorityEnrolled(data);
    });
    _socketService.on('deviceList', (data) {
      _provisioningSink?.onDeviceList(data);
      // T4 C2: the send path's verified-list cache consumes the same answer;
      // each consumer keys on its own pending state, so double routing is
      // harmless.
      _encryptionProvider?.onDeviceList(data);
    });
    _socketService.on('deviceListChanged', (data) {
      _provisioningSink?.onDeviceListChanged(data);
      _encryptionProvider?.onDeviceListChanged(data);
    });
    _socketService.on('deviceRevocationCompleted', (data) {
      _provisioningSink?.onDeviceRevocationCompleted(data);
    });
    // THIS device was revoked (spec §5.5 + amendment (xxvi)). The server tells
    // us, then drops the socket; a later reconnect attempt is refused with the
    // same event before the socket closes, so this is the only place the app
    // ever learns WHY instead of showing the generic connection-lost banner.
    _socketService.on('deviceRevoked', (data) {
      _onOwnDeviceRevoked(data);
    });
    // --- Friend events ---
    _socketService.on('friendRequestsList', (data) {
      _friendsProvider?.onFriendRequestsList(data);
    });
    _socketService.on('sentRequestsList', (data) {
      _friendsProvider?.onSentRequestsList(data);
    });
    _socketService.on('newFriendRequest', (data) {
      _friendsProvider?.onNewFriendRequest(data);
    });
    _socketService.on('friendRequestSent', (data) {
      _friendsProvider?.onFriendRequestSent(data);
    });
    _socketService.on('friendRequestAccepted', (data) {
      _friendsProvider?.onFriendRequestAccepted(data);
    });
    _socketService.on('friendRequestFailed', (data) {
      _friendsProvider?.onFriendRequestFailed(data);
    });
    _socketService.on('friendRequestRejected', (data) {
      _friendsProvider?.onFriendRequestRejected(data);
    });
    _socketService.on('invitationChatReady', (data) {
      _friendsProvider?.onInvitationChatReady(data);
    });
    _socketService.on('pendingRequestsCount', (data) {
      _friendsProvider?.onPendingRequestsCount(data);
    });
    _socketService.on('friendsList', (data) {
      _friendsProvider?.onFriendsList(data);
    });
    _socketService.on('searchUsersResult', (data) {
      _friendsProvider?.onSearchUsersResult(data);
    });
    _socketService.on('unfriended', (data) {
      _friendsProvider?.onUnfriended(data);
    });
    _socketService.on('blockedList', (data) {
      _friendsProvider?.onBlockedList(data);
    });
    _socketService.on('youWereBlocked', (data) {
      _friendsProvider?.onYouWereBlocked(data);
    });

    // --- Conversation events ---
    _socketService.on('conversationsList', (data) {
      _serverResponseCounter++;
      _conversationsProvider?.onConversationsList(data);
    });
    _socketService.on('openConversation', (data) {
      _conversationsProvider?.onOpenConversation(data);
    });
    _socketService.on('conversationDeleted', (data) {
      _conversationsProvider?.onConversationDeleted(data);
      // Also clear messages from MessagingProvider
      final convId = (data as Map<String, dynamic>)['conversationId'] as int;
      _messagingProvider?.onConversationDeleted(convId);
    });
    _socketService.on('disappearingTimerUpdated', (data) {
      _conversationsProvider?.onDisappearingTimerUpdated(data);
    });
    // The throttle refusal for the same request (spec §12 (xxxvii) class):
    // without this the refused device keeps showing a timer the server never
    // accepted.
    _socketService.on('disappearingTimerFailed', (data) {
      _conversationsProvider?.onDisappearingTimerFailed(data);
    });
    _socketService.on('conversationMuteUpdated', (data) {
      _conversationsProvider?.onConversationMuteUpdated(data);
    });
    _socketService.on('messagePinned', (data) {
      final m = data as Map<String, dynamic>;
      final pinnedId = m['pinnedMessageId'] as int?;
      final local = pinnedId != null
          ? _messagingProvider?.messageById(pinnedId)
          : null;
      _conversationsProvider?.onMessagePinned(data, localPinnedMessage: local);
    });
    _socketService.on('messageUnpinned', (data) {
      _conversationsProvider?.onMessageUnpinned(data);
    });
    // A refused pin (today: rate limited). The optimistic pin overwrote this
    // device's pin state and nothing else will correct it until the next
    // conversations snapshot, so the provider restores what it overwrote
    // (spec §12 (xxxvii)).
    _socketService.on('messagePinFailed', (data) {
      _conversationsProvider?.onPinMessageFailed(data);
    });
    _socketService.on('chatHistoryCleared', (data) {
      _messagingProvider?.onChatHistoryCleared(data);
    });

    // --- Message events ---
    _socketService.on('newMessage', (data) {
      _messagingProvider?.onNewMessage(data);
    });
    _socketService.on('messageSent', (data) {
      _messagingProvider?.onMessageSent(data);
    });
    // A refused send: the device list this client used is stale, or it sent the
    // legacy shape to a party that now has devices (spec §12 (vi)/(x)). The
    // provider verifies the delivered lists itself — the server's word is never
    // enough — and resends.
    _socketService.on('deviceListStale', (data) {
      _messagingProvider?.onDeviceListStale(data);
    });
    _socketService.on('messageHistory', (data) {
      _serverResponseCounter++;
      _messagingProvider?.onMessageHistory(data);
    });
    _socketService.on('messageDelivered', (data) {
      _messagingProvider?.onMessageDelivered(data);
    });
    _socketService.on('messageDeleted', (data) {
      _messagingProvider?.onMessageDeleted(data);
    });
    _socketService.on('messageEdited', (data) {
      _messagingProvider?.onMessageEdited(data);
    });
    _socketService.on('editMessageFailed', (data) {
      _messagingProvider?.onEditMessageFailed(data);
    });
    // `reactionUpdated` is the chip state; the two key events are the mailbox
    // that makes those chips readable (docs/design/reaction-privacy.md).
    // MessagingProvider holds the pending round trips because it issues them.
    _socketService
      ..on('reactionUpdated', (data) {
        _messagingProvider?.onReactionUpdated(data);
      })
      ..on('reactionKeyUploaded', (data) {
        _messagingProvider?.onReactionKeyUploaded(data);
      })
      ..on('reactionKeyResponse', (data) {
        _messagingProvider?.onReactionKeyResponse(data);
      });
    _socketService.on('linkPreviewReady', (data) {
      _messagingProvider?.onLinkPreviewReady(data);
    });
    _socketService.on('partnerTyping', (data) {
      _messagingProvider?.onPartnerTyping(data);
    });
    _socketService.on('partnerRecordingVoice', (data) {
      _messagingProvider?.onPartnerRecordingVoice(data);
    });
    _socketService.on('servedMessageIds', _onServedMessageIds);
    _socketService.on('serverTime', _onServerTime);

    // --- Error event ---
    _socketService.on('error', (err) {
      final String msg = err is Map<String, dynamic> && err['message'] != null
          ? err['message'] as String
          : err.toString();
      _errorMessage = msg;
      _messagingProvider?.markSendingMessagesFailed(msg);
      notifyListeners();
    });
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
    notifyListeners();
    onDeviceRevoked?.call(reason);
  }

  // ---------- Dispose ----------

  @override
  void dispose() {
    _debouncedConnectTimer?.cancel();
    _plaintextSweepTimer?.cancel();
    _resumeProbeTimer?.cancel();
    _socketReadyWatchdog?.cancel();
    _reconnectManager.cancel();
    _socketService.disconnect();
    super.dispose();
  }
}
