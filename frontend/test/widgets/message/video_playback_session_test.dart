import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/widgets/message/video_playback_session.dart';
import 'package:flutter_test/flutter_test.dart';

MessageModel _video() => MessageModel(
  id: 7,
  content: '',
  senderId: 1,
  senderUsername: 'alice',
  conversationId: 10,
  deliveryStatus: MessageDeliveryStatus.read,
  messageType: MessageType.video,
  createdAt: DateTime(2026, 1, 1, 14, 30),
  mediaUrl: 'https://example.com/media/msgs/v.bin',
  encryptedContent: 'cipher',
);

Future<Uint8List> _bytes({
  required String url,
  String? key,
  String? iv,
  Object? box,
}) async => Uint8List.fromList([1, 2, 3]);

void main() {
  // A3-MSG-A-09: a session closed while the decrypted file is being written
  // must delete it itself; nothing else ever would.
  test('close during the temp-file write deletes the plaintext file', () async {
    final dir = Directory.systemTemp.createTempSync('fp_video_session_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}clip.mp4');
    final writing = Completer<void>();
    final started = Completer<void>();

    final session = VideoPlaybackSession(
      message: _video(),
      loadBytes: _bytes,
      writeTempFile: (bytes, id) async {
        file.writeAsBytesSync(bytes);
        started.complete();
        await writing.future;
        return file.path;
      },
    );

    final result = session.load();
    await started.future;
    expect(file.existsSync(), isTrue);

    session.dispose();
    writing.complete();

    expect(await result, VideoStageError.unplayable);
    // deleteVideoTempFile is fire-and-forget; give it real IO turns.
    for (var i = 0; i < 50 && file.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(file.existsSync(), isFalse);
  });

  test('close during the fetch never writes a file', () async {
    final fetching = Completer<Uint8List>();
    var writes = 0;
    final session = VideoPlaybackSession(
      message: _video(),
      loadBytes:
          ({required url, key, iv, box}) => fetching.future,
      writeTempFile: (bytes, id) async {
        writes++;
        return '';
      },
    );

    final result = session.load();
    session.dispose();
    fetching.complete(Uint8List.fromList([1]));

    expect(await result, VideoStageError.unplayable);
    expect(writes, 0);
  });
}
