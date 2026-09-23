import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// The decrypt ledger's GATE, driven through the real MessagingProvider path.
///
/// The service-level suite proves the ledger stores the right ids. This proves
/// the thing that actually protects data: that a ledger hit stops the decrypt
/// before it reaches the ratchet.
///
/// Why it matters — a record whose plaintext was persisted once and is now gone
/// has a spent ratchet key. Re-decrypting it cannot succeed; it throws
/// DuplicateMessage and burns the row into a permanent "[Decryption failed]",
/// which reads to the user as corruption. The gate turns that into an honest
/// "no longer stored on this device", which a resend fixes.
///
/// The gate is also the only place in this feature that can destroy something
/// (`markRetired` is permanent), so the cases where it must NOT act are worth
/// more than the case where it must.
class _LedgerEncryption extends EncryptionProvider {
  _LedgerEncryption({
    required this.ledger,
    required this.exists,
    this.replayable = false,
    Map<int, Map<String, dynamic>>? persisted,
  }) : persisted = persisted ?? {};

  /// Ids the ledger claims were decrypted before.
  final Set<int> ledger;

  /// Tri-state answer for `recordExists`: true present, false definitely
  /// absent, null undetermined.
  final bool? exists;

  /// Tri-state answer for `rawReplayExists`. `decrypt` serves the raw replay
  /// cache before the ratchet, so while this is true the message is readable
  /// no matter what `recordExists` says.
  final bool? replayable;

  final Map<int, Map<String, dynamic>> persisted;

  int decryptCalls = 0;
  final List<int> retired = [];

  @override
  bool get isE2EReady => true;
  @override
  bool get hadIdentityReset => false;

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  @override
  bool wasDecryptedBefore(int messageId) => ledger.contains(messageId);

  @override
  Future<bool?> recordExists(int messageId) async => exists;

  @override
  Future<bool?> rawReplayExists(int messageId) async => replayable;

  @override
  void invalidateDecryptionCache(int messageId) {
    invalidated.add(messageId);
    ledger.remove(messageId);
  }

  final List<int> invalidated = [];

  @override
  Future<void> retireLostMessage(int messageId) async {
    retired.add(messageId);
  }

  @override
  bool isRetired(int messageId) => retired.contains(messageId);

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
    // A real spent-key retry throws exactly this. If the gate lets anything
    // through, the row is destroyed and the test says so.
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
    String? wireId,
  }) async {
    persisted[messageId] = Map<String, dynamic>.from(data);
  }

  /// (messageId, expiresAt) pairs the self-heal re-stamped.
  final List<(int, DateTime)> stamped = [];

  @override
  Future<void> stampRecordExpiry(int messageId, DateTime expiresAt) async {
    stamped.add((messageId, expiresAt));
  }
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

  const lostId = 18597;

  Future<({MessagingProvider provider, _LedgerEncryption encryption})> run({
    required Set<int> ledger,
    required bool? exists,
    bool? replayable = false,
    Map<int, Map<String, dynamic>>? persisted,
    String? serverEditedAt,
  }) async {
    final encryption = _LedgerEncryption(
      ledger: ledger,
      exists: exists,
      replayable: replayable,
      persisted: persisted,
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

    final row = _encryptedInboundJson(lostId);
    if (serverEditedAt != null) row['editedAt'] = serverEditedAt;
    provider.onMessageHistory({
      'conversationId': 10,
      'messages': [row],
    });

    // The history pass runs async. Settle on the decrypt attempt rather than on
    // the label, because two of these cases deliberately leave the row alone.
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (encryption.decryptCalls > 0 ||
          encryption.retired.isNotEmpty ||
          encryption.invalidated.isNotEmpty) {
        break;
      }
    }
    return (provider: provider, encryption: encryption);
  }

  MessageModel? rowOf(MessagingProvider p) =>
      p.messages.where((m) => m.id == lostId).firstOrNull;

  test('a definitely-lost record is retired instead of re-decrypted', () async {
    final r = await run(ledger: {lostId}, exists: false);

    expect(
      r.encryption.decryptCalls,
      0,
      reason:
          'the ratchet must never be touched for a spent key — that is '
          'what turns a lost row into a permanent [Decryption failed]',
    );
    expect(r.encryption.retired, contains(lostId));
    expect(rowOf(r.provider)?.content, kRetiredMessageLabel);
  });

  test('serving a record self-heals a missing expiry stamp', () async {
    // The 2026-08-02 destruction: a live-decrypted read-mode message persists
    // with NO expiry stamp (the `messageDelivered` stamp is one unacked socket
    // event and can be lost), and an unstamped record no longer expires
    // locally. _restoreFromPersistedPayload is the single point where every
    // served row meets its record, so it must repair the stamp from the
    // server-carried deadline.
    // RELATIVE TO NOW, and it must stay that way. This hardcoded
    // `DateTime.utc(2026, 8, 5, 19)` — a fixed instant that silently became a
    // PAST deadline when the clock passed it on 2026-08-05T19:00Z, after which
    // the test failed on every run: an already-expired served row is skipped
    // before the self-heal is reached, so `stamped` stayed empty and the
    // failure read as "the self-heal broke" rather than "the fixture rotted".
    // Whole-hour precision keeps the ISO round-trip exact for the equality
    // assertion below.
    final nowUtc = DateTime.now().toUtc();
    final expiresAt = DateTime.utc(
      nowUtc.year,
      nowUtc.month,
      nowUtc.day,
      nowUtc.hour,
    ).add(const Duration(days: 1));
    final encryption = _LedgerEncryption(
      ledger: {lostId},
      exists: true,
      persisted: {
        lostId: {'content': 'hello', 'messageType': 'TEXT'},
      },
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

    final row = _encryptedInboundJson(lostId);
    row['expiresAt'] = expiresAt.toIso8601String();
    provider.onMessageHistory({
      'conversationId': 10,
      'messages': [row],
    });

    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (encryption.stamped.isNotEmpty) break;
    }

    expect(encryption.decryptCalls, 0);
    expect(
      encryption.stamped,
      isNotEmpty,
      reason: 'a served row carrying a deadline must repair its record',
    );
    expect(encryption.stamped.first.$1, lostId);
    expect(encryption.stamped.first.$2.toUtc(), expiresAt);
  });

  test(
    'an undetermined probe retires NOTHING and leaves the row alone',
    () async {
      // `recordExists` returns null for an unbound user or any caught exception.
      // Treating that as loss would let a transient storage error permanently
      // retire a message whose bytes are still on disk. The row must stay
      // untouched so a later pass can ask again.
      final r = await run(ledger: {lostId}, exists: null);

      expect(r.encryption.decryptCalls, 0);
      expect(r.encryption.retired, isEmpty);
      expect(rowOf(r.provider)?.content, isNot(kRetiredMessageLabel));
    },
  );

  test('a record that is merely unhydrated is served, not retired', () async {
    final r = await run(
      ledger: {lostId},
      exists: true,
      persisted: {
        lostId: {'content': 'still here'},
      },
    );

    expect(r.encryption.decryptCalls, 0);
    expect(r.encryption.retired, isEmpty);
    expect(rowOf(r.provider)?.content, 'still here');
  });

  test(
    'a raw-replay hit is NEVER retired, even with no plaintext record',
    () async {
      // CRITICAL regression. `decrypt` consults the raw replay cache BEFORE the
      // ratchet and returns its plaintext with zero ratchet work, so a row that
      // cache covers is fully readable even when the `_decrypted_` record is
      // gone. Retiring it destroys readable data — the exact inversion the
      // governing rule forbids. The first version of this gate did precisely
      // that: it asked recordExists, got false, and retired permanently.
      final r = await run(ledger: {lostId}, exists: false, replayable: true);

      expect(
        r.encryption.retired,
        isEmpty,
        reason: 'the raw replay cache can still serve this message',
      );
      expect(
        r.encryption.decryptCalls,
        greaterThan(0),
        reason: 'decrypt must be allowed to run so the replay path resolves it',
      );
    },
  );

  test('an edit-stale record is not served, and is not retired', () async {
    // CRITICAL regression. An edit puts NEW ciphertext under the SAME id, and
    // that key has never been spent. On a cold start there is no local row, so
    // neither edit route clears the ledger; the gate must notice staleness
    // itself. Serving the pre-edit record would hide the edit forever, and
    // retiring it would destroy a message that decrypts cleanly.
    final r = await run(
      ledger: {lostId},
      exists: true,
      persisted: {
        lostId: {
          'content': 'text from BEFORE the edit',
          'editedAt': '2026-01-01T00:00:00.000Z',
        },
      },
      serverEditedAt: '2026-06-01T00:00:00.000Z',
    );

    expect(
      r.encryption.retired,
      isEmpty,
      reason:
          'the edited ciphertext has an UNSPENT key — retiring it would '
          'destroy a message that decrypts cleanly',
    );
    expect(
      r.encryption.invalidated,
      contains(lostId),
      reason:
          'the gate must drop the stale ledger entry rather than serve the '
          'pre-edit record, so the new ciphertext can be decrypted',
    );
    // NB: what the row finally renders is owned by the decrypt-failure
    // fallback further down _decryptMessageAsync, which predates this change.
    // The gate's contract is only: do not serve stale, do not retire.
  });

  test('an id absent from the ledger still reaches the decrypt path', () async {
    // The gate must not become a blanket veto: a message genuinely never
    // decrypted has to be attempted, or nothing would ever decrypt at all.
    final r = await run(ledger: <int>{}, exists: false);

    expect(r.encryption.decryptCalls, greaterThan(0));
    expect(r.encryption.retired, isEmpty);
  });
}
