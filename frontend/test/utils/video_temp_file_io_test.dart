import 'dart:io';

import 'package:fireplace/utils/video_temp_file_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late Directory support;
  final epoch = DateTime.utc(2026, 11, 16, 12);
  final cutoff = epoch.add(const Duration(minutes: 1));

  setUp(() {
    temp = Directory.systemTemp.createTempSync('video_sweep_temp');
    support = Directory.systemTemp.createTempSync('video_sweep_support');
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
    support.deleteSync(recursive: true);
  });

  File put(Directory dir, String name, {DateTime? modified}) {
    return File('${dir.path}/$name')
      ..writeAsBytesSync([1, 2, 3])
      ..setLastModifiedSync(modified ?? epoch);
  }

  List<String> names(Directory dir) =>
      dir.listSync().map((e) => e.uri.pathSegments.last).toList();

  group('sweepVideoTempDirs (hardening A5)', () {
    test('plaintext video a killed process left behind is deleted', () async {
      put(temp, 'fp_video_42_1763294400000000.mp4');
      put(temp, 'fp_video_probe_1763294400000000.mp4');
      put(temp, 'lc_audio_123.tmp');
      put(support, 'umbra_tx_1763294400000000.mp4');
      put(support, 'umbra_tx_1763294400000000.mp4.p2.mp4');

      final deleted = await sweepVideoTempDirs(
        temp: temp,
        support: support,
        before: cutoff,
      );

      expect(deleted, 5);
      expect(names(temp), isEmpty);
      expect(names(support), isEmpty);
    });

    test('a video opened after the sweep began is kept', () async {
      put(
        temp,
        'fp_video_42_1763294500000000.mp4',
        modified: epoch.add(const Duration(minutes: 2)),
      );

      await sweepVideoTempDirs(temp: temp, support: support, before: cutoff);

      expect(names(temp), ['fp_video_42_1763294500000000.mp4']);
    });

    test("other files in the app's directories are kept", () async {
      put(temp, 'libCachedImageData');
      put(temp, 'thumb_1.jpg');
      put(support, 'fp_content.db');

      await sweepVideoTempDirs(temp: temp, support: support, before: cutoff);

      expect(names(temp), unorderedEquals(['libCachedImageData', 'thumb_1.jpg']));
      expect(names(support), ['fp_content.db']);
    });
  });
}
