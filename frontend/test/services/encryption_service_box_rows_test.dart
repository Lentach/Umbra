import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The box's tombstone and parked-action rows are sealed on web, so a row
/// sealed under a key this session cannot open is served as its raw `fps1:`
/// envelope. Such a row must read as empty AND be replaceable: a reader that
/// throws on it wedges every later write, since each write reads first.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const unsealable = 'fps1:lost-kid:-:AAAA';
  const wire = (senderId: 2, wireId: 'wire-after-key-loss');
  late EncryptionService service;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
  });

  test('an unreadable tombstone row is replaced by the next delete', () async {
    await (await service.contentKv).setString('e2e_1_boxdel_v1', unsealable);

    expect(await service.boxTombstoned(wire), isFalse);
    await service.addBoxTombstone(wire);

    expect(await service.boxTombstoned(wire), isTrue);
  });

  test('an unreadable parked-action row is replaced by the next park', () async {
    await (await service.contentKv).setString('e2e_1_boxact_v1', unsealable);
    final at = DateTime.now();

    expect(await service.parkedBoxActions(10, wire), isEmpty);
    await service.parkBoxAction(10, wire, {'e': '👍'}, receivedAt: at);

    expect(await service.parkedBoxActions(10, wire), [
      {'e': '👍', 'r': at.millisecondsSinceEpoch},
    ]);
  });
}
