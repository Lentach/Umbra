import 'package:fireplace/services/encryption/signal_stores.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// The real Signal key-value store, with failures that can be switched on
/// AFTER the account is set up: the enumeration, or the delete of one key.
class _FailingSignalStorage extends DualStorage {
  _FailingSignalStorage() : super(const FlutterSecureStorage());

  bool failReadAll = false;
  String? failDeleteOf;

  @override
  Future<Map<String, String>> readAll() async {
    if (failReadAll) throw StateError('signal store unavailable');
    return super.readAll();
  }

  @override
  Future<void> delete({required String key}) async {
    if (key == failDeleteOf) throw StateError('delete refused');
    return super.delete(key: key);
  }
}

/// A preferences store whose removals can be told to report a failed commit
/// and keep the value (the quota / backend-failure shape).
class _RefusingStore extends SharedPreferencesStorePlatform {
  final InMemorySharedPreferencesStore _inner =
      InMemorySharedPreferencesStore.empty();

  bool refuseRemove = false;

  @override
  Future<bool> remove(String key) async {
    if (refuseRemove) return false;
    return _inner.remove(key);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      _inner.setValue(valueType, key, value);

  @override
  Future<bool> clear() => _inner.clear();

  @override
  Future<bool> clearWithPrefix(String prefix) => _inner.clearWithPrefix(prefix);

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) =>
      _inner.clearWithParameters(parameters);

  @override
  Future<Map<String, Object>> getAll() => _inner.getAll();

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      _inner.getAllWithPrefix(prefix);

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) => _inner.getAllWithParameters(parameters);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userId = 42;
  const prefix = 'e2e_${userId}_';

  late _RefusingStore store;
  late _FailingSignalStorage storage;
  late EncryptionService service;

  Future<List<String>> contentKeys() async =>
      (await store.getAll()).keys.where((k) => k.contains(prefix)).toList();

  Future<List<String>> signalKeys() async => (await const FlutterSecureStorage()
          .readAll())
      .keys
      .where((k) => k.startsWith(prefix))
      .toList();

  List<String> wipeDiag() => E2ePersistentDiag.entries
      .where((e) => e.contains('KEY_WIPE_INCOMPLETE'))
      .toList();

  setUp(() async {
    store = _RefusingStore();
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();
    FlutterSecureStorage.setMockInitialValues({});
    await E2ePersistentDiag.clear();
    storage = _FailingSignalStorage();
    service = EncryptionService()..debugSetDualStorage(storage);
    await service.initialize(
      userId,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    await service.saveDecryptedContent(1, {'content': 'the only copy'});
    // Controls: both stores hold this account's rows before the wipe.
    expect(await contentKeys(), isNotEmpty);
    expect(await signalKeys(), isNotEmpty);
  });

  tearDown(E2ePersistentDiag.clear);

  group('clearAllKeys finishes every stage when one fails', () {
    test('a Signal store that cannot be listed still gets the messages wiped '
        'and the account forgotten, and the caller is told', () async {
      storage.failReadAll = true;

      await expectLater(service.clearAllKeys(), throwsStateError);

      expect(await contentKeys(), isEmpty);
      expect(service.activeUserId, isNull);
      expect(service.isInitialized, isFalse);
      expect(wipeDiag(), hasLength(1));
      expect(wipeDiag().single, contains('signal'));
    });

    test('one key that refuses to delete does not keep the others, the '
        'messages or the account', () async {
      final before = await signalKeys();
      expect(before.length, greaterThan(1));
      storage.failDeleteOf = before.first;

      await expectLater(service.clearAllKeys(), throwsStateError);

      expect(await signalKeys(), [before.first]);
      expect(await contentKeys(), isEmpty);
      expect(service.activeUserId, isNull);
      expect(service.isInitialized, isFalse);
      expect(wipeDiag(), hasLength(1));
    });

    test('messages the store refuses to remove are recorded, not passed off '
        'as wiped', () async {
      final held = await contentKeys();
      store.refuseRemove = true;

      await service.clearAllKeys();

      expect(await contentKeys(), held);
      expect(await signalKeys(), isEmpty);
      expect(service.activeUserId, isNull);
      expect(wipeDiag(), hasLength(1));
      expect(wipeDiag().single, contains('content'));
      // Counts and type names only: no account id, no key names.
      expect(wipeDiag().single, isNot(contains(prefix)));
    });

    test('a clean wipe records no failure', () async {
      await service.clearAllKeys();

      expect(await contentKeys(), isEmpty);
      expect(await signalKeys(), isEmpty);
      expect(wipeDiag(), isEmpty);
    });
  });
}
