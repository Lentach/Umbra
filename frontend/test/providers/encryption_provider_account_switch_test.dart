// EncryptionProvider is one object per process, reused across logins. State
// and unfinished work of the account that just signed out must never reach
// the account that signs in next.
//
// REAL EncryptionService and EncryptionProvider over mock storage.

import 'dart:async';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A service whose `initialize` can be held per account, and whose uploadable
/// bundle names the account it was last loaded for. Mirrors the real service
/// where the provider depends on it: `initialize` loads one account, the
/// reset disposal runs `beforeWipe` and answers false when it throws.
class _ScriptedService extends EncryptionService {
  final initialized = <int>[];
  final holdInit = <int, Completer<void>>{};
  final staleMaterial = <int>{};
  Completer<void>? holdDisposal;
  int? _loaded;

  @override
  Future<void> initialize(
    int userId, {
    Future<ServerIdentityGuard?> Function()? checkServerIdentity,
  }) async {
    initialized.add(userId);
    await holdInit[userId]?.future;
    _loaded = userId;
  }

  @override
  Future<bool> confirmMaterialDeviceId(int deviceId) async =>
      !staleMaterial.contains(_loaded);

  @override
  Future<bool> disposeMismatchedMaterialForReset(
    int sessionDeviceId, {
    Future<void> Function()? beforeWipe,
  }) async {
    await holdDisposal?.future;
    try {
      await beforeWipe?.call();
    } on Object {
      return false;
    }
    staleMaterial.remove(_loaded);
    return true;
  }

  @override
  Future<Map<String, dynamic>?> getKeyBundleForReupload() async =>
      _loaded == null ? null : {'identityPublicKey': 'identity-of-$_loaded'};

  @override
  Future<void> revokeForPasscodeLock() async => _loaded = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userA = 7;
  const userB = 9;

  late List<(String, dynamic)> emitted;

  /// What `ownKeyBundleStatus` answers per check; null leaves the check
  /// unanswered (the init stays waiting on the server).
  late Map<String, dynamic>? Function() status;

  EncryptionProvider buildProvider() {
    final provider = EncryptionProvider();
    return provider
      ..setEmitCallback((event, data) {
        emitted.add((event, data));
        if (event == 'checkOwnKeyBundle') {
          final answer = status();
          if (answer != null) provider.onOwnKeyBundleStatus(answer);
        }
      })
      ..setOwnDeviceId(1);
  }

  /// An account that already published an identity this install does not hold.
  Map<String, dynamic> enrolled() => {
    'exists': true,
    'linkingEnabled': true,
    'identityReset': null,
  };

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    emitted = [];
  });

  group('the link gate of the account that signed out', () {
    Future<EncryptionProvider> gatedAsA() async {
      status = enrolled;
      final provider = buildProvider();
      await provider.initializeE2E(userA);
      await pumpEventQueue(times: 200);
      expect(provider.needsDeviceLink, isTrue, reason: 'precondition: A is gated');
      return provider;
    }

    test("is gone after logout, before the next account's init answers", () async {
      final provider = await gatedAsA();

      provider.clearAll(); // A taps logout on the gate
      expect(provider.needsDeviceLink, isFalse);

      // B signs in; the server has not answered B's bundle check yet.
      status = () => null;
      final initB = provider.initializeE2E(userB);
      await pumpEventQueue(times: 200);
      expect(provider.needsDeviceLink, isFalse,
          reason: 'B must not see the gate A was stuck on');

      provider.onOwnKeyBundleStatus({'exists': false});
      await initB;
      expect(provider.needsDeviceLink, isFalse);
      expect(provider.isE2EReady, isTrue);
    });

    test('is gone on a fresh (non-reconnect) connect', () async {
      final provider = await gatedAsA();

      provider.onConnect(false);

      expect(provider.needsDeviceLink, isFalse);
    });
  });

  group('an E2E init still running when the account changes', () {
    late _ScriptedService service;
    late EncryptionProvider provider;

    setUp(() {
      service = _ScriptedService();
      provider = EncryptionProvider(service: service)
        ..setEmitCallback((event, data) => emitted.add((event, data)))
        ..setOwnDeviceId(1);
    });

    List<String> uploadedBundles() => [
      for (final (event, data) in emitted)
        if (event == 'uploadKeyBundle')
          (data as Map)['identityPublicKey'] as String,
    ];

    test("A logs out, B logs in: B is initialized and A's bundle never goes out", () async {
      service.holdInit[userA] = Completer<void>();
      final initA = provider.initializeE2E(userA);
      await pumpEventQueue();

      provider.clearAll();
      final initB = provider.initializeE2E(userB);
      service.holdInit[userA]!.complete();
      await Future.wait([initA, initB]);

      expect(service.initialized, [userA, userB],
          reason: "B must get its own initialize, not inherit A's ready flag");
      expect(uploadedBundles(), ['identity-of-$userB']);
      expect(provider.isE2EReady, isTrue);
    });

    test('a passcode re-lock during the init leaves E2E down, and the unlock brings it back',
        () async {
      service.holdInit[userA] = Completer<void>();
      final initA = provider.initializeE2E(userA);
      await pumpEventQueue();

      await provider.revokeForPasscodeLock();
      service.holdInit[userA]!.complete();
      await initA;

      expect(provider.isE2EReady, isFalse,
          reason: 'the stores were revoked while the init ran');
      expect(uploadedBundles(), isEmpty);

      await provider.restoreAfterPasscodeUnlock();
      expect(service.initialized, [userA, userA]);
      expect(provider.isE2EReady, isTrue);
      expect(uploadedBundles(), ['identity-of-$userA']);
    });
  });

  group('a completed reset spent on the gate while the account changes', () {
    test('the new account is not torn down and the old one is not initialized again',
        () async {
      final service = _ScriptedService()
        ..staleMaterial.add(userA)
        ..holdDisposal = Completer<void>();
      var freshLives = 0;
      final provider = EncryptionProvider(service: service)
        ..setEmitCallback((event, data) => emitted.add((event, data)))
        ..setOwnDeviceId(1)
        ..onFreshDeviceLife = () async => freshLives++;

      await provider.initializeE2E(userA);
      expect(provider.deviceMaterialMismatch, isTrue, reason: 'precondition');

      // The server reports A's reset completed: the disposal starts and waits.
      provider.onOwnKeyBundleStatus({
        'exists': true,
        'linkingEnabled': true,
        'identityReset': {
          'status': 'completed',
          'deadlineAt': DateTime.now().toUtc().toIso8601String(),
        },
      });
      await pumpEventQueue();

      provider.clearAll();
      await provider.initializeE2E(userB);
      expect(provider.isE2EReady, isTrue, reason: 'B is up');

      service.holdDisposal!.complete();
      await pumpEventQueue(times: 200);

      expect(freshLives, 0, reason: "A's disposal must not retire B's queues");
      expect(service.initialized, [userA, userB],
          reason: "no initialize for A on B's socket");
      expect(provider.isE2EReady, isTrue);
    });
  });
}
