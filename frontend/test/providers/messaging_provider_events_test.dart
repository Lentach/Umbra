import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/reactions/reaction_display.dart';
import 'package:fireplace/services/reactions/reaction_key_lookup.dart';
import 'package:fireplace/services/reactions/reaction_token_codec.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory `K_react` custody, standing in for the content-key store.
///
/// [locked] reproduces the passcode-locked vault, which must read as
/// "cannot answer" and NEVER as "no key exists" — conflating those re-keys the
/// conversation and orphans every existing chip.
class _MemoryReactionStore extends EncryptionService {
  _MemoryReactionStore({this.locked = false});

  final bool locked;
  final Map<int, String> keys = <int, String>{};
  final Map<int, int> epochs = <int, int>{};

  /// Whether the stored record is still provisional — i.e. saved before the
  /// server confirmed the upload.
  final Map<int, bool> pendings = <int, bool>{};

  @override
  Future<ReactionKeyLookup> loadReactionKey(int conversationId) async {
    if (locked) return const ReactionKeyUnavailable('locked');
    final key = keys[conversationId];
    return key == null
        ? const ReactionKeyAbsent()
        // The epoch actually recorded, not a constant: a fake that lies here
        // would hide an epoch mismatch rather than expose it.
        : ReactionKeyFound(
            epoch: epochs[conversationId] ?? 0,
            keyB64: key,
            pending: pendings[conversationId] ?? false,
          );
  }

  @override
  Future<bool> saveReactionKey({
    required int conversationId,
    required int epoch,
    required String keyB64,
    bool pending = false,
  }) async {
    if (locked) return false;
    keys[conversationId] = keyB64;
    epochs[conversationId] = epoch;
    pendings[conversationId] = pending;
    return true;
  }

  @override
  Future<void> dropReactionKey(int conversationId) async {
    keys.remove(conversationId);
    epochs.remove(conversationId);
    pendings.remove(conversationId);
  }
}

/// Encryption fake that succeeds immediately — happy send path.
class _WorkingEncryption extends EncryptionProvider {
  _WorkingEncryption({EncryptionService? store}) : _store = store;

  final EncryptionService? _store;

  @override
  EncryptionService get encryptionService => _store ?? super.encryptionService;

  final List<Set<int>> localPurges = <Set<int>>[];
  final List<Set<int>> conversationPurges = <Set<int>>[];
  final Map<int, DateTime> stampedExpiries = <int, DateTime>{};
  final List<int> retiredChecks = <int>[];
  var loadRetiredIdsCalls = 0;

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  /// Both accounts are non-enrolled, i.e. single device 1 — the shape the
  /// server affirms with `authorization: null`. The reaction-key fan-out
  /// RESOLVES lists rather than guessing, so a fake that cannot answer this
  /// makes every key creation refuse.
  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    Duration timeout = const Duration(seconds: 10),
  }) async => const VerifiedDeviceList.notEnrolled();

  @override
  Future<String> encrypt(
    int recipientId,
    String plaintext, {
    int deviceId = 1,
  }) async => 'ciphertext';

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async => jsonEncode(E2eEnvelope.build('decrypted'));

  @override
  Future<Map<String, dynamic>?> getDecryptedContent(int messageId) async =>
      null;

  @override
  Future<void> saveDecryptedContent(
    int messageId,
    Map<String, dynamic> data, {
    int? conversationId,
    DateTime? createdAt,
    DateTime? expiresAt,
    int? disappearAfterSeconds,
    WireKey? wire,
  }) async {}

  @override
  Future<void> stampRecordExpiry(int messageId, DateTime expiresAt) async {
    stampedExpiries[messageId] = expiresAt;
  }

  @override
  bool isRetired(int messageId) {
    retiredChecks.add(messageId);
    return false;
  }

  @override
  Future<void> loadRetiredIds() async {
    loadRetiredIdsCalls++;
  }

  @override
  Future<PlaintextPurgeResult> purgeLocalPlaintext(
    Iterable<int> messageIds, {
    Iterable<String> ciphertexts = const <String>[],
  }) async {
    localPurges.add(messageIds.toSet());
    return const PlaintextPurgeResult.empty();
  }

  @override
  Future<PlaintextPurgeResult> purgeConversations(
    Iterable<int> conversationIds, {
    Iterable<String> ciphertexts = const <String>[],
  }) async {
    conversationPurges.add(conversationIds.toSet());
    return const PlaintextPurgeResult.empty();
  }
}

/// Like [_WorkingEncryption], but its `decrypt` answers a raw `K_react`
/// instead of a message envelope — i.e. a device whose reaction-key mailbox
/// row opens successfully.
class _KeyBearingEncryption extends _WorkingEncryption {
  _KeyBearingEncryption(this.keyB64, {super.store});

  final String keyB64;

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async => keyB64;
}

/// Encryption fake whose ensureSession never completes — rows stay SENDING.
class _StuckEncryption extends _WorkingEncryption {
  final _never = Completer<void>();


  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) =>
      _never.future;
}

Map<String, dynamic> _convJson() => {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': null,
};

Map<String, dynamic> _plainIncomingJson(int id) => {
  'id': id,
  'content': 'hello there',
  'senderId': 2,
  'senderUsername': 'bob',
  'conversationId': 10,
  'deliveryStatus': 'DELIVERED',
  'messageType': 'TEXT',
  'createdAt': '2026-01-01T00:00:00.000Z',
};

void main() {
  late MessagingProvider provider;
  late ConversationsProvider conversations;
  late List<Map<String, dynamic>> emitted;

  /// The conversation epoch a stubbed server reports, or null for "no server
  /// answer at all" (every acquisition then fails on timeout, as offline).
  int? serverReactionKeyEpoch;

  /// A wrapped key the stubbed mailbox serves to this device, or null for
  /// "no row for you" (the common case).
  String? serverWrappedKey;

  /// When true, every upload answer is preceded by one naming a DIFFERENT
  /// conversation — the mis-correlation the single upload slot must reject.
  var answerWrongConversationFirst = false;

  /// Stubs the two reaction-key round trips: the mailbox holds
  /// [serverWrappedKey] for this device at [currentEpoch] (or nothing), and an
  /// upload is accepted at the next epoch. The stubbing itself lives in
  /// [wire]'s emit callback, which is where the socket would be.
  void answerReactionKeyRequests({required int currentEpoch}) {
    serverReactionKeyEpoch = currentEpoch;
  }

  void wire(EncryptionProvider encryption) {
    provider = MessagingProvider();
    conversations = ConversationsProvider();
    emitted = <Map<String, dynamic>>[];
    serverReactionKeyEpoch = null;
    serverWrappedKey = null;
    answerWrongConversationFirst = false;

    conversations.setCurrentUserId(1);
    conversations.onConversationsList([_convJson()]);
    conversations.openConversation(10);

    provider.setConversationsProvider(conversations);
    provider.setEncryptionProvider(encryption);
    provider.setCurrentUserId(1);
    provider.setToken('tok');
    provider.setIncomingMessageSoundEnabledForTest(false);
    provider.onConnect(false);
    provider.setEmitCallback((event, data) {
      emitted.add({'event': event, 'data': data});
      final epoch = serverReactionKeyEpoch;
      if (epoch == null) return;
      // Answered synchronously: the provider registers its completer before
      // it emits, so this lands exactly where a socket answer would.
      if (event == 'fetchReactionKey') {
        final wrapped = serverWrappedKey;
        provider.onReactionKeyResponse({
          'conversationId': (data as Map<String, dynamic>)['conversationId'],
          'epoch': epoch,
          'senderUserId': wrapped == null ? null : 2,
          'senderDeviceId': wrapped == null ? null : 1,
          'ciphertext': wrapped,
        });
      } else if (event == 'uploadReactionKey') {
        final conversationId =
            (data as Map<String, dynamic>)['conversationId'] as int;
        if (answerWrongConversationFirst) {
          provider.onReactionKeyUploaded({
            'conversationId': conversationId + 89,
            'success': true,
            'epoch': epoch + 1,
          });
        }
        provider.onReactionKeyUploaded({
          'conversationId': conversationId,
          'success': true,
          'epoch': epoch + 1,
        });
      }
    });
    provider.setActiveConversationIdForTest(10);
  }

  group('onMessageSent temp -> real replacement', () {
    setUp(() => wire(_WorkingEncryption()));

    test('replaces the optimistic temp row with the server row and restores '
        'plaintext from pending send content', () async {
      provider.sendMessage('secret plan');
      // Optimistic row is visible immediately.
      final temp = provider.messages.single;
      expect(temp.id, isNegative);
      expect(temp.deliveryStatus, MessageDeliveryStatus.sending);
      expect(temp.tempId, isNotNull);
      expect(temp.content, 'secret plan');

      // Let _encryptAndSend finish and capture the emitted tempId.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final sendEvent = emitted.singleWhere((e) => e['event'] == 'sendMessage');
      final tempId = (sendEvent['data'] as Map)['tempId'] as String;
      expect(tempId, temp.tempId);

      // Server confirms: real id, '[encrypted]' content, echoed tempId.
      provider.onMessageSent({
        'id': 555,
        'content': '[encrypted]',
        'encryptedContent': 'ciphertext',
        'senderId': 1,
        'senderUsername': 'alice',
        'conversationId': 10,
        'deliveryStatus': 'SENT',
        'messageType': 'TEXT',
        'createdAt': '2026-01-01T00:00:01.000Z',
        'tempId': tempId,
      });

      // Exactly one row: temp gone, real id in, plaintext restored.
      expect(provider.messages, hasLength(1));
      final real = provider.messages.single;
      expect(real.id, 555);
      expect(
        real.content,
        'secret plan',
        reason:
            'plaintext must be restored from _pendingSendContent, '
            'never shown as [encrypted]',
      );
      expect(real.deliveryStatus, MessageDeliveryStatus.sent);
      expect(provider.messages.where((m) => m.id < 0), isEmpty);
    });

    test(
      'messageSent with an unknown tempId does not corrupt existing rows',
      () async {
        provider.sendMessage('first');
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        final before = provider.messages.single;

        provider.onMessageSent({
          'id': 777,
          'content': '[encrypted]',
          'encryptedContent': 'ciphertext',
          'senderId': 1,
          'senderUsername': 'alice',
          'conversationId': 10,
          'deliveryStatus': 'SENT',
          'messageType': 'TEXT',
          'createdAt': '2026-01-01T00:00:02.000Z',
          'tempId': 'temp_unknown_999',
        });

        // The pending row for 'first' must still exist untouched.
        final firstRow = provider.messages.where(
          (m) => m.tempId == before.tempId,
        );
        expect(firstRow, hasLength(1));
        expect(firstRow.single.content, 'first');
        // No duplicate ids.
        final ids = provider.messages.map((m) => m.id).toList();
        expect(ids.toSet().length, ids.length);
      },
    );
  });

  group('reactions', () {
    setUp(() => wire(_WorkingEncryption()));

    test('onReactionUpdated patches the target message reactions', () {
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_plainIncomingJson(50)],
      });
      expect(provider.messages.single.reactions, isEmpty);

      provider.onReactionUpdated({
        'messageId': 50,
        'reactions': {
          '🔥': [2],
          '👍': [1, 2],
        },
      });

      final reactions = provider.messages.single.reactions;
      expect(reactions['🔥'], [2]);
      expect(reactions['👍'], [1, 2]);
    });

    test('onReactionUpdated for an unknown message id is a safe no-op', () {
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_plainIncomingJson(50)],
      });

      expect(
        () => provider.onReactionUpdated({
          'messageId': 9999,
          'reactions': {
            '🔥': [2],
          },
        }),
        returnsNormally,
      );
      expect(provider.messages.single.reactions, isEmpty);
    });

    test('a tap sends a blinded token, never the emoji', () async {
      final store = _MemoryReactionStore();
      wire(_WorkingEncryption(store: store));
      answerReactionKeyRequests(currentEpoch: 0);

      expect(await provider.addReaction(50, '🔥'), isTrue);

      final reaction = emitted.singleWhere((e) => e['event'] == 'addReaction');
      final sent = (reaction['data'] as Map<String, dynamic>)['emoji'] as String;
      expect(sent, isNot('🔥'));
      expect(
        sent,
        matches(RegExp(r'^[A-Za-z0-9_-]{22}$')),
        reason: 'the server must receive a token, not a reaction anyone can read',
      );
      // And it is the RIGHT token: the key the upload distributed produces it.
      final codec = ReactionTokenCodec(
        Uint8List.fromList(base64Decode(store.keys[10]!)),
      );
      expect(codec.tokenFor('🔥'), sent);
    });

    test('the first reaction distributes a key to the peer', () async {
      wire(_WorkingEncryption(store: _MemoryReactionStore()));
      answerReactionKeyRequests(currentEpoch: 0);

      await provider.addReaction(50, '🔥');

      final upload = emitted.singleWhere(
        (e) => e['event'] == 'uploadReactionKey',
      );
      final payload = upload['data'] as Map<String, dynamic>;
      expect(payload['epoch'], 1, reason: 'the conversation had no key');
      final envelopes = payload['envelopes'] as List;
      expect(
        envelopes.map((e) => (e as Map<String, dynamic>)['userId']),
        contains(2),
        reason: 'the peer cannot read a single chip without this',
      );
    });

    test('an incoming token renders as its emoji', () async {
      final store = _MemoryReactionStore();
      wire(_WorkingEncryption(store: store));
      answerReactionKeyRequests(currentEpoch: 0);
      await provider.addReaction(50, '🔥');
      await provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_plainIncomingJson(50)],
      });
      final codec = ReactionTokenCodec(
        Uint8List.fromList(base64Decode(store.keys[10]!)),
      );

      provider.onReactionUpdated({
        'messageId': 50,
        'reactions': {
          codec.tokenFor('👍'): [2],
        },
      });

      expect(provider.messages.single.reactions['👍'], [2]);
    });

    test('a token this device cannot name survives as a token', () async {
      // No key anywhere, and the server has none to hand over: the chip must
      // stay renderable as a placeholder rather than vanish.
      wire(_WorkingEncryption(store: _MemoryReactionStore()));
      answerReactionKeyRequests(currentEpoch: 0);
      await provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_plainIncomingJson(50)],
      });

      provider.onReactionUpdated({
        'messageId': 50,
        'reactions': {
          'AAAAAAAAAAAAAAAAAAAAAA': [2],
        },
      });

      expect(provider.messages.single.reactions.keys.single,
          'AAAAAAAAAAAAAAAAAAAAAA');
    });

    test('a device linked after the key was made does NOT re-key', () async {
      // The owner's rule: this device cannot read the history those chips sit
      // on, but the devices that CAN would lose them if the epoch advanced.
      wire(_WorkingEncryption(store: _MemoryReactionStore()));
      answerReactionKeyRequests(currentEpoch: 3);

      expect(await provider.addReaction(50, '🔥'), isFalse);
      expect(
        emitted.where((e) => e['event'] == 'uploadReactionKey'),
        isEmpty,
        reason: "a re-key here would blank the other devices' chips",
      );
      expect(emitted.where((e) => e['event'] == 'addReaction'), isEmpty);
    });

    test('a locked store never re-keys and never sends plaintext', () async {
      wire(_WorkingEncryption(store: _MemoryReactionStore(locked: true)));
      answerReactionKeyRequests(currentEpoch: 0);

      expect(await provider.addReaction(50, '🔥'), isFalse);
      expect(emitted.where((e) => e['event'] == 'addReaction'), isEmpty);
      expect(emitted.where((e) => e['event'] == 'uploadReactionKey'), isEmpty);
    });

    test('one unreadable chat asks the server for its key once', () async {
      wire(_WorkingEncryption(store: _MemoryReactionStore()));
      answerReactionKeyRequests(currentEpoch: 2);

      await provider.onMessageHistory({
        'conversationId': 10,
        'messages': [
          {
            ..._plainIncomingJson(50),
            'reactions': {
              'AAAAAAAAAAAAAAAAAAAAAA': [2],
            },
          },
          {
            ..._plainIncomingJson(51),
            'reactions': {
              'BBBBBBBBBBBBBBBBBBBBBB': [2],
            },
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(
        emitted.where((e) => e['event'] == 'fetchReactionKey').length,
        1,
        reason: 'a chat of fifty unreadable chips must not send fifty fetches',
      );
    });

    test('chips rendered before the key arrives flip to emoji when it does', () async {
      // The single most likely silent failure of the feature: history paints
      // placeholders (no key yet), the key lands a moment later, and nothing
      // re-renders — every chip frozen on the placeholder until the chat is
      // reopened.
      final keyB64 = base64Encode(List<int>.generate(32, (i) => i + 7));
      final codec = ReactionTokenCodec(
        Uint8List.fromList(base64Decode(keyB64)),
      );
      wire(_KeyBearingEncryption(keyB64, store: _MemoryReactionStore()));
      // The mailbox HAS a row for this device, so the background fetch that
      // history kicks off resolves into a real codec.
      serverWrappedKey = 'wrapped';
      answerReactionKeyRequests(currentEpoch: 4);

      await provider.onMessageHistory({
        'conversationId': 10,
        'messages': [
          {
            ..._plainIncomingJson(50),
            'reactions': {
              codec.tokenFor('🔥'): [2],
            },
          },
        ],
      });
      // At ingest there is no key, so the token is all the UI has.
      expect(
        isUnresolvedReactionKey(provider.messages.single.reactions.keys.single),
        isTrue,
      );

      // Let the background acquisition and the re-render pass run.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(provider.messages.single.reactions['🔥'], [2]);
    });

    test('a relaunch names its chips from the LOCAL key, with no round trip', () async {
      // The relaunch case the test above cannot reach. There the key arrives
      // from the mailbox, i.e. after an awaited round trip, so the rows are
      // long installed by then. Here the key is ALREADY in the local store, so
      // the acquisition completes in a microtask — during the `await` a COLD
      // history entry spends hydrating plaintext from storage, while the rows
      // are still caller-local. The re-render pass then found nothing in
      // `_messages` to repair and spent its one latched attempt, so every chip
      // stayed the unreadable placeholder for the rest of the session on a
      // device that holds the key (falsification R7; observed on a real Chrome
      // relaunch 2026-09-18, chips resolving only for reactions that arrived
      // live afterwards).
      final keyB64 = base64Encode(List<int>.generate(32, (i) => i + 11));
      final codec = ReactionTokenCodec(
        Uint8List.fromList(base64Decode(keyB64)),
      );
      final store = _MemoryReactionStore()
        ..keys[10] = keyB64
        ..epochs[10] = 4;
      wire(_WorkingEncryption(store: store));
      // Deliberately no `answerReactionKeyRequests`: a device holding its own
      // key must not depend on the server answering anything.

      await provider.onMessageHistory({
        'conversationId': 10,
        'messages': [
          {
            ..._plainIncomingJson(50),
            // '[encrypted]' is what makes this a COLD entry: the snapshot has
            // to be hydrated from storage, which is the suspension point the
            // regression hides behind. A plaintext row never awaits.
            'content': '[encrypted]',
            'encryptedContent': 'ciphertext',
            'reactions': {
              codec.tokenFor('🔥'): [2],
            },
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        provider.messages.single.reactions['🔥'],
        [2],
        reason: 'the key was on this device the whole time',
      );
      expect(
        emitted.where((e) => e['event'] == 'fetchReactionKey'),
        isEmpty,
        reason: 'a locally held key must not spend the one-shot mailbox row',
      );
    });

    test('an upload answer for another conversation is not mistaken for this one', () async {
      // The slot is released on timeout, so a late answer can arrive while a
      // DIFFERENT conversation's upload is pending. Accepting it would persist
      // a key the server never took for this conversation — unreadable for
      // both sides, forever, with no client-side recovery.
      final store = _MemoryReactionStore();
      wire(_WorkingEncryption(store: store));
      answerWrongConversationFirst = true;
      answerReactionKeyRequests(currentEpoch: 0);

      expect(await provider.addReaction(50, '🔥'), isTrue);

      // The key stored is the one THIS conversation's accepted upload carried,
      // at the epoch that upload was accepted at.
      expect(store.epochs[10], 1);
      final sent =
          (emitted.singleWhere((e) => e['event'] == 'addReaction')['data']
              as Map<String, dynamic>)['emoji'];
      final codec = ReactionTokenCodec(
        Uint8List.fromList(base64Decode(store.keys[10]!)),
      );
      expect(sent, codec.tokenFor('🔥'));
    });
  });

  group('plaintext purge events', () {
    test('messageDeleted drops the row and requests a per-id purge', () {
      final encryption = _WorkingEncryption();
      wire(encryption);
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_plainIncomingJson(90)],
      });

      provider.onMessageDeleted({'messageId': 90, 'conversationId': 10});

      expect(provider.messages, isEmpty);
      expect(encryption.localPurges, [
        {90},
      ]);
    });

    test('unfriend removes rows and requests a conversation purge', () {
      final encryption = _WorkingEncryption();
      wire(encryption);
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_plainIncomingJson(91)],
      });

      provider.onConversationsRemovedForUser([10]);

      expect(provider.messages, isEmpty);
      expect(encryption.conversationPurges, [
        {10},
      ]);
    });
  });

  group('typing indicators', () {
    setUp(() => wire(_WorkingEncryption()));

    test(
      'onPartnerTyping sets the flag and expires after the timer window',
      () {
        fakeAsync((async) {
          provider.onPartnerTyping({'conversationId': 10});
          expect(provider.isPartnerTyping(10), isTrue);

          async.elapse(const Duration(seconds: 2, milliseconds: 900));
          expect(
            provider.isPartnerTyping(10),
            isTrue,
            reason: 'flag must survive until the 3s window elapses',
          );

          async.elapse(const Duration(milliseconds: 200));
          expect(provider.isPartnerTyping(10), isFalse);
        });
      },
    );

    test(
      'typing in another conversation does not leak into the active one',
      () {
        fakeAsync((async) {
          provider.onPartnerTyping({'conversationId': 99});
          expect(provider.isPartnerTyping(10), isFalse);
          expect(provider.isPartnerTyping(99), isTrue);
          async.elapse(const Duration(seconds: 4));
          expect(provider.isPartnerTyping(99), isFalse);
        });
      },
    );

    test('an incoming message from the partner clears the typing flag', () {
      fakeAsync((async) {
        provider.onPartnerTyping({'conversationId': 10});
        expect(provider.isPartnerTyping(10), isTrue);

        provider.onNewMessage(_plainIncomingJson(60));
        expect(
          provider.isPartnerTyping(10),
          isFalse,
          reason: 'message arrival supersedes the typing indicator',
        );
      });
    });
  });

  group('onLinkPreviewReady', () {
    setUp(() => wire(_WorkingEncryption()));

    test('patches preview fields onto the target message', () {
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_plainIncomingJson(70)],
      });

      provider.onLinkPreviewReady({
        'messageId': 70,
        'linkPreviewUrl': 'https://example.com',
        'linkPreviewTitle': 'Example',
        'linkPreviewImageUrl': 'https://example.com/og.png',
      });

      final msg = provider.messages.single;
      expect(msg.linkPreviewUrl, 'https://example.com');
      expect(msg.linkPreviewTitle, 'Example');
      expect(msg.linkPreviewImageUrl, 'https://example.com/og.png');
    });

    test('unknown message id is a safe no-op', () {
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_plainIncomingJson(70)],
      });

      expect(
        () => provider.onLinkPreviewReady({
          'messageId': 9999,
          'linkPreviewUrl': 'https://example.com',
        }),
        returnsNormally,
      );
      expect(provider.messages.single.linkPreviewUrl, isNull);
    });
  });

  group('markSendingMessagesFailed', () {
    test(
      'flips SENDING rows to failed and leaves settled rows untouched',
      () async {
        wire(_StuckEncryption());

        // Settled row from the peer.
        await provider.onMessageHistory({
          'conversationId': 10,
          'messages': [_plainIncomingJson(80)],
        });

        // Own send stuck in SENDING (ensureSession never resolves).
        provider.sendMessage('stuck one');
        await Future<void>.delayed(Duration.zero);
        expect(
          provider.messages.where(
            (m) => m.deliveryStatus == MessageDeliveryStatus.sending,
          ),
          hasLength(1),
        );

        provider.markSendingMessagesFailed('socket error');

        final own = provider.messages.singleWhere((m) => m.tempId != null);
        expect(own.deliveryStatus, MessageDeliveryStatus.failed);
        final settled = provider.messages.singleWhere((m) => m.id == 80);
        expect(
          settled.deliveryStatus,
          MessageDeliveryStatus.delivered,
          reason: 'already-settled rows must not be touched',
        );
      },
    );

    test(
      'failed rows become retryable: a retry emits sendMessage again',
      () async {
        wire(_WorkingEncryption());

        provider.sendMessage('retry me');
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(emitted.where((e) => e['event'] == 'sendMessage'), hasLength(1));

        // Simulate socket error flipping the (already sent but unconfirmed) row.
        provider.markSendingMessagesFailed('socket error');

        final row = provider.messages.single;
        // Re-run the send path with the same tempId — the exactly-once latch
        // must have been released by the failure.
        await provider.encryptAndSendForTest(
          recipientId: 2,
          content: 'retry me',
          tempId: row.tempId!,
        );
        expect(emitted.where((e) => e['event'] == 'sendMessage'), hasLength(2));
      },
    );
  });
}
