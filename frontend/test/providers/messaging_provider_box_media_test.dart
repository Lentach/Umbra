import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/box/box_media_fetcher.dart';
import 'package:fireplace/services/box/box_media_frame.dart';
import 'package:fireplace/services/box/box_media_store.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encrypted_media_upload_service.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/encrypted_media_loader.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Item 3 / media wiring: box attachments on arrival, on restart, on
/// screen and when destroyed. The real plaintext store; Signal is faked (a
/// "ciphertext" is `3:` + base64(plaintext); a decrypt answers [inbound]).
class _Encryption extends EncryptionProvider {
  _Encryption(this.store) : super(service: store);

  final EncryptionService store;
  String inbound = '';
  final Map<int, VerifiedDeviceList> lists = {};

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
    Duration timeout = const Duration(seconds: 10),
  }) async => lists[userId] ?? const VerifiedDeviceList.notEnrolled();

  @override
  Future<bool> hasSessionWith(int peerUserId, {int deviceId = 1}) async => true;

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  @override
  Future<String> encrypt(
    int recipientId,
    String plaintext, {
    int deviceId = 1,
  }) async => '3:${base64Encode(utf8.encode(plaintext))}';

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async => inbound;

  @override
  Future<void> savePendingSendRecord(
    String key,
    Map<String, dynamic> data,
  ) async {}
}

class _Outbox implements BoxOutbox {
  final Map<int, ContactOutbound> bob = {};

  /// What the box's media route holds, by base64url id.
  final Map<String, Uint8List> media = {};
  final List<Uint8List> uploads = [];
  int _next = kFirstLocalMessageId + 900;

  @override
  Map<int, ContactOutbound> addressesFor(int peerUserId) =>
      peerUserId == 2 ? bob : const {};

  @override
  Map<int, ContactOutbound> siblingAddresses() => const {};

  @override
  Iterable<int> coveredPeers() => bob.isEmpty ? const [] : const [2];

  @override
  Future<bool> deliver(ContactOutbound to, Uint8List body) async => true;

  @override
  Future<int?> nextLocalId() async => _next++;

  @override
  Future<BoxResult<BoxMediaRef>> uploadMedia(
    ContactOutbound to,
    Uint8List framed,
  ) async {
    uploads.add(framed);
    final id = Uint8List(kBoxMediaIdBytes)..[0] = 200 + uploads.length;
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

/// A "ciphertext" is the plaintext reversed plus a 16-byte tag.
class _MediaUpload extends EncryptedMediaUploadService {
  _MediaUpload() : super(api: ApiService(baseUrl: 'http://test'));

  @override
  Future<EncryptedMedia> encrypt(Uint8List bytes) async => EncryptedMedia(
    ciphertext: Uint8List.fromList([...bytes.reversed, ...List.filled(16, 9)]),
    keyBase64: base64Encode(List.filled(32, 9)),
    ivBase64: base64Encode(List.filled(12, 9)),
  );
}

/// A keyed stand-in for AES-GCM (webcrypto cannot run under `flutter test`
/// here, and pointycastle's GCM takes a minute over 17 MiB): the body is the
/// plaintext XORed with the key, then a 16-byte tag holding the IV; a wrong
/// key, IV or tag length throws.
class _KeyedCrypto extends MediaCryptoService {
  static Uint8List seal(Uint8List key, Uint8List iv, Uint8List plain) {
    final out = Uint8List(plain.length + 16);
    for (var i = 0; i < plain.length; i++) {
      out[i] = plain[i] ^ key[i % key.length];
    }
    out.setRange(plain.length, plain.length + iv.length, iv);
    return out;
  }

  @override
  Future<Uint8List> decrypt(
    Uint8List ciphertext,
    String keyB64,
    String ivB64,
  ) async {
    final key = base64Decode(keyB64);
    final iv = base64Decode(ivB64);
    final length = ciphertext.length - 16;
    for (var i = 0; i < iv.length; i++) {
      if (ciphertext[length + i] != iv[i]) throw StateError('bad tag');
    }
    final plain = Uint8List(length);
    for (var i = 0; i < length; i++) {
      plain[i] = ciphertext[i] ^ key[i % key.length];
    }
    return plain;
  }
}

/// A box attachment must never be fetched from `/media`.
class _NoMediaApi extends ApiService {
  _NoMediaApi() : super(baseUrl: 'http://test');

  @override
  Future<Uint8List> fetchMediaBytes(String url, String token) =>
      throw StateError('fetched $url from /media');
}

Uint8List _id(int first) => Uint8List(kBoxMediaIdBytes)..[0] = first;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessagingProvider provider;
  late ConversationsProvider conversations;
  late _Encryption encryption;
  late _Outbox outbox;
  late MemoryBoxMediaStore store;
  late BoxMediaFetcher fetcher;

  /// Every download, in order.
  late List<Uint8List> downloads;

  /// Awaited by every download before the box answers, when set.
  Completer<void>? downloadGate;

  /// Run as each download starts.
  Future<void> Function()? onDownload;
  var nextLocal = kFirstLocalMessageId;

  BoxMediaFetcher newFetcher() => BoxMediaFetcher(
    store: store,
    download: (id) async {
      downloads.add(id);
      await onDownload?.call();
      await downloadGate?.future;
      return outbox.downloadMedia(id);
    },
  );

  MessagingProvider newProvider() => MessagingProvider()
    ..setConversationsProvider(conversations)
    ..setEncryptionProvider(encryption)
    ..setCurrentUserId(1)
    ..setToken('tok')
    ..setIncomingMessageSoundEnabledForTest(false)
    ..onConnect(false)
    ..setActiveConversationIdForTest(10)
    ..setEmitCallback((_, _) {})
    ..setMediaUploadServiceForTest(_MediaUpload())
    ..boxOutbox = outbox
    ..boxMedia = fetcher;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    encryption = _Encryption(service);
    conversations = ConversationsProvider()
      ..setCurrentUserId(1)
      ..onConversationsList([
        {
          'id': 10,
          'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
          'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
          'createdAt': '2026-01-01T00:00:00.000Z',
          'disappearingTimer': null,
          'unreadCount': 0,
          'lastMessage': null,
        },
      ])
      ..openConversation(10);
    outbox = _Outbox();
    store = MemoryBoxMediaStore();
    downloads = [];
    downloadGate = null;
    onDownload = null;
    fetcher = newFetcher();
    provider = newProvider();
  });

  tearDown(() => fetcher.dispose());

  Future<void> pump([int turns = 40]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// The app closed and opened again: a new provider and a new fetcher over
  /// the same store; the chat opens with an empty server page.
  Future<void> restart() async {
    provider.dispose();
    fetcher.dispose();
    downloads.clear();
    fetcher = newFetcher();
    provider = newProvider();
    await provider.onMessageHistory({
      'conversationId': 10,
      'messages': <Object>[],
    });
    await pump(80);
  }

  /// Bob's attachment [id] arrives over the box; answers the entry and
  /// whether the reader finished with it.
  Future<(BoxInboxEntry, bool)> receive(
    Uint8List id, {
    String type = 'IMAGE',
    String content = '',
    String? key = 'S0VZ',
    String? iv = 'SVY=',
  }) async {
    encryption.inbound = jsonEncode(
      E2eEnvelope.build(
        content,
        messageType: type,
        boxMedia: boxB64(id),
        mediaKey: key,
        mediaIv: iv,
        msgId: 'wire-${nextLocal - kFirstLocalMessageId}-media',
      ),
    );
    final e = BoxInboxEntry(
      rid: 'rid',
      id: 'm${nextLocal - kFirstLocalMessageId}',
      localId: nextLocal++,
      peerUserId: 2,
      senderDeviceId: 1,
      signal: '2:AQID',
      receivedAt: DateTime.now().toUtc(),
      acked: true,
    );
    final done = await provider.consumeBoxEntry(
      e,
      const ContactRecord(
        userId: 2,
        username: 'bob',
        tag: '0002',
        state: ContactState.friend,
        legacy: ContactLegacy(conversationId: 10),
      ),
    );
    return (e, done);
  }

  MessageModel row(int id) => provider.messages.singleWhere((m) => m.id == id);

  test(
    'a received box image is shown and stored as box:<id> with its key; its '
    'download starts only once the record is stored, never on the read '
    'chain, and keeps the unframed ciphertext (E17c, decision 40)',
    () async {
      final ct = Uint8List.fromList(List.generate(300, (i) => i % 7));
      outbox.media[boxB64(_id(1))] = frameMediaToRung(ct);
      final storedWhenDownloaded = <bool>[];
      onDownload = () async => storedWhenDownloaded.add(
        await encryption.recordExists(nextLocal - 1) == true,
      );
      downloadGate = Completer<void>();

      final (e, done) = await receive(_id(1));
      expect(done, isTrue, reason: 'finished while the download still waits');

      final shown = row(e.localId);
      expect(shown.mediaUrl, 'box:${boxB64(_id(1))}');
      expect(shown.mediaKey, 'S0VZ');
      expect(shown.mediaIv, 'SVY=');
      final record = await encryption.store.getDecryptedContent(e.localId);
      expect(record?['mediaUrl'], 'box:${boxB64(_id(1))}');
      expect(record?['mediaKey'], 'S0VZ');

      await pump();
      expect(storedWhenDownloaded, [true]);
      downloadGate!.complete();
      await pump();
      expect(await store.get(1, _id(1)), ct);
    },
  );

  test(
    'a box attachment without its key is kept as a broken-media row — shown '
    'and stored with no url, never dropped, never downloaded',
    () async {
      final (e, done) = await receive(_id(2), key: null);
      expect(done, isTrue);
      final shown = row(e.localId);
      expect(shown.messageType, MessageType.image);
      expect(shown.mediaUrl, isNull);
      await pump();
      expect(downloads, isEmpty);
      expect(await encryption.store.getDecryptedContent(e.localId), isNotNull);
    },
  );

  test(
    'a restart fetches any box attachment whose copy never landed, and asks '
    'the store — not the box — about one that did (E17c)',
    () async {
      outbox.media[boxB64(_id(4))] = frameMediaToRung(Uint8List(40));
      final (missing, _) = await receive(_id(3));
      final (kept, _) = await receive(_id(4));
      await pump();
      expect(await store.get(1, _id(3)), isNull, reason: 'not on the box yet');
      expect(await store.get(1, _id(4)), isNotNull);

      outbox.media[boxB64(_id(3))] = frameMediaToRung(Uint8List(30));
      await restart();
      expect(row(missing.localId).mediaUrl, 'box:${boxB64(_id(3))}');
      expect(row(kept.localId).mediaUrl, 'box:${boxB64(_id(4))}');
      expect(downloads, [_id(3)]);
      expect(await store.get(1, _id(3)), Uint8List(30));
    },
  );

  test(
    'a 17 MiB file padded to the 32 MiB rung displays: the cap applies to the '
    'UNFRAMED ciphertext, decrypted with the key from its record — never '
    'fetched from /media',
    () async {
      final plain = Uint8List(17 * 1024 * 1024);
      for (var i = 0; i < plain.length; i += 4096) {
        plain[i] = i ~/ 4096;
      }
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final iv = Uint8List.fromList(List.generate(12, (i) => 100 + i));
      final ct = _KeyedCrypto.seal(key, iv, plain);
      final framed = frameMediaToRung(ct);
      expect(framed.length, 32 * 1024 * 1024);
      outbox.media[boxB64(_id(5))] = framed;

      final (e, _) = await receive(
        _id(5),
        type: 'FILE',
        content: 'big.bin',
        key: base64Encode(key),
        iv: base64Encode(iv),
      );
      final shown = row(e.localId);
      final bytes = await loadDecryptedMediaBytes(
        url: shown.mediaUrl!,
        token: 'tok',
        key: shown.mediaKey,
        iv: shown.mediaIv,
        api: _NoMediaApi(),
        crypto: _KeyedCrypto(),
        box: provider.boxMediaCiphertext,
      );
      expect(bytes.length, plain.length);
      expect(bytes, plain);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the sender keeps its own copy (decision 40): shown and restarted '
    'without a single download',
    () async {
      encryption.lists
        ..[1] = const VerifiedDeviceList.notEnrolled()
        ..[2] = VerifiedDeviceList.enrolled(
          version: 1,
          listHash: 'H' * 44,
          devices: const [
            DeviceListEntry(deviceId: 1, platform: 'test', addedAtMs: 0),
          ],
        );
      outbox.bob[1] = const ContactOutbound(
        peerDeviceId: 1,
        sid: 'sid-1',
        sealPub: 'seal-1',
      );
      provider.refreshBoxDeviceLists();
      final ok = await provider.sendImageMessage(
        'tok',
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'a.jpg'),
        2,
      );
      await pump();
      expect(ok, isTrue);
      final sent = provider.messages.single;
      final id = _id(201);
      expect(sent.mediaUrl, 'box:${boxB64(id)}');
      expect(await store.get(1, id), [3, 2, 1, ...List.filled(16, 9)]);

      final shown = await provider.boxMediaCiphertext(sent.mediaUrl!);
      expect(shown, [3, 2, 1, ...List.filled(16, 9)]);
      await restart();
      expect(row(sent.id).mediaUrl, 'box:${boxB64(id)}');
      expect(downloads, isEmpty);
    },
  );

  test(
    "a destroyed box attachment's local copy goes with its record: "
    'delete-for-me, and a chat removed from this device',
    () async {
      outbox.media[boxB64(_id(6))] = frameMediaToRung(Uint8List(10));
      outbox.media[boxB64(_id(7))] = frameMediaToRung(Uint8List(20));
      final (first, _) = await receive(_id(6));
      await receive(_id(7));
      await pump();
      expect(await store.get(1, _id(6)), isNotNull);
      expect(await store.get(1, _id(7)), isNotNull);

      provider.deleteMessage(first.localId, forEveryone: false);
      await pump();
      expect(await store.get(1, _id(6)), isNull);
      expect(await store.get(1, _id(7)), isNotNull);

      provider.onConversationsRemovedForUser([10]);
      await pump();
      expect(await store.get(1, _id(7)), isNull);
    },
  );
}
