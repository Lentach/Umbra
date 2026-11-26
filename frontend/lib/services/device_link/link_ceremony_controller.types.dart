part of 'link_ceremony_controller.dart';

// The ceremony's public vocabulary: the event sink, the identity gateway and
// the step enums.

/// This device's self-reported platform label for the signed list entry
/// (spec §12 item (i) — informational metadata, ≤32 chars, never a name).
///
/// Lives here rather than on a screen because the §6.2 recovery
/// re-enrollment ((xlv) clause 1) runs from ConnectionProvider, at login,
/// with no screen mounted — and a provider must not import one.
String linkPlatformLabel() {
  if (kIsWeb) return 'web';
  return defaultTargetPlatform.name.toLowerCase();
}

/// Server events ConnectionProvider forwards to the registered ceremony
/// controller. One interface so the provider stays a dumb router.
abstract class ProvisioningEventSink {
  void onProvisioningOpened(dynamic data);
  void onProvisioningHelloAck(dynamic data);
  void onProvisioningHelloRelay(dynamic data);
  void onProvisionDeviceAck(dynamic data);
  void onProvisioningBlob(dynamic data);
  void onProvisioningCompleted(dynamic data);
  void onProvisioningCancelled(dynamic data);
  void onDeviceAuthorityEnrolled(dynamic data);
  void onDeviceList(dynamic data);
  void onDeviceListChanged(dynamic data);
  void onDeviceRevocationCompleted(dynamic data);

  /// Answer to `updateDeviceList` — the event a device RENAME rides
  /// ((lxxx) clause 1 reuses the existing mutating request rather than
  /// growing a wire). The restore machine in EncryptionProvider awaits the
  /// same event through its own completer; both hear every answer, and each
  /// ignores one it has nothing in flight for.
  void onDeviceListUpdated(dynamic data);

  /// The session's socket just became authenticated (`socketReady`). The
  /// only moment an emit is guaranteed to reach the CURRENT socket — a
  /// rebind's reconnect returns before its transport exists, and an
  /// account-room broadcast that landed between sockets is gone.
  void onSessionReady();

  /// The session's socket dropped or was replaced: an emit still waiting
  /// for its answer may never get one.
  void onSessionLost();
}

/// The narrow identity surface the ceremony needs. Production wraps
/// [EncryptionService]; tests fake it.
abstract class LinkIdentityGateway {
  /// base64 of the own serialized identity public key, or null when this
  /// device holds no identity.
  Future<String?> ownIdentityPublicKeyBase64();

  /// The full identity pair (primary side, blob building). READ ONLY.
  Future<dynamic> ownIdentityKeyPair();

  /// [disposeStaleMaterial] is the (lxv) authorization: wipe an existing
  /// (lxiv)-mismatched identity before adopting. Only the ceremony passes it.
  Future<void> adoptProvisionedIdentity({
    required int userId,
    required String ikPubBase64,
    required String ikPrivBase64,
    required String dakPubBase64,
    bool disposeStaleMaterial = false,
  });

  Future<void> discardProvisionedIdentity(int userId);

  /// The ceremony's server commit landed: the adopted identity is this
  /// install's own and no abort or restart may discard it any more.
  Future<void> settleProvisionedIdentity(int userId);
}

/// Production gateway over the app's one EncryptionService instance.
class EncryptionServiceLinkGateway implements LinkIdentityGateway {
  EncryptionServiceLinkGateway(this._service, {this.beforeWipe});

  final EncryptionService _service;

  /// Issue #208: runs inside the adopt once the blob has parsed, right
  /// before it wipes this install's account namespace —
  /// `EncryptionProvider.prepareFreshDeviceLife` stops the old life's box,
  /// deletes its queues and closes the contact store.
  final Future<void> Function()? beforeWipe;

  @override
  Future<String?> ownIdentityPublicKeyBase64() =>
      _service.currentIdentityPublicKeyBase64();

  @override
  Future<dynamic> ownIdentityKeyPair() => _service.identityKeyPairForLinking();

  @override
  Future<void> adoptProvisionedIdentity({
    required int userId,
    required String ikPubBase64,
    required String ikPrivBase64,
    required String dakPubBase64,
    bool disposeStaleMaterial = false,
  }) => _service.adoptProvisionedIdentity(
    userId: userId,
    ikPubBase64: ikPubBase64,
    ikPrivBase64: ikPrivBase64,
    dakPubBase64: dakPubBase64,
    disposeStaleMaterial: disposeStaleMaterial,
    beforeWipe: beforeWipe,
  );

  @override
  Future<void> discardProvisionedIdentity(int userId) =>
      _service.discardProvisionedIdentity(userId);

  @override
  Future<void> settleProvisionedIdentity(int userId) =>
      _service.settleProvisionedIdentity(userId);
}

/// Where the devices surface stands for THIS device/account.
enum DeviceListState { loading, notEnrolled, enrolled, chainInvalid }

/// Primary-flow steps, in ceremony order. `opening`/`showCode` belong to the
/// FLIPPED flow (amendment (lxxvii): the primary opens with role 'primary'
/// and displays a `p` code); the classic paste flow enters at
/// [awaitingHelloAck].
enum PrimaryLinkStep {
  idle,
  opening,
  showCode,
  awaitingHelloAck,
  showSas,
  staging,
  waitingForDevice,
  done,
  failed,
}

/// New-device-flow steps, in ceremony order. `awaitingHelloAck` belongs to
/// the FLIPPED flow (this device scanned the primary's `p` code and said
/// hello); the classic flow goes opening → showCode.
enum NewDeviceLinkStep {
  idle,
  opening,
  showCode,
  awaitingHelloAck,
  showSas,
  completing,
  rebinding,
  done,
  aborted,
}
