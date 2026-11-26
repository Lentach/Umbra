import 'dart:async';
import 'dart:convert';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:fireplace/utils/video_preview.dart';
import 'package:fireplace/widgets/input/chat_input_bar.dart';
import 'package:fireplace/widgets/input/composer_attachment_controller.dart';
import 'package:fireplace/widgets/input/picked_attachment.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/chat_seed.dart';
import '../../support/l10n.dart';

/// 1x1 transparent PNG so Image.memory decodes without errors.
final kTinyPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Media crypto with no real cipher: a "ciphertext" is the plaintext reversed
/// plus a 16-byte tag. [fail] makes every encryption throw (an upload that
/// cannot go out). The size guard is the real one's.
class _FakeMediaCrypto extends MediaCryptoService {
  _FakeMediaCrypto({this.fail = false, this.gate, this.onParked});

  final bool fail;

  /// When set, the FIRST encryption waits for it: a media send parked
  /// mid-flight while later ones go through.
  Future<void>? gate;

  /// Called when an encryption starts waiting on [gate].
  final void Function()? onParked;

  @override
  Future<EncryptedMedia> encrypt(Uint8List bytes) async {
    final parked = gate;
    gate = null;
    if (parked != null) onParked?.call();
    await parked;
    if (fail || bytes.length > MediaCryptoService.maxBytes) {
      throw StateError('cannot encrypt');
    }
    return EncryptedMedia(
      ciphertext: Uint8List.fromList([...bytes.reversed, ...List.filled(16, 9)]),
      keyBase64: base64Encode(List.filled(32, 9)),
      ivBase64: base64Encode(List.filled(12, 9)),
    );
  }
}

/// The real plaintext store; Signal and the device-list round trip are
/// faked. A "ciphertext" is `3:` + base64(the plaintext), so a frame the box
/// was handed can be read back.
class _SendEncryption extends EncryptionProvider {
  _SendEncryption(this.store) : super(service: store);

  final EncryptionService store;
  final Map<int, VerifiedDeviceList> lists = {};
  final Set<(int, int)> sessions = {};

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  int get ownDeviceId => 1;

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => lists[userId];

  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    bool batched = false,
    Duration timeout = const Duration(seconds: 10),
  }) async => lists.putIfAbsent(
    userId,
    () => const VerifiedDeviceList.notEnrolled(),
  );

  @override
  Future<bool> hasSessionWith(int peerUserId, {int deviceId = 1}) async =>
      sessions.contains((peerUserId, deviceId));

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {
    sessions.add((recipientId, deviceId));
  }

  @override
  Future<String> encrypt(
    int recipientId,
    String plaintext, {
    int deviceId = 1,
  }) async => '3:${base64Encode(utf8.encode(plaintext))}';

  // The records a send keeps are not what these tests are about.
  @override
  Future<void> saveBoxUnsent(
    int userId,
    String tempId,
    Map<String, Object?> entry,
  ) async {}

  @override
  Future<void> dropBoxUnsent(int userId, String tempId) async {}

  @override
  Future<bool?> recordExists(int messageId) async => true;

  @override
  Future<void> saveDecryptedContent(
    int messageId,
    Map<String, dynamic> data, {
    int? conversationId,
    DateTime? createdAt,
    DateTime? expiresAt,
    int? disappearAfterSeconds,
    WireKey? wire,
  }) async {}
}

/// The send side of the box with one friend (Bob, device 2): hands every
/// message frame's envelope to [onMessage] in send order.
class _Outbox implements BoxOutbox {
  _Outbox(this.onMessage);

  final void Function(Map<String, dynamic> envelope) onMessage;
  final address = const ContactOutbound(
    peerDeviceId: 2,
    sid: 'sid-2',
    sealPub: 'seal-2',
  );
  final Map<String, Uint8List> media = {};
  int _next = kFirstLocalMessageId + 40;

  @override
  Map<int, ContactOutbound> addressesFor(int peerUserId) =>
      peerUserId == 2 ? {2: address} : const {};

  @override
  Map<int, ContactOutbound> siblingAddresses() => const {};

  @override
  Iterable<int> coveredPeers() => const [2];

  @override
  Future<BoxSendOutcome> deliver(
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
  }) async {
    final frame = BoxFrame.decode(body)!;
    final envelope =
        jsonDecode(utf8.decode(frame.signal)) as Map<String, dynamic>;
    // Typing and receipts carry a `type`; a message carries its wire id.
    if (envelope.containsKey('msgId') && envelope['type'] == null) {
      onMessage(envelope);
    }
    return BoxSendOutcome.taken;
  }

  @override
  Future<int?> nextLocalId() async => _next++;

  @override
  Future<BoxResult<void>> deleteMedia(Uint8List id, Uint8List secret) async =>
      const BoxOk(null);

  @override
  Future<BoxResult<BoxMediaRef>> uploadMedia(
    ContactOutbound to,
    Uint8List framed,
  ) async {
    final id = Uint8List(kBoxMediaIdBytes)..[0] = media.length + 1;
    media[boxB64(id)] = framed;
    return BoxOk(
      BoxMediaRef(id: id, bucket: 'd14', expiresAt: DateTime.utc(2026, 10, 10)),
    );
  }

  @override
  Future<BoxResult<Uint8List>> downloadMedia(Uint8List id) async {
    final body = media[boxB64(id)];
    return body == null ? const BoxRefused(BoxCode.notFound) : BoxOk(body);
  }
}

/// A provider whose video send THROWS instead of answering false: the
/// optimistic video row's notification blows up, once.
class _ThrowingVideoMessaging extends MessagingProvider {
  bool _thrown = false;

  @override
  void notifyListeners() {
    final rows = loadedMessagesForTest;
    if (!_thrown &&
        rows.isNotEmpty &&
        rows.last.messageType == MessageType.video &&
        rows.last.deliveryStatus == MessageDeliveryStatus.sending) {
      _thrown = true;
      throw StateError('video send blew up');
    }
    super.notifyListeners();
  }
}

/// Lets a test unmount the composer while the rest of the app stays up (a
/// popped chat on mobile).
final _barVisible = ValueNotifier<bool>(true);

Future<
  ({
    GlobalKey<ChatInputBarState> key,
    List<String> emitted,
    List<Map<String, dynamic>> emittedData,
    ConversationsProvider convs,
  })
>
pumpComposer(
  WidgetTester tester, {
  Object? throwOnUpload,
  MessagingProvider? messagingOverride,
  Future<void>? encryptGate,
  void Function()? onEncryptParked,
}) async {
  final key = GlobalKey<ChatInputBarState>();
  // What the box was handed, in order: each message's kind, and its envelope.
  final emitted = <String>[];
  final emittedData = <Map<String, dynamic>>[];

  FlutterSecureStorage.setMockInitialValues({});
  final service = EncryptionService();
  await tester.runAsync(() async {
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    // Box-ready a moment ago: a held peer list is kept.
    await service.markBoxListsReady(DateTime.now().millisecondsSinceEpoch);
  });
  final encryption = _SendEncryption(service)
    ..lists[2] = VerifiedDeviceList.enrolled(
      version: 3,
      listHash: 'H' * 44,
      devices: [DeviceListEntry(deviceId: 2, platform: 'test', addedAtMs: 0)],
    );

  final convs = ConversationsProvider()..setCurrentUserId(1);
  seedConversations(convs, [
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

  final messaging = messagingOverride ?? MessagingProvider();
  messaging.setConversationsProvider(convs);
  messaging.setCurrentUserId(1);
  messaging.setToken('tok');
  messaging.setIncomingMessageSoundEnabledForTest(false);
  messaging.onConnect(false);
  messaging.setMediaCryptoForTest(
    _FakeMediaCrypto(
      fail: throwOnUpload != null,
      gate: encryptGate,
      onParked: onEncryptParked,
    ),
  );
  messaging.setEncryptionProvider(encryption);
  messaging.boxOutbox = _Outbox((envelope) {
    emitted.add(envelope['messageType'] as String? ?? 'TEXT');
    emittedData.add(envelope);
  });
  // The connect's list refresh (its retry timer must live in the real zone,
  // not the test's fake clock): both lists are verified before a send.
  await tester.runAsync(() async {
    messaging.refreshBoxDeviceLists();
    await Future<void>.delayed(const Duration(milliseconds: 100));
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
          child: ValueListenableBuilder<bool>(
            valueListenable: _barVisible,
            builder: (_, visible, _) =>
                visible ? ChatInputBar(key: key) : const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
  return (key: key, emitted: emitted, emittedData: emittedData, convs: convs);
}

/// A fire-and-forget text send (the caption after an image, a plain send)
/// has reached the box.
Future<void> _textSettled(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
}

void main() {
  // AuthProvider reads its saved token on construction; without a mock that
  // channel call fails asynchronously and lands in whichever test runs then.
  setUp(() {
    _barVisible.value = true;
    SharedPreferences.setMockInitialValues({});
  });

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
    await _textSettled(tester);
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
    await _textSettled(tester);
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

    expect(find.text(l10n.snackbarPastedImageTooLarge), findsOneWidget);
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

    expect(find.text(l10n.snackbarPastedImageUnsupported), findsOneWidget);
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

    expect(find.text(l10n.snackbarPastedImageUnavailable), findsOneWidget);
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
        find.text(l10n.videoTooLarge('20.0')),
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
        find.text(l10n.videoTooLarge('20.0')),
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
      expect(find.text(l10n.videoUnsupportedFormat), findsOneWidget);
      expect(h.emitted, isEmpty);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('paperclip picks send immediately (owner ruling 2026-10-27)', () {
    PickedAttachment photo(String name) =>
        PickedAttachment(name: name, readBytes: () async => kTinyPng);

    // Every pick in this group is tapped in chat 10, the harness's open chat.
    Future<void> pick(
      ({GlobalKey<ChatInputBarState> key, List<String> emitted,
        List<Map<String, dynamic>> emittedData, ConversationsProvider convs}) h,
      List<PickedAttachment> files,
    ) => h.key.currentState!.sendPickedFiles(files, pickedIn: 10);

    // A second chat to switch to; the desktop split view keeps the composer
    // mounted across that switch.
    void addSecondChat(ConversationsProvider convs) {
      Map<String, dynamic> conv(int id, int peerId, String peer) => {
        'id': id,
        'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
        'userTwo': {'id': peerId, 'username': peer, 'tag': '0003'},
        'createdAt': '2026-01-01T00:00:00.000Z',
        'unreadCount': 0,
        'lastMessage': null,
      };
      seedConversations(convs, [conv(10, 2, 'bob'), conv(11, 3, 'carol')]);
    }

    // The duration probe answers VideoPreview.unknown under flutter_test (see
    // the group above); the send proceeds regardless.
    testWidgets('every file goes out at once, one message each, in pick '
        'order; nothing stages and the draft stays', (tester) async {
      final h = await pumpComposer(tester);
      await tester.enterText(find.byType(TextField), 'half-typed');

      await tester.runAsync(
        () => pick(h, [
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
        () => pick(h, [
          for (var i = 0; i < kMaxFilesPerPick + 2; i++) photo('p$i.jpg'),
        ]),
      );
      await tester.pump();

      expect(h.emitted, List.filled(kMaxFilesPerPick, 'IMAGE'));
      expect(
        find.text(l10n.attachmentPickLimit(kMaxFilesPerPick)),
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
        () => pick(h, [
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
        find.text(l10n.attachmentBatchInterrupted),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    // A video awaits its transcode and its probe AFTER the per-file check.
    // One test per wait: each check alone must hold its window.
    testWidgets('switching chats during a video transcode sends it nowhere '
        'and says so', (tester) async {
      final h = await pumpComposer(tester);
      addSecondChat(h.convs);
      addTearDown(() => ChatInputBarState.debugTranscodeOverride = null);
      ChatInputBarState.debugTranscodeOverride = (bytes) async {
        h.convs.openConversation(11);
        return Uint8List(1024);
      };
      addTearDown(() => ChatInputBarState.debugProbeOverride = null);
      ChatInputBarState.debugProbeOverride = (bytes) async {
        // Once the transcode check is gone, a send could only be stopped
        // here; reopening chat 10 keeps this check from covering for it.
        h.convs.openConversation(10);
        return VideoPreview.unknown;
      };

      await tester.runAsync(
        () => pick(h, [
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
        find.text(l10n.attachmentBatchInterrupted),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    // The web path: a clip under the cap is never transcoded, and the web
    // probe can wait seconds for a picture.
    testWidgets('switching chats during a video probe sends it nowhere and '
        'says so', (tester) async {
      final h = await pumpComposer(tester);
      addSecondChat(h.convs);
      addTearDown(() => ChatInputBarState.debugProbeOverride = null);
      ChatInputBarState.debugProbeOverride = (bytes) async {
        h.convs.openConversation(11);
        return VideoPreview.unknown;
      };

      await tester.runAsync(
        () => pick(h, [
          PickedAttachment(
            name: 'clip.mp4',
            readBytes: () async => Uint8List(64),
          ),
          photo('after.jpg'),
        ]),
      );
      await tester.pump();

      expect(h.emitted, isEmpty);
      expect(
        find.text(l10n.attachmentBatchInterrupted),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    // A web pick reads every file before handing them over; the user can
    // open another chat in that time.
    testWidgets('files that arrive after a switch to another chat go nowhere '
        'and say so', (tester) async {
      final h = await pumpComposer(tester);
      addSecondChat(h.convs);
      h.convs.openConversation(11);

      await tester.runAsync(() => pick(h, [photo('a.jpg'), photo('b.jpg')]));
      await tester.pump();

      expect(h.emitted, isEmpty);
      expect(
        find.text(l10n.attachmentBatchInterrupted),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    testWidgets('an unsupported file is refused and the rest still go', (
      tester,
    ) async {
      final h = await pumpComposer(tester);

      await tester.runAsync(
        () => pick(h, [
          PickedAttachment(name: 'scan.heic', readBytes: () async => kTinyPng),
          photo('a.jpg'),
        ]),
      );
      await tester.pump();

      expect(h.emitted, ['IMAGE']);
      expect(find.text(l10n.attachmentUnsupportedFileType), findsOneWidget);
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    // UI-07: sendImage and sendDocument swallow a throw and toast; a video
    // that threw used to end the whole batch without a word.
    testWidgets('a video whose send throws says so and the rest still go', (
      tester,
    ) async {
      final h = await pumpComposer(
        tester,
        messagingOverride: _ThrowingVideoMessaging(),
      );

      await tester.runAsync(
        () => pick(h, [
          PickedAttachment(
            name: 'clip.mp4',
            readBytes: () async => Uint8List(64),
          ),
          photo('after.jpg'),
        ]),
      );
      await tester.pump();

      expect(h.emitted, ['IMAGE']);
      expect(find.text(l10n.uploadFailed), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    // A3-CMP-05: the toast said "Document sent!" whatever happened, because
    // the provider swallowed the failure and returned nothing.
    testWidgets('a document that is too large to send says the upload '
        'failed, never that it was sent', (tester) async {
      final h = await pumpComposer(tester);

      await tester.runAsync(
        () => pick(h, [
          PickedAttachment(
            name: 'huge.pdf',
            readBytes: () async => Uint8List(MediaCryptoService.maxBytes + 1),
          ),
        ]),
      );
      await tester.pump();

      expect(h.emitted, isEmpty);
      expect(find.text(l10n.snackbarDocumentSent), findsNothing);
      expect(find.text(l10n.uploadFailed), findsOneWidget);
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    testWidgets('a document whose upload fails says the upload failed, never '
        'that it was sent', (tester) async {
      final h = await pumpComposer(tester, throwOnUpload: Exception('boom'));

      await tester.runAsync(
        () => pick(h, [
          PickedAttachment(
            name: 'plan.pdf',
            readBytes: () async => Uint8List(64),
          ),
        ]),
      );
      await tester.pump();

      expect(h.emitted, isEmpty);
      expect(find.text(l10n.snackbarDocumentSent), findsNothing);
      expect(find.text(l10n.uploadFailed), findsOneWidget);
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    testWidgets('a document that went out says it was sent', (tester) async {
      final h = await pumpComposer(tester);

      await tester.runAsync(
        () => pick(h, [
          PickedAttachment(
            name: 'plan.pdf',
            readBytes: () async => Uint8List(64),
          ),
        ]),
      );
      await tester.pump();

      expect(h.emitted, ['FILE']);
      expect(find.text(l10n.snackbarDocumentSent), findsOneWidget);
      expect(find.text(l10n.uploadFailed), findsNothing);
      await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
    });

    // UI-06: a second pick made while the first batch is still sending used
    // to interleave with it, so the peer saw the files out of pick order.
    testWidgets('a second pick made mid-batch goes out after the first, '
        'in full and in order', (tester) async {
      final gate = Completer<void>();
      var secondReads = 0;
      var parked = false;
      final h = await pumpComposer(
        tester,
        encryptGate: gate.future,
        onEncryptParked: () => parked = true,
      );

      late Future<void> first;
      late Future<void> second;
      await tester.runAsync(() async {
        first = pick(h, [photo('a1.jpg'), photo('a2.jpg')]);
        // a1 is parked in its upload (poll the flag in the real zone).
        while (!parked) {
          await Future<void>.delayed(Duration.zero);
        }
        second = pick(h, [
          PickedAttachment(
            name: 'b1.mp4',
            readBytes: () async {
              secondReads++;
              return Uint8List(64);
            },
          ),
        ]);
        // A fixed number of event-loop turns, not a wall-clock window: an
        // unqueued second batch reads its first file within the first few.
        await pumpEventQueue();
      });
      // The second batch waits for the first: nothing read, nothing sent.
      expect(secondReads, 0);
      expect(h.emitted, isEmpty);

      gate.complete();
      await tester.runAsync(() => Future.wait([first, second]));
      await tester.pump();

      expect(h.emitted, ['IMAGE', 'IMAGE', 'VIDEO']);
    });
  });

  // UI-05: the desktop split view keeps the composer mounted across a chat
  // switch, and the provider sends into the ACTIVE chat — a caption sent
  // after the image's await landed in whichever chat was open by then.
  testWidgets('switching chats while a staged image sends keeps the caption '
      'out of the new chat', (tester) async {
    final gate = Completer<void>();
    final h = await pumpComposer(tester, encryptGate: gate.future);
    seedConversations(h.convs, [
      for (final (id, peerId, peer) in [(10, 2, 'bob'), (11, 3, 'carol')])
        {
          'id': id,
          'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
          'userTwo': {'id': peerId, 'username': peer, 'tag': '0003'},
          'createdAt': '2026-01-01T00:00:00.000Z',
          'unreadCount': 0,
          'lastMessage': null,
        },
    ]);
    final state = h.key.currentState!;
    final messaging = tester
        .element(find.byType(ChatInputBar))
        .read<MessagingProvider>();
    state.attachmentControllerForTest.stage(
      bytes: kTinyPng,
      mimeType: 'image/png',
      filename: 'pasted.png',
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'my caption');

    late Future<void> sending;
    await tester.runAsync(() async {
      sending = state.sendForTest();
      // Let the image reach its parked encryption.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    h.convs.openConversation(11); // the user opens another chat mid-send
    gate.complete();
    await tester.runAsync(() => sending);
    await tester.pumpAndSettle();
    await _textSettled(tester);

    expect(h.emitted, ['IMAGE']); // the image went to Bob, the caption nowhere
    expect(
      messaging.loadedMessagesForTest.where(
        (m) => m.messageType == MessageType.text,
      ),
      isEmpty,
    );
    // The words are not lost: they come back to the field.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'my caption',
    );
  });

  // UI-05, second half: on mobile the user pops the chat, the composer
  // unmounts, and `if (!mounted) return` used to drop the caption silently.
  Future<
    ({
      GlobalKey<ChatInputBarState> key,
      List<String> emitted,
      List<Map<String, dynamic>> emittedData,
      ConversationsProvider convs,
    })
  >
  stageAndPark(WidgetTester tester, Completer<void> gate) async {
    final h = await pumpComposer(tester, encryptGate: gate.future);
    h.key.currentState!.attachmentControllerForTest.stage(
      bytes: kTinyPng,
      mimeType: 'image/png',
      filename: 'pasted.png',
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'my caption');
    return h;
  }

  testWidgets('composer unmounted mid-send, chat still open: the caption is '
      'still sent', (tester) async {
    final gate = Completer<void>();
    final h = await stageAndPark(tester, gate);
    late Future<void> sending;
    await tester.runAsync(() async {
      sending = h.key.currentState!.sendForTest();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    _barVisible.value = false;
    await tester.pump();
    gate.complete();
    await tester.runAsync(() => sending);
    await _textSettled(tester);

    expect(h.emitted, ['IMAGE', 'TEXT']);
  });

  testWidgets('composer unmounted mid-send and the chat left: no caption in '
      'any chat, and the user is told', (tester) async {
    final gate = Completer<void>();
    final h = await stageAndPark(tester, gate);
    late Future<void> sending;
    await tester.runAsync(() async {
      sending = h.key.currentState!.sendForTest();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    _barVisible.value = false;
    await tester.pump();
    h.convs.closeConversation(); // what popping the chat screen does
    gate.complete();
    await tester.runAsync(() => sending);
    await _textSettled(tester);
    await tester.pump();

    expect(h.emitted, ['IMAGE']);
    expect(
      find.text(l10n.attachmentBatchInterrupted),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
  });

  // UI-06 follow-up: a queued batch must re-check the chat before it reads
  // its first file (a web pick's reads are the expensive part).
  testWidgets('a queued batch whose chat was left reads none of its files', (
    tester,
  ) async {
    final gate = Completer<void>();
    var parked = false;
    final h = await pumpComposer(
      tester,
      encryptGate: gate.future,
      onEncryptParked: () => parked = true,
    );
    seedConversations(h.convs, [
      for (final (id, peerId, peer) in [(10, 2, 'bob'), (11, 3, 'carol')])
        {
          'id': id,
          'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
          'userTwo': {'id': peerId, 'username': peer, 'tag': '0003'},
          'createdAt': '2026-01-01T00:00:00.000Z',
          'unreadCount': 0,
          'lastMessage': null,
        },
    ]);
    var secondReads = 0;
    PickedAttachment photo(String n) =>
        PickedAttachment(name: n, readBytes: () async => kTinyPng);
    late Future<void> first;
    late Future<void> second;
    await tester.runAsync(() async {
      first = h.key.currentState!.sendPickedFiles([
        photo('a1.jpg'),
        photo('a2.jpg'),
      ], pickedIn: 10);
      while (!parked) {
        await Future<void>.delayed(Duration.zero);
      }
      second = h.key.currentState!.sendPickedFiles([
        PickedAttachment(
          name: 'b1.jpg',
          readBytes: () async {
            secondReads++;
            return kTinyPng;
          },
        ),
      ], pickedIn: 10);
    });
    h.convs.openConversation(11);
    gate.complete();
    await tester.runAsync(() => Future.wait([first, second]));
    await tester.pump();

    expect(secondReads, 0);
    await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
  });

  // A3-CMP-06: the staged path ignored the edit, so the corrected text went
  // out as a NEW message and the original stayed wrong under its banner.
  testWidgets('send while editing with a pasted picture: the edit is saved '
      'as an edit and the picture goes out on its own', (tester) async {
    final h = await pumpComposer(tester);
    final state = h.key.currentState!;
    final messaging = tester
        .element(find.byType(ChatInputBar))
        .read<MessagingProvider>();
    final original = MessageModel(
      id: kFirstLocalMessageId + 1,
      content: 'typo',
      senderId: 1,
      senderUsername: 'alice',
      conversationId: 10,
      createdAt: DateTime.now(),
      wireId: 'wire-00000001',
    );
    messaging
      ..seedMessagesForTest(10, [original])
      ..beginEditMessage(original);
    await tester.pump();
    state.attachmentControllerForTest.stage(
      bytes: kTinyPng,
      mimeType: 'image/png',
      filename: 'pasted.png',
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'fixed');

    await tester.runAsync(state.sendForTest);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await _textSettled(tester);

    expect(messaging.editingMessage, isNull);
    final texts = messaging.loadedMessagesForTest
        .where((m) => m.messageType == MessageType.text)
        .toList();
    expect(texts, hasLength(1)); // no second message carrying the correction
    expect(texts.single.id, original.id);
    expect(texts.single.content, 'fixed');
    expect(
      messaging.loadedMessagesForTest.where(
        (m) => m.messageType == MessageType.image,
      ),
      hasLength(1),
    );
    expect(h.emitted.where((kind) => kind == 'IMAGE'), hasLength(1));
    expect(state.attachmentControllerForTest.staged, isNull);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  // A3-CMP-07: with the action panel open the user started a voice note and
  // the paperclip was still there; its picks were dropped without a word.
  testWidgets('starting a voice note closes the action panel, so the '
      'paperclip is not reachable while recording', (tester) async {
    final h = await pumpComposer(tester);
    final state = h.key.currentState!;
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pump();
    expect(state.isActionPanelOpenForTest, isTrue);

    state.setRecordingForTest(true);
    await tester.pump();

    expect(state.isActionPanelOpenForTest, isFalse);
    state.setRecordingForTest(false);
    await tester.pump();
    expect(state.isActionPanelOpenForTest, isFalse);
  });

  testWidgets('a pick that reaches the composer mid-recording says why '
      'nothing was sent', (tester) async {
    final h = await pumpComposer(tester);
    final state = h.key.currentState!..setRecordingForTest(true);
    await tester.pump();

    await tester.runAsync(
      () => state.sendPickedFiles([
        PickedAttachment(name: 'a.jpg', readBytes: () async => kTinyPng),
      ], pickedIn: 10),
    );
    await tester.pump();

    expect(
      find.text(
        AppLocalizations.of(
          tester.element(find.byType(ChatInputBar)),
        ).attachmentBlockedWhileRecording,
      ),
      findsOneWidget,
    );
    expect(h.emitted, isEmpty);
    await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
  });

  testWidgets('send while editing with a picture and over-long text: the '
      '"too long" toast, nothing applied or sent, edit and picture stay', (
    tester,
  ) async {
    final h = await pumpComposer(tester);
    final state = h.key.currentState!;
    final messaging = tester
        .element(find.byType(ChatInputBar))
        .read<MessagingProvider>();
    final original = MessageModel(
      id: kFirstLocalMessageId + 1,
      content: 'typo',
      senderId: 1,
      senderUsername: 'alice',
      conversationId: 10,
      createdAt: DateTime.now(),
      wireId: 'wire-00000001',
    );
    messaging
      ..seedMessagesForTest(10, [original])
      ..beginEditMessage(original);
    await tester.pump();
    state.attachmentControllerForTest.stage(
      bytes: kTinyPng,
      mimeType: 'image/png',
      filename: 'pasted.png',
    );
    await tester.pumpAndSettle();
    final long = 'x' * 20000;
    tester.widget<TextField>(find.byType(TextField)).controller!.text = long;

    await tester.runAsync(state.sendForTest);
    await tester.pump();
    await _textSettled(tester);

    expect(
      find.text(
        AppLocalizations.of(
          tester.element(find.byType(ChatInputBar)),
        ).messageTooLong,
      ),
      findsOneWidget,
    );
    expect(h.emitted, isEmpty);
    expect(messaging.editingMessage, isNotNull);
    expect(messaging.loadedMessagesForTest.single.content, 'typo');
    expect(state.attachmentControllerForTest.staged, isNotNull);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      long,
    );
    await tester.pump(const Duration(seconds: 3)); // flush snackbar timer
  });
}
