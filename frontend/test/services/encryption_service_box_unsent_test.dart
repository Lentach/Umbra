import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Decision 104: a box message that did not go out is kept on the device,
/// one content-kv key per tempId (`e2e_<uid>_boxunsent_v1_<tempId>`), until
/// it is sent, deleted, past its own timer, or the user signs out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const uid = 42;
  const prefix = 'e2e_${uid}_boxunsent_v1_';
  late EncryptionService service;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    service = EncryptionService();
    await service.initialize(
      uid,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
  });

  Future<Set<String>> unsentKeys() async => (await service.contentKv)
      .getKeys()
      .where((k) => k.startsWith(prefix))
      .toSet();

  Map<String, Object?> entry(int conversationId, {int? atMs, int? ttl}) => {
    'c': conversationId,
    'at': atMs ?? DateTime.now().millisecondsSinceEpoch,
    'ttl': ?ttl,
    'content': 'words',
  };

  test('an entry reads back for its own chat only', () async {
    await service.saveBoxUnsent(uid, 'temp_1_42', entry(10));
    await service.saveBoxUnsent(uid, 'temp_2_42', entry(11));

    final ten = await service.boxUnsent(uid, 10);
    expect(ten.keys, ['temp_1_42']);
    expect(ten['temp_1_42'], containsPair('content', 'words'));
    expect((await service.boxUnsent(uid, 11)).keys, ['temp_2_42']);
  });

  test('an entry is filed under the account that sent it, not the one the '
      'service now serves', () async {
    await service.saveBoxUnsent(7, 'temp_9_7', entry(10));

    expect(await unsentKeys(), isEmpty);
    expect((await service.boxUnsent(7, 10)).keys, ['temp_9_7']);
    await service.clearBoxUnsent(7);
    expect(await service.boxUnsent(7, 10), isEmpty);
  });

  test('an entry past its own timer is not served and its key is gone '
      '(E18: no words of a disappearing message are kept)', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await service.saveBoxUnsent(
      uid,
      'temp_old_42',
      entry(10, atMs: now - 120 * 1000, ttl: 60),
    );
    await service.saveBoxUnsent(
      uid,
      'temp_live_42',
      entry(10, atMs: now - 30 * 1000, ttl: 60),
    );

    expect((await service.boxUnsent(uid, 10)).keys, ['temp_live_42']);
    expect(await unsentKeys(), {'${prefix}temp_live_42'});
  });

  test('an entry older than 30 days is pruned', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await service.saveBoxUnsent(
      uid,
      'temp_stale_42',
      entry(10, atMs: now - const Duration(days: 31).inMilliseconds),
    );

    expect(await service.boxUnsent(uid, 10), isEmpty);
    expect(await unsentKeys(), isEmpty);
  });

  test('an entry that cannot be read now is skipped, never destroyed: its '
      'key may come back', () async {
    final kv = await service.contentKv;
    await kv.setString('${prefix}temp_sealed_42', 'fps1:k9:-:unreadable');

    expect(await service.boxUnsent(uid, 10), isEmpty);
    expect(await unsentKeys(), {'${prefix}temp_sealed_42'});
  });

  test('drop removes the entry', () async {
    await service.saveBoxUnsent(uid, 'temp_1_42', entry(10));
    await service.dropBoxUnsent(uid, 'temp_1_42');

    expect(await service.boxUnsent(uid, 10), isEmpty);
    expect(await unsentKeys(), isEmpty);
  });

  test('the cap keeps the newest entries', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < EncryptionService.boxUnsentCap + 3; i++) {
      await service.saveBoxUnsent(
        uid,
        'temp_${i}_42',
        entry(10, atMs: now + i),
      );
    }

    final kept = await unsentKeys();
    expect(kept, hasLength(EncryptionService.boxUnsentCap));
    expect(kept, isNot(contains('${prefix}temp_0_42')));
    expect(
      kept,
      contains('${prefix}temp_${EncryptionService.boxUnsentCap + 2}_42'),
    );
  });

  test("sign-out clears this account's entries and no other's", () async {
    await service.saveBoxUnsent(uid, 'temp_1_42', entry(10));
    final kv = await service.contentKv;
    await kv.setString('e2e_7_boxunsent_v1_temp_9_7', '{"c":10,"at":1}');

    await service.clearBoxUnsent(uid);

    expect(await unsentKeys(), isEmpty);
    expect(kv.getString('e2e_7_boxunsent_v1_temp_9_7'), isNotNull);
  });

  test('"delete all local history" destroys unsent words too', () async {
    await service.saveBoxUnsent(uid, 'temp_1_42', entry(10));

    await service.clearDecryptedContentCache();

    expect(await unsentKeys(), isEmpty);
  });
}
