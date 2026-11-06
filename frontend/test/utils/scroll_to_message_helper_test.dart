import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/utils/scroll_to_message_helper.dart';
import 'package:flutter_test/flutter_test.dart';

MessageModel _m(int id) => MessageModel(
      id: id,
      content: 'msg$id',
      senderId: 1,
      senderUsername: 'alice',
      conversationId: 10,
      createdAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  test('listIndexForMessageId oldest-first in reverse ListView', () {
    expect(
      listIndexForMessageId(
        messageId: 2,
        messages: [
          _m(1),
          _m(2),
          _m(3),
        ],
      ),
      1,
    );
  });

  test('returns null when id not in list', () {
    expect(
      listIndexForMessageId(messageId: 99, messages: [_m(1)]),
      isNull,
    );
  });
}
