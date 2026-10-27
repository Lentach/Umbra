import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/encrypted_media_upload_service.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:fireplace/utils/e2e_diag_log.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// Fake upload service: records call args, fires onEncrypted (so the provider
/// writes pending content), then either returns a canned result or throws.
class _FakeMediaUpload extends EncryptedMediaUploadService {
  _FakeMediaUpload({this.throwOnUpload})
    : super(api: ApiService(baseUrl: 'http://test'));

  final Object? throwOnUpload;
  final List<Map<String, Object?>> calls = [];
  String? capturedKey;

  @override
  Future<EncryptedMediaUpload> encryptAndUpload({
    required Uint8List bytes,
    required String token,
    required String mediaType,
    int? duration,
    int? expiresIn,
    String? fileName,
    void Function(String keyBase64, String ivBase64)? onEncrypted,
  }) async {
    calls.add({
      'mediaType': mediaType,
      'token': token,
      'duration': duration,
      'expiresIn': expiresIn,
      'fileName': fileName,
      'bytesLen': bytes.length,
    });
    onEncrypted?.call('K', 'IV');
    capturedKey = 'K';
    if (throwOnUpload != null) throw throwOnUpload!;
    return EncryptedMediaUpload(
      mediaUrl: 'http://test/media/msgs/x.bin',
      keyBase64: 'K',
      ivBase64: 'IV',
      mediaDuration: duration,
    );
  }
}

/// Simulates a socket reconnect landing while the upload bytes are on the
/// wire: `onConnect(isReconnect: true)` wipes `_pendingSendContent` and the
/// exactly-once latch (messaging_provider.dart, "retry was cancelled"), and
/// the send path resumes to find its entry gone.
class _ReconnectMidUpload extends EncryptedMediaUploadService {
  _ReconnectMidUpload(this.onMidUpload)
    : super(api: ApiService(baseUrl: 'http://test'));

  final void Function() onMidUpload;

  @override
  Future<EncryptedMediaUpload> encryptAndUpload({
    required Uint8List bytes,
    required String token,
    required String mediaType,
    int? duration,
    int? expiresIn,
    String? fileName,
    void Function(String keyBase64, String ivBase64)? onEncrypted,
  }) async {
    onEncrypted?.call('K', 'IV');
    onMidUpload();
    return EncryptedMediaUpload(
      mediaUrl: 'http://test/media/msgs/x.bin',
      keyBase64: 'K',
      ivBase64: 'IV',
      mediaDuration: duration,
    );
  }
}

/// E2E-ready fake so _encryptAndSend reaches the socket emit (send path only).
class _SendReadyEncryption extends EncryptionProvider {
  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  final List<String> encryptedPlaintexts = [];
  final Map<String, Map<String, dynamic>> pendingRecords = {};

  @override
  Future<String> encrypt(int recipientId, String plaintext, {int deviceId = 1}) async {
    encryptedPlaintexts.add(plaintext);
    return '1:abc-${encryptedPlaintexts.length}';
  }

  @override
  Future<void> savePendingSendRecord(
    String ciphertext,
    Map<String, dynamic> data,
  ) async {
    pendingRecords[ciphertext] = Map<String, dynamic>.from(data);
  }

  @override
  Future<Map<String, dynamic>?> getDecryptedContent(int messageId) async =>
      null;
}

Future<Uint8List> _solidPng({required int width, required int height}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

MessagingProvider _newProvider() {
  final provider = MessagingProvider();
  final conversations = ConversationsProvider();
  conversations.onConversationsList([
    {
      'id': 10,
      'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
      'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
      'createdAt': '2026-01-01T00:00:00.000Z',
      'unreadCount': 0,
      'lastMessage': null,
    },
  ]);
  provider.setConversationsProvider(conversations);
  provider.setCurrentUserId(1);
  provider.setToken('tok'); // also sets _tokenForReconnect (voice path)
  provider.onConnect(false);
  conversations.openConversation(10);
  return provider;
}

void main() {
  group('MessagingProvider media send — image', () {
    test('routes through the upload service and patches the message', () async {
      final provider = _newProvider();
      final fake = _FakeMediaUpload();
      provider.setMediaUploadServiceForTest(fake);

      await provider.sendImageMessage(
        'tok',
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'a.jpg'),
        2,
      );

      final msg = provider.messages.last;
      // mediaUrl/key/iv are patched BEFORE _encryptAndSend, so they survive even
      // though deliveryStatus ends 'failed' here (no EncryptionProvider in test).
      expect(msg.mediaUrl, 'http://test/media/msgs/x.bin');
      expect(msg.mediaKey, 'K');
      expect(msg.mediaIv, 'IV');
      expect(fake.calls.single['mediaType'], 'image');
      expect(fake.capturedKey, 'K');
    });

    test(
      'keeps media dimensions and ThumbHash encrypted, never in outer emit',
      () async {
        final provider = _newProvider();
        provider.setMediaUploadServiceForTest(_FakeMediaUpload());
        final encryption = _SendReadyEncryption();
        provider.setEncryptionProvider(encryption);
        final emitted = <Map<String, dynamic>>[];
        provider.setEmitCallback((event, data) {
          if (event == 'sendMessage') {
            emitted.add(Map<String, dynamic>.from(data as Map));
          }
        });

        final ok = await provider.sendImageMessage(
          'tok',
          XFile.fromData(await _solidPng(width: 4, height: 2), name: 'a.png'),
          2,
        );

        expect(ok, isTrue);
        final outerPayload = emitted.single;
        expect(outerPayload['messageType'], 'IMAGE');
        expect(outerPayload['mediaUrl'], 'http://test/media/msgs/x.bin');
        expect(outerPayload.containsKey('mediaWidth'), isFalse);
        expect(outerPayload.containsKey('mediaHeight'), isFalse);
        expect(outerPayload.containsKey('mediaThumbHash'), isFalse);

        final innerEnvelope = E2eEnvelope.parse(
          encryption.encryptedPlaintexts.single,
        );
        expect(innerEnvelope.mediaWidth, 4);
        expect(innerEnvelope.mediaHeight, 2);
        expect(innerEnvelope.mediaThumbHash, isNotNull);
        expect(innerEnvelope.mediaThumbHash, isNotEmpty);

        final pendingSnapshot =
            encryption.pendingRecords[outerPayload['encryptedContent']];
        expect(pendingSnapshot?['mediaWidth'], 4);
        expect(pendingSnapshot?['mediaHeight'], 2);
        expect(pendingSnapshot?['mediaThumbHash'], isNotEmpty);
      },
    );

    test('marks the message failed (no mediaUrl) when upload throws', () async {
      final provider = _newProvider();
      provider.setMediaUploadServiceForTest(
        _FakeMediaUpload(throwOnUpload: Exception('boom')),
      );

      await provider.sendImageMessage(
        'tok',
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'a.jpg'),
        2,
      );

      final msg = provider.messages.last;
      expect(msg.deliveryStatus, MessageDeliveryStatus.failed);
      expect(
        msg.mediaUrl,
        isNull,
      ); // never patched — upload threw before the patch
    });
  });

  group('MessagingProvider media send — video', () {
    test(
      'carries geometry and ThumbHash inside the envelope, never in the '
      'outer emit',
      () async {
        final provider = _newProvider();
        provider.setMediaUploadServiceForTest(_FakeMediaUpload());
        final encryption = _SendReadyEncryption();
        provider.setEncryptionProvider(encryption);
        final emitted = <Map<String, dynamic>>[];
        provider.setEmitCallback((event, data) {
          if (event == 'sendMessage') {
            emitted.add(Map<String, dynamic>.from(data as Map));
          }
        });

        final ok = await provider.sendVideoMessage(
          'tok',
          Uint8List.fromList([1, 2, 3]),
          2,
          duration: 19,
          width: 360,
          height: 480,
          thumbHash: 'video-thumb-hash',
        );

        expect(ok, isTrue);
        final outerPayload = emitted.single;
        expect(outerPayload['messageType'], 'VIDEO');
        // Geometry is content, not metadata: the server must stay blind to it.
        expect(outerPayload.containsKey('mediaWidth'), isFalse);
        expect(outerPayload.containsKey('mediaHeight'), isFalse);
        expect(outerPayload.containsKey('mediaThumbHash'), isFalse);

        final innerEnvelope = E2eEnvelope.parse(
          encryption.encryptedPlaintexts.single,
        );
        expect(innerEnvelope.mediaWidth, 360);
        expect(innerEnvelope.mediaHeight, 480);
        expect(innerEnvelope.mediaThumbHash, 'video-thumb-hash');

        // The durable pending-send record is the only surviving plaintext copy
        // when the ack is lost, so it must carry the geometry too.
        final pendingSnapshot =
            encryption.pendingRecords[outerPayload['encryptedContent']];
        expect(pendingSnapshot?['mediaWidth'], 360);
        expect(pendingSnapshot?['mediaHeight'], 480);
        expect(pendingSnapshot?['mediaThumbHash'], 'video-thumb-hash');
      },
    );

    test(
      'a RETRY after the upload succeeded still carries geometry and '
      'ThumbHash in the envelope',
      () async {
        // Regression: the video retry branch rebuilt the pending payload from
        // url/key/iv/duration only, so a clip that failed once and was retried
        // reached the peer with no geometry — the 220 px legacy square with a
        // blank poster — while the first attempt's optimistic bubble looked
        // right. Images never had this hole; video must match them.
        final provider = _newProvider();
        provider.setMediaUploadServiceForTest(_FakeMediaUpload());
        final encryption = _SendReadyEncryption();
        provider.setEncryptionProvider(encryption);
        final emitted = <Map<String, dynamic>>[];
        provider.setEmitCallback((event, data) {
          if (event == 'sendMessage') {
            emitted.add(Map<String, dynamic>.from(data as Map));
          }
        });

        await provider.sendVideoMessage(
          'tok',
          Uint8List.fromList([1, 2, 3]),
          2,
          duration: 19,
          width: 360,
          height: 480,
          thumbHash: 'video-thumb-hash',
        );
        final tempId = emitted.single['tempId'] as String;

        provider.markSendingMessagesFailed('dropped');
        await provider.retryFailedMessage(tempId);
        for (var i = 0; i < 30; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(emitted, hasLength(2));
        final retried = E2eEnvelope.parse(encryption.encryptedPlaintexts.last);
        expect(retried.mediaUrl, 'http://test/media/msgs/x.bin');
        expect(retried.mediaWidth, 360);
        expect(retried.mediaHeight, 480);
        expect(retried.mediaThumbHash, 'video-thumb-hash');
        expect(retried.mediaDuration, 19);
      },
    );

    test('optimistic bubble carries geometry before the upload resolves', () async {
      final provider = _newProvider();
      provider.setMediaUploadServiceForTest(
        _FakeMediaUpload(throwOnUpload: Exception('boom')),
      );

      await provider.sendVideoMessage(
        'tok',
        Uint8List.fromList([1, 2, 3]),
        2,
        duration: 19,
        width: 360,
        height: 480,
        thumbHash: 'video-thumb-hash',
      );

      // Upload threw, so mediaUrl was never patched — but the bubble must
      // still be correctly shaped, because geometry is known before upload.
      final msg = provider.messages.last;
      expect(msg.deliveryStatus, MessageDeliveryStatus.failed);
      expect(msg.mediaUrl, isNull);
      expect(msg.mediaWidth, 360);
      expect(msg.mediaHeight, 480);
      expect(msg.mediaThumbHash, 'video-thumb-hash');
    });

    test('rejects a clip longer than the duration cap without uploading', () async {
      final provider = _newProvider();
      final fake = _FakeMediaUpload();
      provider.setMediaUploadServiceForTest(fake);

      final ok = await provider.sendVideoMessage(
        'tok',
        Uint8List.fromList([1, 2, 3]),
        2,
        duration: MediaCryptoService.maxVideoDurationSeconds + 1,
      );

      expect(ok, isFalse);
      expect(fake.calls, isEmpty); // backstop fires BEFORE encrypt/upload
      expect(provider.messages.last.deliveryStatus,
          MessageDeliveryStatus.failed);
    });

    test('accepts a clip exactly at the duration cap', () async {
      final provider = _newProvider();
      final fake = _FakeMediaUpload();
      provider.setMediaUploadServiceForTest(fake);

      await provider.sendVideoMessage(
        'tok',
        Uint8List.fromList([1, 2, 3]),
        2,
        duration: MediaCryptoService.maxVideoDurationSeconds,
      );

      expect(fake.calls.single['mediaType'], 'video');
      expect(fake.calls.single['duration'],
          MediaCryptoService.maxVideoDurationSeconds);
    });
  });

  group('MessagingProvider media send — voice', () {
    test('routes through the upload service with duration', () async {
      final provider = _newProvider();
      final fake = _FakeMediaUpload();
      provider.setMediaUploadServiceForTest(fake);

      await provider.sendVoiceMessage(
        recipientId: 2,
        duration: 5,
        conversationId: 10,
        localAudioBytes: Uint8List.fromList([1, 2, 3]),
      );

      final msg = provider.messages.last;
      expect(msg.mediaUrl, 'http://test/media/msgs/x.bin');
      expect(
        msg.mediaDuration,
        5,
      ); // serverDuration = upload.mediaDuration ?? duration
      expect(msg.mediaKey, 'K');
      expect(fake.calls.single['mediaType'], 'voice');
      expect(fake.calls.single['duration'], 5);
    });

    test('marks the message failed when upload throws', () async {
      final provider = _newProvider();
      provider.setMediaUploadServiceForTest(
        _FakeMediaUpload(throwOnUpload: Exception('boom')),
      );

      await provider.sendVoiceMessage(
        recipientId: 2,
        duration: 5,
        conversationId: 10,
        localAudioBytes: Uint8List.fromList([1, 2, 3]),
      );

      expect(
        provider.messages.last.deliveryStatus,
        MessageDeliveryStatus.failed,
      );
    });
  });

  group('MessagingProvider media send — file', () {
    test(
      'routes through the upload service with fileName and no expiresIn',
      () async {
        final provider = _newProvider();
        final fake = _FakeMediaUpload();
        provider.setMediaUploadServiceForTest(fake);

        await provider.sendFileMessage(
          'tok',
          Uint8List.fromList([1, 2, 3]),
          'doc.pdf',
          'application/pdf',
          2,
        );

        final msg = provider.messages.last;
        expect(msg.mediaUrl, 'http://test/media/msgs/x.bin');
        expect(msg.content, 'doc.pdf');
        expect(fake.calls.single['mediaType'], 'file');
        expect(fake.calls.single['fileName'], 'doc.pdf');
        expect(fake.calls.single['expiresIn'], isNull);
      },
    );

    test('marks the message failed (no mediaUrl) when upload throws', () async {
      final provider = _newProvider();
      provider.setMediaUploadServiceForTest(
        _FakeMediaUpload(throwOnUpload: Exception('boom')),
      );

      await provider.sendFileMessage(
        'tok',
        Uint8List.fromList([1, 2, 3]),
        'doc.pdf',
        'application/pdf',
        2,
      );

      final msg = provider.messages.last;
      expect(msg.deliveryStatus, MessageDeliveryStatus.failed);
      expect(msg.mediaUrl, isNull);
    });
  });

  group('sendImageMessage ordering contract (Clipboard Phase 2)', () {
    test('completes only after the IMAGE emit and returns true', () async {
      final provider = _newProvider();
      provider.setMediaUploadServiceForTest(_FakeMediaUpload());
      provider.setEncryptionProvider(_SendReadyEncryption());
      final emitted = <String>[];
      provider.setEmitCallback((event, data) {
        if (event == 'sendMessage') {
          emitted.add((data as Map)['messageType'] as String? ?? 'TEXT');
        }
      });

      final ok = await provider.sendImageMessage(
        'tok',
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'a.jpg'),
        2,
      );

      expect(ok, isTrue);
      // THE contract: when the Future completes, the emit already happened.
      expect(emitted, ['IMAGE']);

      provider.sendMessage('caption');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(emitted, ['IMAGE', 'TEXT']); // caption strictly after image
    });

    // A paperclip batch starts the next file the moment the previous one is
    // emitted; two sends that start within one millisecond must both go out.
    test('two images started in the same millisecond both go out', () async {
      final emitted = <String>[];
      final provider = _newProvider()
        ..setMediaUploadServiceForTest(_FakeMediaUpload())
        ..setEncryptionProvider(_SendReadyEncryption())
        ..setEmitCallback((event, data) {
          if (event == 'sendMessage') emitted.add(event);
        });

      XFile image() =>
          XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'a.jpg');
      final sent = await withClock(
        Clock.fixed(DateTime.utc(2026, 10, 27, 12)),
        () => Future.wait([
          provider.sendImageMessage('tok', image(), 2),
          provider.sendImageMessage('tok', image(), 2),
        ]),
      );

      expect(sent, [isTrue, isTrue]);
      expect(emitted, hasLength(2));
    });

    test('returns false when upload throws', () async {
      final provider = _newProvider();
      provider.setMediaUploadServiceForTest(
        _FakeMediaUpload(throwOnUpload: Exception('boom')),
      );
      provider.setEncryptionProvider(_SendReadyEncryption());

      final ok = await provider.sendImageMessage(
        'tok',
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'a.jpg'),
        2,
      );

      expect(ok, isFalse);
    });

    test('returns false when E2E is not ready', () async {
      final provider = _newProvider(); // no EncryptionProvider set
      provider.setMediaUploadServiceForTest(_FakeMediaUpload());

      final ok = await provider.sendImageMessage(
        'tok',
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'a.jpg'),
        2,
      );

      expect(ok, isFalse);
    });
  });

  group('MEDIA_ORPHAN_LIKELY diagnostic (I1 observability)', () {
    test('logged when a media send fails AFTER a successful upload', () async {
      // Upload succeeds (fake returns a mediaUrl) but no EncryptionProvider is
      // set, so _encryptAndSend fails on the !e2eReady path → the blob is
      // uploaded yet never referenced by an emitted message = orphan-likely.
      final provider = _newProvider();
      provider.setMediaUploadServiceForTest(_FakeMediaUpload());
      E2eDiagLog.clear();

      final ok = await provider.sendImageMessage(
        'tok',
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'a.jpg'),
        2,
      );

      expect(ok, isFalse);
      final orphanEvents = E2eDiagLog.entries
          .where((e) => e.contains('MEDIA_ORPHAN_LIKELY'))
          .toList();
      expect(orphanEvents, hasLength(1));
      expect(orphanEvents.single, contains('tempId'));
    });

    test('NOT logged for a text send failure (nothing was uploaded)', () async {
      final provider = _newProvider(); // no EncryptionProvider → E2E not ready
      E2eDiagLog.clear();

      provider.sendMessage('hello');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        E2eDiagLog.entries.where((e) => e.contains('MEDIA_ORPHAN_LIKELY')),
        isEmpty,
      );
    });
  });

  group('reconnect during an in-flight media upload', () {
    // onConnect(isReconnect: true) clears _pendingSendContent while the
    // upload await is still pending. The old code then crashed on
    // `_pendingSendContent[tempId]!` into the generic catch; the contract is
    // a CLEAN failure — bubble marked failed, send returns false, no emit.
    test('video send fails cleanly instead of throwing', () async {
      final provider = _newProvider();
      provider.setMediaUploadServiceForTest(
        _ReconnectMidUpload(() => provider.onConnect(true)),
      );
      provider.setEncryptionProvider(_SendReadyEncryption());
      final emitted = <String>[];
      provider.setEmitCallback((event, data) {
        if (event == 'sendMessage') emitted.add(event);
      });

      final ok = await provider.sendVideoMessage(
        'tok',
        List<int>.filled(64, 7),
        2,
        duration: 5,
      );

      expect(ok, isFalse);
      expect(emitted, isEmpty);
      final msg = provider.messages.last;
      expect(msg.messageType, MessageType.video);
      expect(msg.deliveryStatus, MessageDeliveryStatus.failed);
    });

    test('image send fails cleanly instead of throwing', () async {
      final provider = _newProvider();
      provider.setMediaUploadServiceForTest(
        _ReconnectMidUpload(() => provider.onConnect(true)),
      );
      provider.setEncryptionProvider(_SendReadyEncryption());
      final emitted = <String>[];
      provider.setEmitCallback((event, data) {
        if (event == 'sendMessage') emitted.add(event);
      });

      final ok = await provider.sendImageMessage(
        'tok',
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'a.jpg'),
        2,
      );

      expect(ok, isFalse);
      expect(emitted, isEmpty);
      expect(
        provider.messages.last.deliveryStatus,
        MessageDeliveryStatus.failed,
      );
    });
  });
}
