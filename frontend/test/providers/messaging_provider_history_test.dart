import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/box_send_harness.dart';

/// Opening a chat reads this device's records and nothing else (decision
/// 99): a message of the old path is neither fetched nor shown, whatever
/// plaintext of it is still on disk.
void main() {
  late BoxSendHarness h;

  setUp(() async => h = await BoxSendHarness.create());
  tearDown(() => h.dispose());

  Future<void> store(int id, String text, {required String wire}) =>
      h.encryption.store.saveDecryptedContent(
        id,
        {'content': text, 'senderId': 2},
        conversationId: 10,
        createdAt: DateTime.now().toUtc(),
        wire: (senderId: 2, wireId: wire),
      );

  test('a chat shows its box messages and never a stored old-path record, '
      'and asks the server for nothing', () async {
    await store(77, 'old path', wire: 'wire-old');
    await store(kFirstLocalMessageId + 1, 'over the box', wire: 'wire-box');

    h.provider.getMessages(10);
    await h.pump(80);

    expect(h.provider.messages.map((m) => m.content), ['over the box']);
    expect(h.emitted, isEmpty);
  });
}
