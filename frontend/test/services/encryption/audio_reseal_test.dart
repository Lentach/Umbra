import 'dart:io';
import 'dart:typed_data';

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

  setUp(() => dir = Directory.systemTemp.createTempSync('audio_reseal_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  File put(String name, List<int> bytes, {DateTime? modified}) {
    return File('${dir.path}/$name')
      ..writeAsBytesSync(bytes)
      ..setLastModifiedSync(modified ?? epoch);
  }

  Future<Uint8List?> seal(Uint8List p) async => _sealedFrom(p);

  group('sealPlainAudioCacheFiles (hardening A5)', () {
    test('a legacy plaintext note is sealed in place', () async {
      final note = put('5.audio', plain);
      final legacy = put('6.m4a', plain);

      final sealed = await sealPlainAudioCacheFiles(
        seal,
        dir: dir,
        before: epoch.add(const Duration(minutes: 1)),
      );

      expect(sealed, 2);
      expect(note.readAsBytesSync(), _sealedFrom(plain));
      expect(legacy.readAsBytesSync(), _sealedFrom(plain));
      expect(
        dir.listSync().map((e) => e.uri.pathSegments.last),
        unorderedEquals(['5.audio', '6.m4a']),
        reason: 'no temp file is left behind',
      );
    });

    test('a note already sealed is not sealed again', () async {
      final note = put('5.audio', _sealedFrom(plain));

      final sealed = await sealPlainAudioCacheFiles(
        seal,
        dir: dir,
        before: epoch.add(const Duration(minutes: 1)),
      );

      expect(sealed, 0);
      expect(note.readAsBytesSync(), _sealedFrom(plain));
    });

    test('a file written after the sweep began is left alone', () async {
      final fresh = put(
        '5.audio',
        plain,
        modified: epoch.add(const Duration(minutes: 2)),
      );

      await sealPlainAudioCacheFiles(
        seal,
        dir: dir,
        before: epoch.add(const Duration(minutes: 1)),
      );

      expect(fresh.readAsBytesSync(), plain);
    });

    test('a store that cannot seal changes nothing', () async {
      final note = put('5.audio', plain);

      final sealed = await sealPlainAudioCacheFiles(
        (_) async => null,
        dir: dir,
        before: epoch.add(const Duration(minutes: 1)),
      );

      expect(sealed, 0);
      expect(note.readAsBytesSync(), plain);
    });

    test('files that are not cached notes are left alone', () async {
      final part = put('5.audio.part', plain);
      final other = put('notes.txt', plain);

      await sealPlainAudioCacheFiles(
        seal,
        dir: dir,
        before: epoch.add(const Duration(minutes: 1)),
      );

      expect(part.readAsBytesSync(), plain);
      expect(other.readAsBytesSync(), plain);
    });
  });
}
