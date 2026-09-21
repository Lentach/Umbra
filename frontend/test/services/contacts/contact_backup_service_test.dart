import 'dart:convert';

import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/auth_token_store.dart';
import 'package:fireplace/services/contacts/contact_backup.dart';
import 'package:fireplace/services/contacts/contact_backup_service.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/socket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/passcode_fakes.dart';

/// `ConnectionProvider` without I/O: the regression below needs the real
/// connect() sequence, not a socket.
class _MuteSocket extends SocketService {
  @override
  bool get isConnected => false;
  @override
  void connect({required String baseUrl, required String token}) {}
  @override
  void disconnect() {}
  @override
  void on(String event, void Function(dynamic) callback) {}
  @override
  void onConnect(void Function() callback) {}
  @override
  void onDisconnect(void Function(dynamic) callback) {}
}

/// The server row, as a test drives it: one in-memory record with the same
/// rev/salt semantics `backend/src/backup/contact-backup.service.ts` enforces.
class _FakeBackend {
  Map<String, dynamic>? row;
  final List<Map<String, dynamic>> puts = [];
  int gets = 0;

  /// Forces the NEXT put to answer 409 — the "another device wrote" case.
  bool nextPutIsStale = false;
  int? nextPutStatus;

  /// Forces the NEXT get to answer this status — the "we cannot tell what the
  /// server holds" case, which is NOT the same as a 404.
  int? nextGetStatus;

  http.Client client() => MockClient((request) async {
    if (request.url.path != '/backup/contacts') {
      return http.Response('not found', 404);
    }
    if (request.method == 'GET') {
      gets++;
      final forcedGet = nextGetStatus;
      if (forcedGet != null) {
        nextGetStatus = null;
        return http.Response('{"message":"bad gateway"}', forcedGet);
      }
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

  // G2 regression (2026-09-21, review M2). The 409 re-read MERGES the
  // server's wrap set so a wrap being ADDED is never lost — and that same
  // merge used to revert every REMOVAL, republishing the superseded password
  // while answering `true`.
  test('a 409 does not resurrect the wrap a prune is removing', () async {
    await seedRow(password: 'old', contacts: [_friend(41)]);
    final changing = await service();
    changing.attach(store);
    await changing.onSession(userId: 7, token: 'jwt', password: 'old');
    await changing.addWrap(kind: ContactWrapKind.password, secret: 'new');
    expect((backend.row!['wraps'] as List).length, 2);

    await tokens.clearContactBackupKey();
    // The prune's PUT loses a race with another device, exactly once.
    backend.nextPutIsStale = true;
    final fresh = await service();
    fresh.attach(store);
    await fresh.onSession(userId: 7, token: 'jwt', password: 'new');

    expect(
      (backend.row!['wraps'] as List).length,
      1,
      reason: 'a superseded password must not survive a lost race',
    );
    // And the surviving wrap is the live one.
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

  test('a 409 on a wrap upload KEEPS the wrap being added', () async {
    // The password-change path: a wrap staged for the NEW password must
    // survive the re-read, or the row stays openable only by the password
    // `resetPassword` is about to destroy and the backup is gone for good.
    await seedRow(password: 'old', contacts: [_friend(41)]);
    final svc = await service();
    svc.attach(store);
    await svc.onSession(userId: 7, token: 'jwt', password: 'old');
    await svc.applyRestore();

    backend.nextPutIsStale = true;
    expect(
      await svc.addWrap(kind: ContactWrapKind.password, secret: 'new'),
      isTrue,
    );

    // The proof that matters: the NEW password opens the row afterwards.
    await tokens.clearContactBackupKey();
    final next = await service();
    await next.onSession(userId: 7, token: 'jwt', password: 'new');
    expect(next.state, ContactBackupState.ready);
  });

  test('a 409 on a wrap upload does not republish the pre-409 blob', () async {
    await seedRow(password: 'pw', contacts: [_friend(41)]);
    final svc = await service();
    svc.attach(store);
    await svc.onSession(userId: 7, token: 'jwt', password: 'pw');
    await svc.applyRestore();

    // Another device publishes a NEWER graph while our wrap PUT is in flight.
    final newer = Map<String, dynamic>.from(backend.row!);
    newer['rev'] = 7;
    newer['blob'] = 'bmV3ZXItZ3JhcGg=';
    backend.row = newer;

    await svc.addWrap(kind: ContactWrapKind.password, secret: 'second');

    expect(
      backend.row!['blob'],
      'bmV3ZXItZ3JhcGg=',
      reason: 'a wrap-only write must never roll the graph back',
    );
  });

  test('an upload is refused while the store still holds unreadable rows',
      () async {
    // The store's RAM view is smaller than the disk, and the blob is a FULL
    // replacement: publishing it would delete peers that still exist here.
    await seedRow(password: 'pw');
    await kv.setString('e2e_7_contact_v1_77', 'not json at all');
    final reopened = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await reopened.open(7);
    expect(reopened.undeterminedCount, 1);

    final svc = await service();
    svc.attach(reopened);
    await svc.onSession(userId: 7, token: 'jwt', password: 'pw');
    await svc.applyRestore();

    expect(await svc.uploadNow(), isFalse);
    expect(backend.puts, isEmpty);
  });

  test('an unchanged graph is not re-uploaded, so no clock moves', () async {
    await seedRow(password: 'pw');
    final svc = await service();
    svc.attach(store);
    await svc.onSession(userId: 7, token: 'jwt', password: 'pw');
    await svc.applyRestore();
    await store.update(41, (_) => _friend(41));
    await store.settled;

    expect(await svc.uploadNow(), isTrue);
    final after = backend.puts.length;

    // A fresh GCM IV makes every re-seal different bytes, so the SERVER's
    // byte compare can never catch this — the gate has to be here.
    expect(await svc.uploadNow(), isTrue);
    expect(backend.puts.length, after, reason: 'no PUT for an unchanged graph');
  });

  test('a pure RESTORE publishes nothing — the wipe itself is not a clock',
      () async {
    await seedRow(password: 'pw', contacts: [_friend(42), _friend(41)]);
    final svc = await service();
    svc.attach(store);
    await svc.onSession(userId: 7, token: 'jwt', password: 'pw');

    expect(await svc.applyRestore(), 2);
    await store.settled;
    // `applyRestore`'s own writes fire `onChanged`; the graph they produce is
    // the one the server already holds, seeded as this session's fingerprint
    // when the blob was opened — including the reversed order it was sealed
    // in, which a non-canonical encoding would read as a change.
    expect(await svc.uploadNow(), isTrue);
    expect(backend.puts, isEmpty,
        reason: 'a storage-loss restore must not re-stamp updatedAt');
    expect(backend.row!['rev'], 3);

    // A real change after the restore still publishes.
    await store.update(43, (_) => _friend(43));
    await store.settled;
    expect(await svc.uploadNow(), isTrue);
    expect(backend.puts, hasLength(1));
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

  // G2 regression (2026-09-21, review M1). `unreachable` covers two causes
  // that must NOT be treated alike: `resetPassword` aborts on ignorance (or
  // one transient 502 at login plus a password change locks the backup for
  // good) and must proceed on a known-absent row (or an account with no
  // backup cannot change its password from a token-resumed session).
  group('rowStatusUnknown', () {
    test('a GET that FAILED is unknown', () async {
      await seedRow(password: 'pw');
      backend.nextGetStatus = 502;
      final svc = await service();
      await svc.onSession(userId: 7, token: 'jwt', password: 'pw');

      expect(svc.state, ContactBackupState.unreachable);
      expect(svc.holdsOpenableBackup, isFalse);
      expect(svc.rowStatusUnknown, isTrue);
    });

    test('a 404 with no password to mint under is NOT unknown', () async {
      final svc = await service();
      // A session resumed from a stored token: no password was typed, so
      // `onSession` is called without one and the 404 cannot be minted over.
      await svc.onSession(userId: 7, token: 'jwt');

      expect(svc.state, ContactBackupState.unreachable);
      expect(
        svc.rowStatusUnknown,
        isFalse,
        reason: 'the server ANSWERED that there is no row',
      );
    });

    test('an opened row is neither unknown nor absent', () async {
      await seedRow(password: 'pw');
      final svc = await service();
      await svc.onSession(userId: 7, token: 'jwt', password: 'pw');

      expect(svc.state, ContactBackupState.ready);
      expect(svc.rowStatusUnknown, isFalse);
      expect(svc.holdsOpenableBackup, isTrue);
    });
  });

  // G2 regression (2026-09-21). `_adopt` latches `_pendingRestore` on EVERY
  // session that opens the blob, and `uploadNow` refuses while it is set. The
  // only production caller of `applyRestore` lives in `ConnectionProvider`, so
  // this drives the real provider rather than calling `applyRestore` by hand
  // the way every test above does — that hand call is exactly what hid the
  // freeze: a populated store never reached it and published nothing again for
  // the life of the session.
  test(
    'an ordinary login on a POPULATED store still publishes later changes',
    () async {
      await seedRow(password: 'pw', contacts: [_friend(41)]);
      // The device already holds the graph: this is every login after the first.
      await store.update(41, (_) => _friend(41));
      await store.settled;

      final svc = await service();
      final connection = ConnectionProvider(socketService: _MuteSocket())
        ..setProviders(
          encryption: EncryptionProvider(),
          friends: FriendsProvider(),
          conversations: ConversationsProvider(),
          messaging: MessagingProvider(),
          contactStore: store,
          contactBackup: svc,
        );
      addTearDown(connection.disconnect);

      await svc.onSession(userId: 7, token: 'jwt', password: 'pw');
      await connection.connect(7, 'jwt', 'http://t');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final before = backend.puts.length;

      // A new friend arrives mid-session — the graph changed and the server
      // copy must follow it, or a later storage loss restores a stale list.
      await store.update(42, (_) => _friend(42));
      await store.settled;
      final published = await svc.uploadNow();

      expect(
        published,
        isTrue,
        reason: 'a populated store must not freeze its own backup',
      );
      expect(backend.puts.length, greaterThan(before));
      // `FakeContentSealer` is `key[0..4] || plaintext`, and the plaintext is
      // the padded `uint32be(len) || json` frame, so the new peer is findable
      // in the decoded bytes — this asserts WHAT was published, not just that
      // a PUT happened.
      final sealed = utf8.decode(
        base64Decode(backend.puts.last['blob'] as String),
        allowMalformed: true,
      );
      expect(
        sealed.contains('peer42'),
        isTrue,
        reason: 'the published blob carries the new contact',
      );
    },
  );
}
