import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encrypted_media_upload_service.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/plaintext_record_codec.dart';
import 'package:fireplace/services/reactions/reaction_key_service.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A chat made over the box (owner decision 52) has no server row: its id is
/// `localConversationIdFor(peer)`, and the server must never be told about
/// it. Bob (2) is such a friend; Carol (3) is an old-path friend with server
/// chat 10 — the positive control every negative sweep here runs beside.
/// Erin (5) is a box friend restored from the contact backup, which drops
/// `legacy`: only `boxOrigin` says her chat is local. Fay (6) is a pending
/// box request — not a chat.
const _me = 1;
const _bob = 2;
const _carol = 3;
const _erin = 5;
const _fay = 6;
const _serverChat = 10;
final int _localChat = localConversationIdFor(_bob);

/// Signal and the device-list round trip faked; the plaintext store real.
class _Encryption extends EncryptionProvider {
  _Encryption(EncryptionService service) : super(service: service);

  final Map<int, VerifiedDeviceList> lists = {};

  /// What [localMessageRecords] finds, by conversation id.
  final Map<int, Map<int, Map<String, dynamic>>> records = {};

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
  }) async =>
      lists[userId] ??= const VerifiedDeviceList.notEnrolled();

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
  Future<void> savePendingSendRecord(
    String key,
    Map<String, dynamic> data,
  ) async {}

  @override
  Future<Map<int, Map<String, dynamic>>> localMessageRecords(
    int conversationId,
  ) async => records[conversationId] ?? const {};
}

/// Box coverage only: a peer is covered when it has an address.
class _Outbox implements BoxOutbox {
  final Map<int, Map<int, ContactOutbound>> addresses = {};

  @override
  Map<int, ContactOutbound> addressesFor(int peerUserId) =>
      addresses[peerUserId] ?? const {};

  @override
  Map<int, ContactOutbound> siblingAddresses() => const {};

  @override
  Iterable<int> coveredPeers() => addresses.keys;

  @override
  Future<bool> deliver(ContactOutbound to, Uint8List body) async => true;

  @override
  Future<int?> nextLocalId() async => null;

  @override
  Future<BoxResult<BoxMediaRef>> uploadMedia(
    ContactOutbound to,
    Uint8List framed,
  ) async => throw UnimplementedError();

  @override
  Future<BoxResult<Uint8List>> downloadMedia(Uint8List id) async =>
      throw UnimplementedError();
}

/// The old path's `/media/upload`, faked: every upload is kept.
class _MediaUpload extends EncryptedMediaUploadService {
  _MediaUpload() : super(api: ApiService(baseUrl: 'http://test'));

  final List<String> oldPathUploads = [];

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
    oldPathUploads.add(mediaType);
    onEncrypted?.call('OLDK', 'OLDIV');
    return EncryptedMediaUpload(
      mediaUrl: 'http://test/media/msgs/x.bin',
      keyBase64: 'OLDK',
      ivBase64: 'OLDIV',
      mediaDuration: duration,
    );
  }
}

VerifiedDeviceList _enrolled(List<int> live) => VerifiedDeviceList.enrolled(
  version: 3,
  listHash: 'H' * 44,
  devices: [
    for (final id in live)
      DeviceListEntry(deviceId: id, platform: 'test', addedAtMs: 0),
  ],
);

Map<String, dynamic> _user(int id, String name) => {
  'id': id,
  'username': name,
  'tag': '000$id',
};

Map<String, dynamic> _conv(int id, int peerId, String peer) => {
  'id': id,
  'userOne': _user(_me, 'me'),
  'userTwo': _user(peerId, peer),
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 1,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContactStore store;
  late ConversationsProvider conversations;
  late MessagingProvider messaging;
  late _Encryption encryption;
  late _MediaUpload mediaUpload;

  /// Every account-socket emit, from every provider, in order.
  late List<(String, Object?)> emitted;
  List<String> events() => [for (final (event, _) in emitted) event];

  void capture(String event, dynamic data) => emitted.add((event, data));

  Future<void> pump([int turns = 40]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final kv = await PrefsContentKv.open();
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(_me);
    await store.setSelf(
      UserModel(id: _me, username: 'me', tag: '0001'),
    );
    await store.update(
      _bob,
      (_) => ContactRecord(
        userId: _bob,
        username: 'bob',
        tag: '0002',
        state: ContactState.friend,
        settings: const ContactSettings(disappearingTimer: 300),
        boxOrigin: ContactBoxOrigin(at: DateTime.utc(2026, 9, 27)),
        legacy: ContactLegacy(
          conversationId: _localChat,
          conversationCreatedAt: DateTime.utc(2026, 9, 27),
        ),
      ),
    );
    await store.update(
      _carol,
      (_) => ContactRecord(
        userId: _carol,
        username: 'carol',
        tag: '0003',
        state: ContactState.friend,
        legacy: ContactLegacy(
          conversationId: _serverChat,
          conversationCreatedAt: DateTime.utc(2026),
        ),
      ),
    );
    await store.settled;

    final service = EncryptionService();
    await service.initialize(
      _me,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    await service.markBoxListsReady(DateTime.now().millisecondsSinceEpoch);
    encryption = _Encryption(service);
    mediaUpload = _MediaUpload();
    emitted = [];
    conversations = ConversationsProvider()
      ..contactStore = store
      ..setCurrentUserId(_me)
      ..setEmitCallback(capture);
    messaging = MessagingProvider()
      ..setConversationsProvider(conversations)
      ..setEncryptionProvider(encryption)
      ..setCurrentUserId(_me)
      ..setToken('tok')
      ..setIncomingMessageSoundEnabledForTest(false)
      ..onConnect(false)
      ..setEmitCallback(capture)
      ..setMediaUploadServiceForTest(mediaUpload);
  });

  group('the chat list', () {
    test(
      'a local chat hydrates from its record and survives every server '
      '`conversationsList`, which never names it: the row, its unread '
      'count, the open chat and the record all stay',
      () async {
        final erinChat = localConversationIdFor(_erin);
        for (final (peer, name, state) in [
          (_erin, 'erin', ContactState.friend),
          (_fay, 'fay', ContactState.pendingIn),
        ]) {
          await store.update(
            peer,
            (_) => ContactRecord(
              userId: peer,
              username: name,
              tag: '000$peer',
              state: state,
              boxOrigin: ContactBoxOrigin(at: DateTime.utc(2026, 9, 26)),
            ),
          );
        }
        await store.settled;

        conversations.hydrateFromStore();
        expect(
          conversations.conversations.map((c) => c.id),
          unorderedEquals([_serverChat, _localChat, erinChat]),
          reason: 'a pending box request is no chat',
        );
        final hydrated = conversations.getConversationById(_localChat);
        expect(hydrated?.userTwo.username, 'bob');
        expect(hydrated?.userOne.id, _me);
        expect(hydrated?.disappearingTimer, 300);
        expect(hydrated?.createdAt, DateTime.utc(2026, 9, 27));

        conversations
          ..openConversation(_localChat)
          ..onConversationsList([_conv(_serverChat, _carol, 'carol')])
          ..incrementUnreadCount(_localChat)
          // A second snapshot: a reconnect's.
          ..onConversationsList([_conv(_serverChat, _carol, 'carol')]);
        await store.settled;

        expect(
          conversations.conversations.map((c) => c.id),
          unorderedEquals([_serverChat, _localChat, erinChat]),
        );
        expect(conversations.getUnreadCount(_localChat), 1);
        expect(conversations.getUnreadCount(_serverChat), 1);
        expect(
          conversations.activeConversationDeletedByOther,
          isFalse,
          reason: 'no server list names a local chat, so absence is no delete',
        );
        final bob = store.byUserId(_bob);
        expect(bob?.legacy.conversationId, _localChat);
        expect(bob?.settings.disappearingTimer, 300);
        expect(bob?.state, ContactState.friend);
        // Positive control: the same sweep DOES drop a server chat the list
        // no longer names.
        conversations.onConversationsList([_conv(11, 4, 'dave')]);
        await store.settled;
        expect(
          conversations.conversations.map((c) => c.id),
          unorderedEquals([11, _localChat, erinChat]),
        );
        expect(store.byUserId(_carol)?.legacy.conversationId, isNull);
        expect(store.byUserId(_bob)?.legacy.conversationId, _localChat);
        expect(
          store.byUserId(_erin),
          isA<ContactRecord>()
              .having((r) => r.state, 'state', ContactState.friend)
              .having((r) => r.boxOrigin, 'boxOrigin', isNotNull),
        );
      },
    );
  });

  group('server events keyed by a conversation id', () {
    setUp(() {
      conversations.hydrateFromStore();
      encryption.records[_localChat] = {
        kFirstLocalMessageId + 7: {
          'senderId': _bob,
          'content': 'hello over the box',
          PlaintextRecordCodec.createdAtKey: DateTime.utc(
            2026,
            9,
            27,
            12,
          ).millisecondsSinceEpoch,
        },
      };
    });

    /// Every chat action a user can take on [conversationId] with [peer]:
    /// open (history), read, timer, mute, typing, recording, unpin, clear,
    /// and last the delete, as the chat list does it.
    Future<void> everyAction(int conversationId, int peer) async {
      conversations.openConversation(conversationId);
      messaging.getMessages(conversationId);
      await pump();
      messaging
        ..markConversationRead(conversationId)
        ..sendTypingIndicator(peer, conversationId)
        ..sendRecordingVoiceIndicator(peer, conversationId, isRecording: true)
        ..unpinMessage(conversationId)
        ..clearChatHistory(conversationId);
      conversations
        ..setDisappearingTimer(conversationId, 3600)
        ..setConversationMute(conversationId, '8h');
      await pump();
      messaging.onConversationDeleted(conversationId);
      conversations.deleteConversation(conversationId);
      await store.settled;
    }

    test(
      'a local chat is served, read, timed, muted, cleared and deleted '
      'without one emit, while the same actions on a server chat emit each '
      'event',
      () async {
        conversations
          ..updateLastMessage(
            _localChat,
            MessageModel(
              id: kFirstLocalMessageId + 7,
              content: 'hello over the box',
              senderId: _bob,
              senderUsername: 'bob',
              conversationId: _localChat,
              createdAt: DateTime.utc(2026, 9, 27, 12),
            ),
          )
          ..openConversation(_localChat);
        messaging.getMessages(_localChat);
        await pump();
        expect(
          messaging.messages.map((m) => m.content),
          ['hello over the box'],
          reason: 'the history comes from the local records alone',
        );
        messaging
          ..markConversationRead(_localChat)
          ..sendTypingIndicator(_bob, _localChat)
          ..sendRecordingVoiceIndicator(_bob, _localChat, isRecording: true)
          ..unpinMessage(_localChat);
        conversations
          ..setDisappearingTimer(_localChat, 3600)
          ..setConversationMute(_localChat, '8h');
        await store.settled;

        final timed = conversations.getConversationById(_localChat);
        expect(timed?.disappearingTimer, 3600);
        expect(timed?.muted, isTrue);
        expect(
          timed?.mutedUntil?.isAfter(
            DateTime.now().add(const Duration(hours: 7)),
          ),
          isTrue,
        );
        final settings = store.byUserId(_bob)?.settings;
        expect(settings?.disappearingTimer, 3600);
        expect(settings?.muted, isTrue);

        messaging.clearChatHistory(_localChat);
        expect(messaging.messages, isEmpty);
        expect(conversations.lastMessages, isNot(contains(_localChat)));

        messaging.onConversationDeleted(_localChat);
        conversations.deleteConversation(_localChat);
        await store.settled;
        expect(conversations.getConversationById(_localChat), isNull);
        expect(
          store.byUserId(_bob),
          isA<ContactRecord>()
              .having((r) => r.state, 'state', ContactState.friend)
              .having(
                (r) => r.legacy.conversationId,
                'conversationId',
                _localChat,
              ),
          reason: 'deleting the chat keeps the friend',
        );
        expect(events(), isEmpty);

        // Positive control: the very same actions on a server chat.
        await everyAction(_serverChat, _carol);
        expect(
          events(),
          containsAll(<String>[
            'getMessages',
            'markConversationRead',
            'typing',
            'recordingVoice',
            'unpinMessage',
            'clearChatHistory',
            'setDisappearingTimer',
            'setConversationMute',
            'deleteConversationOnly',
          ]),
        );
      },
    );

    test(
      'the socket-ready and resume refetches of an open local chat never ask '
      'the server for its history',
      () async {
        conversations.openConversation(_localChat);
        messaging.getMessages(_localChat);
        await pump();
        await messaging.loadOlderMessages(_localChat);
        expect(events(), isEmpty);
      },
    );

    test(
      'the invitation "create chat" door of a box friendship opens the local '
      'chat instead of asking the server for one',
      () async {
        final friends = FriendsProvider()
          ..contactStore = store
          ..setCurrentUserId(_me)
          ..setEmitCallback(capture);
        for (final (peer, name, chat) in [
          (_bob, 'bob', _localChat),
          (_carol, 'carol', null),
        ]) {
          friends.onFriendRequestAccepted({
            'id': 40 + peer,
            'sender': _user(peer, name),
            'receiver': _user(_me, 'me'),
            'status': 'accepted',
            'createdAt': '2026-09-27T12:00:00.000Z',
            'conversationId': chat,
            'chatReady': false,
          });
        }

        friends.ensureInvitationChat(_bob);
        expect(events(), isEmpty);
        expect(friends.acceptedOutcomeForPeer(_bob)?.chatReady, isTrue);
        expect(friends.acceptedOutcomeForPeer(_bob)?.conversationId, _localChat);

        friends.ensureInvitationChat(_carol);
        expect(events(), ['ensureInvitationChat']);
      },
    );
  });

  group('a send in a local chat', () {
    setUp(() {
      conversations.hydrateFromStore();
      messaging.boxOutbox = _Outbox();
    });

    Future<MessageModel> send(int conversationId, String text) async {
      conversations.openConversation(conversationId);
      messaging.sendMessage(text);
      await pump();
      return messaging.messages.last;
    }

    test(
      'to a peer the box does not cover FAILS, with no sendMessage; the '
      'same send in a server chat takes the old path',
      () async {
        final local = await send(_localChat, 'hi bob');
        expect(local.deliveryStatus, MessageDeliveryStatus.failed);
        expect(events(), isNot(contains('sendMessage')));

        await send(_serverChat, 'hi carol');
        expect(events(), contains('sendMessage'));
      },
    );

    test(
      'to a peer the box covers only in part (a live device with no address) '
      'FAILS instead of taking the old path',
      () async {
        encryption.lists[_bob] = _enrolled([1, 2]);
        (messaging.boxOutbox! as _Outbox).addresses[_bob] = {
          1: const ContactOutbound(peerDeviceId: 1, sid: 'sid-1', sealPub: 'p'),
        };
        messaging.refreshBoxDeviceLists();
        await pump();

        final local = await send(_localChat, 'hi bob');
        expect(local.deliveryStatus, MessageDeliveryStatus.failed);
        expect(events(), isNot(contains('sendMessage')));
      },
    );

    test(
      'an attachment to an uncovered peer is never uploaded to the old '
      "path's /media/upload, nor sent; in a server chat it is",
      () async {
        final photo = XFile.fromData(
          Uint8List.fromList(List<int>.generate(500, (i) => i % 251)),
          name: 'a.jpg',
        );
        conversations.openConversation(_localChat);
        expect(await messaging.sendImageMessage('tok', photo, _bob), isFalse);
        await pump();
        expect(mediaUpload.oldPathUploads, isEmpty);
        expect(events(), isNot(contains('sendMessage')));
        expect(
          messaging.messages.last.deliveryStatus,
          MessageDeliveryStatus.failed,
        );

        conversations.openConversation(_serverChat);
        await messaging.sendImageMessage('tok', photo, _carol);
        await pump();
        expect(mediaUpload.oldPathUploads, ['image']);
        expect(events(), contains('sendMessage'));
      },
    );
  });

  group('reaction keys', () {
    ReactionKeyService build(EncryptionService store, List<String> asked) =>
        ReactionKeyService(
          store: store,
          request: (event, payload) async {
            asked.add(event);
            return event == 'fetchReactionKey'
                ? {'epoch': 0, 'ciphertext': null}
                : {'success': true, 'epoch': 1};
          },
          resolveTargets: (_) async => const [(userId: _bob, deviceId: 1)],
          encryptFor: (u, d, plaintext) async => 'ct:$u:$d',
          decryptFrom: (_, _, _) async => throw StateError('not expected'),
        );

    test(
      'a local chat never fetches or uploads a key (box reactions are plain '
      'emoji); a server chat does',
      () async {
        final service = EncryptionService();
        await service.initialize(
          _me,
          checkServerIdentity: () async =>
              const ServerIdentityGuard(exists: false),
        );
        final asked = <String>[];
        final svc = build(service, asked);

        final local = await svc.ensureCodec(
          _localChat,
          peerUserId: _bob,
          mayCreate: true,
        );
        expect(local.codec, isNull);
        expect(asked, isEmpty);

        final server = await svc.ensureCodec(
          _serverChat,
          peerUserId: _carol,
          mayCreate: true,
        );
        expect(server.codec, isNotNull);
        expect(asked, ['fetchReactionKey', 'uploadReactionKey']);
      },
    );
  });
}
