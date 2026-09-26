import 'dart:io';
import 'dart:typed_data';

import 'package:fireplace/services/box/box_media_store.dart';
import 'package:fireplace/services/box/box_media_store_io.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _id(int fill) => Uint8List(32)..fillRange(0, 32, fill);

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('box_media_store_test');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  final stores = <String, BoxMediaStore Function()>{
    'memory': MemoryBoxMediaStore.new,
    'files': () => IoBoxMediaStore(root: () async => root),
  };

  for (final MapEntry(key: name, value: make) in stores.entries) {
    group(name, () {
      test('put then get answers the bytes; an id never put is null', () async {
        final store = make();
        await store.put(1, _id(1), Uint8List.fromList([1, 2, 3]));
        expect(await store.get(1, _id(1)), [1, 2, 3]);
        expect(await store.get(1, _id(2)), isNull);
      });

      test(
        "one account's copy is not another's: the same id under another "
        'user id is absent, and deleting it there leaves this one',
        () async {
          final store = make();
          await store.put(1, _id(1), Uint8List.fromList([1]));
          expect(await store.get(2, _id(1)), isNull);
          await store.put(2, _id(1), Uint8List.fromList([2]));
          await store.delete(2, _id(1));
          expect(await store.get(1, _id(1)), [1]);
          expect(await store.get(2, _id(1)), isNull);
        },
      );

      test(
        'a second put replaces; delete removes; deleting twice is fine',
        () async {
          final store = make();
          await store.put(1, _id(1), Uint8List.fromList([1]));
          await store.put(1, _id(1), Uint8List.fromList([4, 5]));
          expect(await store.get(1, _id(1)), [4, 5]);
          await store.delete(1, _id(1));
          await store.delete(1, _id(1));
          expect(await store.get(1, _id(1)), isNull);
        },
      );

      test("the stored bytes are a copy, not the caller's buffer", () async {
        final store = make();
        final bytes = Uint8List.fromList([1, 2]);
        await store.put(1, _id(1), bytes);
        bytes[0] = 9;
        expect(await store.get(1, _id(1)), [1, 2]);
      });

      test('has answers whether a copy is kept, per account', () async {
        final store = make();
        expect(await store.has(1, _id(1)), isFalse);
        await store.put(1, _id(1), Uint8List.fromList([1]));
        expect(await store.has(1, _id(1)), isTrue);
        expect(await store.has(2, _id(1)), isFalse);
        await store.delete(1, _id(1));
        expect(await store.has(1, _id(1)), isFalse);
      });

      test('an id that is not 32 bytes is refused', () async {
        final store = make();
        await expectLater(
          store.put(1, Uint8List(31), Uint8List(1)),
          throwsArgumentError,
        );
      });
    });
  }

  test(
    'files: each copy is one file under box_media/<userId>/<base64url id>, '
    'and no temp file is left behind',
    () async {
      final store = IoBoxMediaStore(root: () async => root);
      await store.put(7, _id(0xfb), Uint8List.fromList([1, 2, 3]));
      final dir = Directory('${root.path}/box_media/7');
      final names = [
        for (final e in dir.listSync()) e.uri.pathSegments.last,
      ];
      expect(names, ['-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_s']);
    },
  );

  test(
    "the in-app erase deletes every account's copies, box_media and all",
    () async {
      final store = IoBoxMediaStore(root: () async => root);
      await store.put(7, _id(1), Uint8List.fromList([1]));
      await store.put(8, _id(2), Uint8List.fromList([2]));
      expect(await deleteAllBoxMediaCopies(root: () async => root), isTrue);
      expect(Directory('${root.path}/box_media').existsSync(), isFalse);
      expect(await deleteAllBoxMediaCopies(root: () async => root), isTrue);
    },
  );
}
