import 'package:socket_io_client/socket_io_client.dart' as io;

class SocketService {
  io.Socket? _socket;

  io.Socket? get socket => _socket;

  /// True if the socket exists and is connected.
  bool get isConnected => _socket?.connected ?? false;

  void connect({required String baseUrl, required String token}) {
    // Defensive cleanup: ensure any previous socket is fully disposed
    // before creating a new one (prevents cache reuse)
    if (_socket != null) {
      _socket!.disconnect();
      _socket!.dispose();
      _socket = null;
    }

    // Token in auth only (not query) — avoids URL/log/Referer leakage
    _socket = io.io(
      baseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .disableAutoConnect()
          .enableForceNew()
          .build(),
    );

    _socket!.connect();
  }

  /// Register a listener for a socket event.
  void on(String event, void Function(dynamic) callback) {
    _socket?.on(event, callback);
  }

  /// Remove listener(s) for a socket event.
  void off(String event) {
    _socket?.off(event);
  }

  /// Register a callback for the 'connect' event.
  void onConnect(void Function() callback) {
    _socket?.onConnect((_) => callback());
  }

  /// Register a callback for the 'disconnect' event.
  void onDisconnect(void Function(dynamic) callback) {
    _socket?.onDisconnect(callback);
  }

  void searchUsers(String handle) {
    _socket?.emit('searchUsers', {'handle': handle});
  }

  /// Ask for a fresh server-clock observation; the server answers on
  /// `serverTime` with `{serverTime: <ISO-8601>}`.
  ///
  /// The `socketReady` observation ages out of trust after
  /// [ServerClock.maxExtrapolation]; the in-session expiry sweep calls this to
  /// re-arm the clock instead of letting expired plaintext survive until the
  /// next reconnect. Against an older backend without the handler the emit is
  /// silently ignored, the clock stays unconfirmed, and nothing is destroyed —
  /// the safe direction.
  void getServerTime() {
    _socket?.emit('getServerTime');
  }

  // ========== E2E Key Exchange ==========

  void uploadKeyBundle(Map<String, dynamic> bundle) {
    _socket?.emit('uploadKeyBundle', bundle);
  }

  void uploadOneTimePreKeys(List<Map<String, dynamic>> keys) {
    _socket?.emit('uploadOneTimePreKeys', {'keys': keys});
  }

  void fetchPreKeyBundle(int userId, {int deviceId = 1}) {
    // deviceId omitted for 1 — the server default, and an older server's DTO
    // predates the field (rollout order is server first).
    _socket?.emit('fetchPreKeyBundle', {
      'userId': userId,
      if (deviceId != 1) 'deviceId': deviceId,
    });
  }

  void requestSessionRebuild(int recipientId) {
    _socket?.emit('requestSessionRebuild', {'recipientId': recipientId});
  }

  // ========== Device list + §5.1 provisioning ceremony (Phase 2 T3) ==========

  void enrollDeviceAuthority(Map<String, dynamic> payload) {
    _socket?.emit('enrollDeviceAuthority', payload);
  }

  void openProvisioning() {
    _socket?.emit('openProvisioning', <String, dynamic>{});
  }

  void provisioningHello(Map<String, dynamic> payload) {
    _socket?.emit('provisioningHello', payload);
  }

  void provisionDevice(Map<String, dynamic> payload) {
    _socket?.emit('provisionDevice', payload);
  }

  void fetchProvisioningBlob(Map<String, dynamic> payload) {
    _socket?.emit('fetchProvisioningBlob', payload);
  }

  void provisioningComplete(Map<String, dynamic> payload) {
    _socket?.emit('provisioningComplete', payload);
  }

  void cancelProvisioning(Map<String, dynamic> payload) {
    _socket?.emit('cancelProvisioning', payload);
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }
}
