import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A destructive call pinned to an account that is no longer current must
/// refuse: local ids restart at the same base for every account, so acting on
/// the new account's rows is data loss (A3-SVC-D-02).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const accountA = 42;
  const accountB = 43;
  const sharedId = kFirstLocalMessageId + 1;
  const fresh = ServerIdentityGuard(exists: false);

  late EncryptionService service;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    service = EncryptionService();
    await service.initialize(accountB, checkServerIdentity: () async => fresh);
    await service.saveDecryptedContent(sharedId, {'content': 'B keeps this'});
    await service.flushDecryptedLedger();
    await service.enqueuePurge({sharedId}, const <String>{});
  });

  test('every destructive call refuses a user id that is no longer current',
      () async {
    expect(
      await service.enqueuePurge({7}, const <String>{}, forUser: accountA),
      isFalse,
    );
    final removed = await service.removeDecryptedContent(
      {sharedId},
      forUser: accountA,
    );
    expect(removed.failedIds, {sharedId});
    expect(removed.removed, 0);
    expect(
      await service.removePendingSendRecord('ct', forUser: accountA),
      isFalse,
    );
    await service.markRetired({sharedId}, forUser: accountA);
    await service.forgetDecryptedMany({sharedId}, forUser: accountA);
    await service.resolvePurged(
      {sharedId},
      const <String>{},
      forUser: accountA,
    );
    expect((await service.purgeBacklog(forUser: accountA)).ids, isEmpty);

    expect(
      (await service.getDecryptedContent(sharedId))?['content'],
      'B keeps this',
    );
    expect((await service.purgeBacklog()).ids, {sharedId});
    expect(
      await service.decryptedLedgerIds(),
      contains(sharedId),
      reason: "a stale forgetDecryptedMany must not drop B's ledger entry",
    );
    expect(await service.retiredMessageIds(), isEmpty);
  });

  test('the same calls pinned to the current account do their work', () async {
    await service.markRetired({sharedId}, forUser: accountB);
    expect(await service.retiredMessageIds(), {sharedId});
    expect(
      await service.enqueuePurge({8}, const <String>{}, forUser: accountB),
      isTrue,
    );
    expect((await service.purgeBacklog(forUser: accountB)).ids, {sharedId, 8});
    final removed = await service.removeDecryptedContent(
      {sharedId},
      forUser: accountB,
    );
    expect(removed.isComplete, isTrue);
    expect(removed.removed, 1);
    await service.resolvePurged(
      {sharedId, 8},
      const <String>{},
      forUser: accountB,
    );
    expect((await service.purgeBacklog()).ids, isEmpty);
  });
}
