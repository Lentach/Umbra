import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _bytes(int length, int fill) =>
    Uint8List(length)..fillRange(0, length, fill);

ContactQueue _queue(int fill) => ContactQueue(
  rid: boxB64(_bytes(32, fill)),
  sid: boxB64(_bytes(32, fill + 1)),
  nid: boxB64(_bytes(16, fill + 2)),
  authPriv: boxB64(_bytes(64, fill + 3)),
  sealPriv: boxB64(_bytes(32, fill + 4)),
  sealPub: boxB64(_bytes(32, fill + 5)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentKv kv;
  late ContactStore store;

  ContactStore newStore() => ContactStore(
    open: () async => kv,
    lock: <T>(_, action) => action(),
    accepts: (_) => true,
  );

  Future<void> friend(int peer, List<ContactQueue> queues) => store.update(
    peer,
    (_) => ContactRecord(
      userId: peer,
      username: 'peer$peer',
      tag: '0001',
      state: ContactState.friend,
      queues: queues,
    ),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = await PrefsContentKv.open();
    store = newStore();
    await store.open(1);
  });

  test(
    'a nid whose queue no record holds any more is dropped on the next write',
    () async {
      final a = _queue(0x10);
      final b = _queue(0x20);
      await friend(42, [a]);
      await friend(43, [b]);
      expect(await store.markNotifier(a.nid, 'T'), isTrue);

      await friend(42, const []);
      expect(await store.markNotifier(b.nid, 'T'), isTrue);

      final again = newStore();
      await again.open(1);
      expect(again.notifierActive(b.nid, 'T'), isTrue);
      expect(again.notifierActive(a.nid, 'T'), isFalse);
    },
  );

  test(
    'a new target drops every nid registered under the old one: their '
    'notifiers still name the old token',
    () async {
      final a = _queue(0x10);
      final b = _queue(0x20);
      await friend(42, [a]);
      await friend(43, [b]);
      expect(await store.markNotifier(a.nid, 'T'), isTrue);
      expect(await store.markNotifier(b.nid, 'U'), isTrue);

      expect(store.notifierActive(b.nid, 'U'), isTrue);
      expect(store.notifierActive(a.nid, 'U'), isFalse);
      expect(store.notifierActive(a.nid, 'T'), isFalse);
    },
  );

  test("a newer build's row is never overwritten", () async {
    final a = _queue(0x10);
    await friend(42, [a]);
    final key = ContactStore.notifiersKey(1);
    final newer = jsonEncode({
      'v': ContactStore.notifiersVersion + 1,
      'target': 'T',
      'nids': <String>[],
    });
    expect(await kv.setString(key, newer), isTrue);
    await store.open(1);

    expect(store.notifiersUnsupported, isTrue);
    expect(await store.markNotifier(a.nid, 'T'), isFalse);
    expect(kv.getString(key), newer);
  });
}
