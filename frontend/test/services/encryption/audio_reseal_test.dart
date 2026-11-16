import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fireplace/services/audio_cache_store.dart';
import 'package:fireplace/services/encryption/audio_reseal.dart';
import 'package:flutter_test/flutter_test.dart';

/// A sealed-file header (`FPAE`, v1, kid "k") around [body]: the sweep only
/// has to recognise the format, so no crypto is needed.
Uint8List _sealedFrom(Uint8List body) => Uint8List.fromList([
  0x46, 0x50, 0x41, 0x45, 1, 1, 0x6b, // magic, version, kid length, "k"
  ...List.filled(12, 0), // IV
  ...body,
]);

void main() {
  late Directory dir;
  final plain = Uint8List.fromList(List.generate(40, (i) => 100 + i));
  final epoch = DateTime.utc(2026, 11, 16, 12);
  final cutoff = epoch.add(const Duration(minutes: 1));

  setUp(() => dir = Directory.systemTemp.createTempSync('audio_reseal_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  File put(String name, List<int> bytes, {DateTime? modified}) {
    return File('${dir.path}/$name')
      ..writeAsBytesSync(bytes)
      ..setLastModifiedSync(modified ?? epoch);
  }

  List<String> names() =>
      dir.listSync().map((e) => e.uri.pathSegments.last).toList();

  Future<Uint8List?> seal(Uint8List p) async => _sealedFrom(p);

  test('a legacy plaintext note is sealed in place (A5)', () async {
    final note = put('5.audio', plain);
    final legacy = put('6.m4a', plain);

    final sealed = await sealPlainAudioCacheFiles(seal, dir: dir, before: cutoff);

    expect(sealed, 2);
    expect(note.readAsBytesSync(), _sealedFrom(plain));
    expect(legacy.readAsBytesSync(), _sealedFrom(plain));
    expect(
      names(),
      unorderedEquals(['5.audio', '6.m4a']),
      reason: 'no temp file is left behind',
    );
  });

  test('a note already sealed is not sealed again', () async {
    final done = put('5.audio', _sealedFrom(plain));
    final legacy = put('6.audio', plain);

    final sealed = await sealPlainAudioCacheFiles(seal, dir: dir, before: cutoff);

    expect(sealed, 1, reason: 'only the plain note is sealed');
    expect(done.readAsBytesSync(), _sealedFrom(plain));
    expect(legacy.readAsBytesSync(), _sealedFrom(plain));
  });

  test('a file written after the sweep began is left alone', () async {
    final fresh = put(
      '5.audio',
      plain,
      modified: epoch.add(const Duration(minutes: 2)),
    );
    final old = put('6.audio', plain);

    await sealPlainAudioCacheFiles(seal, dir: dir, before: cutoff);

    expect(fresh.readAsBytesSync(), plain);
    expect(old.readAsBytesSync(), _sealedFrom(plain), reason: 'control');
  });

  test('a store that cannot seal changes nothing', () async {
    final note = put('5.audio', plain);

    final sealed = await sealPlainAudioCacheFiles(
      (_) async => null,
      dir: dir,
      before: cutoff,
    );

    expect(sealed, 0);
    expect(note.readAsBytesSync(), plain);
  });

  test('files that are not cached notes are left alone', () async {
    final other = put('notes.txt', plain);
    final note = put('5.audio', plain);

    await sealPlainAudioCacheFiles(seal, dir: dir, before: cutoff);

    expect(other.readAsBytesSync(), plain);
    expect(note.readAsBytesSync(), _sealedFrom(plain), reason: 'control');
  });

  test('temp files a killed write left behind are deleted', () async {
    put('5.audio.tmp', _sealedFrom(plain));
    put('6.m4a.tmp', _sealedFrom(plain));
    put('7.m4a.reseal', _sealedFrom(plain));
    put(
      '8.audio.tmp',
      _sealedFrom(plain),
      modified: epoch.add(const Duration(minutes: 2)),
    );

    await sealPlainAudioCacheFiles(seal, dir: dir, before: cutoff);

    expect(
      names(),
      ['8.audio.tmp'],
      reason: 'a write that began after the sweep is not a leftover',
    );
  });

  test('a note purged while it is being sealed stays deleted', () async {
    put('5.audio', plain);
    final sealing = Completer<void>();
    final released = Completer<void>();

    final pass = sealPlainAudioCacheFiles(
      (p) async {
        sealing.complete();
        await released.future;
        return _sealedFrom(p);
      },
      dir: dir,
      before: cutoff,
    );
    await sealing.future;
    final purge = AudioCacheStore.removeIn(dir, [5]);
    released.complete();
    await pass;
    final failed = await purge;

    expect(failed, isEmpty);
    expect(names(), isEmpty, reason: 'the seal must not rename it back');
  });

  test('a purge removes the temp files of the purged note', () async {
    put('5.audio', _sealedFrom(plain));
    put('5.audio.tmp', _sealedFrom(plain));
    put('5.m4a.reseal', _sealedFrom(plain));
    put('6.audio', _sealedFrom(plain));

    final failed = await AudioCacheStore.removeIn(dir, [5]);

    expect(failed, isEmpty);
    expect(names(), ['6.audio']);
  });
}
