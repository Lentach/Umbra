import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_diag_log.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The terminal-duplicate retirement rule, driven through the real
/// MessagingProvider decrypt path (docs/design/terminal-duplicate-retirement.md
/// §3, falsification plan §5).
///
/// The service suite proves the counter counts. This proves the wiring that
/// can actually retire something: a HISTORY row failing `duplicate` with no
/// ledger entry reaches `_evaluateTerminalDuplicate`, whose guards must each
/// individually block the retire. The cases where the rule must NOT act are
/// worth more than the one where it must.
class _DupEncryption extends EncryptionProvider {
  _DupEncryption({
    required this.ledger,
    required List<bool?> existsScript,
    this.replayable = false,
    Map<int, Map<String, dynamic>>? persisted,
    this.noteReturn,
  }) : _existsScript = List.of(existsScript),
       persisted = persisted ?? {};

  final Set<int> ledger;

  /// Tri-state answers for successive `recordExists` calls; the last value
  /// repeats. Lets a test give the pre-decrypt gate a different answer than
  /// the post-failure evaluation (the edit-stale fall-through shape).
  final List<bool?> _existsScript;

  final bool? replayable;
  final Map<int, Map<String, dynamic>> persisted;

  /// Scripted count returned by [noteTerminalDuplicate]; null = "nothing
  /// recorded" (unbound user / refused write).
  final int? noteReturn;

  int decryptCalls = 0;
  final List<int> retired = [];
  final List<int> noteCalls = [];
  final List<int> clearCalls = [];
  final List<int> invalidated = [];

  @override
  bool get isE2EReady => true;
  @override
  bool get hadIdentityReset => false;

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  @override
  bool wasDecryptedBefore(int messageId) => ledger.contains(messageId);

  @override
  Future<bool?> recordExists(int messageId) async => _existsScript.length > 1
      ? _existsScript.removeAt(0)
      : _existsScript.first;

  @override
  Future<bool?> rawReplayExists(int messageId) async => replayable;

  @override
  void invalidateDecryptionCache(int messageId) {
    invalidated.add(messageId);
    ledger.remove(messageId);
    // The 6a/6b shapes need the catch-path restore (getDecryptedContent) to
    // MISS so the failure reaches the decision + evaluation. Dropping the
    // payload here models "the stale record is not servable this pass";
    // recordExists keeps answering from its own script, so guard (b) is
    // exercised independently of this read.
    persisted.remove(messageId);
  }

  @override
  Future<void> retireLostMessage(int messageId) async {
    retired.add(messageId);
  }

  @override
  bool isRetired(int messageId) => retired.contains(messageId);

  @override
  Future<int?> noteTerminalDuplicate(int messageId) async {
    noteCalls.add(messageId);
    return noteReturn;
  }

  @override
  Future<void> clearTerminalDuplicate(int messageId) async {
    clearCalls.add(messageId);
  }

  @override
  Future<void> flushDecryptedLedger() async {}

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async {
    decryptCalls++;
    throw Exception('DuplicateMessageException — ratchet key already consumed');
  }

  @override
  MessageModel? getCachedDecryption(int messageId) => null;
  @override
  void cacheDecryption(int messageId, MessageModel msg) {}

  @override
  Future<Map<String, dynamic>?> getDecryptedContent(int messageId) async =>
      persisted[messageId];

  @override
  Future<void> saveDecryptedContent(
    int messageId,
    Map<String, dynamic> data, {
    int? conversationId,
    DateTime? createdAt,
    DateTime? expiresAt,
    int? disappearAfterSeconds,
    WireKey? wire,
  }) async {
    persisted[messageId] = Map<String, dynamic>.from(data);
  }

  @override
  Future<void> stampRecordExpiry(int messageId, DateTime expiresAt) async {}
}

Map<String, dynamic> _convJson() => {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': null,
};

Map<String, dynamic> _encryptedInboundJson(int id) => {
  'id': id,
  'content': '[encrypted]',
  'encryptedContent': '2:ciphertext-$id',
  'senderId': 2,
  'senderUsername': 'bob',
  'conversationId': 10,
  'deliveryStatus': 'DELIVERED',
  'messageType': 'TEXT',
  'createdAt': '2026-01-01T00:00:00.000Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const dupId = 19102;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await E2ePersistentDiag.init();
    await E2ePersistentDiag.clear();
    E2eDiagLog.clear();
  });

  Future<({MessagingProvider provider, _DupEncryption encryption})> run({
    Set<int>? ledger,
    required List<bool?> existsScript,
    bool? replayable = false,
    Map<int, Map<String, dynamic>>? persisted,
    int? noteReturn,
    String? serverEditedAt,
  }) async {
    final encryption = _DupEncryption(
      ledger: ledger ?? <int>{},
      existsScript: existsScript,
      replayable: replayable,
      persisted: persisted,
      noteReturn: noteReturn,
    );
    final conversations = ConversationsProvider();
    conversations.setCurrentUserId(1);
    conversations.onConversationsList([_convJson()]);
    conversations.openConversation(10);

    final provider = MessagingProvider();
    provider.setConversationsProvider(conversations);
    provider.setEncryptionProvider(encryption);
    provider.setCurrentUserId(1);
    provider.setToken('tok');
    provider.setIncomingMessageSoundEnabledForTest(false);
    provider.onConnect(false);
    provider.setEmitCallback((_, _) {});
    provider.setActiveConversationIdForTest(10);

    final row = _encryptedInboundJson(dupId);
    if (serverEditedAt != null) row['editedAt'] = serverEditedAt;
    provider.onMessageHistory({
      'conversationId': 10,
      'messages': [row],
    });

    // Settle on the decrypt attempt, then drain the microtask chain the
    // post-failure evaluation runs on.
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (encryption.decryptCalls > 0 || encryption.retired.isNotEmpty) break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return (provider: provider, encryption: encryption);
  }

  MessageModel? rowOf(MessagingProvider p) =>
      p.messages.where((m) => m.id == dupId).firstOrNull;

  test('§5.1 guard (b): a record that EXISTS but was unreadable this pass '
      'resets the counter and retires nothing', () async {
    final r = await run(existsScript: [true], noteReturn: 99);

    expect(r.encryption.decryptCalls, greaterThan(0));
    expect(
      r.encryption.noteCalls,
      isEmpty,
      reason: 'an existing record must never accumulate observations',
    );
    expect(
      r.encryption.clearCalls,
      contains(dupId),
      reason: 'a DEFINITE readable source resets the clock',
    );
    expect(r.encryption.retired, isEmpty);
  });

  test(
    '§5.2 guard (c): a raw-replay-covered row resets and never retires',
    () async {
      final r = await run(
        existsScript: [false],
        replayable: true,
        noteReturn: 99,
      );

      expect(r.encryption.noteCalls, isEmpty);
      expect(r.encryption.clearCalls, contains(dupId));
      expect(r.encryption.retired, isEmpty);
    },
  );

  test('§5.3 tri-state: an undetermined answer changes NOTHING — no count, '
      'no reset, no retire', () async {
    final r = await run(existsScript: [null], noteReturn: 99);

    expect(r.encryption.noteCalls, isEmpty);
    expect(
      r.encryption.clearCalls,
      isEmpty,
      reason: 'null must not erase evidence either',
    );
    expect(r.encryption.retired, isEmpty);
  });

  test('below threshold: observation recorded, row stays [Decryption failed], '
      'nothing retired', () async {
    final r = await run(existsScript: [false], noteReturn: 1);

    expect(r.encryption.noteCalls, contains(dupId));
    expect(r.encryption.retired, isEmpty);
    expect(rowOf(r.provider)?.content, '[Decryption failed]');
    expect(
      E2ePersistentDiag.entries.where(
        (e) => e.contains('DUP_TERMINAL_RETIRED'),
      ),
      isEmpty,
    );
  });

  test('at threshold: the row is retired, rendered honestly, and the durable '
      'evidence is written', () async {
    final r = await run(existsScript: [false], noteReturn: 3);

    expect(r.encryption.retired, contains(dupId));
    expect(
      r.encryption.clearCalls,
      contains(dupId),
      reason:
          'the counter is dropped on retire (§3.1) so a '
          'retired-set-load-failure boot cannot re-retire and burn a '
          'second durable for the same id',
    );
    expect(
      rowOf(r.provider)?.content,
      kRetiredMessageLabel,
      reason:
          'an honest "no longer stored" beats a scary '
          '[Decryption failed] for a row a resend can fix',
    );
    expect(
      E2ePersistentDiag.entries.where(
        (e) => e.contains('DUP_TERMINAL_RETIRED') && e.contains('$dupId'),
      ),
      hasLength(1),
    );
  });

  test('a refused observation (note returns null) retires nothing', () async {
    final r = await run(existsScript: [false], noteReturn: null);

    expect(r.encryption.noteCalls, contains(dupId));
    expect(r.encryption.retired, isEmpty);
    expect(rowOf(r.provider)?.content, '[Decryption failed]');
  });

  test('§5.6a partition: an in-ledger edit-stale row with its stale record '
      'PRESENT records nothing — guard (b) carries the safety', () async {
    final r = await run(
      ledger: {dupId},
      // Gate read AND evaluation read both see the record present.
      existsScript: [true],
      persisted: {
        dupId: {'content': 'old text', 'editedAt': '2026-01-01T00:00:00.000Z'},
      },
      serverEditedAt: '2026-02-01T00:00:00.000Z',
      noteReturn: 99,
    );

    expect(
      r.encryption.invalidated,
      contains(dupId),
      reason:
          'the edit-stale fall-through must have run for this test '
          'to exercise the R2 shape',
    );
    expect(r.encryption.decryptCalls, greaterThan(0));
    expect(r.encryption.noteCalls, isEmpty);
    expect(r.encryption.retired, isEmpty);
  });

  test(
    '§5.6b partition: an edit-stale row whose record and replay are '
    'verifiably ABSENT accumulates observations like any other row',
    () async {
      final r = await run(
        ledger: {dupId},
        // Gate sees the stale record; the post-failure evaluation sees it gone.
        existsScript: [true, false],
        persisted: {
          dupId: {
            'content': 'old text',
            'editedAt': '2026-01-01T00:00:00.000Z',
          },
        },
        serverEditedAt: '2026-02-01T00:00:00.000Z',
        noteReturn: 1,
      );

      expect(r.encryption.invalidated, contains(dupId));
      expect(
        r.encryption.noteCalls,
        contains(dupId),
        reason:
            'pins the intended honest-retire semantics for a row whose '
            'edit was consumed elsewhere and never persisted anywhere',
      );
      expect(r.encryption.retired, isEmpty, reason: 'count 1 < threshold');
    },
  );

  test('the emitted DECRYPT_DECISION line matches the dedupe substrings — '
      'pins the call-site payload format', () async {
    await run(existsScript: [false], noteReturn: 1);

    final decisions = E2ePersistentDiag.entries
        .where((e) => e.contains(' DECRYPT_DECISION | '))
        .toList();
    expect(decisions, hasLength(1));
    expect(
      decisions.single,
      contains('{msgId: $dupId,'),
      reason:
          'recordDeduped matches on this exact prefix; a payload '
          'reorder would silently disable the dedupe',
    );
    expect(decisions.single, contains(' kind: duplicate,'));
  });
}
