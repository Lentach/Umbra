import 'dart:async';
import 'dart:convert';

import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [_inner] (the prefs store, forced onto its web branch) whose next
/// [authoritativeSnapshot] is read at the call, as on web, but handed back
/// only when the test releases it — so a write can land between what a scan
/// read and when it answers.
class _HeldSnapshotKv implements ContentKv {
  _HeldSnapshotKv(this._inner);

  final ContentKv _inner;
  ({Completer<void> taken, Completer<void> release})? _hold;

  /// Store reads so far: on web each one unseals every record.
  int snapshots = 0;

  /// Holds the next snapshot. `taken` completes once it was read.
  ({Completer<void> taken, Completer<void> release}) holdNext() =>
      _hold = (taken: Completer<void>(), release: Completer<void>());

  @override
  Future<Map<String, Object>?> authoritativeSnapshot() async {
    final hold = _hold;
    _hold = null;
    snapshots++;
    final snapshot = await _inner.authoritativeSnapshot();
    if (hold != null) {
      hold.taken.complete();
      await hold.release.future;
    }
    return snapshot;
  }

  @override
  Future<void> reload() => _inner.reload();

  @override
  String? getString(String key) => _inner.getString(key);

  @override
  int? getInt(String key) => _inner.getInt(key);

  @override
  bool containsKey(String key) => _inner.containsKey(key);

  @override
  Set<String> getKeys() => _inner.getKeys();

  @override
  Future<bool> setString(String key, String value) =>
      _inner.setString(key, value);

  @override
  Future<bool> setInt(String key, int value) => _inner.setInt(key, value);

  @override
  Future<bool> remove(String key) => _inner.remove(key);
}

/// The wire-id cache behind `wireHeldByOther`/`wireHolder` is built by ONE
/// scan of the store. A stamp that scan did not see and the cache does not
/// hold is a message the box stores and shows twice, or a quote/action that
/// misses its target — for the rest of the session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const first = (senderId: 2, wireId: 'wire-first-0001');
  const second = (senderId: 2, wireId: 'wire-second-0002');
  late EncryptionService service;
  late _HeldSnapshotKv kv;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    PrefsContentKv.debugForceAuthoritative = true;
    addTearDown(() => PrefsContentKv.debugForceAuthoritative = false);
    kv = _HeldSnapshotKv(await service.contentKv);
    service.debugSetContentKv(kv);
  });

  /// Starts the first lookup and returns once its scan read the store.
  Future<({Future<bool?> lookup, Completer<void> release})> heldFirstScan() async {
    final hold = kv.holdNext();
    final lookup = service.wireHeldByOther(first, 0);
    await hold.taken.future;
    return (lookup: lookup, release: hold.release);
  }

  Future<void> save(int id, WireKey wire) =>
      service.saveDecryptedContent(id, {'content': 'box'}, wire: wire);

  test('a stamp saved while the first scan runs is held after it', () async {
    final scan = await heldFirstScan();
    await save(900, first);
    scan.release.complete();
    await scan.lookup;

    // A resent copy of the message under another id is a duplicate.
    expect(await service.wireHeldByOther(first, 901), isTrue);
    expect(await service.wireHolder(first), 900);
  });

  test('a lookup during the first scan shares it and loses no row', () async {
    final scan = await heldFirstScan();
    await save(900, first);
    // A second lookup (a receipt, a reaction) while the first scan runs,
    // then a row saved after it answered.
    final reads = kv.snapshots;
    final during = service.wireHolder(first);
    await pumpEventQueue();
    expect(kv.snapshots, reads, reason: 'a second scan re-unseals the store');
    await save(901, second);
    scan.release.complete();
    await scan.lookup;

    expect(await during, 900);
    expect(await service.wireHolder(first), 900);
    expect(await service.wireHolder(second), 901);
  });

  test('rows imported during the first scan are held after it', () async {
    final scan = await heldFirstScan();
    // A history-file import writes behind saveDecryptedContent, then drops
    // the cache.
    await kv.setString(
      'e2e_1_decrypted_${1 << 48}',
      jsonEncode({'content': 'imported', '_wid': first.wireId, '_wsid': 2}),
    );
    service.forgetWireClaims();
    scan.release.complete();
    await scan.lookup;

    expect(await service.wireHolder(first), 1 << 48);
  });

  test('a scan the store failed is retried by the next lookup', () async {
    await save(900, first);
    final scan = await heldFirstScan();
    scan.release.completeError(StateError('store locked'));

    expect(await scan.lookup, isNull);
    expect(await service.wireHolder(first), 900);
  });
}
