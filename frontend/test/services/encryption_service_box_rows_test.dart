import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [inner] whose [setString] shows the new value only once it committed,
/// after an await — as `NativeContentStore` does on Android — so two
/// read-modify-writes overlap unless something serializes them.
class _SlowWriteKv implements ContentKv {
  _SlowWriteKv(this.inner);

  final ContentKv inner;

  @override
  Future<void> reload() => inner.reload();

  @override
  Future<Map<String, Object>?> authoritativeSnapshot() =>
      inner.authoritativeSnapshot();

  @override
  String? getString(String key) => inner.getString(key);

  @override
  int? getInt(String key) => inner.getInt(key);

  @override
  bool containsKey(String key) => inner.containsKey(key);

  @override
  Set<String> getKeys() => inner.getKeys();

  @override
  Future<bool> setString(String key, String value) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return inner.setString(key, value);
  }

  @override
  Future<bool> setInt(String key, int value) => inner.setInt(key, value);

  @override
  Future<bool> remove(String key) => inner.remove(key);
}

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

  test('an unreadable seen-marks row is replaced by the next mark', () async {
    await (await service.contentKv).setString('e2e_1_boxseen_v1', unsealable);
    final at = DateTime.utc(2026, 9, 30, 12);

    expect((await service.boxSeenMarks())?.chats, isEmpty);
    await service.markBoxChatSeen(10, at);

    expect((await service.boxSeenMarks())?.chats, {
      10: at.millisecondsSinceEpoch,
    });
  });

  group('box seen marks (decision 73, E73a)', () {
    test('a chat never shown here reads as seen up to when this device '
        'first kept marks, and that moment stays put', () async {
      final before = DateTime.now().millisecondsSinceEpoch;
      final first = await service.boxSeenMarks();
      final after = DateTime.now().millisecondsSinceEpoch;
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final again = await service.boxSeenMarks();

      expect(first!.base, inInclusiveRange(before, after));
      expect(again!.base, first.base);
      expect(again.chats, isEmpty);
    });

    test('a mark never moves back (another tab showed the chat later)', () async {
      final later = DateTime.utc(2026, 9, 30, 12, 5);
      await service.markBoxChatSeen(10, later);
      await service.markBoxChatSeen(10, DateTime.utc(2026, 9, 30, 12));
      await service.markBoxChatSeen(11, DateTime.utc(2026, 9, 30, 11));

      expect((await service.boxSeenMarks())!.chats, {
        10: later.millisecondsSinceEpoch,
        11: DateTime.utc(2026, 9, 30, 11).millisecondsSinceEpoch,
      });
    });

    test('two chats marked at once both keep their mark, on a store that '
        'shows a write only once it committed', () async {
      service.debugSetContentKv(_SlowWriteKv(await service.contentKv));
      final at = DateTime.utc(2026, 9, 30, 12);
      await Future.wait([
        service.markBoxChatSeen(10, at),
        service.markBoxChatSeen(11, at),
      ]);

      expect(
        (await service.boxSeenMarks())!.chats.keys,
        unorderedEquals([10, 11]),
      );
    });
  });
}
