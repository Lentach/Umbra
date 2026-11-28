import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import '../support/box_send_harness.dart';

/// Decision 152 (option C), the send side: while a friend's new key waits
/// for the person's tap (`calmHoldState(peer) != null`), nothing is sealed
/// for that friend on the session of the key being replaced — a message
/// would be unreadable to the friend's new install for good — and no lookup
/// or bundle fetch is caused by the send itself (E114e: only the tap asks).
/// The crossing test proves the release against real Signal on both sides.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BoxSendHarness h;
  late ScriptedSendEncryption encryption;
  late ScriptedSendOutbox outbox;
  late MessagingProvider provider;

  setUp(() async {
    outbox = ScriptedSendOutbox();
    h = await BoxSendHarness.create(
      encryption: (store) => encryption = ScriptedSendEncryption(store),
      outbox: outbox,
    );
    provider = h.provider..receiptsAndTyping = () => true;
    h.bob([1]);
    encryption.sessions.add((2, 1));
    await h.pump();
    encryption.forcedFetches.clear();
    encryption.fetches.clear();
  });

  tearDown(() => h.dispose());

  /// Nothing was sealed, delivered, fetched or looked up for Bob.
  void expectNothingWentOut() {
    expect(encryption.encryptCalls, isEmpty);
    expect(outbox.delivered, isEmpty);
    expect(outbox.uploads, isEmpty, reason: 'no file goes up for the old key');
    expect(h.emitted, isEmpty);
    expect(
      encryption.bundleFetches,
      isEmpty,
      reason: 'a send never fetches a bundle',
    );
    expect(encryption.forcedFetches, isEmpty, reason: 'a send never looks up');
    expect(encryption.fetches, isEmpty);
  }

  for (final state in CalmHoldState.values) {
    test('a text sent while the calm line is $state is not sealed: the row '
        'waits, says so, and nothing reaches the old session', () async {
      provider
        ..seedCalmHoldForTest(2, state)
        ..sendMessage('hello');
      await h.pump();

      expectNothingWentOut();
      final row = provider.messages.single;
      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(row.waitingToSend, isTrue);
      expect(
        provider.sendRefusedForIdentity(row.tempId),
        isFalse,
        reason: 'no key changed for the worse: the wording is neutral',
      );
    });
  }

  test('a ping, a picture, a reaction and typing wait too', () async {
    // One real message first, so a reaction has a target.
    provider.sendMessage('before');
    await h.pump();
    final target = provider.messages.single;
    expect(outbox.delivered, hasLength(1));
    outbox.delivered.clear();
    encryption.encryptCalls.clear();
    provider
      ..seedCalmHoldForTest(2, CalmHoldState.waiting)
      ..sendPing(2);
    await h.pump();
    final ok = await provider.sendImageMessage(
      XFile.fromData(
        Uint8List.fromList(List<int>.generate(5000, (i) => i % 251)),
        name: 'a.jpg',
      ),
      2,
    );
    await h.pump();
    final reacted = await provider.addReaction(target.id, '👍');
    provider.sendTypingIndicator(2, 10);
    await h.pump();

    expect(ok, isFalse);
    expect(reacted, isFalse);
    expectNothingWentOut();
    expect(
      h.crypto.encrypted,
      hasLength(1),
      reason: 'the picture was held for its retry',
    );
    expect(h.provider.messages.where((m) => m.deliveryStatus.name == 'failed'),
        hasLength(2));
  });

  test('the tap that ends the line lets the row go, once, on a retry',
      () async {
    provider
      ..seedCalmHoldForTest(2, CalmHoldState.waiting)
      ..sendMessage('hello');
    await h.pump();
    final row = provider.messages.single;

    provider.onFriendshipEnded(2); // any end of the line frees the send path
    await h.pump();
    expect(provider.messages.single.waitingToSend, isFalse);
    expect(provider.messages.single.deliveryStatus, MessageDeliveryStatus.failed);
    await provider.retryFailedMessage(row.tempId!);
    await h.pump();

    expect(outbox.delivered, hasLength(1));
    expect(
      utf8.decode(outbox.delivered.single.$2.signal),
      contains('hello'),
    );
    expect(
      provider.messages.single.deliveryStatus,
      MessageDeliveryStatus.sent,
    );
    expect(provider.messages.single.waitingToSend, isFalse);
  });
}
