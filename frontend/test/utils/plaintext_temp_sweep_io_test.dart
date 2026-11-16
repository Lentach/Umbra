import 'dart:io';

import 'package:fireplace/utils/plaintext_temp_sweep_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late Directory support;
  final epoch = DateTime.utc(2026, 11, 16, 12);
  final cutoff = epoch.add(const Duration(minutes: 1));
  final later = epoch.add(const Duration(minutes: 2));

  setUp(() {
    temp = Directory.systemTemp.createTempSync('plaintext_sweep_temp');
    support = Directory.systemTemp.createTempSync('plaintext_sweep_support');
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
    support.deleteSync(recursive: true);
  });

  File put(Directory dir, String path, {DateTime? modified}) {
    final file = File('${dir.path}/$path')..createSync(recursive: true);
    return file
      ..writeAsBytesSync([1, 2, 3])
      ..setLastModifiedSync(modified ?? epoch);
  }

  /// Every path under [dir], relative, with `/` separators.
  List<String> tree(Directory dir) => dir
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path.substring(dir.path.length + 1).replaceAll(r'\', '/'))
      .toList();

  Future<void> sweep() =>
      sweepPlaintextTempDirs(temp: temp, support: support, before: cutoff);

  test('plaintext video a killed process left behind is deleted (A5)', () async {
    put(temp, 'fp_video_42_1763294400000000.mp4');
    put(temp, 'fp_video_probe_1763294400000000.mp4');
    put(temp, 'lc_audio_123.tmp');
    put(support, 'umbra_tx_1763294400000000.mp4');
    put(support, 'umbra_tx_1763294400000000.mp4.p2.mp4');

    await sweep();

    expect(tree(temp), isEmpty);
    expect(tree(support), isEmpty);
  });

  test("file_picker's and image_picker's copies of picked files are deleted",
      () async {
    put(temp, 'file_picker/1763294400000/IMG_0001.jpg');
    put(temp, 'file_picker/1763294400000/contract.pdf');
    put(temp, '3f2a9c1e-5b7d-4e8a-9c0b-1d2e3f4a5b6c/avatar.jpg');

    await sweep();

    expect(tree(temp), isEmpty);
  });

  test('a file created after the sweep began is kept', () async {
    put(temp, 'fp_video_42_1763294500000000.mp4', modified: later);
    put(temp, 'file_picker/1763294500000/IMG_0002.jpg', modified: later);
    put(temp, 'fp_video_41_1763294400000000.mp4');

    await sweep();

    expect(
      tree(temp),
      unorderedEquals([
        'fp_video_42_1763294500000000.mp4',
        'file_picker/1763294500000/IMG_0002.jpg',
      ]),
      reason: 'the older video is the control and goes',
    );
  });

  test("other files in the app's directories are kept", () async {
    put(temp, 'libCachedImageData/a.jpg');
    put(temp, 'thumb_1.jpg');
    put(temp, 'voice_1763294400000.m4a');
    put(support, 'fp_content.db');
    put(temp, 'fp_video_41_1763294400000000.mp4');

    await sweep();

    expect(
      tree(temp),
      unorderedEquals([
        'libCachedImageData/a.jpg',
        'thumb_1.jpg',
        'voice_1763294400000.m4a',
      ]),
      reason: 'a failed voice send is retried from its recording',
    );
    expect(tree(support), ['fp_content.db']);
  });
}
