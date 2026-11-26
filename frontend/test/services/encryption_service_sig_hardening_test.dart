import 'package:fireplace/services/encryption/signal_stores.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fireplace/utils/e2e_persistent_diag.dart';

/// The two B2b companion hardenings (docs/design/web-sig-sealing.md §3.1a) —
/// the catch sites the design review proved could convert an enumeration
/// throw into an absent-equivalent default:
///
///  * R1 (CRITICAL): `_hasPriorInstallResidue` swallowed a `readAll` throw
///    into `false`, letting `initialize` treat "identity gone + enumeration
///    failing" as a fresh install and MINT A NEW IDENTITY over surviving
///    session/prekey material.
///  * R3 (HIGH): `_highestStoredPreKeyId` swallowed the throw into the
///    fresh-install floor, so a lost counter + a failing enumeration would
///    REUSE prekey ids whose public halves the server already serves.
class _ScriptedDualStorage extends DualStorage {
  _ScriptedDualStorage() : super(const FlutterSecureStorage());

  final Map<String, String> store = {};
  bool throwReadAll = false;
  bool throwDelete = false;
  int writeCount = 0;

  @override
  Future<void> write({required String key, required String value}) async {
    writeCount++;
    store[key] = value;
  }

  @override
  Future<String?> read({required String key}) async => store[key];

  @override
  Future<void> delete({required String key}) async {
    if (throwDelete) throw Exception('delete failed');
    store.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    if (throwReadAll) throw Exception('enumeration failed');
    return Map.of(store);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ScriptedDualStorage storage;
  late EncryptionService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await E2ePersistentDiag.clear();
    await E2ePersistentDiag.init();
    storage = _ScriptedDualStorage();
    service = EncryptionService();
    service.debugSetDualStorage(storage);
  });

  test('§5.11 R1: identity absent + enumeration FAILING refuses to '
      'regenerate — inconclusive residue reads as residue-present', () async {
    storage.throwReadAll = true;

    // (lxxi): the server decides. With a bundle published, an inconclusive
    // scan must read as residue-present and refuse — the pre-(lxxi) `catch →
    // false` would have minted over the enrolled identity.
    await expectLater(
      service.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: true)),
      throwsA(isA<E2eIdentityIncompleteException>()),
    );
    expect(storage.writeCount, 0,
        reason: 'a NEW identity minted over a surviving (but unenumerable) '
            'install is the permanent silent loss the guard exists to block');
    expect(
      E2ePersistentDiag.entries
          .where((e) => e.contains('IDENTITY_RESIDUE_UNKNOWN')),
      hasLength(1),
    );
  });

  test('identity absent + enumeration FAILING + server says no bundle '
      'DEFERS — the discard must be proven, never attempted blind', () async {
    storage.throwReadAll = true;

    // The explicit "no bundle" authorizes the discard, but a discard that
    // cannot enumerate could leave session rows under a freshly minted
    // identity — exactly the stranded state (lxxi) exists to avoid. Same
    // outcome as an UNKNOWN server answer: nothing written, retry next boot.
    await expectLater(
      service.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false)),
      throwsA(isA<E2eIdentityCheckUnavailableException>()),
    );
    expect(storage.writeCount, 0);
    expect(
      E2ePersistentDiag.entries
          .where((e) => e.contains('IDENTITY_RESIDUE_DISCARD_DEFERRED')),
      hasLength(1),
    );
  });

  test('a residue row that was seen but could NOT be deleted also DEFERS — '
      'a surviving session under a fresh identity is the same stranded state',
      () async {
    storage.store['e2e_37_session_2_1'] = 'ratchet';
    storage.throwDelete = true;

    await expectLater(
      service.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false)),
      throwsA(isA<E2eIdentityCheckUnavailableException>()),
    );
    expect(storage.writeCount, 0);
    expect(storage.store['e2e_37_session_2_1'], 'ratchet');
    expect(storage.store.keys, isNot(contains('e2e_37_identity_record_v1')));
    expect(
      E2ePersistentDiag.entries
          .where((e) => e.contains('IDENTITY_RESIDUE_DISCARD_DEFERRED')),
      hasLength(1),
    );
  });

  test('identity absent + enumeration SUCCEEDING empty still regenerates '
      '(fresh installs must keep working), and says so DURABLY', () async {
    await service.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    expect(storage.store.keys, contains('e2e_37_identity_record_v1'));
    // Until 2026-09-04 the only trace of a mint was a debugPrint, so a
    // misclassification that minted over a surviving install could only be
    // inferred afterwards from a peer identity-change cascade. Phase 2 makes
    // the local key material passcode-wrapped, which adds a brand-new way to
    // reach this branch wrongly, so the mint has to be visible in the field.
    expect(
      E2ePersistentDiag.entries.where((e) => e.contains('IDENTITY_MINTED')),
      hasLength(1),
    );
  });

  test('identity absent + surviving session rows + server bundle exists '
      'refuses to regenerate and leaves the rows alone', () async {
    storage.store['e2e_37_session_2_1'] = 'ratchet';

    await expectLater(
      service.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: true)),
      throwsA(isA<E2eIdentityIncompleteException>()),
    );
    expect(storage.store.keys, isNot(contains('e2e_37_identity_record_v1')));
    expect(storage.store['e2e_37_session_2_1'], 'ratchet');
  });

  test('identity absent + surviving session rows + server says no bundle '
      'discards the rows and mints (lxxi)', () async {
    storage.store['e2e_37_session_2_1'] = 'ratchet';

    await service.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    expect(storage.store.keys, contains('e2e_37_identity_record_v1'));
    expect(storage.store.keys, isNot(contains('e2e_37_session_2_1')));
    expect(
      E2ePersistentDiag.entries
          .where((e) => e.contains('IDENTITY_RESIDUE_DISCARDED')),
      hasLength(1),
    );
  });

  test('§5.12 R3: lost counter + enumeration FAILING skips the prekey mint '
      'instead of defaulting into id reuse', () async {
    await service.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false)); // fresh install; writes keys + counter
    final writesAfterInit = storage.writeCount;

    storage.store.remove('e2e_37_next_pre_key_id'); // the lost-counter case
    storage.throwReadAll = true;

    final minted = await service.generateMorePreKeys();
    expect(minted, isEmpty);
    expect(storage.writeCount, writesAfterInit,
        reason: 'no prekey may be written from an inconclusive scan — a '
            'reused id overwrites a live private half whose public half the '
            'server already handed out');
    expect(
      E2ePersistentDiag.entries.where((e) => e.contains('PREKEY_MINT_SKIPPED')),
      hasLength(1),
    );
  });

  test('lost counter + enumeration SUCCEEDING derives from the highest '
      'stored id (the fallback keeps working when it can be trusted)',
      () async {
    await service.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    storage.store.remove('e2e_37_next_pre_key_id');

    final minted = await service.generateMorePreKeys();
    expect(minted, isNotEmpty);
    // Initial batch is ids 0..99; the derived next id must be 100, never a
    // reuse of 0..99.
    expect(storage.store.keys, contains('e2e_37_pre_key_100'));
    expect(storage.store['e2e_37_next_pre_key_id'], isNotNull);
  });
}
