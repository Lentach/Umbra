// A2-AUTH-01, effect side: a message for the OPEN chat that arrives while the
// passcode lock is up starts no countdown and sends no read receipt; the
// unlock then does both, as on any foreground.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/main_shell.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_siblings.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/chat_seed.dart';
import '../support/passcode_fakes.dart';

class _Auth extends AuthProvider {
  bool released = false;

  @override
  bool get isLoggedIn => true;

  @override
  bool get isRestoringSession => false;

  @override
  String? get token => 'tok';

  @override
  UserModel? get currentUser => UserModel(id: 1, username: 'alice', tag: '0001');

  @override
  Future<void> ensureSessionReady() =>
      released ? Future<void>.value() : Completer<void>().future;
}

class _Passcode extends PasscodeProvider {
  _Passcode() : super(store: MemoryPasscodeStore(), kdf: FakePasscodeKdf());

  PasscodeLockState _fake = PasscodeLockState.unlocked;

  @override
  PasscodeLockState get state => _fake;

  @override
  bool get isLocked => _fake == PasscodeLockState.locked;

  @override
  bool get isEnabled => true;

  @override
  Future<void> noteBackgrounded() async {}

  @override
  Future<void> evaluateOnForeground() async {}

  void setLock(PasscodeLockState next) {
    _fake = next;
    notifyListeners();
  }
}

class _Encryption extends EncryptionProvider {
  _Encryption(this.store) : super(service: store);

  final EncryptionService store;
  final Map<int, VerifiedDeviceList> lists = {};
  String inbound = '{}';

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  int get ownDeviceId => 1;

  @override
  bool get ownDeviceIdConfirmed => true;

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => lists[userId];

  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    bool batched = false,
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
  Future<bool> carriesOwnIdentity(String ciphertext) async => true;

  @override
  Future<bool> preKeyWouldReplaceSession(
    int userId,
    int deviceId,
    String ciphertext,
  ) async => false;
}

class _Outbox implements BoxOutbox {
  final Map<int, ContactOutbound> bob = {
    1: const ContactOutbound(peerDeviceId: 1, sid: 'sid-1', sealPub: 'seal'),
  };
  final List<BoxFrame> delivered = [];
  int _next = kFirstLocalMessageId + 500;

  @override
  Map<int, ContactOutbound> addressesFor(int peerUserId) =>
      peerUserId == 2 ? bob : const {};

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
    delivered.add(BoxFrame.decode(body)!);
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
  ) async => throw UnimplementedError();

  @override
  Future<BoxResult<Uint8List>> downloadMedia(Uint8List id) async =>
      throw UnimplementedError();
}

class _Link implements BoxSiblingLink {
  @override
  ContactRecord? contactOf(int userId) => userId == 2 ? _bob : null;

  @override
  Future<void> rekeySibling(int deviceId) async {}

  @override
  bool awaitingRekeyFrom(int deviceId) => false;

  @override
  void rekeyAnswered(int deviceId) {}

  @override
  Future<SiblingWrite> takeSiblingHandoff(
    int deviceId, {
    required String sid,
    required String sealPub,
  }) async => SiblingWrite.stored;

  @override
  Future<SiblingWrite> siblingAcked(int deviceId, String sid) async =>
      SiblingWrite.stored;
}

const _bob = ContactRecord(
  userId: 2,
  username: 'bob',
  tag: '0002',
  state: ContactState.friend,
  legacy: ContactLegacy(conversationId: 10),
);

const Map<String, dynamic> _bobConv = {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // [lockedAtMount]: the shell mounts already under the lock (cold start, a
  // notification tap) instead of the lock engaging afterwards.
  Future<void> scenario(
    WidgetTester tester, {
    required bool lockedAtMount,
  }) async {
    await tester.runAsync(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
    });
    final auth = _Auth();
    final passcode = _Passcode();
    if (lockedAtMount) passcode._fake = PasscodeLockState.locked;
    addTearDown(auth.dispose);
    addTearDown(passcode.dispose);
    final outbox = _Outbox();
    late _Encryption encryption;
    late ConversationsProvider conversations;
    late MessagingProvider messaging;

    await tester.runAsync(() async {
      final service = EncryptionService();
      await service.initialize(
        1,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: false),
      );
      encryption = _Encryption(service)
        ..lists[1] = VerifiedDeviceList.enrolled(
          version: 3,
          listHash: 'H' * 44,
          devices: const [
            DeviceListEntry(deviceId: 1, platform: 'test', addedAtMs: 0),
          ],
        )
        ..lists[2] = VerifiedDeviceList.enrolled(
          version: 3,
          listHash: 'H' * 44,
          devices: const [
            DeviceListEntry(deviceId: 1, platform: 'test', addedAtMs: 0),
          ],
        );
      final kv = await PrefsContentKv.open();
      final store = ContactStore(
        open: () async => kv,
        lock: <T>(_, action) => action(),
        accepts: (_) => true,
      );
      await store.open(1);
      conversations = ConversationsProvider()
        ..contactStore = store
        ..setCurrentUserId(1);
      seedConversations(conversations, [_bobConv]);
      conversations.openConversation(10);
      await store.settled;
      messaging = MessagingProvider()
        ..setConversationsProvider(conversations)
        ..setEncryptionProvider(encryption)
        ..setCurrentUserId(1)
        ..setToken('tok')
        ..setIncomingMessageSoundEnabledForTest(false)
        ..onConnect(false)
        ..boxOutbox = outbox
        ..boxSiblings = _Link()
        ..receiptsAndTyping = (() => true)
        ..refreshBoxDeviceLists();
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    addTearDown(messaging.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
          ChangeNotifierProvider(create: (_) => FriendsProvider()),
          ChangeNotifierProvider<ConversationsProvider>.value(
            value: conversations,
          ),
          ChangeNotifierProvider<MessagingProvider>.value(value: messaging),
          ChangeNotifierProvider(create: (_) => ConnectionProvider()),
          ChangeNotifierProvider<PasscodeProvider>.value(value: passcode),
        ],
        child: MaterialApp(
          theme: RpgTheme.themeDataLight,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MainShell(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // The shell's screen re-wires the receipts switch from the settings.
    messaging.receiptsAndTyping = () => true;

    if (!lockedAtMount) {
      passcode.setLock(PasscodeLockState.locked);
      await tester.pump();
    }
    expect(conversations.isClientVisible, isFalse);

    late int localId;
    await tester.runAsync(() async {
      encryption.inbound = jsonEncode(
        E2eEnvelope.build(
          'vanishing',
          msgId: 'wire-bob-0001',
          ttl: 60,
          sentAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
        ),
      );
      localId = kFirstLocalMessageId + 1;
      final entry = BoxInboxEntry(
        rid: 'rid',
        id: 'm1',
        localId: localId,
        peerUserId: 2,
        senderDeviceId: 1,
        signal: '2:AQID',
        receivedAt: DateTime.now().toUtc(),
        acked: true,
      );
      expect(await messaging.consumeBoxEntry(entry, _bob), isTrue);
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    final shown = messaging.messages.singleWhere((m) => m.id == localId);
    expect(shown.expiresAt, isNull, reason: 'locked: not shown, no countdown');
    expect(outbox.delivered, isEmpty, reason: 'locked: no read receipt');

    passcode.setLock(PasscodeLockState.unlocked);
    await tester.pump();
    for (var i = 0; i < 100 && outbox.delivered.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      messaging.messages.singleWhere((m) => m.id == localId).expiresAt,
      isNotNull,
      reason: 'unlocked: the open chat is shown, the countdown starts',
    );
    expect(outbox.delivered, isNotEmpty, reason: 'unlocked: read receipt');
  }

  testWidgets('a message for the open chat that arrives while locked starts '
      'no countdown and sends no read receipt until the unlock', (
    tester,
  ) => scenario(tester, lockedAtMount: false));

  testWidgets('the same for a shell that mounted under the lock: the chat a '
      'notification tap opened is not read behind it', (
    tester,
  ) => scenario(tester, lockedAtMount: true));
}
