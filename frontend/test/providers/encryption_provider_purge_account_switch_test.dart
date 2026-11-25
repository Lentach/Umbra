import 'dart:async';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/server_clock.dart';
import 'package:fireplace/utils/e2e_diag_log.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A content store that parks ONE chosen operation until the test releases it,
/// so an account switch can land between two awaits of a running purge pass.
class _GateKv implements ContentKv {
  _GateKv(this._inner);

  final ContentKv _inner;

  /// Parks the first call of the matching operation (after [arm]).
  bool Function(String op, String? key)? _match;
  late Completer<void> _parked;
  late Completer<void> _release;

  /// Arms the gate; the returned future completes once an operation parked.
  Future<void> arm(bool Function(String op, String? key) match) {
    _match = match;
    _parked = Completer<void>();
    _release = Completer<void>();
    return _parked.future;
  }

  void release() => _release.complete();

  Future<void> _maybePark(String op, [String? key]) async {
    final match = _match;
    if (match == null || !match(op, key)) return;
    _match = null;
    _parked.complete();
    await _release.future;
  }

  @override
  Future<void> reload() => _inner.reload();

  @override
  Future<Map<String, Object>?> authoritativeSnapshot() async {
    await _maybePark('snapshot');
    return _inner.authoritativeSnapshot();
  }

  @override
  String? getString(String key) => _inner.getString(key);

  @override
  int? getInt(String key) => _inner.getInt(key);

  @override
  bool containsKey(String key) => _inner.containsKey(key);

  @override
  Set<String> getKeys() => _inner.getKeys();

  @override
  Future<bool> setString(String key, String value) async {
    await _maybePark('setString', key);
    return _inner.setString(key, value);
  }

  @override
  Future<bool> setInt(String key, int value) async {
    await _maybePark('setInt', key);
    return _inner.setInt(key, value);
  }

  @override
  Future<bool> remove(String key) async {
    await _maybePark('remove', key);
    return _inner.remove(key);
  }
}

/// A retention sweep or a backlog drain that started for account A must never
/// touch account B's records after a switch, although local ids restart at the
/// same base for every account (A3-SVC-D-02).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const accountA = 42;
  const accountB = 43;
  // The same local id in both accounts: the collision the audit names.
  const sharedId = kFirstLocalMessageId + 1;
  const fresh = ServerIdentityGuard(exists: false);

  late EncryptionService service;
  late EncryptionProvider provider;
  late _GateKv kv;
  late DateTime serverNow;

  Future<void> switchTo(int user) =>
      service.initialize(user, checkServerIdentity: () async => fresh);

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    E2eDiagLog.clear();
    ServerClock.instance.resetForTest();
    serverNow = DateTime.now().toUtc();
    ServerClock.instance.observe(serverNow);
    service = EncryptionService();
    await service.initialize(accountA, checkServerIdentity: () async => fresh);
    kv = _GateKv(await service.contentKv);
    service.debugSetContentKv(kv);
    provider = EncryptionProvider(service: service);

    // B holds a LIVE record under the same id and one owed purge of its own.
    await switchTo(accountB);
    await service.saveDecryptedContent(sharedId, {'content': 'B keeps this'});
    await service.enqueuePurge({sharedId}, const <String>{});
    await switchTo(accountA);
  });

  tearDown(() {
    ServerClock.instance.resetForTest();
    E2eDiagLog.clear();
  });

  Future<void> expectBUntouched({required bool backlogKept}) async {
    expect(service.activeUserId, accountB);
    expect(
      (await service.getDecryptedContent(sharedId))?['content'],
      'B keeps this',
      reason: "account A's pass must not delete account B's record",
    );
    final owed = await service.purgeBacklog();
    if (backlogKept) {
      expect(owed.ids, {sharedId}, reason: "B's own owed purge is still owed");
    }
  }

  group('a purge pass pinned to the account it started under', () {
    test('sweep: a switch while the obligation is being written', () async {
      await service.saveDecryptedContent(
        sharedId,
        {'content': 'A expired'},
        expiresAt: serverNow.subtract(const Duration(minutes: 6)),
      );
      final parked = kv.arm((op, key) => op == 'setString' && key!.contains('purge'));
      final sweep = provider.sweepDestroyablePlaintext();
      await parked;

      await switchTo(accountB);
      kv.release();
      await sweep;

      await expectBUntouched(backlogKept: true);
    });

    test('sweep: a switch between choosing the ids and writing them down',
        () async {
      await service.saveDecryptedContent(
        sharedId,
        {'content': 'A expired'},
        expiresAt: serverNow.subtract(const Duration(minutes: 6)),
      );
      // The first destroyable scan stamps the retention epoch; park there.
      final parked = kv.arm((op, key) => op == 'setInt');
      final sweep = provider.sweepDestroyablePlaintext();
      await parked;

      await switchTo(accountB);
      kv.release();
      await sweep;

      await expectBUntouched(backlogKept: true);
    });

    test('drain: a switch while a record is read before it is destroyed',
        () async {
      await service.enqueuePurge({sharedId}, const <String>{});
      // An expiry stamp keeps the obligation through the one-time amnesty.
      await service.saveDecryptedContent(
        sharedId,
        {'content': 'A owed'},
        expiresAt: serverNow.subtract(const Duration(minutes: 6)),
      );
      // The amnesty pass has run once: only the pre-removal read parks next.
      await service.amnestyUnstampedPurgeObligations();
      final parked = kv.arm((op, key) => op == 'snapshot');
      final drain = provider.drainPurgeBacklog();
      await parked;

      await switchTo(accountB);
      kv.release();
      await drain;

      await expectBUntouched(backlogKept: true);
    });

    test('drain: a switch while the record is being removed', () async {
      await service.enqueuePurge({sharedId}, const <String>{});
      // An expiry stamp keeps the obligation through the one-time amnesty.
      await service.saveDecryptedContent(
        sharedId,
        {'content': 'A owed'},
        expiresAt: serverNow.subtract(const Duration(minutes: 6)),
      );
      await service.amnestyUnstampedPurgeObligations();
      final parked = kv.arm(
        (op, key) => op == 'remove' && key!.contains('decrypted'),
      );
      final drain = provider.drainPurgeBacklog();
      await parked;

      await switchTo(accountB);
      kv.release();
      await drain;

      await expectBUntouched(backlogKept: true);
    });
  });
}
