import 'package:fireplace/services/box/box_push_nids.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ContactQueue _queue(String nid) => ContactQueue(
  rid: 'rid-$nid',
  sid: 'sid-$nid',
  nid: nid,
  authPriv: 'auth',
  sealPriv: 'sealPriv',
  sealPub: 'sealPub',
);

ContactRecord _record(
  int userId, {
  List<ContactQueue> queues = const [],
  ContactState state = ContactState.friend,
  int? conversationId,
  bool box = false,
}) => ContactRecord(
  userId: userId,
  username: 'peer$userId',
  tag: '0001',
  state: state,
  queues: queues,
  legacy: ContactLegacy(conversationId: conversationId),
  boxOrigin: box ? ContactBoxOrigin(at: DateTime.utc(2026, 10)) : null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BoxPushNids.tableOf', () {
    test('names the chat of each queue: a server chat, else the local id', () {
      final table = BoxPushNids.tableOf([
        _record(2, queues: [_queue('a'), _queue('a2')], conversationId: 40),
        _record(3, queues: [_queue('b')], box: true),
      ]);

      expect(table, {'a': 40, 'a2': 40, 'b': localConversationIdFor(3)});
    });

    test('leaves out contacts nobody may ring and contacts with no chat', () {
      final table = BoxPushNids.tableOf([
        _record(2, queues: [_queue('blocked')], state: ContactState.blocked),
        _record(3, queues: [_queue('former')], state: ContactState.former),
        _record(4, queues: [_queue('chatless')]),
        _record(5, queues: [_queue('kept')], conversationId: 7),
      ]);

      expect(table, {'kept': 7});
    });
  });

  group('BoxPushNids.sync', () {
    late ContactStore store;
    late List<Map<String, int>> written;
    var failNext = false;
    late BoxPushNids nids;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final kv = await PrefsContentKv.open();
      store = ContactStore(
        open: () async => kv,
        lock: <T>(_, action) => action(),
        accepts: (_) => true,
      );
      await store.open(1);
      written = [];
      failNext = false;
      nids = BoxPushNids(
        store: store,
        sink: (table) async {
          if (failNext) {
            failNext = false;
            throw StateError('storage refused');
          }
          written.add(table);
        },
      );
    });

    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await pumpEventQueue();
      }
    }

    test('writes the table once, again only when a queue appears', () async {
      await store.update(
        2,
        (_) => _record(2, queues: [_queue('a')], conversationId: 40),
      );

      nids
        ..sync()
        ..sync();
      await settle();
      expect(written, [
        {'a': 40},
      ]);

      await store.update(
        3,
        (_) => _record(3, queues: [_queue('b')], conversationId: 41),
      );
      nids.sync();
      await settle();
      expect(written.last, {'a': 40, 'b': 41});
      expect(written, hasLength(2));
    });

    test('a refused write is offered again by the next sync', () async {
      await store.update(
        2,
        (_) => _record(2, queues: [_queue('a')], conversationId: 40),
      );
      failNext = true;

      nids.sync();
      await settle();
      expect(written, isEmpty);

      nids.sync();
      await settle();
      expect(written, [
        {'a': 40},
      ]);
    });

    test('writes nothing while the store is closed', () async {
      await store.update(
        2,
        (_) => _record(2, queues: [_queue('a')], conversationId: 40),
      );
      store.close();

      nids.sync();
      await settle();

      expect(written, isEmpty);
    });
  });
}
