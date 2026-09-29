import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/backup/history_backup.dart';
import 'package:fireplace/services/backup/history_backup_service.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/passcode_fakes.dart';

HistoryBackupCodec _codec() =>
    HistoryBackupCodec(kdf: FakePasscodeKdf(), sealer: FakeContentSealer());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HistoryBackupCodec', () {
    test('a sealed file round-trips every row verbatim', () async {
      final codec = _codec();
      const payload = HistoryBackupPayload(
        userId: 7,
        records: {
          'e2e_7_decrypted_101': '{"c":"hello"}',
          'e2e_7_decrypt_raw_v1_101': '{"raw":true}',
        },
        contacts: {'e2e_7_contact_v1_42': '{"v":1}'},
      );

      final opened = await codec.open(
        await codec.seal(payload, 'correct horse'),
        'correct horse',
      );

      expect(opened.userId, 7);
      expect(opened.records['e2e_7_decrypted_101'], '{"c":"hello"}');
      expect(opened.records['e2e_7_decrypt_raw_v1_101'], '{"raw":true}');
      expect(opened.contacts['e2e_7_contact_v1_42'], '{"v":1}');
    });

    test('a wrong passphrase is WrongPassphrase, never Corrupt', () async {
      final codec = _codec();
      final bytes = await codec.seal(
        const HistoryBackupPayload(userId: 7, records: {}, contacts: {}),
        'right',
      );

      await expectLater(
        codec.open(bytes, 'wrong'),
        throwsA(isA<HistoryBackupWrongPassphrase>()),
      );
    });

    test('a file that is not an Umbra backup is Corrupt, never WrongPassphrase',
        () async {
      final codec = _codec();

      // Each of these is a distinct way a user picks the wrong file, and none
      // of them may be reported as "you typed the wrong passphrase".
      for (final bad in [
        Uint8List.fromList(utf8.encode('not json at all')),
        Uint8List.fromList(utf8.encode(jsonEncode({'fp': 'something-else'}))),
        Uint8List.fromList(
          utf8.encode(jsonEncode({'fp': kHistoryBackupMagic, 'v': 99})),
        ),
      ]) {
        await expectLater(
          codec.open(bad, 'any'),
          throwsA(isA<HistoryBackupCorrupt>()),
        );
      }
    });

    test('a hostile iteration count is refused BEFORE the derivation runs',
        () async {
      final kdf = FakePasscodeKdf();
      final codec = HistoryBackupCodec(kdf: kdf, sealer: FakeContentSealer());
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'fp': kHistoryBackupMagic,
            'v': kHistoryBackupVersion,
            'salt': base64Encode(List<int>.filled(16, 0)),
            'iterations': 900000000,
            'blob': base64Encode(List<int>.filled(32, 0)),
          }),
        ),
      );

      await expectLater(
        codec.open(bytes, 'any'),
        throwsA(isA<HistoryBackupCorrupt>()),
      );
      expect(kdf.calls, 0, reason: 'the phone must not pay for a hostile file');
    });

    test('the envelope keeps the parameters a bare device needs in the clear',
        () async {
      final bytes = await _codec().seal(
        const HistoryBackupPayload(userId: 7, records: {}, contacts: {}),
        'pw',
      );
      final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

      expect(envelope['fp'], kHistoryBackupMagic);
      expect(envelope['iterations'], kHistoryBackupKdfIterations);
      expect(base64Decode(envelope['salt'] as String).length, 16);
      // …and nothing readable beyond them.
      expect(envelope.keys.toSet(), {'fp', 'v', 'salt', 'iterations', 'blob'});
    });
  });

  group('HistoryBackupService', () {
    late ContentKv kv;
    late HistoryBackupService service;
    Uint8List? emitted;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      emitted = null;
      kv = await PrefsContentKv.open();
      service = HistoryBackupService(
        open: () async => kv,
        codec: _codec(),
        emit: (bytes, _) async => emitted = bytes,
      );
    });

    test('an export takes both record families and the contacts, and nothing '
        'belonging to another account', () async {
      await kv.setString('e2e_7_decrypted_1', 'mine');
      await kv.setString('e2e_7_decrypt_raw_v1_1', 'mine-raw');
      await kv.setString('e2e_7_contact_v1_42', 'peer');
      await kv.setString('e2e_8_decrypted_1', 'theirs');
      await kv.setString('e2e_7_retired_v1', 'control-record');

      final counts = await service.exportAndShare(userId: 7, passphrase: 'pw');

      expect(counts, (records: 2, contacts: 1));
      final payload = await _codec().open(emitted!, 'pw');
      expect(
        payload.records.keys,
        containsAll(['e2e_7_decrypted_1', 'e2e_7_decrypt_raw_v1_1']),
      );
      expect(payload.records.containsKey('e2e_8_decrypted_1'), isFalse);
      // Control records are machinery, not history; restoring them would
      // reinstate a retired-key set the device has moved past.
      expect(payload.records.containsKey('e2e_7_retired_v1'), isFalse);
    });

    test('an import writes missing rows and NEVER overwrites a live one',
        () async {
      final bytes = await _codec().seal(
        const HistoryBackupPayload(
          userId: 7,
          records: {'e2e_7_decrypted_1': 'from-backup',
            'e2e_7_decrypted_2': 'new'},
          contacts: {'e2e_7_contact_v1_42': 'peer'},
        ),
        'pw',
      );
      await kv.setString('e2e_7_decrypted_1', 'live-and-newer');

      final counts = await service.importBytes(
        userId: 7,
        bytes: bytes,
        passphrase: 'pw',
      );

      expect(counts, (records: 1, contacts: 1));
      expect(kv.getString('e2e_7_decrypted_1'), 'live-and-newer');
      expect(kv.getString('e2e_7_decrypted_2'), 'new');
      expect(kv.getString('e2e_7_contact_v1_42'), 'peer');
    });

    test("another account's backup is refused before anything is written",
        () async {
      final bytes = await _codec().seal(
        const HistoryBackupPayload(
          userId: 8,
          records: {'e2e_8_decrypted_1': 'theirs'},
          contacts: {},
        ),
        'pw',
      );

      await expectLater(
        service.importBytes(userId: 7, bytes: bytes, passphrase: 'pw'),
        throwsA(isA<HistoryBackupForeignAccount>()),
      );
      expect(kv.getKeys(), isEmpty);
    });

    test('a row whose key names another account is dropped, not re-namespaced',
        () async {
      // A hand-edited or version-skewed file: the header says account 7 while
      // a row is keyed for 8. Writing it would create a row account 7's own
      // sweeps never reach.
      final bytes = await _codec().seal(
        const HistoryBackupPayload(
          userId: 7,
          records: {'e2e_8_decrypted_1': 'smuggled', 'e2e_7_decrypted_1': 'ok'},
          contacts: {},
        ),
        'pw',
      );

      final counts = await service.importBytes(
        userId: 7,
        bytes: bytes,
        passphrase: 'pw',
      );

      expect(counts.records, 1);
      expect(kv.containsKey('e2e_8_decrypted_1'), isFalse);
    });

    test('a crafted file cannot plant anything but the two record families',
        () async {
      // The file format is documented and the attacker picks the passphrase
      // they hand the victim with it. On the device this path targets — one
      // whose store was just destroyed — nothing is present, so `existing`
      // blocks none of it. Only the prefixes the EXPORT produces may land.
      final bytes = await _codec().seal(
        const HistoryBackupPayload(
          userId: 7,
          records: {
            'e2e_7_decrypted_1': 'legitimate',
            'e2e_7_decrypt_raw_v1_1': 'legitimate-raw',
            // Control rows and identity state living in the same namespace.
            'e2e_7_retired_v1': 'retire-everything',
            'e2e_7_devicelist_pins_v1': 'pin-a-hostile-device-list',
            'e2e_7_peer_identity_changed_v1': 'suppress-the-warning',
            'e2e_7_pendsend_v1_abc': 'replay-me',
          },
          contacts: {},
        ),
        'pw',
      );

      final counts = await service.importBytes(
        userId: 7,
        bytes: bytes,
        passphrase: 'pw',
      );

      expect(counts.records, 2);
      for (final planted in [
        'e2e_7_retired_v1',
        'e2e_7_devicelist_pins_v1',
        'e2e_7_peer_identity_changed_v1',
        'e2e_7_pendsend_v1_abc',
      ]) {
        expect(kv.containsKey(planted), isFalse, reason: planted);
      }
    });

    test('the filename names the day and NEVER the account', () {
      final name = HistoryBackupService.filenameFor(DateTime.utc(2026, 9, 20));
      expect(name, 'umbra-backup-2026-09-20.$kHistoryBackupFileExtension');
      // The share sheet hands this string to Drive/Gmail/Downloads in
      // cleartext; an account id there undoes the sealing it sits next to.
      expect(name, isNot(contains('7')));
    });
  });

  // After a storage loss the box hands out local ids from 2^48 again, and the
  // file's box messages hold ids from the same range: the file must never
  // lose a message to a live one that happens to share its id.
  group('HistoryBackupService local ids', () {
    const cid = 281474976710658;
    const x = kFirstLocalMessageId;
    late EncryptionService enc;
    late ContactStore store;
    late HistoryBackupService service;
    late int allocations;
    late int tombstoneReads;

    Future<Uint8List> file(Map<String, String> records) => _codec().seal(
      HistoryBackupPayload(userId: 7, records: records, contacts: const {}),
      'pw',
    );

    Future<String?> content(int id) async =>
        (await enc.getDecryptedContent(id))?['content'] as String?;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      enc = EncryptionService();
      await enc.initialize(
        7,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: false),
      );
      store = ContactStore(
        open: () => enc.contentKv,
        lock: <T>(_, action) => action(),
        accepts: (_) => true,
      );
      await store.open(7);
      allocations = 0;
      tombstoneReads = 0;
      service = HistoryBackupService(
        open: () => enc.contentKv,
        codec: _codec(),
        allocateLocalIds: (count) {
          allocations++;
          return store.allocateLocalIds(count);
        },
        tombstones: () {
          tombstoneReads++;
          return enc.boxTombstoneSnapshot();
        },
        onImported: enc.forgetWireClaims,
      );
      // A box message received after the loss, before the import, and the
      // wire-id cache the box dedups against, built while it is the only one.
      expect(await store.allocateLocalId(), x);
      await enc.saveDecryptedContent(
        x,
        {'content': 'live', 'senderId': 2},
        conversationId: cid,
        wire: (senderId: 2, wireId: 'live-wire'),
      );
      expect(await enc.wireHolder((senderId: 2, wireId: 'live-wire')), x);
    });

    test('every local id in the file comes from ONE allocation, each unique '
        'and past every id the device holds', () async {
      final bytes = await file({
        for (var i = 0; i < 3; i++)
          'e2e_7_decrypted_${x + i}': jsonEncode({
            'content': 'file-$i',
            '_cid': cid,
            '_wid': 'file-wire-$i',
            '_wsid': 2,
          }),
        // A replay row alone: no record key names its new id, so only the
        // allocator's counter keeps the box from handing that id out again.
        'e2e_7_decrypt_raw_v1_${x + 7}': jsonEncode({
          'ciphertext': '3:old-device',
          'plaintext': 'x',
        }),
      });

      await service.importBytes(userId: 7, bytes: bytes, passphrase: 'pw');

      expect(allocations, 1);
      final moved = [
        for (var i = 0; i < 3; i++)
          await enc.wireHolder((senderId: 2, wireId: 'file-wire-$i')),
      ].whereType<int>().toList();
      expect(moved.toSet(), hasLength(3));
      expect(moved, everyElement(greaterThan(x)));
      expect(
        [for (final id in moved) await content(id)],
        ['file-0', 'file-1', 'file-2'],
      );
      final imported = [
        for (final key in (await enc.contentKv).getKeys())
          if (RegExp(r'^e2e_7_decrypt(ed|_raw_v1)_(\d+)$').firstMatch(key)
              case final m?)
            int.parse(m.group(2)!),
      ];
      final highest = imported.reduce((a, b) => a > b ? a : b);
      expect(await store.allocateLocalId(), greaterThan(highest));
    });

    test('a message deleted for everyone on this device stays out, and the '
        'tombstones are read once per import', () async {
      const gone = (senderId: 2, wireId: 'gone-wire');
      await enc.addBoxTombstone(gone);
      final bytes = await file({
        'e2e_7_decrypted_${x + 3}': jsonEncode({
          'content': 'deleted words',
          '_cid': cid,
          '_wid': 'gone-wire',
          '_wsid': 2,
        }),
        'e2e_7_decrypted_${x + 4}': jsonEncode({
          'content': 'kept words',
          '_cid': cid,
          '_wid': 'kept-wire',
          '_wsid': 2,
        }),
      });

      final counts = await service.importBytes(
        userId: 7,
        bytes: bytes,
        passphrase: 'pw',
      );

      expect(counts.records, 1);
      expect(await enc.wireHolder(gone), isNull);
      expect(await enc.wireHolder((senderId: 2, wireId: 'kept-wire')), isNotNull);
      expect(tombstoneReads, 1);
    });

    test('a file message at a live local id moves to a fresh one, and what '
        'the file names it by follows', () async {
      final bytes = await file({
        'e2e_7_decrypted_$x': jsonEncode({
          'content': 'from-file',
          'senderId': 2,
          '_cid': cid,
          '_wid': 'file-wire',
          '_wsid': 2,
        }),
        'e2e_7_decrypted_${x + 1}': jsonEncode({
          'content': 'reply',
          'senderId': 7,
          'replyTo': {
            'id': x,
            'content': 'from-file',
            'senderUsername': 'peer',
            'messageType': 'TEXT',
            'wireId': 'file-wire',
            'senderId': 2,
          },
          '_cid': cid,
          '_wid': 'reply-wire',
          '_wsid': 7,
        }),
      });

      final counts = await service.importBytes(
        userId: 7,
        bytes: bytes,
        passphrase: 'pw',
      );

      expect(counts.records, 2);
      expect(await content(x), 'live');
      final moved = await enc.wireHolder((senderId: 2, wireId: 'file-wire'));
      expect(moved, isNotNull);
      expect(moved, isNot(x));
      expect(await content(moved!), 'from-file');
      final reply = await enc.wireHolder((senderId: 7, wireId: 'reply-wire'));
      final quoted = (await enc.getDecryptedContent(reply!))!['replyTo'];
      expect(quoted, containsPair('id', moved));
      // The allocator's counter moved past both: the next box message can
      // never land on an imported one.
      expect(await store.allocateLocalId(), greaterThan(moved > reply ? moved : reply));
    });

    test('importing the same file twice writes its messages once', () async {
      final bytes = await file({
        'e2e_7_decrypted_$x': jsonEncode({
          'content': 'from-file',
          '_cid': cid,
          '_wid': 'file-wire',
          '_wsid': 2,
        }),
      });

      await service.importBytes(userId: 7, bytes: bytes, passphrase: 'pw');
      final again = await service.importBytes(
        userId: 7,
        bytes: bytes,
        passphrase: 'pw',
      );

      expect(again.records, 0);
      expect(await enc.wireHolder((senderId: 2, wireId: 'file-wire')), isNotNull);
    });

    test('a message the device already holds by its wire id is not imported '
        'again', () async {
      final bytes = await file({
        'e2e_7_decrypted_${x + 5}': jsonEncode({
          'content': 'live',
          '_cid': cid,
          '_wid': 'live-wire',
          '_wsid': 2,
        }),
        // Its replay row goes with it: nothing of it is written again.
        'e2e_7_decrypt_raw_v1_${x + 5}': jsonEncode({
          'ciphertext': '3:old-device',
          'plaintext': 'live',
        }),
      });

      final counts = await service.importBytes(
        userId: 7,
        bytes: bytes,
        passphrase: 'pw',
      );

      expect(counts.records, 0);
      expect(await enc.wireHolder((senderId: 2, wireId: 'live-wire')), x);
    });

    test('with no allocator answering, a file holding local ids is refused '
        'before anything is written', () async {
      store.close();
      final bytes = await file({
        'e2e_7_decrypted_1': jsonEncode({'content': 'server-row'}),
        'e2e_7_decrypted_$x': jsonEncode({'content': 'from-file'}),
      });

      await expectLater(
        service.importBytes(userId: 7, bytes: bytes, passphrase: 'pw'),
        throwsA(isA<HistoryBackupLocalIdsUnavailable>()),
      );
      expect(await enc.getDecryptedContent(1), isNull);
      expect(await content(x), 'live');
    });

    test("a kept request's replay id moves off a live one", () async {
      // Its accept replays the decrypt under `lid`, and drops the replay row
      // there afterwards: left at x, it would drop the live message's row.
      final bytes = await _codec().seal(
        HistoryBackupPayload(
          userId: 7,
          records: const {},
          contacts: {
            'e2e_7_contact_v1_42': jsonEncode({
              'userId': 42,
              'box': {
                'at': 0,
                'kept': [
                  {'dev': 1, 'sig': '3:AAAA', 'at': 0, 'lid': x},
                ],
              },
            }),
          },
        ),
        'pw',
      );

      await service.importBytes(userId: 7, bytes: bytes, passphrase: 'pw');

      final row = jsonDecode(
        (await enc.contentKv).getString('e2e_7_contact_v1_42')!,
      );
      final lid = switch (row) {
        {'box': {'kept': [{'lid': final Object? lid}]}} => lid,
        _ => null,
      };
      expect(lid, isA<int>().having(isLocalMessageId, 'local', isTrue));
      expect(lid, isNot(x));
    });
  });
}
