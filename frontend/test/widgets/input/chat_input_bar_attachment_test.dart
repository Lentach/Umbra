import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/encrypted_media_upload_service.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/input/chat_input_bar.dart';
import 'package:fireplace/widgets/input/composer_attachment_controller.dart';
import 'package:fireplace/widgets/input/picked_attachment.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 1x1 transparent PNG so Image.memory decodes without errors.
final kTinyPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _FakeMediaUpload extends EncryptedMediaUploadService {
  _FakeMediaUpload({this.throwOnUpload})
    : super(api: ApiService(baseUrl: 'http://test'));

  final Object? throwOnUpload;

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
    if (throwOnUpload != null) throw throwOnUpload!;
    return EncryptedMediaUpload(
      mediaUrl: 'http://test/media/msgs/x.bin',
      keyBase64: 'K',
      ivBase64: 'IV',
      mediaDuration: duration,
    );
  }
}

class _SendReadyEncryption extends EncryptionProvider {
  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  @override
  Future<String> encrypt(int recipientId, String plaintext, {int deviceId = 1}) async => '1:abc';

  @override
  Future<Map<String, dynamic>?> getDecryptedContent(int messageId) async =>
      null;
}

Future<
  ({
    GlobalKey<ChatInputBarState> key,
    List<String> emitted,
    List<Map<String, dynamic>> emittedData,
    ConversationsProvider convs,
  })
>
pumpComposer(WidgetTester tester, {Object? throwOnUpload}) async {
  final key = GlobalKey<ChatInputBarState>();
  final emitted = <String>[];
  final emittedData = <Map<String, dynamic>>[];

  final convs = ConversationsProvider();
  convs.onConversationsList([
    {
      'id': 10,
      'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
      'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
      'createdAt': '2026-01-01T00:00:00.000Z',
      'unreadCount': 0,
      'lastMessage': null,
    },
  ]);
  convs.openConversation(10);

  final messaging = MessagingProvider();
  messaging.setConversationsProvider(convs);
  messaging.setCurrentUserId(1);
  messaging.setToken('tok');
  messaging.onConnect(false);
  messaging.setMediaUploadServiceForTest(
    _FakeMediaUpload(throwOnUpload: throwOnUpload),
  );
  messaging.setEncryptionProvider(_SendReadyEncryption());
  messaging.setEmitCallback((event, data) {
    if (event == 'sendMessage') {
      final map = Map<String, dynamic>.from(data as Map);
      emitted.add(map['messageType'] as String? ?? 'TEXT');
      emittedData.add(map);
    }
  });

  final auth = AuthProvider()..setAccessTokenForTest('tok');

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: RpgTheme.themeDataLight,
      home: Scaffold(
        body: MultiProvider(
          providers: [
            ChangeNotifierProvider<ConversationsProvider>.value(value: convs),
            ChangeNotifierProvider<MessagingProvider>.value(value: messaging),
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider(
              create: (_) => SettingsProvider(initialThemePreference: 'light'),
            ),
          ],
          child: ChatInputBar(key: key),
        ),
      ),
    ),
  );
  return (key: key, emitted: emitted, emittedData: emittedData, convs: convs);
}

void main() {
  // AuthProvider reads its saved token on construction; without a mock that
  // channel call fails asynchronously and lands in whichever test runs then.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('staged image shows chip; remove clears it', (tester) async {
    final h = await pumpComposer(tester);

    h.key.currentState!.attachmentControllerForTest.stage(
      bytes: kTinyPng,
      mimeType: 'image/png',
      filename: 'pasted.png',
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('composer_attachment_thumb')),
      findsOneWidget,
    );
    expect(find.text('pasted.png'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('composer_attachment_remove')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('composer_attachment_thumb')),
      findsNothing,
    );
  });

  testWidgets('send affordance visible with staged image and empty text', (
    tester,
  ) async {
    final h = await pumpComposer(tester);
    final layer = find.byKey(const ValueKey('composer_text_send_layer'));

    AnimatedOpacity opacityOf() => tester.widget<AnimatedOpacity>(
      find.descendant(of: layer, matching: find.byType(AnimatedOpacity)),
    );

    expect(opacityOf().opacity, 0.0); // empty composer: mic showing

    h.key.currentState!.attachmentControllerForTest.stage(
      bytes: kTinyPng,
      mimeType: 'image/png',
      filename: 'pasted.png',
    );
    await tester.pumpAndSettle();

    expect(opacityOf().opacity, 1.0);
  });

  testWidgets('send: image emits before caption; composer fully cleared', (
    tester,
  ) async {
    final h = await pumpComposer(tester);

    h.key.currentState!.attachmentControllerForTest.stage(
      bytes: kTinyPng,
      mimeType: 'image/png',
      filename: 'pasted.png',
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'my caption');

    await tester.runAsync(() => h.key.currentState!.sendForTest());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    expect(h.emitted, ['IMAGE', 'TEXT']); // ordering contract end-to-end
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(
      find.byKey(const ValueKey('composer_attachment_thumb')),
      findsNothing,
    );
  });

  testWidgets('image failure: caption restored, no TEXT emit, can retry send', (
    tester,
  ) async {
    final h = await pumpComposer(tester, throwOnUpload: Exception('boom'));

    h.key.currentState!.attachmentControllerForTest.stage(
      bytes: kTinyPng,
      mimeType: 'image/png',
      filename: 'pasted.png',
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'my caption');

    await tester.runAsync(() => h.key.currentState!.sendForTest());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    expect(h.emitted, isEmpty); // upload threw pre-emit; caption NOT auto-sent
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'my caption', // ordering contract rule 3: user keeps their words
    );
    expect(
      find.byKey(const ValueKey('composer_attachment_thumb')),
      findsNothing,
    ); // failed optimistic bubble owns retry, not the chip

    // Guard reset: a plain text send still works afterwards.
    await tester.runAsync(() => h.key.currentState!.sendForTest());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.emitted, ['TEXT']);
  });

  testWidgets('pasted text inserts at the cursor, replacing the selection', (
    tester,
  ) async {
    final h = await pumpComposer(tester);
    await tester.enterText(find.byType(TextField), 'hello world');
    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    controller.selection = const TextSelection(baseOffset: 6, extentOffset: 11);

    h.key.currentState!.insertPastedTextForTest('there');
    await tester.pump();

    expect(controller.text, 'hello there');
    expect(controller.selection, const TextSelection.collapsed(offset: 11));
  });

  testWidgets('oversize pasted image: snackbar, nothing staged', (
    tester,
  ) async {
    final h = await pumpComposer(tester);

    h.key.currentState!.handlePastedImageForTest(
      Uint8List(MediaCryptoService.maxBytes + 1),
      'image/png',
      'huge.png',
    );
    await tester.pump();

    expect(find.text('Image is too large (max 20 MB)'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('composer_attachment_thumb')),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
  });

  testWidgets('unsupported pasted image type: snackbar, nothing staged', (
    tester,
  ) async {
    final h = await pumpComposer(tester);

    h.key.currentState!.handlePastedImageForTest(
      kTinyPng,
      'image/tiff', // image/* but outside kStageableImageMimeTypes
      'scan.tiff',
    );
    await tester.pump();

    expect(find.text("This image type can't be pasted"), findsOneWidget);
    expect(
      find.byKey(const ValueKey('composer_attachment_thumb')),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('valid pasted image stages the chip via the paste handler', (
    tester,
  ) async {
    final h = await pumpComposer(tester);

    h.key.currentState!.handlePastedImageForTest(
      kTinyPng,
      'image/png',
      'pasted.png',
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('composer_attachment_thumb')),
      findsOneWidget,
    );
  });

  testWidgets('keyboard commitContent with bytes stages the chip', (
    tester,
  ) async {
    await pumpComposer(tester);
    final tf = tester.widget<TextField>(find.byType(TextField));
    final config = tf.contentInsertionConfiguration;

    expect(config, isNotNull);
    expect(config!.allowedMimeTypes, containsAll(kStageableImageMimeTypes));

    config.onContentInserted(
      KeyboardInsertedContent(
        mimeType: 'image/png',
        uri: 'content://clipboard/0',
        data: kTinyPng,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('composer_attachment_thumb')),
      findsOneWidget,
    );
  });

  testWidgets('keyboard commitContent without bytes shows honest snackbar', (
    tester,
  ) async {
    await pumpComposer(tester);
    final config = tester
        .widget<TextField>(find.byType(TextField))
        .contentInsertionConfiguration!;

    config.onContentInserted(
      const KeyboardInsertedContent(
        mimeType: 'image/png',
        uri: 'content://clipboard/0',
      ),
    );
    await tester.pump();

    expect(find.text("Couldn't read the pasted image"), findsOneWidget);
    expect(
      find.byKey(const ValueKey('composer_attachment_thumb')),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
  });

  group('picked video sends immediately (owner ruling 2026-08-31)', () {
    // The duration probe resolves to the dart:io implementation under
    // flutter_test, where path_provider has no platform binding, so it answers
    // VideoPreview.unknown. That is the honest "platform could not read it"
    // path: duration/geometry are omitted and the send proceeds regardless.
    testWidgets('picking a video SENDS it — no chip, VIDEO emitted', (
      tester,
    ) async {
      final h = await pumpComposer(tester);

      await tester.runAsync(
        () => h.key.currentState!.sendPickedVideo(
          bytes: Uint8List(64),
          filename: 'clip.mp4',
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));

      expect(h.emitted, ['VIDEO']);
      // Nothing stages: no chip, and the staging controller stays empty.
      expect(
        find.byKey(const ValueKey('composer_attachment_thumb')),
        findsNothing,
      );
      expect(h.key.currentState!.attachmentControllerForTest.staged, isNull);
    });

    testWidgets('a typed caption is NOT consumed by the video send', (
      tester,
    ) async {
      final h = await pumpComposer(tester);
      await tester.enterText(find.byType(TextField), 'my caption');

      await tester.runAsync(
        () => h.key.currentState!.sendPickedVideo(
          bytes: Uint8List(64),
          filename: 'clip.mp4',
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));

      // Immediate send has no staging step to attach a caption to, so the
      // draft must survive rather than be silently sent or dropped.
      expect(h.emitted, ['VIDEO']);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'my caption',
      );
    });

    testWidgets('oversize video: toast, nothing sent', (tester) async {
      final h = await pumpComposer(tester);

      await tester.runAsync(
        () => h.key.currentState!.sendPickedVideo(
          bytes: Uint8List(MediaCryptoService.maxBytes + 1),
          filename: 'huge.mp4',
        ),
      );
      await tester.pump();

      // maxBytes + 1 is 20.000001 MB; the toast names the actual size so the
      // user learns WHY the clip failed, not just that a limit exists.
      expect(
        find.text('Video is too large (20.0 MB, max 20 MB)'),
        findsOneWidget,
      );
      expect(h.emitted, isEmpty);
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    testWidgets('oversize video transcodes and sends when the codec fits it', (
      tester,
    ) async {
      final h = await pumpComposer(tester);
      addTearDown(() => ChatInputBarState.debugTranscodeOverride = null);
      final received = <int>[];
      ChatInputBarState.debugTranscodeOverride = (bytes) async {
        received.add(bytes.length);
        return Uint8List(1024); // codec fit it under the cap
      };

      await tester.runAsync(
        () => h.key.currentState!.sendPickedVideo(
          bytes: Uint8List(MediaCryptoService.maxBytes + 1),
          filename: 'huge.mp4',
        ),
      );
      await tester.pump();

      // The transcode saw the ORIGINAL bytes, the user saw the progress toast,
      // and the send went out — no "too large" refusal.
      expect(received, [MediaCryptoService.maxBytes + 1]);
      expect(h.emitted, ['VIDEO']);
      expect(find.textContaining('too large'), findsNothing);
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    testWidgets('transcode that stays oversize still refuses the send', (
      tester,
    ) async {
      // Physics case: the codec's 2 Mbps floor means a long clip can come out
      // of the transcode still over the cap. That MUST refuse, not upload.
      final h = await pumpComposer(tester);
      addTearDown(() => ChatInputBarState.debugTranscodeOverride = null);
      ChatInputBarState.debugTranscodeOverride = (bytes) async =>
          Uint8List(MediaCryptoService.maxBytes + 1);

      await tester.runAsync(
        () => h.key.currentState!.sendPickedVideo(
          bytes: Uint8List(MediaCryptoService.maxBytes + 1),
          filename: 'huge.mp4',
        ),
      );
      await tester.pump();

      expect(
        find.text('Video is too large (20.0 MB, max 20 MB)'),
        findsOneWidget,
      );
      expect(h.emitted, isEmpty);
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    testWidgets('wrong extension: toast, nothing sent', (tester) async {
      final h = await pumpComposer(tester);

      await tester.runAsync(
        () => h.key.currentState!.sendPickedVideo(
          bytes: Uint8List(64),
          filename: 'clip.avi',
        ),
      );
      await tester.pump();

      // The last gate before an IMMEDIATE, unconfirmed send.
      expect(find.text('Unsupported video format (MP4 only)'), findsOneWidget);
      expect(h.emitted, isEmpty);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('paperclip picks send immediately (owner ruling 2026-10-27)', () {
    PickedAttachment photo(String name) =>
        PickedAttachment(name: name, readBytes: () async => kTinyPng);

    // The duration probe answers VideoPreview.unknown under flutter_test (see
    // the group above); the send proceeds regardless.
    testWidgets('every file goes out at once, one message each, in pick '
        'order; nothing stages and the draft stays', (tester) async {
      final h = await pumpComposer(tester);
      await tester.enterText(find.byType(TextField), 'half-typed');

      await tester.runAsync(
        () => h.key.currentState!.sendPickedFiles([
          photo('a.jpg'),
          PickedAttachment(
            name: 'clip.mp4',
            readBytes: () async => Uint8List(64),
          ),
          photo('b.png'),
        ]),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));

      expect(h.emitted, ['IMAGE', 'VIDEO', 'IMAGE']);
      expect(h.key.currentState!.attachmentControllerForTest.staged, isNull);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'half-typed',
      );
    });

    testWidgets('a pick over the cap sends the first $kMaxFilesPerPick and '
        'says so', (tester) async {
      final h = await pumpComposer(tester);

      await tester.runAsync(
        () => h.key.currentState!.sendPickedFiles([
          for (var i = 0; i < kMaxFilesPerPick + 2; i++) photo('p$i.jpg'),
        ]),
      );
      await tester.pump();

      expect(h.emitted, List.filled(kMaxFilesPerPick, 'IMAGE'));
      expect(
        find.text(
          'Up to $kMaxFilesPerPick files at a time — sending the first '
          '$kMaxFilesPerPick',
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    // The provider sends into the ACTIVE chat: a file that kept going after
    // the user left would land in whichever chat is open by then.
    testWidgets('leaving the chat mid-batch stops it and says so', (
      tester,
    ) async {
      final h = await pumpComposer(tester);

      await tester.runAsync(
        () => h.key.currentState!.sendPickedFiles([
          photo('a.jpg'),
          PickedAttachment(
            name: 'b.jpg',
            readBytes: () async {
              h.convs.closeConversation();
              return kTinyPng;
            },
          ),
          photo('c.jpg'),
        ]),
      );
      await tester.pump();

      expect(h.emitted, ['IMAGE']);
      expect(
        find.text('Some files were not sent — you left the chat'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    // Desktop split view keeps this composer mounted across a chat switch, and
    // a video awaits its transcode and probe AFTER the per-file check: a
    // switch during that wait must not send the clip into the new chat.
    testWidgets('switching chats while a video is being prepared sends it '
        'nowhere and says so', (tester) async {
      final h = await pumpComposer(tester);
      Map<String, dynamic> conv(int id, int peerId, String peer) => {
        'id': id,
        'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
        'userTwo': {'id': peerId, 'username': peer, 'tag': '0003'},
        'createdAt': '2026-01-01T00:00:00.000Z',
        'unreadCount': 0,
        'lastMessage': null,
      };
      h.convs.onConversationsList([conv(10, 2, 'bob'), conv(11, 3, 'carol')]);
      addTearDown(() => ChatInputBarState.debugTranscodeOverride = null);
      ChatInputBarState.debugTranscodeOverride = (bytes) async {
        h.convs.openConversation(11);
        return Uint8List(1024);
      };

      await tester.runAsync(
        () => h.key.currentState!.sendPickedFiles([
          PickedAttachment(
            name: 'huge.mp4',
            readBytes: () async => Uint8List(MediaCryptoService.maxBytes + 1),
          ),
          photo('after.jpg'),
        ]),
      );
      await tester.pump();

      expect(h.emitted, isEmpty);
      expect(
        find.text('Some files were not sent — you left the chat'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    testWidgets('an unreadable or unsupported file is refused and the rest '
        'still go', (tester) async {
      final h = await pumpComposer(tester);

      await tester.runAsync(
        () => h.key.currentState!.sendPickedFiles([
          PickedAttachment(name: 'scan.heic', readBytes: () async => kTinyPng),
          photo('a.jpg'),
        ]),
      );
      await tester.pump();

      expect(h.emitted, ['IMAGE']);
      expect(find.text('Unsupported file type'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });
  });
}
