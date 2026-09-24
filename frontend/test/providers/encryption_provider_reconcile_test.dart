import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/message_ids.dart';

/// Server reconciliation: destroy the local plaintext of every stored message
/// the server no longer serves.
///
/// This is the only rule that can clean up records written before the metadata
/// stamps existed — records deleted or expired before this feature shipped
/// match no local rule and their server row is already gone, so nothing else
/// would ever revisit them. It is also the most dangerous rule in the file:
/// the persisted plaintext is the ONLY copy (the ciphertext's ratchet key was
/// consumed at first decrypt), so a wrong answer here is permanent loss.
/// Every negative case below is guarding exactly that.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EncryptionService service;
  late EncryptionProvider provider;

  /// Ids each `askServer` batch was asked about, in call order.
  late List<Set<int>> asked;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    service = EncryptionService();
    await service.initialize(
      42,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    provider = EncryptionProvider(service: service);
    asked = [];
  });

  /// An `askServer` that reports every asked id as served EXCEPT [gone].
  Future<Set<int>?> Function(Set<int>) serverWithout(Set<int> gone) {
    return (batch) async {
      asked.add(batch);
      return batch.difference(gone);
    };
  }

  Future<void> seed(Iterable<int> ids) async {
    for (final id in ids) {
      await service.saveDecryptedContent(id, {'content': 'msg $id'});
    }
  }

  Future<bool> stored(int id) async =>
      (await service.getDecryptedContent(id)) != null;

  group('reconcileStoredPlaintext', () {
    test(
      'destroys records the server no longer serves, keeps the rest',
      () async {
        await seed([1, 2, 3]);

        await provider.reconcileStoredPlaintext(serverWithout({2}));

        expect(await stored(1), isTrue);
        expect(
          await stored(2),
          isFalse,
          reason: 'the server dropped it, so nothing will ever return it',
        );
        expect(await stored(3), isTrue);
      },
    );

    test(
      'never asks about, or destroys, a box message: it has no server row',
      () async {
        // Decision 14: a box-delivered message lives under a LOCAL id; the
        // server has never heard of it, so its "not served" is no evidence.
        const local = kFirstLocalMessageId + 7;
        await seed([1, local]);

        await provider.reconcileStoredPlaintext(serverWithout(const {}));

        expect(asked.expand((b) => b), isNot(contains(local)));
        expect(asked.expand((b) => b), contains(1));
        expect(await stored(local), isTrue);
      },
    );

    test(
      'hands the orphaned ids to the message-list owner, and only those',
      () async {
        // Destroying the stored plaintext is half the job: a session that was
        // offline when the row was deleted is still HOLDING it in memory with
        // content decrypted earlier, and the history merge never prunes. Whoever
        // owns the list has to be told which rows died.
        await seed([1, 2, 3]);
        final handed = <Set<int>>[];
        provider.onStoredPlaintextOrphaned = handed.add;

        await provider.reconcileStoredPlaintext(serverWithout({2}));

        expect(handed.single, {2});
      },
    );

    test(
      'hands over nothing when the server still serves everything',
      () async {
        await seed([1, 2]);
        final handed = <Set<int>>[];
        provider.onStoredPlaintextOrphaned = handed.add;

        await provider.reconcileStoredPlaintext(serverWithout(const <int>{}));

        expect(handed, isEmpty);
      },
    );

    test('an unanswered batch hands over nothing', () async {
      // Same one-bit distinction as the purge case below: silence must not be
      // read as "all of these are dead" and evict a live chat from the UI.
      await seed([1, 2]);
      final handed = <Set<int>>[];
      provider.onStoredPlaintextOrphaned = handed.add;

      await provider.reconcileStoredPlaintext((batch) async => null);

      expect(handed, isEmpty);
    });

    test('an unanswered batch destroys NOTHING', () async {
      // The single most important case. "No answer" and "the server has none
      // of these" are one bit apart and one of them wipes the device.
      await seed([1, 2, 3]);

      await provider.reconcileStoredPlaintext((batch) async {
        asked.add(batch);
        return null;
      });

      expect(await stored(1), isTrue);
      expect(await stored(2), isTrue);
      expect(await stored(3), isTrue);
      expect(asked.single, {1, 2, 3});
    });

    test('an empty answer IS authoritative and destroys everything', () async {
      // The legitimate counterpart to the case above: a history the user
      // cleared everywhere really does leave nothing to keep.
      await seed([1, 2]);

      await provider.reconcileStoredPlaintext((batch) async => <int>{});

      expect(await stored(1), isFalse);
      expect(await stored(2), isFalse);
    });

    test(
      'a message saved DURING the pass is never asked about or destroyed',
      () async {
        // The race the snapshot-first ordering exists for: a message that
        // arrives mid-pass is absent from the server's answer only because the
        // answer predates it.
        await seed([1, 2]);

        await provider.reconcileStoredPlaintext((batch) async {
          asked.add(batch);
          await service.saveDecryptedContent(999, {'content': 'just arrived'});
          return batch;
        });

        expect(
          asked.single,
          {1, 2},
          reason: 'the batch was snapshotted before the request went out',
        );
        expect(await stored(999), isTrue);
      },
    );

    test(
      'purges only what was answered when a later batch goes unanswered',
      () async {
        final small = EncryptionProvider(service: service);
        await seed(
          List.generate(
            EncryptionProvider.reconcileBatchSize + 1,
            (i) => i + 1,
          ),
        );

        var call = 0;
        await small.reconcileStoredPlaintext((batch) async {
          asked.add(batch);
          // First batch answered (one id gone), second never answers.
          return call++ == 0 ? batch.difference({1}) : null;
        });

        expect(asked.length, 2);
        expect(asked.first.length, EncryptionProvider.reconcileBatchSize);
        expect(await stored(1), isFalse, reason: 'batch 1 was answered');
        expect(await stored(2), isTrue);
      },
    );
  });

  group('throttling', () {
    test('a completed pass suppresses the next one', () async {
      await seed([1, 2]);

      await provider.reconcileStoredPlaintext(serverWithout(const {}));
      await provider.reconcileStoredPlaintext(serverWithout(const {}));

      expect(asked.length, 1);
    });

    test('force ignores the interval', () async {
      await seed([1, 2]);

      await provider.reconcileStoredPlaintext(serverWithout(const {}));
      await provider.reconcileStoredPlaintext(
        serverWithout(const {}),
        force: true,
      );

      expect(asked.length, 2);
    });

    test('an INCOMPLETE pass does not suppress the next one', () async {
      // A pass that never heard back has proved nothing, so throttling it away
      // would postpone the cleanup indefinitely.
      await seed([1, 2]);

      await provider.reconcileStoredPlaintext((batch) async {
        asked.add(batch);
        return null;
      });
      await provider.reconcileStoredPlaintext(serverWithout({2}));

      expect(asked.length, 2);
      expect(await stored(2), isFalse);
    });

    test('an empty store still stamps, so it stops re-asking', () async {
      await provider.reconcileStoredPlaintext(serverWithout(const {}));
      await provider.reconcileStoredPlaintext(serverWithout(const {}));

      expect(asked, isEmpty);
      expect(await service.lastReconcileAtMs(), isNotNull);
    });

    test('a pass already in flight is not started twice', () async {
      await seed([1, 2]);

      late Future<void> second;
      final first = provider.reconcileStoredPlaintext((batch) async {
        asked.add(batch);
        // Re-enter while this batch is still outstanding, the way a reconnect
        // storm does: every socketReady fires maintenance unawaited.
        second = provider.reconcileStoredPlaintext(serverWithout(const {}));
        await second;
        return batch;
      });
      await first;
      await second;

      expect(asked.length, 1);
    });
  });

  group('account safety', () {
    test('does not purge when the account changed mid-pass', () async {
      // Storage keys are namespaced per user and message ids are global, so
      // purging ids collected under account A against account B's namespace
      // could destroy B's copy of a message they both hold.
      await seed([1, 2]);

      await provider.reconcileStoredPlaintext((batch) async {
        asked.add(batch);
        await service.initialize(
          43,
          checkServerIdentity: () async =>
              const ServerIdentityGuard(exists: false),
        );
        return <int>{};
      });

      await service.initialize(
        42,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: false),
      );
      expect(await stored(1), isTrue);
      expect(await stored(2), isTrue);
    });

    test('does nothing before the service has an account', () async {
      final fresh = EncryptionProvider(service: EncryptionService());

      await fresh.reconcileStoredPlaintext((batch) async {
        asked.add(batch);
        return <int>{};
      });

      expect(asked, isEmpty);
    });
  });

  group('EncryptionService.storedMessageIds', () {
    test(
      'covers both id-keyed stores, including unstamped legacy records',
      () async {
        SharedPreferences.setMockInitialValues({
          // A record from before the metadata stamps existed: no _cid, no
          // _savedAt. Invisible to every other purge rule, which is the whole
          // reason reconciliation exists.
          'e2e_42_decrypted_7': '{"content":"legacy"}',
          'e2e_42_decrypt_raw_v1_8': '{"plaintext":"raw","ciphertext":"c"}',
          // Other keys in the same namespace must not be read as message ids.
          'e2e_42_retired_v1': '[1,2]',
          'e2e_42_purge_pending_v1': '{"ids":[],"cts":[]}',
          'e2e_42_retention_epoch_v1': 1,
          // Another account's record.
          'e2e_43_decrypted_9': '{"content":"not mine"}',
        });
        final scanner = EncryptionService();
        await scanner.initialize(
          42,
          checkServerIdentity: () async =>
              const ServerIdentityGuard(exists: false),
        );

        expect(await scanner.storedMessageIds(), {7, 8});
      },
    );
  });
}
