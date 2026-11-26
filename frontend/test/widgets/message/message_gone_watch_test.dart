import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/widgets/message/message_context_menu_overlay.dart'
    show messageGoneWatch;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

MessageModel _row(int id, {String? tempId, String? wireId}) => MessageModel(
  id: id,
  tempId: tempId,
  wireId: wireId,
  content: 'row $id',
  senderId: 1,
  senderUsername: 'alice',
  conversationId: 10,
  createdAt: DateTime.utc(2026),
);

/// A3-MSG-B-06: a send that settles swaps a temp id for the server id, so an
/// open menu / viewer must still find its row by the temp id or the wire id.
void main() {
  bool goneIn(List<MessageModel> rows, MessageModel watched) => messageGoneWatch(
    ValueNotifier<int>(0),
    () => rows,
    watched,
  ).isGone();

  test('a row with the same id is present', () {
    expect(goneIn([_row(5)], _row(5)), isFalse);
  });

  test('a settled send is found by its temp id after the id changed', () {
    final watched = _row(-3, tempId: 't-1');
    expect(goneIn([_row(900, tempId: 't-1')], watched), isFalse);
  });

  test('a settled send is found by its wire id after the id changed', () {
    final watched = _row(-3, wireId: 'w-1');
    expect(goneIn([_row(900, wireId: 'w-1')], watched), isFalse);
  });

  test('no row by id, temp id or wire id means gone', () {
    final watched = _row(-3, tempId: 't-1', wireId: 'w-1');
    expect(goneIn([_row(900, tempId: 't-2', wireId: 'w-2')], watched), isTrue);
    expect(goneIn(const [], watched), isTrue);
  });

  test('a message with no temp or wire id never matches another null one', () {
    expect(goneIn([_row(900)], _row(-3)), isTrue);
  });
}
