import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../../providers/chat_reconnect_manager.dart';
import 'box_signer.dart';
import 'box_wire.dart';

/// A queue this device may read: its rid and the key that proves it.
class BoxQueueAuth {
  const BoxQueueAuth({required this.rid, required this.key});

  final Uint8List rid;
  final BoxAuthKey key;
}

/// What [BoxClient] needs from ONE socket.io connection. [BoxClient] builds a
/// fresh one for every (re)connect and never reuses a dropped one: each
/// connection has its own namespace socket id, and every signature is bound
/// to that id.
abstract interface class BoxSocket {
  /// The `/box` namespace socket's id while connected — what gets signed.
  String? get id;
  bool get connected;
  void onConnect(void Function() handler);
  void onDisconnect(void Function() handler);
  void onConnectError(void Function() handler);
  void onMsg(void Function(Object? data) handler);
  void emitWithAck(
    String event,
    Map<String, Object?> frame,
    void Function(Object? answer) ack,
  );
  void connect();

  /// Closes the connection and drops every handler; nothing fires afterwards.
  void dispose();
}

typedef BoxSocketFactory = BoxSocket Function(String url);

/// [BoxSocket] over `socket_io_client`: its OWN Manager (`enableForceNew` — a
/// shared one would multiplex `/box` and the account socket over one
/// engine.io connection, design §4.6), no `setAuth` (the box has no account on
/// its path), and NO library reconnection: a reconnect is a new instance
/// driven by [BoxClient]'s own [ChatReconnectManager].
class IoBoxSocket implements BoxSocket {
  IoBoxSocket(String url)
    : _socket = io.io(
        url,
        io.OptionBuilder()
            .setTransports(['websocket'])
            .disableAutoConnect()
            .enableForceNew()
            .disableReconnection()
            .build(),
      );

  final io.Socket _socket;

  @override
  String? get id => _socket.id;

  @override
  bool get connected => _socket.connected;

  @override
  void onConnect(void Function() handler) => _socket.onConnect((_) => handler());

  @override
  void onDisconnect(void Function() handler) =>
      _socket.onDisconnect((_) => handler());

  @override
  void onConnectError(void Function() handler) =>
      _socket.onConnectError((_) => handler());

  @override
  void onMsg(void Function(Object? data) handler) =>
      _socket.on('msg', (data) => handler(data));

  @override
  void emitWithAck(
    String event,
    Map<String, Object?> frame,
    void Function(Object? answer) ack,
  ) => _socket.emitWithAck(event, frame, ack: (Object? answer) => ack(answer));

  @override
  void connect() => _socket.connect();

  @override
  void dispose() => _socket.dispose();
}

class _Pending {
  final Completer<BoxResult<Map<String, Object?>>> completer =
      Completer<BoxResult<Map<String, Object?>>>();
  Timer? timer;
}

/// The client of the box (metadata-privacy PR1.2, G3 surface A "Plain RPC";
/// contract `docs/contracts/wire.md` "The box"). Ships DARK: nothing wires it
/// into the app until PR3.1.
///
/// Rules, each one load-bearing:
///  * Every call is one event with a socket.io ACK; the ack IS the answer
///    ([BoxOk] / [BoxRefused]). No answer is [BoxUnknown], never a refusal.
///  * NEVER emit while disconnected: socket.io would park the frame in its
///    `sendBuffer` and send it on the next connection, carrying a signature
///    bound to the dead socket id. Offline answers [BoxUnknownReason.offline]
///    with nothing emitted.
///  * socket.io never fails a pending ack when the connection closes, so this
///    client does: every call in flight answers
///    [BoxUnknownReason.disconnected] the moment the socket drops.
///  * Every connection re-signs `subscribe` for the WHOLE set over its own id,
///    in chunks of [kBoxSubscribeMax]; [BoxState.ready] only once every chunk
///    has answered. A rid refused there is gone (deleted or reaped) and is
///    reported on [lostQueues].
///  * The consumer acks every [BoxDelivery] once it is durably stored — also
///    one it cannot open, or it holds one of the 16 window slots forever.
class BoxClient {
  BoxClient({
    required String baseUrl,
    BoxSigner signer = const Ed25519BoxSigner(),
    Duration timeout = const Duration(seconds: 15),
    Duration mediaTimeout = const Duration(minutes: 2),
    BoxSocketFactory? socketFactory,
    http.Client? httpClient,
  }) : _baseUrl = baseUrl,
       _signer = signer,
       _timeout = timeout,
       _mediaTimeout = mediaTimeout,
       _socketFactory = socketFactory ?? IoBoxSocket.new,
       _http = httpClient ?? http.Client();

  final String _baseUrl;
  final BoxSigner _signer;
  final Duration _timeout;
  final Duration _mediaTimeout;
  final BoxSocketFactory _socketFactory;
  final http.Client _http;
  final ChatReconnectManager _reconnect = ChatReconnectManager(
    requiresToken: false,
  );

  final StreamController<BoxState> _states =
      StreamController<BoxState>.broadcast(sync: true);
  final StreamController<BoxDelivery> _deliveries =
      StreamController<BoxDelivery>.broadcast(sync: true);
  final StreamController<BoxRefusal> _lost =
      StreamController<BoxRefusal>.broadcast(sync: true);

  /// The resubscribe set: base64url rid → how to prove it.
  final Map<String, BoxQueueAuth> _set = <String, BoxQueueAuth>{};
  final Set<_Pending> _pending = <_Pending>{};
  BoxSocket? _socket;
  bool _wanted = false;
  BoxState _state = BoxState.offline;

  Stream<BoxState> get states => _states.stream;
  BoxState get state => _state;
  Stream<BoxDelivery> get deliveries => _deliveries.stream;
  Stream<BoxRefusal> get lostQueues => _lost.stream;

  /// The rids a reconnect re-subscribes.
  Iterable<Uint8List> get subscribed => _set.values.map((q) => q.rid);

  /// Starts (or keeps) a connection; reconnects with backoff until [close].
  void connect() {
    _wanted = true;
    _reconnect
      ..intentionalDisconnect = false
      ..resetAttempts()
      ..cancel();
    if (_socket == null) _open();
  }

  /// Drops the connection and stops reconnecting. The subscribe set is kept:
  /// the next [connect] re-subscribes it.
  void close() {
    _wanted = false;
    _reconnect
      ..intentionalDisconnect = true
      ..cancel();
    _drop();
  }

  /// [close], then releases the streams and the HTTP client.
  void dispose() {
    close();
    _http.close();
    unawaited(_states.close());
    unawaited(_deliveries.close());
    unawaited(_lost.close());
  }

  void _open() {
    final socket = _socketFactory('$_baseUrl/box');
    _socket = socket;
    _setState(BoxState.connecting);
    socket
      ..onConnect(() {
        if (identical(_socket, socket)) unawaited(_resubscribe(socket));
      })
      ..onDisconnect(() {
        if (identical(_socket, socket)) _lostConnection();
      })
      ..onConnectError(() {
        if (identical(_socket, socket)) _lostConnection();
      })
      ..onMsg((data) {
        if (identical(_socket, socket)) _onMsg(data);
      })
      ..connect();
  }

  /// Fails every call in flight and forgets the socket. Detached BEFORE
  /// disposal: disposing a connected socket fires its own `disconnect`
  /// synchronously, which must not read as a lost connection.
  void _drop() {
    final socket = _socket;
    _socket = null;
    for (final pending in _pending.toList()) {
      _settle(pending, const BoxUnknown(BoxUnknownReason.disconnected));
    }
    socket?.dispose();
    _setState(BoxState.offline);
  }

  void _lostConnection() {
    _drop();
    if (!_wanted) return;
    _reconnect.onDisconnect(() {
      if (_wanted && _socket == null) _open();
    }, (_) {});
  }

  /// A fresh connection: re-sign the whole set over its id. Any chunk that
  /// does not answer [BoxOk] drops the connection, and the reconnect backoff
  /// tries again — `ready` with a queue silently unsubscribed would lose it
  /// to the 90-day reaper.
  Future<void> _resubscribe(BoxSocket socket) async {
    final result = await _subscribeChunks(_set.values.toList());
    if (!identical(_socket, socket)) return;
    if (result is! BoxOk<List<BoxRefusal>>) {
      _lostConnection();
      return;
    }
    result.value.forEach(_lost.add);
    _reconnect.resetAttempts();
    _setState(BoxState.ready);
  }

  void _setState(BoxState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  void _onMsg(Object? data) {
    if (data is! Map) return;
    final rid = boxB64Decode(data['rid'], kBoxRidBytes);
    final id = boxB64Decode(data['id'], kBoxMsgIdBytes);
    final blob = boxB64Decode(data['blob'], kBoxBlobBytes);
    // Unreadable is unackable (no valid id): nothing to hand on.
    if (rid == null || id == null || blob == null) return;
    if (!_deliveries.isClosed) {
      _deliveries.add(BoxDelivery(rid: rid, id: id, blob: blob));
    }
  }

  void _settle(_Pending pending, BoxResult<Map<String, Object?>> result) {
    if (!_pending.remove(pending)) return;
    pending.timer?.cancel();
    pending.completer.complete(result);
  }

  /// One event, one ack. [frame] is built from the id of the socket it goes
  /// out on, at the moment it goes out.
  Future<BoxResult<Map<String, Object?>>> _call(
    String event,
    Map<String, Object?> Function(String sockId) frame,
  ) {
    final socket = _socket;
    final sockId = socket?.id;
    if (socket == null || !socket.connected || sockId == null) {
      return Future.value(const BoxUnknown(BoxUnknownReason.offline));
    }
    final pending = _Pending();
    _pending.add(pending);
    pending.timer = Timer(
      _timeout,
      () => _settle(pending, const BoxUnknown(BoxUnknownReason.timeout)),
    );
    socket.emitWithAck(
      event,
      frame(sockId),
      (answer) => _settle(pending, _readAnswer(answer)),
    );
    return pending.completer.future;
  }

  static BoxResult<Map<String, Object?>> _readAnswer(Object? answer) {
    if (answer is! Map) return const BoxUnknown(BoxUnknownReason.malformed);
    final map = Map<String, Object?>.from(answer);
    if (map['ok'] == true) return BoxOk(map);
    if (map['ok'] != false) return const BoxUnknown(BoxUnknownReason.malformed);
    final retryMs = map['retryAfterMs'];
    return BoxRefused(
      BoxCode.parse(map['code']),
      retryAfter: retryMs is int ? Duration(milliseconds: retryMs) : null,
    );
  }

  String _sig(
    BoxAuthKey key,
    BoxSignedVerb verb,
    String sockId,
    List<int> fields,
  ) => boxB64(_signer.sign(key, boxSignedMessage(verb, sockId, fields)));

  /// Creates a queue owned by [key]. Idempotent per key: a retry after a lost
  /// answer gets the same address back, so retry with the SAME key.
  Future<BoxResult<QueueAddress>> createQueue(
    QueueKind kind,
    BoxAuthKey key,
  ) async {
    final result = await _call(
      'createQueue',
      (sockId) => {
        'v': 1,
        'kind': kind.name,
        'authPub': boxB64(key.publicKey),
        'sig': _sig(
          key,
          BoxSignedVerb.createQueue,
          sockId,
          createQueueFields(kind, key.publicKey),
        ),
      },
    );
    return switch (result) {
      BoxOk(:final value) => _address(value),
      BoxRefused(:final code, :final retryAfter) => BoxRefused(
        code,
        retryAfter: retryAfter,
      ),
      BoxUnknown(:final reason) => BoxUnknown(reason),
    };
  }

  static BoxResult<QueueAddress> _address(Map<String, Object?> answer) {
    final rid = boxB64Decode(answer['rid'], kBoxRidBytes);
    final sid = boxB64Decode(answer['sid'], kBoxSidBytes);
    final nid = boxB64Decode(answer['nid'], kBoxNidBytes);
    if (rid == null || sid == null || nid == null) {
      return const BoxUnknown(BoxUnknownReason.malformed);
    }
    return BoxOk(QueueAddress(rid: rid, sid: sid, nid: nid));
  }

  /// Stores one sealed [blob] in the queue [sid] addresses. Unsigned: the sid
  /// is the bearer credential. An unknown or deleted sid ALSO answers
  /// [BoxOk] (the box has no block oracle).
  Future<BoxResult<void>> send(Uint8List sid, Uint8List blob) async {
    _requireLength(sid, kBoxSidBytes, 'sid');
    _requireLength(blob, kBoxBlobBytes, 'blob');
    final result = await _call(
      'send',
      (_) => {'v': 1, 'sid': boxB64(sid), 'blob': boxB64(blob)},
    );
    return _void(result);
  }

  /// Adds [queues] to the resubscribe set and, when connected, subscribes
  /// them now. The answer lists the rids the box refused; those are gone and
  /// leave the set. Offline, the set still keeps them for the next
  /// connection.
  Future<BoxResult<List<BoxRefusal>>> subscribe(
    Iterable<BoxQueueAuth> queues,
  ) {
    final list = queues.toList(growable: false);
    for (final q in list) {
      _requireLength(q.rid, kBoxRidBytes, 'rid');
      _set[boxB64(q.rid)] = q;
    }
    return _subscribeChunks(list);
  }

  Future<BoxResult<List<BoxRefusal>>> _subscribeChunks(
    List<BoxQueueAuth> queues,
  ) async {
    final refused = <BoxRefusal>[];
    for (var start = 0; start < queues.length; start += kBoxSubscribeMax) {
      final end = start + kBoxSubscribeMax < queues.length
          ? start + kBoxSubscribeMax
          : queues.length;
      final chunk = queues.sublist(start, end);
      final result = await _call(
        'subscribe',
        (sockId) => {
          'v': 1,
          'subs': [
            for (final q in chunk)
              {
                'rid': boxB64(q.rid),
                'sig': _sig(q.key, BoxSignedVerb.subscribe, sockId, q.rid),
              },
          ],
        },
      );
      switch (result) {
        case BoxOk(:final value):
          final entries = value['refused'];
          if (entries is! List) {
            return const BoxUnknown(BoxUnknownReason.malformed);
          }
          for (final entry in entries) {
            final rid = entry is Map
                ? boxB64Decode(entry['rid'], kBoxRidBytes)
                : null;
            if (rid == null) return const BoxUnknown(BoxUnknownReason.malformed);
            _set.remove(boxB64(rid));
            refused.add(
              BoxRefusal(rid: rid, code: BoxCode.parse((entry as Map)['code'])),
            );
          }
        case BoxRefused(:final code, :final retryAfter):
          return BoxRefused(code, retryAfter: retryAfter);
        case BoxUnknown(:final reason):
          return BoxUnknown(reason);
      }
    }
    return BoxOk(refused);
  }

  /// Drops [rid] from the resubscribe set. Local only.
  void forget(Uint8List rid) => _set.remove(boxB64(rid));

  /// Deletes delivered message [id] from [queue]. Acking a gone id is ok.
  Future<BoxResult<void>> ack(BoxQueueAuth queue, Uint8List id) async {
    _requireLength(id, kBoxMsgIdBytes, 'id');
    final result = await _call(
      'ack',
      (sockId) => {
        'v': 1,
        'rid': boxB64(queue.rid),
        'id': boxB64(id),
        'sig': _sig(
          queue.key,
          BoxSignedVerb.ack,
          sockId,
          ackFields(queue.rid, id),
        ),
      },
    );
    return _void(result);
  }

  /// Deletes [queue] with its messages and notifier, and forgets it. The box
  /// answers a repeat — a queue already gone — `auth_failed` (an `ok` there
  /// would be an existence oracle), so that answer IS success here.
  Future<BoxResult<void>> deleteQueue(BoxQueueAuth queue) async {
    final result = await _call(
      'deleteQueue',
      (sockId) => {
        'v': 1,
        'rid': boxB64(queue.rid),
        'sig': _sig(queue.key, BoxSignedVerb.deleteQueue, sockId, queue.rid),
      },
    );
    if (result case BoxOk() || BoxRefused(code: BoxCode.authFailed)) {
      forget(queue.rid);
      return const BoxOk(null);
    }
    return _void(result);
  }

  /// Notifier step 1: the box pushes a challenge code to [token] and stores
  /// nothing durable. [queue] is the queue whose [nid] this is.
  Future<BoxResult<NotifierState>> challengeNotifier(
    BoxQueueAuth queue,
    Uint8List nid,
    NotifierPlatform platform,
    String token,
  ) async {
    _requireLength(nid, kBoxNidBytes, 'nid');
    final result = await _call(
      'registerNotifier',
      (sockId) => {
        'v': 1,
        'nid': boxB64(nid),
        'platform': platform.name,
        'token': token,
        'sig': _sig(
          queue.key,
          BoxSignedVerb.registerNotifier,
          sockId,
          notifierChallengeFields(nid, platform, token),
        ),
      },
    );
    return _notifierState(result);
  }

  /// Notifier step 2: the [code] the push delivered, signed by the queue key.
  Future<BoxResult<NotifierState>> activateNotifier(
    BoxQueueAuth queue,
    Uint8List nid,
    Uint8List code,
  ) async {
    _requireLength(nid, kBoxNidBytes, 'nid');
    _requireLength(code, kBoxCodeBytes, 'code');
    final result = await _call(
      'registerNotifier',
      (sockId) => {
        'v': 1,
        'nid': boxB64(nid),
        'code': boxB64(code),
        'sig': _sig(
          queue.key,
          BoxSignedVerb.registerNotifier,
          sockId,
          notifierActivateFields(nid, code),
        ),
      },
    );
    return _notifierState(result);
  }

  static BoxResult<NotifierState> _notifierState(
    BoxResult<Map<String, Object?>> result,
  ) => switch (result) {
    BoxOk(:final value) => switch (value['state']) {
      'challenged' => const BoxOk(NotifierState.challenged),
      'active' => const BoxOk(NotifierState.active),
      _ => const BoxUnknown(BoxUnknownReason.malformed),
    },
    BoxRefused(:final code, :final retryAfter) => BoxRefused(
      code,
      retryAfter: retryAfter,
    ),
    BoxUnknown(:final reason) => BoxUnknown(reason),
  };

  static BoxResult<void> _void(BoxResult<Map<String, Object?>> result) =>
      switch (result) {
        BoxOk() => const BoxOk(null),
        BoxRefused(:final code, :final retryAfter) => BoxRefused(
          code,
          retryAfter: retryAfter,
        ),
        BoxUnknown(:final reason) => BoxUnknown(reason),
      };

  static void _requireLength(Uint8List bytes, int length, String name) {
    if (bytes.length != length) {
      throw ArgumentError.value(bytes.length, name, 'must be $length bytes');
    }
  }

  /// Uploads [body] (already encrypted and padded to a ladder rung) against
  /// the queue [sid] addresses; its daily budget pays for it. The sid rides
  /// a header, never the URL. An unknown sid still answers an id the box
  /// never stored (no dead-sid oracle).
  Future<BoxResult<BoxMediaRef>> uploadMedia(
    Uint8List sid,
    Uint8List body,
  ) async {
    _requireLength(sid, kBoxSidBytes, 'sid');
    if (!kBoxMediaLadder.contains(body.length)) {
      throw ArgumentError.value(body.length, 'body', 'not a ladder size');
    }
    final http.Response res;
    try {
      res = await _http
          .post(
            Uri.parse('$_baseUrl/box/media'),
            headers: {
              'Box-Sid': boxB64(sid),
              'Content-Type': 'application/octet-stream',
            },
            body: body,
          )
          .timeout(_mediaTimeout);
    } on TimeoutException {
      return const BoxUnknown(BoxUnknownReason.timeout);
    } on Object {
      return const BoxUnknown(BoxUnknownReason.offline);
    }
    if (res.statusCode == 201) {
      final json = _jsonMap(res.body);
      final id = boxB64Decode(json?['id'], kBoxMediaIdBytes);
      final bucket = json?['bucket'];
      final expiresAt = DateTime.tryParse('${json?['expiresAt']}');
      if (id == null || bucket is! String || expiresAt == null) {
        return const BoxUnknown(BoxUnknownReason.malformed);
      }
      return BoxOk(BoxMediaRef(id: id, bucket: bucket, expiresAt: expiresAt));
    }
    return _httpRefusal(res);
  }

  /// The stored body of media [id]; [BoxCode.notFound] once it expired (or
  /// never existed — the box does not say which).
  Future<BoxResult<Uint8List>> downloadMedia(Uint8List id) async {
    _requireLength(id, kBoxMediaIdBytes, 'id');
    final http.Response res;
    try {
      res = await _http
          .get(Uri.parse('$_baseUrl/box/media/${boxB64(id)}'))
          .timeout(_mediaTimeout);
    } on TimeoutException {
      return const BoxUnknown(BoxUnknownReason.timeout);
    } on Object {
      return const BoxUnknown(BoxUnknownReason.offline);
    }
    if (res.statusCode == 200) return BoxOk(res.bodyBytes);
    if (res.statusCode == 404) return const BoxRefused(BoxCode.notFound);
    return _httpRefusal(res);
  }

  static BoxResult<T> _httpRefusal<T>(http.Response res) {
    final json = _jsonMap(res.body);
    final retryMs = json?['retryAfterMs'];
    final retryAfter = retryMs is int ? Duration(milliseconds: retryMs) : null;
    return switch (res.statusCode) {
      413 => const BoxRefused(BoxCode.badSize),
      429 => BoxRefused(BoxCode.parse(json?['error']), retryAfter: retryAfter),
      // 5xx and anything unexpected: the upload may or may not have landed.
      _ => const BoxUnknown(BoxUnknownReason.malformed),
    };
  }

  static Map<String, Object?>? _jsonMap(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }
}
