import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fireplace/services/encryption_service.dart';

/// Legacy pending-send records (`e2e_<uid>_pendsend_v1_<ct>`): an older build
/// wrote them at send time; nothing writes or reads them any more, but they
/// hold outgoing plaintext, so they must still die (72 h TTL prune, clear and
/// account wipe).
///
/// Real [EncryptionService] over the standard mocked storage.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EncryptionService legacy pending-send records', () {
    const uid = 42;
    const pendPrefix = 'e2e_${uid}_pendsend_v1_';

    late EncryptionService service;
    late SharedPreferences prefs;

    String record(DateTime at, String content) => jsonEncode({
      'at': at.millisecondsSinceEpoch,
      'data': {'content': content},
    });

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      service = EncryptionService();
      await service.initialize(
        uid,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: false),
      );
      prefs = await SharedPreferences.getInstance();
    });

    test(
      'prune removes records past 72h or unreadable, keeps fresh ones',
      () async {
        final now = DateTime.now();
        await prefs.setString(
          '${pendPrefix}2:stale',
          record(now.subtract(const Duration(hours: 73)), 'expired'),
        );
        await prefs.setString('${pendPrefix}2:corrupt', 'not json');
        await prefs.setString(
          '${pendPrefix}2:fresh',
          record(now.subtract(const Duration(hours: 1)), 'kept'),
        );

        await service.prunePendingSendRecords();

        expect(prefs.getString('${pendPrefix}2:stale'), isNull);
        expect(prefs.getString('${pendPrefix}2:corrupt'), isNull);
        expect(prefs.getString('${pendPrefix}2:fresh'), isNotNull);
      },
    );

    test('prune never touches another account', () async {
      await prefs.setString(
        'e2e_99_pendsend_v1_2:other',
        record(DateTime.now().subtract(const Duration(hours: 100)), 'theirs'),
      );

      await service.prunePendingSendRecords();

      expect(prefs.getString('e2e_99_pendsend_v1_2:other'), isNotNull);
    });

    test('clearAllKeys wipes pending-send records', () async {
      await prefs.setString('${pendPrefix}2:c1', record(DateTime.now(), 'one'));

      await service.clearAllKeys();

      expect(prefs.getString('${pendPrefix}2:c1'), isNull);
    });

    test('clearDecryptedContentCache wipes pending-send records', () async {
      await prefs.setString(
        '${pendPrefix}2:c3',
        record(DateTime.now(), 'three'),
      );

      final result = await service.clearDecryptedContentCache();

      expect(result.removed, 1);
      expect(result.isComplete, isTrue);
      expect(prefs.getString('${pendPrefix}2:c3'), isNull);
    });
  });
}
