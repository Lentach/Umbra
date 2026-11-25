import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/server_clock.dart';
import 'package:fireplace/utils/e2e_diag_log.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A content store that parks ONE chosen operation until the test releases it,
/// so an account switch can land between two awaits of a running purge pass.
class _GateKv implements ContentKv {
  _GateKv(this._inner);

  final ContentKv _inner;

  /// Parks the first call of the matching operation (after [arm]).
  bool Function(String op, String? key)? _match;
  late Completer<void> _parked;
  late Completer<void> _release;

  /// Arms the gate; the returned future completes once an operation parked.
  Future<void> arm(bool Function(String op, String? key) match) {
    _match = match;
    _parked = Completer<void>();
    _release = Completer<void>();
    return _parked.future;
  }

  void release() => _release.complete();

  Future<void> _maybePark(String op, [String? key]) async {
    final match = _match;
    if (match == null || !match(op, key)) return;
    _match = null;
    _parked.complete();
    await _release.future;
  }

  @override
  Future<void> reload() async {
    await _maybePark('reload');
    return _inner.reload();
  }

  @override
  Future<Map<String, Object>?> authoritativeSnapshot() async {
    await _maybePark('snapshot');
    return _inner.authoritativeSnapshot();
  }

  @override
  String? getString(String key) => _inner.getString(key);

  @override
  int? getInt(String key) => _inner.getInt(key);

  @override
  bool containsKey(String key) => _inner.containsKey(key);

  @override
  Set<String> getKeys() => _inner.getKeys();

  @override
  Future<bool> setString(String key, String value) async {
    await _maybePark('setString', key);
    return _inner.setString(key, value);
  }

  @override
  Future<bool> setInt(String key, int value) async {
    await _maybePark('setInt', key);
    return _inner.setInt(key, value);
  }

  @override
  Future<bool> remove(String key) async {
    await _maybePark('remove', key);
    return _inner.remove(key);
  }
}

/// A retention sweep or a backlog drain that started for account A must never
/// touch account B's records after a switch, although local ids restart at the
/// same base for every account (A3-SVC-D-02).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const accountA = 42;
  const accountB = 43;
  // The same local id in both accounts: the collision the audit names.
  const sharedId = kFirstLocalMessageId + 1;
  // What B itself owes: a DIFFERENT id, so an obligation of A's that leaks
  // into B's backlog shows.
  const otherId = kFirstLocalMessageId + 2;
  const fresh = ServerIdentityGuard(exists: false);
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  late EncryptionService service;
  late EncryptionProvider provider;
  late _GateKv kv;
  late DateTime serverNow;
  late Directory docs;

  Future<void> switchTo(int user) =>
      service.initialize(user, checkServerIdentity: () async => fresh);

  File audioOf(int id) => File('${docs.path}/audio_cache/$id.audio');

  /// A record old enough for the retention rule, written straight into the
  /// store (the service stamps every save with "now").
  Future<void> saveOld(String content) => kv.setString(
    'e2e_${accountA}_decrypted_$sharedId',
    jsonEncode({
      'content': content,
      '_savedAt': serverNow
          .subtract(EncryptionService.retentionWindow + const Duration(days: 1))
          .millisecondsSinceEpoch,
    }),
  );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    E2eDiagLog.clear();
    ServerClock.instance.resetForTest();
    serverNow = DateTime.now().toUtc();
    ServerClock.instance.observe(serverNow);

    // The voice-note cache is one directory for every account.
    docs = Directory.systemTemp.createTempSync('purge_switch_');
    Directory('${docs.path}/audio_cache').createSync(recursive: true);
    audioOf(sharedId).writeAsBytesSync([1, 2, 3]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async => docs.path);

    service = EncryptionService();
    await service.initialize(accountA, checkServerIdentity: () async => fresh);
    kv = _GateKv(await service.contentKv);
    service.debugSetContentKv(kv);
    provider = EncryptionProvider(service: service);

    // B holds a LIVE record under the same id, that id in its ledger, and one
    // owed purge of its own.
    await switchTo(accountB);
    await service.saveDecryptedContent(sharedId, {'content': 'B keeps this'});
    await service.flushDecryptedLedger();
    await service.enqueuePurge({otherId}, const <String>{});
    await switchTo(accountA);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    docs.deleteSync(recursive: true);
    ServerClock.instance.resetForTest();
    E2eDiagLog.clear();
  });

  /// Account B is current, and nothing of A's pass reached it: its record, its
  /// ledger, its retired set and its backlog are as set up, and (unless A's
  /// pass legitimately removed it before the switch) the shared audio file.
  Future<void> expectBUntouched({
    Set<int> owes = const {otherId},
    bool audioKept = true,
  }) async {
    expect(service.activeUserId, accountB);
    expect(
      (await service.getDecryptedContent(sharedId))?['content'],
      'B keeps this',
      reason: "account A's pass must not delete account B's record",
    );
    expect(
      (await service.purgeBacklog()).ids,
      owes,
      reason: "B's backlog holds what B owes, nothing of A's",
    );
    expect(
      await service.decryptedLedgerIds(),
      contains(sharedId),
      reason: "B's ledger entry is not A's to drop",
    );
    expect(
      await service.retiredMessageIds(),
      isEmpty,
      reason: "B's rows are not retired by A's pass",
    );
    if (audioKept) {
      expect(
        audioOf(sharedId).existsSync(),
        isTrue,
        reason: 'the audio cache is not per account: a moved pass keeps off it',
      );
    }
  }

  /// What A still owes once it signs in again: the next drain finishes it.
  Future<void> expectAStillOwes() async {
    await switchTo(accountA);
    expect((await service.purgeBacklog()).ids, contains(sharedId));
  }

  group('a purge pass pinned to the account it started under', () {
    test('sweep: a switch while the obligation is being written', () async {
      await service.saveDecryptedContent(
        sharedId,
        {'content': 'A expired'},
        expiresAt: serverNow.subtract(const Duration(minutes: 6)),
      );
      final parked = kv.arm(
        (op, key) => op == 'setString' && key!.contains('purge'),
      );
      final sweep = provider.sweepDestroyablePlaintext();
      await parked;

      await switchTo(accountB);
      kv.release();
      await sweep;

      await expectBUntouched();
      await switchTo(accountA);
      expect(
        (await service.getDecryptedContent(sharedId))?['content'],
        'A expired',
        reason: 'a refused pass leaves its own account untouched',
      );
    });

    test('sweep: a switch between choosing the ids and writing the retired '
        'mark', () async {
      await saveOld('A old');
      final parked = kv.arm(
        (op, key) => op == 'reload',
      );
      final sweep = provider.sweepDestroyablePlaintext();
      await parked;

      await switchTo(accountB);
      kv.release();
      await sweep;

      await expectBUntouched();
      await switchTo(accountA);
      expect(
        (await service.getDecryptedContent(sharedId))?['content'],
        'A old',
        reason: 'the next sweep of A finds it again',
      );
    });

    test('sweep: a switch while the ledger entry is being dropped', () async {
      await service.saveDecryptedContent(
        sharedId,
        {'content': 'A expired'},
        expiresAt: serverNow.subtract(const Duration(minutes: 6)),
      );
      // B owes the SAME id too, so a confirmation that lands on B shows.
      await switchTo(accountB);
      await service.enqueuePurge({sharedId}, const <String>{});
      await switchTo(accountA);
      final parked = kv.arm(
        (op, key) => op == 'setString' && key!.contains('ledger'),
      );
      final sweep = provider.sweepDestroyablePlaintext();
      await parked;

      await switchTo(accountB);
      kv.release();
      await sweep;

      await expectBUntouched(owes: {sharedId, otherId}, audioKept: false);
    });

    test('drain: a switch while a record is read before it is destroyed',
        () async {
      await service.enqueuePurge({sharedId}, {'ctA'});
      // An expiry stamp keeps the obligation through the one-time amnesty.
      await service.saveDecryptedContent(
        sharedId,
        {'content': 'A owed'},
        expiresAt: serverNow.subtract(const Duration(minutes: 6)),
      );
      // B's outgoing record under the very same ciphertext.
      const bPending = 'e2e_${accountB}_pendsend_v1_ctA';
      await kv.setString(bPending, jsonEncode({'at': 1}));
      // The amnesty pass has run once: only the pre-removal read parks next.
      await service.amnestyUnstampedPurgeObligations();
      final parked = kv.arm((op, key) => op == 'snapshot');
      final drain = provider.drainPurgeBacklog();
      await parked;

      await switchTo(accountB);
      kv.release();
      await drain;

      await expectBUntouched();
      expect(
        kv.containsKey(bPending),
        isTrue,
        reason: "A's ciphertext obligation must not remove B's record",
      );
      await expectAStillOwes();
    });

    test('drain: a switch while the record is being removed', () async {
      await service.enqueuePurge({sharedId}, const <String>{});
      // An expiry stamp keeps the obligation through the one-time amnesty.
      await service.saveDecryptedContent(
        sharedId,
        {'content': 'A owed'},
        expiresAt: serverNow.subtract(const Duration(minutes: 6)),
      );
      await service.amnestyUnstampedPurgeObligations();
      final parked = kv.arm(
        (op, key) => op == 'remove' && key!.contains('decrypted'),
      );
      final drain = provider.drainPurgeBacklog();
      await parked;

      await switchTo(accountB);
      kv.release();
      await drain;

      await expectBUntouched();
      await expectAStillOwes();
    });

    test('drain: a switch after the record is removed, before the ledger and '
        'the audio', () async {
      await service.enqueuePurge({sharedId}, const <String>{});
      await service.saveDecryptedContent(
        sharedId,
        {'content': 'A owed'},
        expiresAt: serverNow.subtract(const Duration(minutes: 6)),
      );
      await service.amnestyUnstampedPurgeObligations();
      // The last store operation of the removal: the raw replay row.
      final parked = kv.arm(
        (op, key) => op == 'remove' && key!.contains('decrypt_raw'),
      );
      final drain = provider.drainPurgeBacklog();
      await parked;

      await switchTo(accountB);
      kv.release();
      await drain;

      await expectBUntouched();
      await expectAStillOwes();
    });

    test('drain: a switch while the ledger entry is being dropped', () async {
      await service.enqueuePurge({sharedId}, const <String>{});
      await service.saveDecryptedContent(
        sharedId,
        {'content': 'A owed'},
        expiresAt: serverNow.subtract(const Duration(minutes: 6)),
      );
      await service.amnestyUnstampedPurgeObligations();
      // B owes the SAME id too, so a confirmation that lands on B shows.
      await switchTo(accountB);
      await service.enqueuePurge({sharedId}, const <String>{});
      await switchTo(accountA);
      final parked = kv.arm(
        (op, key) => op == 'setString' && key!.contains('ledger'),
      );
      final drain = provider.drainPurgeBacklog();
      await parked;

      await switchTo(accountB);
      kv.release();
      await drain;

      await expectBUntouched(owes: {sharedId, otherId}, audioKept: false);
    });
  });

  group('clearing a chat pinned to the account that cleared it', () {
    test('a switch while the chat\'s messages are being listed', () async {
      await service.saveDecryptedContent(
        sharedId,
        {'content': 'A cleared this'},
        conversationId: 5,
      );
      final parked = kv.arm((op, key) => op == 'snapshot');
      final purge = provider.purgeConversations([5]);
      await parked;

      await switchTo(accountB);
      kv.release();
      await purge;

      await expectBUntouched();
    });
  });
}
