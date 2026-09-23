import 'dart:math';
import 'dart:typed_data';

import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/encryption/content_sealer.dart';
import 'package:pointycastle/export.dart' as pc;

/// One emitted box command, with the ack the client is waiting on.
class EmittedFrame {
  EmittedFrame(this.event, this.frame, this._ack);

  final String event;
  final Map<String, Object?> frame;
  final void Function(Object? answer) _ack;

  void answer(Object? value) => _ack(value);
}

/// A [BoxSocket] the test drives by hand: the "server" connects it, drops
/// it, pushes `msg`, and answers each emitted command.
class FakeBoxSocket implements BoxSocket {
  FakeBoxSocket(this.url, this._owner);

  final String url;
  final FakeBoxSockets _owner;
  final List<EmittedFrame> emitted = [];

  String? _id;
  bool _connected = false;
  bool connectCalled = false;
  bool disposed = false;
  void Function()? _onConnect;
  void Function()? _onDisconnect;
  void Function()? _onConnectError;
  void Function(Object?)? _onMsg;

  @override
  String? get id => _id;

  @override
  bool get connected => _connected;

  @override
  void onConnect(void Function() handler) => _onConnect = handler;

  @override
  void onDisconnect(void Function() handler) => _onDisconnect = handler;

  @override
  void onConnectError(void Function() handler) => _onConnectError = handler;

  @override
  void onMsg(void Function(Object? data) handler) => _onMsg = handler;

  @override
  void emitWithAck(
    String event,
    Map<String, Object?> frame,
    void Function(Object? answer) ack,
  ) {
    if (disposed || !_connected) {
      throw StateError('emit on a socket that is not connected');
    }
    final emittedFrame = EmittedFrame(event, frame, ack);
    emitted.add(emittedFrame);
    final auto = _owner.respond?.call(this, emittedFrame);
    if (auto != null) emittedFrame.answer(auto);
  }

  @override
  void connect() => connectCalled = true;

  @override
  void dispose() {
    disposed = true;
    _connected = false;
    _id = null;
    _onConnect = _onDisconnect = _onConnectError = null;
    _onMsg = null;
  }

  // --- the server's side ---

  void serverConnect(String sockId) {
    _id = sockId;
    _connected = true;
    _onConnect?.call();
  }

  void serverDrop() {
    _connected = false;
    _id = null;
    _onDisconnect?.call();
  }

  void refuseConnection() => _onConnectError?.call();

  void push(Object? msg) => _onMsg?.call(msg);
}

/// The [BoxSocketFactory]: records every socket the client builds.
class FakeBoxSockets {
  final List<FakeBoxSocket> sockets = [];

  /// When set, answers each emitted frame immediately (null = leave it
  /// pending for the test to answer by hand).
  Object? Function(FakeBoxSocket socket, EmittedFrame frame)? respond;

  BoxSocket call(String url) {
    final socket = FakeBoxSocket(url, this);
    sockets.add(socket);
    return socket;
  }

  FakeBoxSocket get last => sockets.last;
}

/// Real AES-256-GCM (pointycastle) behind the [ContentSealer] seam, in the
/// production envelope `IV(12) ‖ ciphertext ‖ tag(16)`. webcrypto's native
/// library cannot load under `flutter test` on the dev box (no MSVC), and a
/// byte-shuffling fake could not prove that tampering is refused.
class PointyGcmSealer implements ContentSealer {
  final Random _random = Random.secure();

  pc.GCMBlockCipher _gcm(bool encrypt, Uint8List key, Uint8List iv) =>
      pc.GCMBlockCipher(pc.AESEngine())..init(
        encrypt,
        pc.AEADParameters(pc.KeyParameter(key), 128, iv, Uint8List(0)),
      );

  @override
  Future<Uint8List?> seal(Uint8List key, Uint8List plaintext) async {
    final iv = Uint8List.fromList(List.generate(12, (_) => _random.nextInt(256)));
    final ct = _gcm(true, key, iv).process(plaintext);
    return Uint8List.fromList([...iv, ...ct]);
  }

  @override
  Future<Uint8List?> unseal(Uint8List key, Uint8List sealed) async {
    if (sealed.length < 28) return null;
    try {
      return _gcm(
        false,
        key,
        Uint8List.sublistView(sealed, 0, 12),
      ).process(Uint8List.sublistView(sealed, 12));
    } on Object {
      return null;
    }
  }
}
