import 'dart:io';

import 'package:fireplace/utils/download_utils_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A3-MSG-A-04: "Save image" / "Download" put decrypted bytes on the device.
/// They go to ONE subfolder of the app documents directory so the logout and
/// the local-data wipes can delete exactly them, and nothing the app owns.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  late Directory docs;

  File saved(String name) => File('${docs.path}/saved_downloads/$name');

  setUp(() {
    docs = Directory.systemTemp.createTempSync('saved_downloads_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async => docs.path);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    docs.deleteSync(recursive: true);
  });

  test('a saved file lands in the dedicated subfolder, never at the top of '
      'the documents directory', () async {
    await saveBytesAsDownload([1, 2, 3], 'photo.png');

    expect(saved('photo.png').readAsBytesSync(), [1, 2, 3]);
    expect(File('${docs.path}/photo.png').existsSync(), isFalse);
  });

  test('deleting the saved copies removes the subfolder and only what the '
      'old save code wrote', () async {
    await saveBytesAsDownload([1], 'contract.pdf');
    // Before this change both save sites wrote straight into the documents
    // directory; the gallery's name is `image_<messageId>.<ext>` and nothing
    // else in the app writes a name of that shape there.
    File('${docs.path}/image_12.png').writeAsBytesSync([2]);
    File('${docs.path}/image_-3.jpg').writeAsBytesSync([2]);
    // Not the app's save shape: a user-named document from the old code can
    // not be told apart from a file the app owns, so it stays.
    File('${docs.path}/notes.pdf').writeAsBytesSync([3]);
    File('${docs.path}/image_final.png').writeAsBytesSync([3]);
    // The app's own data.
    final audio = File('${docs.path}/audio_cache/7.audio')
      ..createSync(recursive: true)
      ..writeAsBytesSync([4]);

    final ok = await deleteSavedDownloads();

    expect(ok, isTrue);
    expect(Directory('${docs.path}/saved_downloads').existsSync(), isFalse);
    expect(File('${docs.path}/image_12.png').existsSync(), isFalse);
    expect(File('${docs.path}/image_-3.jpg').existsSync(), isFalse);
    expect(File('${docs.path}/notes.pdf').existsSync(), isTrue);
    expect(File('${docs.path}/image_final.png').existsSync(), isTrue);
    expect(audio.existsSync(), isTrue);
  });

  test('with nothing saved the delete is a clean no-op', () async {
    expect(await deleteSavedDownloads(), isTrue);
  });
}
