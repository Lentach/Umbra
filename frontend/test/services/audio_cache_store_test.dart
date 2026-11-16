import 'dart:io';
import 'dart:typed_data';

import 'package:fireplace/services/audio_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File target;
  final plain = Uint8List.fromList(List.generate(64, (i) => i));
  final sealed = Uint8List.fromList([0x46, 0x50, 0x41, 0x45, 1, 9, 9, 9]);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('audio_cache_store_test');
    target = File('${dir.path}/7.audio');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('with no content store, nothing is written (A5)', () async {
    final written = await AudioCacheStore.writeSealed(target, plain, null);

    expect(written, isFalse);
    expect(dir.listSync(), isEmpty);
  });

  test('a store that cannot seal leaves nothing on disk', () async {
    final written = await AudioCacheStore.writeSealed(
      target,
      plain,
      (_) async => null,
    );

    expect(written, isFalse);
    expect(dir.listSync(), isEmpty);
  });

  test('a sealed note is written as the sealed bytes only', () async {
    final written = await AudioCacheStore.writeSealed(
      target,
      plain,
      (_) async => sealed,
    );

    expect(written, isTrue);
    expect(target.readAsBytesSync(), sealed);
    expect(
      dir.listSync().map((e) => e.uri.pathSegments.last),
      ['7.audio'],
      reason: 'the temp file is renamed into place',
    );
  });
}
