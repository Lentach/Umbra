// Amendment (lxviii) clauses 1 and 2 — what the devices screen knows after
// a ceremony, and who gets offered the primary flow.
//
// Live QA 2026-09-02: after a device-side ceremony reported "linked and
// ready", the devices screen beneath it still showed the pre-ceremony
// chain-unverifiable line and the keyless CTA; only a re-entry showed the
// verified list. `refreshDeviceList()` ran only in the screen's initState, and
// the account-room `deviceListChanged` broadcast landed while the install was
// between sockets. Separately, every enrolled install was offered "link a
// device" — including linked ones, which hold no DAK and fail closed with
// `linkNoDak` only after the user has typed a code.
//
// Falsification contract: removing the post-rebind `refreshDeviceList()` turns
// the first test RED (no second `getDeviceList`); removing `_resolveDakPresence`
// leaves `holdsDak` null and turns the other two RED.

import 'package:fireplace/services/device_link/dak_store.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

class _NoIdentity implements LinkIdentityGateway {
  @override
  Future<String?> ownIdentityPublicKeyBase64() async => null;

  @override
  Future<dynamic> ownIdentityKeyPair() async =>
      throw StateError('not used here');

  @override
  Future<void> adoptProvisionedIdentity({
    required int userId,
    required String ikPubBase64,
    required String ikPrivBase64,
    required String dakPubBase64,
    bool disposeStaleMaterial = false,
  }) async {}

  @override
  Future<void> discardProvisionedIdentity(int userId) async {}
}

class _StubDakStore extends DakStore {
  _StubDakStore(this._record);

  final DakRecord? _record;

  @override
  Future<DakRecord?> read({required int userId}) async => _record;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userId = 42;
  late List<(String, dynamic)> emitted;

  LinkCeremonyController build({DakRecord? dak}) => LinkCeremonyController(
    userId: userId,
    emit: (event, data) => emitted.add((event, data)),
    identity: _NoIdentity(),
    adoptSession: (_) async {},
    reconnect: (_) async {},
    dakStore: _StubDakStore(dak),
  );

  int listRequests() => emitted.where((e) => e.$1 == 'getDeviceList').length;

  setUp(() => emitted = []);

  test('the rebind itself does NOT emit into the socket gap', () async {
    final controller = build();
    addTearDown(controller.dispose);
    controller.refreshDeviceList(); // the screen's initState
    expect(listRequests(), 1);

    // The blob was adopted and `provisioningComplete` was sent; the server
    // answers with the device-bound session. `reconnect` returns before the
    // new transport exists (that is what ConnectionProvider.connect does), so
    // an emit here would be lost — observed live as the screen keeping the
    // pre-ceremony list version.
    controller.newDeviceStep = NewDeviceLinkStep.completing;
    controller.onProvisioningCompleted({
      'success': true,
      'access_token': 'bound-access',
      'refresh_token': 'bound-refresh',
    });
    await pumpEventQueue();

    expect(controller.newDeviceStep, NewDeviceLinkStep.done);
    expect(listRequests(), 1, reason: 'nothing may be emitted between sockets');
  });

  test('a failed rebind aborts with rebind_failed and emits nothing', () async {
    // The adopt succeeded and the server committed the device, but session
    // adoption failed afterwards: the identity is real, so the controller
    // surfaces the failure instead of discarding it.
    final controller = LinkCeremonyController(
      userId: userId,
      emit: (event, data) => emitted.add((event, data)),
      identity: _NoIdentity(),
      adoptSession: (_) async => throw StateError('storage down'),
      reconnect: (_) async {},
      dakStore: _StubDakStore(null),
    );
    addTearDown(controller.dispose);
    controller.newDeviceStep = NewDeviceLinkStep.completing;
    controller.onProvisioningCompleted({
      'success': true,
      'access_token': 'bound-access',
      'refresh_token': 'bound-refresh',
    });
    await pumpEventQueue();

    expect(controller.newDeviceStep, NewDeviceLinkStep.aborted);
    expect(controller.newDeviceError, 'rebind_failed');
    expect(listRequests(), 0);
  });

  test('session readiness re-requests the device list', () async {
    final controller = build();
    addTearDown(controller.dispose);
    controller.refreshDeviceList(); // the screen's initState
    expect(listRequests(), 1);

    // The rebound socket authenticates: the ONE moment an emit is guaranteed
    // to reach the current socket. ConnectionProvider calls this from its
    // socketReady handler.
    controller.onSessionReady();

    expect(
      listRequests(),
      2,
      reason:
          'the screen beneath the ceremony still holds the pre-ceremony '
          'answer; only a request on the rebound socket can replace it',
    );
  });

  test('a refresh resolves DAK presence: the primary holds it', () async {
    // A real DAK: `_readDak` restores it into the engine, so garbage bytes
    // would read as "absent" — which is the correct answer for garbage.
    final armed = DeviceAuthorityEngine()
      ..mintEnrollment(
        userId: userId,
        identity: generateIdentityKeyPair(),
        createdAtMs: 1755600000000,
      );
    final stored = armed.exportDakForPersistence();
    final controller = build(
      dak: DakRecord(
        userId: userId,
        dakPub: stored['dakPub']!,
        dakPriv: stored['dakPriv']!,
        createdAtMs: 1755600000000,
      ),
    );
    addTearDown(controller.dispose);
    expect(controller.holdsDak, isNull, reason: 'unknown until resolved');

    controller.refreshDeviceList();
    await pumpEventQueue();

    expect(controller.holdsDak, isTrue);
  });

  test('a refresh resolves DAK presence: a linked device does not', () async {
    final controller = build();
    addTearDown(controller.dispose);

    var notified = 0;
    controller.addListener(() => notified++);
    controller.refreshDeviceList();
    await pumpEventQueue();

    expect(controller.holdsDak, isFalse);
    expect(notified, 1, reason: 'the screen must learn the answer');

    // Idempotent: a second refresh with the same answer does not churn.
    controller.refreshDeviceList();
    await pumpEventQueue();
    expect(notified, 1);
  });

  // Issue #208: the link gate mounts before the socket is authenticated.
  group('the new-device open', () {
    int opens() => emitted.where((e) => e.$1 == 'openProvisioning').length;
    const first = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    const second = 'bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee';

    // Mutation: drop the re-send from `onSessionReady`.
    test('sent before the session was ready is asked again at socketReady',
        () async {
      final controller = build();
      addTearDown(controller.dispose);
      await controller.startNewDeviceFlow(platform: 'web');
      controller.onSessionReady();
      expect(opens(), 2, reason: 'the first open reached no handler');
    });

    // Mutation: re-send for every flow still `opening`.
    test('sent on a ready session is never sent twice', () async {
      final controller = build();
      addTearDown(controller.dispose);
      controller.onSessionReady();
      await controller.startNewDeviceFlow(platform: 'web');
      controller.onSessionReady(); // a reconnect while the answer is in flight
      expect(opens(), 1, reason: 'every open allocates a device id');
    });

    // Mutation: drop the owed open from `onSessionLost`.
    test('unanswered when the socket dropped is asked again at the next '
        'socketReady', () async {
      final controller = build();
      addTearDown(controller.dispose);
      controller.onSessionReady();
      await controller.startNewDeviceFlow(platform: 'web');
      controller
        ..onSessionLost()
        ..onSessionReady();
      expect(opens(), 2, reason: 'the answer left with the old socket');
    });

    test('answered before the socket dropped is not asked again', () async {
      final controller = build();
      addTearDown(controller.dispose);
      controller.onSessionReady();
      await controller.startNewDeviceFlow(platform: 'web');
      controller
        ..onProvisioningOpened({'success': true, 'provisioningId': first})
        ..onSessionLost()
        ..onSessionReady();
      expect(opens(), 1);
      expect(controller.oobCode, contains(first));
    });

    // Mutation: drop the cancel of an extra stage.
    test('answered twice keeps the first stage and cancels the second',
        () async {
      final controller = build();
      addTearDown(controller.dispose);
      await controller.startNewDeviceFlow(platform: 'web');
      controller
        ..onSessionReady()
        ..onProvisioningOpened({'success': true, 'provisioningId': first})
        ..onProvisioningOpened({'success': true, 'provisioningId': second});

      expect(controller.oobCode, contains(first));
      expect(
        emitted.where((e) => e.$1 == 'cancelProvisioning').map((e) => e.$2),
        [
          {'provisioningId': second},
        ],
      );
    });
  });
}
