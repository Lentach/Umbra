import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/backup/history_backup.dart';
import 'package:fireplace/services/backup/history_backup_service.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
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

    test('the filename names the account and the day', () {
      expect(
        HistoryBackupService.filenameFor(7, DateTime.utc(2026, 9, 20)),
        'umbra-7-2026-09-20.$kHistoryBackupFileExtension',
      );
    });
  });
}
