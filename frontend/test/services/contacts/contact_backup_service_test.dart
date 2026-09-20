import 'dart:convert';

import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/auth_token_store.dart';
import 'package:fireplace/services/contacts/contact_backup.dart';
import 'package:fireplace/services/contacts/contact_backup_service.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/passcode_fakes.dart';

/// The server row, as a test drives it: one in-memory record with the same
/// rev/salt semantics `backend/src/backup/contact-backup.service.ts` enforces.
class _FakeBackend {
  Map<String, dynamic>? row;
  final List<Map<String, dynamic>> puts = [];
  int gets = 0;

  /// Forces the NEXT put to answer 409 — the "another device wrote" case.
  bool nextPutIsStale = false;
  int? nextPutStatus;

  http.Client client() => MockClient((request) async {
    if (request.url.path != '/backup/contacts') {
      return http.Response('not found', 404);
    }
    if (request.method == 'GET') {
      gets++;
      final current = row;
      if (current == null) return http.Response('{}', 404);
      return http.Response(jsonEncode(current), 200,
          headers: {'Content-Type': 'application/json'});
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    puts.add(body);
    final forced = nextPutStatus;
    if (forced != null) {
      nextPutStatus = null;
      return http.Response(jsonEncode({'error': 'x'}), forced);
    }
    if (nextPutIsStale) {
      nextPutIsStale = false;
      return http.Response(
        jsonEncode({'error': 'stale_backup', 'rev': row?['rev'] ?? 0}),
        409,
      );
    }
    final current = row;
    if (current != null && body['baseRev'] != current['rev']) {
      return http.Response(
        jsonEncode({'error': 'stale_backup', 'rev': current['rev']}),
        409,
      );
    }
    if (current != null && body['salt'] != current['salt']) {
      return http.Response(jsonEncode({'error': 'salt_mismatch'}), 409);
    }
    final rev = ((current?['rev'] as int?) ?? 0) + 1;
    row = {
      'v': 1,
      'rev': rev,
      'salt': body['salt'],
      'ckId': body['ckId'],
      'wraps': body['wraps'],
      'blob': body['blob'],
      'updatedAt': '2026-09-20T00:00:00.000Z',
    };
    return http.Response(jsonEncode({'rev': rev, 'updatedAt': row!['updatedAt']}),
        200, headers: {'Content-Type': 'application/json'});
  });
}

ContactRecord _friend(int id) => ContactRecord(
  userId: id,
  username: 'peer$id',
  tag: '0001',
  state: ContactState.friend,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeBackend backend;
  late FakePasscodeKdf kdf;
  late AuthTokenStore tokens;
  late ContactStore store;
  late ContentKv kv;

  Future<ContactBackupService> service() async => ContactBackupService(
    api: ApiService(baseUrl: 'http://t', httpClient: backend.client()),
    tokens: tokens,
    codec: ContactBackupCodec(kdf: kdf, sealer: FakeContentSealer()),
    uploadDebounce: Duration.zero,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    backend = _FakeBackend();
    kdf = FakePasscodeKdf();
    tokens = AuthTokenStore(useSecureStorage: false);
    kv = await PrefsContentKv.open();
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(7);
  });

  /// Seeds a row the tests can then try to open, exactly the way a first
  /// device would have created it.
  Future<void> seedRow({
    required String password,
    String? phrase,
    List<ContactRecord> contacts = const [],
  }) async {
    final codec = ContactBackupCodec(kdf: kdf, sealer: FakeContentSealer());
    final (ck, ckId) = ContactBackupCodec.mintContentKey();
    final salt = ContactBackupCodec.mintSalt();
    final wraps = <Map<String, dynamic>>[
      (await codec.wrap(
        kind: ContactWrapKind.password,
        wrapKey: await codec.deriveWrapKey(
          kind: ContactWrapKind.password,
          secret: password,
          salt: salt,
        ),
        ck: ck,
      )).toJson(),
      if (phrase != null)
        (await codec.wrap(
          kind: ContactWrapKind.phrase,
          wrapKey: await codec.deriveWrapKey(
            kind: ContactWrapKind.phrase,
            secret: phrase,
            salt: salt,
          ),
          ck: ck,
        )).toJson(),
    ];
    backend.row = {
      'v': 1,
      'rev': 3,
      'salt': salt,
      'ckId': ckId,
      'wraps': wraps,
      'blob': await codec.sealPayload(
        ck,
        ContactBackupPayload(
          userId: 7,
          self: UserModel(id: 7, username: 'me', tag: '0007'),
          contacts: contacts,
        ),
      ),
      'updatedAt': '2026-09-20T00:00:00.000Z',
    };
  }

  test('a 404 mints a key and salt; nothing is written until the graph is',
      () async {
    final svc = await service();
    await svc.onSession(userId: 7, token: 'jwt', password: 'pw');

    expect(svc.state, ContactBackupState.ready);
    expect(backend.puts, isEmpty,
        reason: 'minting must not publish an empty contact list');
    expect(await tokens.readContactBackupKey(7), isNotNull);
  });

  test('the password opens the row and the restore fills an EMPTY store',
      () async {
    await seedRow(password: 'pw', contacts: [_friend(41), _friend(42)]);
    final svc = await service();
    svc.attach(store);
    await svc.onSession(userId: 7, token: 'jwt', password: 'pw');

    expect(svc.state, ContactBackupState.ready);
    expect(await svc.applyRestore(), 2);
    expect(store.byUserId(41)?.username, 'peer41');
    expect(store.byUserId(42)?.username, 'peer42');
    expect(store.self?.username, 'me');
  });

  test('a restore never overwrites a record the device already holds',
      () async {
    await seedRow(password: 'pw', contacts: [_friend(41)]);
    await store.update(41, (_) => _friend(41).copyWith(username: 'local'));
    final svc = await service();
    svc.attach(store);
    await svc.onSession(userId: 7, token: 'jwt', password: 'pw');
    await svc.applyRestore();

    expect(store.byUserId(41)?.username, 'local');
  });

  test('a cached content key opens the row with NO derivation at all',
      () async {
    await seedRow(password: 'pw');
    // First session caches it.
    final first = await service();
    await first.onSession(userId: 7, token: 'jwt', password: 'pw');
    expect(first.state, ContactBackupState.ready);

    kdf.calls = 0;
    final second = await service();
    await second.onSession(userId: 7, token: 'jwt');

    expect(second.state, ContactBackupState.ready);
    expect(kdf.calls, 0,
        reason: 'the common login path must not pay PBKDF2-600k');
  });

  test('a cached key belonging to ANOTHER account is never adopted', () async {
    await seedRow(password: 'pw');
    final first = await service();
    await first.onSession(userId: 7, token: 'jwt', password: 'pw');

    expect(await tokens.readContactBackupKey(8), isNull);
  });

  test('a session that cannot open the row is LOCKED and never overwrites it',
      () async {
    await seedRow(password: 'right', contacts: [_friend(41)]);
    final before = backend.row!['blob'];
    final svc = await service();
    svc.attach(store);
    await svc.onSession(userId: 7, token: 'jwt', password: 'wrong');

    expect(svc.state, ContactBackupState.locked);
    // The store then does what it always does on connect: write through.
    await store.update(99, (_) => _friend(99));
    await store.settled;
    await svc.uploadNow();

    expect(backend.puts, isEmpty);
    expect(backend.row!['blob'], before,
        reason: 'a locked session must leave a row others can still open');
  });

  test('the phrase door recovers the key AND mints a wrap for the new password',
      () async {
    await seedRow(password: 'old', phrase: 'abandon ability able');
    final svc = await service();
    svc.attach(store);
    await svc.onSession(
      userId: 7,
      token: 'jwt',
      password: 'brand new',
      phrase: 'abandon ability able',
    );

    expect(svc.state, ContactBackupState.ready);
    // One PUT, carrying the SAME blob and a password wrap the new password
    // opens — without it the next ordinary login would be locked out.
    expect(backend.puts, hasLength(1));
    expect(backend.puts.single['blob'], isNotNull);

    final next = await service();
    await tokens.clearContactBackupKey();
    await next.onSession(userId: 7, token: 'jwt', password: 'brand new');
    expect(next.state, ContactBackupState.ready);
  });

  test('a wrap-only write keeps the blob byte-identical', () async {
    await seedRow(password: 'old', contacts: [_friend(41)]);
    final original = backend.row!['blob'] as String;
    final svc = await service();
    svc.attach(store);
    await svc.onSession(userId: 7, token: 'jwt', password: 'old');
    // The store is deliberately NOT carrying the graph here — this is the
    // Settings password-change door, where nothing has hydrated yet.
    await svc.addWrap(kind: ContactWrapKind.password, secret: 'new');

    expect(backend.puts.single['blob'], original);
    expect(
      (backend.puts.single['wraps'] as List).length,
      2,
      reason: 'the old wrap must survive until other devices prove the new one',
    );
  });

  test('a password login prunes the wrap the previous password opened',
      () async {
    await seedRow(password: 'old', contacts: [_friend(41)]);
    final changing = await service();
    changing.attach(store);
    await changing.onSession(userId: 7, token: 'jwt', password: 'old');
    await changing.addWrap(kind: ContactWrapKind.password, secret: 'new');
    expect((backend.row!['wraps'] as List).length, 2);

    await tokens.clearContactBackupKey();
    final fresh = await service();
    fresh.attach(store);
    await fresh.onSession(userId: 7, token: 'jwt', password: 'new');

    expect((backend.row!['wraps'] as List).length, 1);
    // And the pruned row still opens with the live password.
    await tokens.clearContactBackupKey();
    final again = await service();
    await again.onSession(userId: 7, token: 'jwt', password: 'new');
    expect(again.state, ContactBackupState.ready);
  });

  test('a 409 is re-read and retried once, and the write lands', () async {
    await seedRow(password: 'pw');
    final svc = await service();
    svc.attach(store);
    await svc.onSession(userId: 7, token: 'jwt', password: 'pw');
    await svc.applyRestore();
    await store.update(41, (_) => _friend(41));
    await store.settled;

    backend.nextPutIsStale = true;
    expect(await svc.uploadNow(), isTrue);
    expect(backend.puts, hasLength(2));
    expect(backend.gets, greaterThan(1), reason: 'the retry must re-read');
  });

  test('a row re-keyed behind our back LOCKS the session instead of clobbering',
      () async {
    await seedRow(password: 'pw');
    final svc = await service();
    svc.attach(store);
    await svc.onSession(userId: 7, token: 'jwt', password: 'pw');
    await svc.applyRestore();
    await store.update(41, (_) => _friend(41));
    await store.settled;

    // Another device ran a phrase restore: new content key, new wraps.
    final survivor = Map<String, dynamic>.from(backend.row!);
    survivor['rev'] = 9;
    survivor['ckId'] = 'ZZZZZZZZZZZZZZZZZZZZZZ';
    backend.row = survivor;

    expect(await svc.uploadNow(), isFalse);
    expect(svc.state, ContactBackupState.locked);
    expect(backend.row!['ckId'], 'ZZZZZZZZZZZZZZZZZZZZZZ');
  });

  test('an upload before the restore is applied is refused', () async {
    await seedRow(password: 'pw', contacts: [_friend(41), _friend(42)]);
    final svc = await service();
    svc.attach(store);
    await svc.onSession(userId: 7, token: 'jwt', password: 'pw');

    // applyRestore has NOT run: the store is empty and publishing it would
    // delete both peers server-side.
    expect(await svc.uploadNow(), isFalse);
    expect(backend.puts, isEmpty);
  });

  test('a 401 parks the upload and the next token flushes it', () async {
    await seedRow(password: 'pw');
    final svc = await service();
    svc.attach(store);
    await svc.onSession(userId: 7, token: 'jwt', password: 'pw');
    await svc.applyRestore();
    await store.update(41, (_) => _friend(41));
    await store.settled;

    backend.nextPutStatus = 401;
    expect(await svc.uploadNow(), isFalse);
    final parked = backend.puts.length;

    svc.onToken('fresh-jwt');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(backend.puts.length, greaterThan(parked));
    expect(backend.row!['rev'], 4);
  });

  test('logout destroys the cached content key', () async {
    await seedRow(password: 'pw');
    final svc = await service();
    await svc.onSession(userId: 7, token: 'jwt', password: 'pw');
    expect(await tokens.readContactBackupKey(7), isNotNull);

    await svc.clear();
    expect(await tokens.readContactBackupKey(7), isNull);
  });
}
