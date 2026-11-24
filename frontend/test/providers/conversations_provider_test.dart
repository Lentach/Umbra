import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/services/box/box_wire.dart';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/models/conversation_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/push_sw_channel_stub.dart';
import 'package:fireplace/services/wake_up_mute.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/chat_seed.dart';
import '../support/contact_seed.dart';

class _RecordingPushSwChannel implements PushSwChannel {
  final List<Map<String, Object?>> messages = [];
  @override
  Future<bool> postMessage(Map<String, Object?> message) async {
    messages.add(message);
    return true;
  }
}

/// [inner] whose next [refuseWrites] record writes are refused: a commit that did
/// not land, as a full disk or a failed seal answers.
class _RefusingKv implements ContentKv {
  _RefusingKv(this.inner);

  final ContentKv inner;
  int refuseWrites = 0;

  /// While set, a record write waits for it: a commit still in flight.
  Completer<void>? hold;

  @override
  Future<void> reload() => inner.reload();

  @override
  Future<Map<String, Object>?> authoritativeSnapshot() =>
      inner.authoritativeSnapshot();

  @override
  String? getString(String key) => inner.getString(key);

  @override
  int? getInt(String key) => inner.getInt(key);

  @override
  bool containsKey(String key) => inner.containsKey(key);

  @override
  Set<String> getKeys() => inner.getKeys();

  @override
  Future<bool> setString(String key, String value) async {
    await hold?.future;
    if (refuseWrites > 0) {
      refuseWrites--;
      return false;
    }
    return inner.setString(key, value);
  }

  @override
  Future<bool> setInt(String key, int value) => inner.setInt(key, value);

  @override
  Future<bool> remove(String key) => inner.remove(key);
}

/// An open contact store over [kv] for account 1, holding [records].
Future<ContactStore> _storeOver(
  ContentKv kv,
  List<ContactRecord> records,
) async {
  final store = ContactStore(
    open: () async => kv,
    selfProfile: () => UserModel(id: 1, username: 'alice', tag: '0001'),
    lock: <T>(_, action) => action(),
    accepts: (_) => true,
  );
  await store.open(1);
  await putContacts(store, records);
  return store;
}

Map<String, dynamic> _conv(
  int id, {
  int unread = 0,
  Map<String, dynamic> extra = const {},
}) => {
  'id': id,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
  'unreadCount': unread,
  ...extra,
};

void main() {
  group('ConversationsProvider', () {
    ConversationsProvider buildProviderWithSampleData() {
      final provider = ConversationsProvider()..onConnect(false);
      seedConversations(provider, [
        _conv(10, unread: 1),
        {
          'id': 11,
          'userOne': {'id': 2, 'username': 'bob', 'tag': '0002'},
          'userTwo': {'id': 1, 'username': 'alice', 'tag': '0001'},
          'createdAt': DateTime.utc(2026, 1, 2).toIso8601String(),
          'unreadCount': 0,
        },
      ]);
      provider.updateLastMessage(
        10,
        MessageModel(
          id: 100,
          content: 'Hello',
          senderId: 1,
          senderUsername: 'alice',
          conversationId: 10,
          createdAt: DateTime.utc(2026, 1, 1, 12),
        ),
      );
      return provider;
    }

    test('onConnect(false) clears all state', () {
      final provider = buildProviderWithSampleData();
      provider.openConversation(10);
      expect(provider.hasLoadedConversations, isTrue);

      provider.onConnect(false);

      expect(provider.conversations, isEmpty);
      expect(provider.activeConversationId, isNull);
      expect(provider.lastMessages, isEmpty);
      expect(provider.unreadCounts, isEmpty);
      expect(provider.pendingOpenConversationId, isNull);
      expect(provider.pendingNotificationConversationId, isNull);
      expect(provider.hasLoadedConversations, isFalse);
    });

    test('hydrateFromStore with a closed store still counts as loaded', () {
      final provider = ConversationsProvider();
      expect(provider.hasLoadedConversations, isFalse);

      provider.hydrateFromStore();

      expect(provider.hasLoadedConversations, isTrue);
      expect(provider.conversations, isEmpty);
    });

    test(
      'requestNavigateToConversationFromNotification pending is consumed and cleared',
      () {
        final provider = ConversationsProvider();
        provider.requestNavigateToConversationFromNotification(42);
        expect(provider.pendingNotificationConversationId, 42);
        expect(provider.consumePendingNotificationConversationId(), 42);
        expect(provider.pendingNotificationConversationId, isNull);
        expect(provider.consumePendingNotificationConversationId(), isNull);
      },
    );

    test(
      'requestNavigateToConversationFromNotification ignores duplicate same id',
      () {
        final provider = ConversationsProvider();
        var notifies = 0;
        provider.addListener(() => notifies++);
        provider.requestNavigateToConversationFromNotification(7);
        expect(notifies, 1);
        provider.requestNavigateToConversationFromNotification(7);
        expect(notifies, 1);
        expect(provider.pendingNotificationConversationId, 7);
      },
    );

    test('onConnect(false) clears pending notification conversation id', () {
      final provider = ConversationsProvider();
      provider.requestNavigateToConversationFromNotification(99);
      provider.onConnect(false);
      expect(provider.pendingNotificationConversationId, isNull);
    });

    test(
      'onConnect(true) preserves conversations and active chat (no flicker)',
      () {
        final provider = buildProviderWithSampleData();
        provider.openConversation(10);

        provider.onConnect(true);

        expect(provider.conversations, isNotEmpty);
        expect(provider.activeConversationId, 10);
      },
    );

    test(
      'removeConversationsForUser removes conversations and clears active if needed',
      () {
        final provider = ConversationsProvider();
        seedConversations(provider, [
          _conv(10),
          {
            'id': 11,
            'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
            'userTwo': {'id': 1, 'username': 'alice', 'tag': '0001'},
            'createdAt': DateTime.utc(2026, 1, 2).toIso8601String(),
            'unreadCount': 0,
          },
        ]);

        provider.openConversation(10);
        provider.removeConversationsForUser(2);

        expect(provider.conversations.length, 1);
        expect(provider.conversations.first.id, 11);
        expect(provider.activeConversationId, isNull);
      },
    );

    test('deleteConversation removes the conversation on this device', () {
      final provider = buildProviderWithSampleData();

      provider.deleteConversation(10);

      expect(provider.conversations.length, 1);
      expect(provider.conversations.first.id, 11);
      expect(provider.lastMessages.containsKey(10), isFalse);
    });

    test(
      'openConversation(notify: false) sets active id without notifying listeners',
      () {
        final provider = ConversationsProvider();
        var listenerCalls = 0;
        provider.addListener(() => listenerCalls++);

        provider.openConversation(10, notify: false);

        expect(listenerCalls, 0);
        expect(provider.activeConversationId, 10);
        expect(provider.getUnreadCount(10), 0);

        provider.notifyActiveConversationChanged();
        expect(listenerCalls, 1);
      },
    );

    test(
      'setDisappearingTimer updates conversationDisappearingTimer immediately',
      () {
        final provider = buildProviderWithSampleData();
        provider.openConversation(10);

        provider.setDisappearingTimer(10, 86400);

        expect(provider.conversationDisappearingTimer, 86400);
      },
    );

    group('a friend from before the box (store-backed settings)', () {
      late ContactStore store;

      setUp(() async {
        SharedPreferences.setMockInitialValues({});
        final kv = await PrefsContentKv.open();
        store = ContactStore(
          open: () async => kv,
          selfProfile: () => UserModel(id: 1, username: 'me', tag: '0001'),
          lock: <T>(_, action) => action(),
          accepts: (_) => true,
        );
        await store.open(1);
        unawaited(
          store.update(
            2,
            (_) => ContactRecord(
              userId: 2,
              username: 'bob',
              tag: '0002',
              state: ContactState.friend,
              legacy: ContactLegacy(
                conversationId: 10,
                conversationCreatedAt: DateTime.utc(2026, 1, 1),
              ),
            ),
          ),
        );
        await store.settled;
      });

      test(
        'setDisappearingTimer writes the record and tells the box nobody',
        () async {
          final provider = ConversationsProvider()
            ..contactStore = store
            ..setCurrentUserId(1);
          final told = <(int, int?)>[];
          provider.onLocalChatTimerChanged = (peer, seconds, at) =>
              told.add((peer, seconds));
          provider.hydrateFromStore();
          expect(provider.conversations.map((c) => c.id), [10]);

          provider.setDisappearingTimer(10, 600);
          await store.settled;

          expect(provider.conversations.single.disappearingTimer, 600);
          final record = store.byUserId(2)!;
          expect(record.onBoxRoute, isFalse);
          expect(record.settings.disappearingTimer, 600);
          expect(record.settings.timerAt, isNotNull);
          expect(told, isEmpty);
        },
      );
    });

    group('pushClientState (server push suppression)', () {
      test(
        'closeConversation(notify: false) clears active id without notifying',
        () {
          final provider = ConversationsProvider();
          var listenerCalls = 0;
          provider.addListener(() => listenerCalls++);
          provider.onConnect(false);
          provider.openConversation(42);
          listenerCalls = 0;

          provider.closeConversation(notify: false);

          expect(listenerCalls, 0);
          expect(provider.activeConversationId, isNull);

          provider.notifyActiveConversationChanged();
          expect(listenerCalls, 1);
        },
      );
      test(
        'posts active conversation to the push SW; background posts null',
        () {
          final channel = _RecordingPushSwChannel();
          final provider = ConversationsProvider(pushSwChannel: channel);
          provider.onConnect(false);
          channel.messages.clear();

          provider.openConversation(42);
          provider.setClientVisible(false);
          provider.setClientVisible(true);

          final active = channel.messages
              .where((m) => m['type'] == 'active-conversation')
              .toList();
          expect(active.first['conversationId'], 42);
          expect(
            active.any((m) => m['conversationId'] == null),
            isTrue,
            reason: 'backgrounded (clientVisible=false) must post null',
          );
          expect(active.last['conversationId'], 42);
        },
      );

      test('repostActiveConversationToSw says the open chat again', () {
        final channel = _RecordingPushSwChannel();
        final provider = ConversationsProvider(pushSwChannel: channel);
        provider.onConnect(false);
        provider.openConversation(42);
        channel.messages.clear();

        provider.repostActiveConversationToSw();

        expect(channel.messages.single, {
          'type': 'active-conversation',
          'conversationId': 42,
        });
      });
    });

    // Spec §12 (xxxvii). A pin that did not go out is undone on this device:
    // only this device knows what its optimistic pin overwrote.
    group('a refused pin restores what the optimistic pin overwrote', () {
      MessageModel preview(int id) => MessageModel(
        id: id,
        content: 'msg $id',
        senderId: 1,
        senderUsername: 'alice',
        conversationId: 10,
        createdAt: DateTime.utc(2026, 1, 1, 12),
      );

      ConversationsProvider seeded({int? pinned}) {
        final provider = ConversationsProvider();
        provider.onConnect(false);
        seedConversations(provider, [
          _conv(
            10,
            extra: {
              'pinnedMessageId': ?pinned,
              if (pinned != null)
                'pinnedMessage': {
                  'id': pinned,
                  'content': 'msg $pinned',
                  'senderId': 1,
                  'conversationId': 10,
                  'createdAt': DateTime.utc(2026, 1, 1, 12).toIso8601String(),
                },
            },
          ),
        ]);
        return provider;
      }

      ConversationModel only(ConversationsProvider p) =>
          p.conversations.firstWhere((c) => c.id == 10);

      test('restores the PREVIOUS pin, not "unpinned"', () {
        final provider = seeded(pinned: 41);

        provider.setPinnedPreviewOptimistic(10, 77, preview(77));
        expect(only(provider).pinnedMessageId, 77);

        provider.revertOptimisticPin(10);

        expect(only(provider).pinnedMessageId, 41);
        expect(only(provider).pinnedMessagePreview?.id, 41);
      });

      test('restores UNPINNED when nothing was pinned before', () {
        final provider = seeded();
        provider.setPinnedPreviewOptimistic(10, 77, preview(77));
        expect(only(provider).pinnedMessageId, 77);

        provider.revertOptimisticPin(10);

        expect(only(provider).pinnedMessageId, isNull);
        expect(only(provider).pinnedMessagePreview, isNull);
      });

      test('a settled pin is not undone by a LATER unrelated refusal', () {
        final provider = seeded();
        provider.setPinnedPreviewOptimistic(10, 77, preview(77));
        // The box write settled it, so there is nothing left to undo.
        provider.applyBoxPin(
          10,
          BoxPin(at: DateTime.utc(2026, 2), senderId: 1, wireId: 'w77'),
          shown: preview(77),
        );

        provider.revertOptimisticPin(10);

        expect(only(provider).pinnedMessageId, 77);
      });

      test('two optimistic pins in a row still revert to the settled state', () {
        final provider = seeded();
        provider.setPinnedPreviewOptimistic(10, 77, preview(77));
        // Second tap before the first settles: the snapshot must still hold
        // the settled state (unpinned), never the first optimistic pin.
        provider.setPinnedPreviewOptimistic(10, 88, preview(88));

        provider.revertOptimisticPin(10);

        expect(only(provider).pinnedMessageId, isNull);
      });
    });

    group('mute survives unrelated conversation mutations', () {
      ConversationsProvider mutedProvider() {
        final provider = ConversationsProvider();
        provider.onConnect(false);
        seedConversations(provider, [
          _conv(
            10,
            extra: {
              'muted': true,
              'mutedUntil': DateTime.utc(2026, 6, 1).toIso8601String(),
            },
          ),
        ]);
        return provider;
      }

      ConversationModel only(ConversationsProvider p) =>
          p.conversations.firstWhere((c) => c.id == 10);

      test('setDisappearingTimer keeps mute and can clear the timer', () {
        final provider = mutedProvider();
        provider.setDisappearingTimer(10, 3600);
        expect(only(provider).disappearingTimer, 3600);
        expect(only(provider).muted, isTrue);

        provider.setDisappearingTimer(10, null);
        expect(only(provider).disappearingTimer, isNull);
        expect(only(provider).muted, isTrue);
      });

      test('setConversationMute off clears mutedUntil', () {
        final provider = mutedProvider();
        provider.setConversationMute(10, 'off');

        expect(only(provider).muted, isFalse);
        expect(only(provider).mutedUntil, isNull);
      });
    });

    group('postHiddenArrivalCard (decision 76)', () {
      late _RecordingPushSwChannel channel;

      ConversationsProvider build({
        bool muted = false,
        DateTime? mutedUntil,
        bool hidden = true,
      }) {
        channel = _RecordingPushSwChannel();
        final provider = ConversationsProvider(pushSwChannel: channel)
          ..onConnect(false);
        seedConversations(provider, [
          _conv(
            10,
            extra: {
              'createdAt': DateTime.utc(2026).toIso8601String(),
              'muted': muted,
              'mutedUntil': mutedUntil?.toIso8601String(),
            },
          ),
        ]);
        if (hidden) provider.setClientVisible(false);
        return provider;
      }

      List<Map<String, Object?>> cards() =>
          channel.messages.where((m) => m['type'] == 'local-card').toList();

      test('a hidden page asks the push SW for a per-chat card', () {
        build().postHiddenArrivalCard(10);

        expect(cards(), [
          {'type': 'local-card', 'conversationId': 10, 'count': 1},
        ]);
      });

      test('counts the burst, and the chat unread when it is higher', () {
        final provider = build()
          ..postHiddenArrivalCard(10)
          ..postHiddenArrivalCard(10);
        expect(cards().last['count'], 2);

        provider
          ..updateUnreadCount(10, 5)
          ..postHiddenArrivalCard(10);
        expect(cards().last['count'], 5);
      });

      test('a visible page posts nothing: the badge alone speaks', () {
        build(hidden: false).postHiddenArrivalCard(10);

        expect(cards(), isEmpty);
      });

      test('a muted chat posts nothing', () {
        build(muted: true).postHiddenArrivalCard(10);

        expect(cards(), isEmpty);
      });

      test('a mute that has run out no longer silences the card', () {
        build(
          muted: true,
          mutedUntil: DateTime.now().subtract(const Duration(hours: 1)),
        ).postHiddenArrivalCard(10);

        expect(cards(), hasLength(1));
      });

      test('a mute that runs on still does', () {
        build(
          muted: true,
          mutedUntil: DateTime.now().add(const Duration(hours: 1)),
        ).postHiddenArrivalCard(10);

        expect(cards(), isEmpty);
      });

      test('coming back to the screen restarts the count', () {
        build()
          ..postHiddenArrivalCard(10)
          ..postHiddenArrivalCard(10)
          ..setClientVisible(true)
          ..setClientVisible(false)
          ..postHiddenArrivalCard(10);

        expect(cards().last['count'], 1);
      });
    });
  });

  // A friend's photo moves without the set of chats changing (decision 138):
  // the chat already shown takes the photo its contact record holds now.
  group('ConversationsProvider peer photo refresh', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    ProfilePhotoRef photo(int rev, {int idFill = 1}) => ProfilePhotoRef(
      rev: rev,
      mediaId: boxB64(Uint8List(32)..fillRange(0, 32, idFill)),
      key: base64.encode(List.filled(32, 7)),
      iv: base64.encode(List.filled(12, 9)),
    );

    ContactRecord friend(int id, {ProfilePhotoRef? avatar, bool muted = false}) =>
        contactRecord(
          id,
          'peer$id',
          ContactState.friend,
          box: true,
          settings: ContactSettings(muted: muted),
        ).copyWith(avatar: avatar);

    test("a friend's new photo replaces the peer of the chat on the next "
        'refresh; the chat set is unchanged', () async {
      final store = await openContactStore([friend(2), friend(3)]);
      final chats = conversationsOver(store);
      var told = 0;
      chats.addListener(() => told++);
      final ids = chats.conversations.map((c) => c.id).toList();
      expect(chats.conversations.map((c) => c.userTwo.avatar), [null, null]);

      await putContacts(store, [friend(2, avatar: photo(5))]);
      chats.refreshChats();

      expect(chats.conversations.map((c) => c.id), ids);
      final bob = chats.conversations.firstWhere((c) => c.userTwo.id == 2);
      final cara = chats.conversations.firstWhere((c) => c.userTwo.id == 3);
      expect(bob.userTwo.avatar, photo(5));
      expect(cara.userTwo.avatar, isNull, reason: 'only the one that moved');
      expect(told, 1);
    });

    test('a refresh with no change tells nobody', () async {
      final store = await openContactStore([friend(2, avatar: photo(5))]);
      final chats = conversationsOver(store);
      var told = 0;
      chats.addListener(() => told++);

      chats.refreshChats();
      chats.refreshChats();
      expect(told, 0);
      expect(chats.conversations.single.userTwo.avatar, photo(5));
    });

    test('a newer photo, a removal and a record without one each replace the '
        'shown peer', () async {
      final store = await openContactStore([friend(2, avatar: photo(5))]);
      final chats = conversationsOver(store);

      await putContacts(store, [friend(2, avatar: photo(6, idFill: 2))]);
      chats.refreshChats();
      expect(chats.conversations.single.userTwo.avatar, photo(6, idFill: 2));

      await putContacts(store, [
        friend(2, avatar: const ProfilePhotoRef.cleared(7)),
      ]);
      chats.refreshChats();
      expect(chats.conversations.single.userTwo.avatar?.isCleared, isTrue);
      expect(chats.conversations.single.userTwo.avatar?.rev, 7);

      await putContacts(store, [friend(2)]);
      chats.refreshChats();
      expect(chats.conversations.single.userTwo.avatar, isNull);
    });

    test("the rest of the shown row is kept: only the peer's photo moves",
        () async {
      final store = await openContactStore([friend(2, muted: true)]);
      final chats = conversationsOver(store);
      final before = chats.conversations.single;
      expect(before.muted, isTrue);

      // The record now says "not muted" (a setting write that landed after the
      // row was shown): the shown row keeps its own; only the photo moves.
      await putContacts(store, [friend(2, avatar: photo(5))]);
      chats.refreshChats();

      final after = chats.conversations.single;
      expect(after.id, before.id);
      expect(after.userOne, same(before.userOne));
      expect(after.createdAt, before.createdAt);
      expect(after.muted, before.muted);
      expect(after.userTwo.username, before.userTwo.username);
      expect(after.userTwo.avatar, photo(5));
    });

    test('a chat that is not shown yet is built with the photo the record '
        'holds', () async {
      final store = await openContactStore([friend(2, avatar: photo(5))]);
      final chats = conversationsOver(store);
      expect(chats.conversations.single.userTwo.avatar, photo(5));

      await putContacts(store, [friend(4, avatar: photo(8, idFill: 4))]);
      chats.refreshChats();
      final added = chats.conversations.firstWhere((c) => c.userTwo.id == 4);
      expect(added.userTwo.avatar, photo(8, idFill: 4));
      expect(
        chats.conversations.firstWhere((c) => c.userTwo.id == 2).userTwo.avatar,
        photo(5),
      );
    });
  });

  // Issue #274: a chat deleted on this device is hidden, not gone, and its
  // record still holds the mute. Its next message is told to the user before
  // the chat is back in the list, so the mute must be read from the record.
  group('ConversationsProvider mute of a chat deleted here (#274)', () {
    late _RecordingPushSwChannel channel;

    Future<(ConversationsProvider, int)> hiddenChat({
      required bool muted,
      DateTime? mutedUntil,
    }) async {
      final store = await openContactStore([
        contactRecord(
          2,
          'bob',
          ContactState.friend,
          box: true,
          settings: ContactSettings(
            muted: muted,
            mutedUntil: mutedUntil,
            chatHidden: true,
          ),
        ),
      ]);
      channel = _RecordingPushSwChannel();
      final chats = ConversationsProvider(pushSwChannel: channel)
        ..contactStore = store
        ..setCurrentUserId(store.userId!)
        ..hydrateFromStore()
        ..setClientVisible(false);
      expect(chats.conversations, isEmpty, reason: 'the chat is hidden');
      return (chats, store.byUserId(2)!.chatId!);
    }

    List<Map<String, Object?>> cards() =>
        channel.messages.where((m) => m['type'] == 'local-card').toList();

    test('a muted hidden chat posts no card', () async {
      final (chats, chatId) = await hiddenChat(muted: true);

      chats.postHiddenArrivalCard(chatId);

      expect(cards(), isEmpty);
    });

    test('a hidden chat whose mute ran out posts its card', () async {
      final (chats, chatId) = await hiddenChat(
        muted: true,
        mutedUntil: DateTime.now().subtract(const Duration(hours: 1)),
      );

      chats.postHiddenArrivalCard(chatId);

      expect(cards(), hasLength(1));
    });

    test('a hidden chat that is not muted posts its card', () async {
      final (chats, chatId) = await hiddenChat(muted: false);

      chats.postHiddenArrivalCard(chatId);

      expect(cards(), hasLength(1));
    });
  });

  // Decision 149: the closed Android app is told only whether EVERY chat is
  // muted (the FCM wake-up names none).
  group('ConversationsProvider wake-up mute (decision 149)', () {
    late List<String?> written;

    ContactRecord peer(int id, {bool muted = false, bool hidden = false}) =>
        contactRecord(
          id,
          'peer$id',
          ContactState.friend,
          box: true,
          settings: ContactSettings(muted: muted, chatHidden: hidden),
        );

    Future<ConversationsProvider> over(List<ContactRecord> records) async {
      final store = await openContactStore(records);
      written = [];
      return ConversationsProvider(
          wakeUpMute: (value) async => written.add(value),
        )
        ..contactStore = store
        ..setCurrentUserId(store.userId!)
        ..hydrateFromStore();
    }

    test('every chat muted is written as forever', () async {
      await over([peer(2, muted: true), peer(3, muted: true)]);

      expect(written, [kWakeUpMutedForever]);
    });

    test('one audible chat writes "not all muted"', () async {
      await over([peer(2, muted: true), peer(3)]);

      expect(written, [null]);
    });

    test('muting the last audible chat silences; un-muting one ends it',
        () async {
      final chats = await over([peer(2, muted: true), peer(3)]);
      final carol = chats.conversations.firstWhere((c) => c.userTwo.id == 3);

      chats.setConversationMute(carol.id, 'always');
      expect(written.last, kWakeUpMutedForever);

      chats.setConversationMute(carol.id, 'off');
      expect(written.last, isNull);
    });

    test('a chat deleted here still counts, by the mute its record keeps',
        () async {
      await over([peer(2, muted: true), peer(3, muted: true, hidden: true)]);
      expect(written, [kWakeUpMutedForever]);

      await over([peer(2, muted: true), peer(3, hidden: true)]);
      expect(written, [null]);
    });

    test('the same answer is written once', () async {
      final chats = await over([peer(2, muted: true)]);

      chats
        ..updateUnreadCount(chats.conversations.single.id, 3)
        ..refreshChats();

      expect(written, [kWakeUpMutedForever]);
    });

    test('logout clears it', () async {
      final chats = await over([peer(2, muted: true)]);

      chats.clearAll();

      expect(written, [kWakeUpMutedForever, null]);
    });

    test('a session whose store is closed writes nothing: what the last '
        'open session left stands', () {
      written = [];
      ConversationsProvider(wakeUpMute: (value) async => written.add(value))
        ..setCurrentUserId(1)
        ..hydrateFromStore()
        ..updateUnreadCount(10, 1);

      expect(written, isEmpty);
    });

    // A request we sent holds a queue with its own push notifier: the
    // friend's first messages after an accept arrive on it while the app is
    // closed, and that chat is not muted.
    test('a pending request that holds a queue keeps wake-ups audible, and '
        'is seen when the app goes to the background', () async {
      final chats = await over([peer(2, muted: true)]);
      expect(written, [kWakeUpMutedForever]);

      await putContacts(chats.contactStore!, [
        contactRecord(5, 'dave', ContactState.pendingOut, box: true).copyWith(
          queues: const [
            ContactQueue(
              rid: 'r',
              sid: 's',
              nid: 'n',
              authPriv: 'a',
              sealPriv: 'sp',
              sealPub: 'p',
            ),
          ],
        ),
      ]);
      // Sending a request tells the friends list, not this provider; leaving
      // the app is the moment the answer must be right.
      chats.setClientVisible(false);

      expect(written, [kWakeUpMutedForever, null]);
    });

    test('a blocked contact that still holds a queue does not count',
        () async {
      await over([
        peer(2, muted: true),
        contactRecord(6, 'eve', ContactState.blocked, box: true).copyWith(
          queues: const [
            ContactQueue(
              rid: 'r6',
              sid: 's6',
              nid: 'n6',
              authPriv: 'a',
              sealPriv: 'sp',
              sealPub: 'p',
            ),
          ],
        ),
      ]);

      expect(written, [kWakeUpMutedForever]);
    });

    test('a write that failed is tried again on the next change', () async {
      final store = await openContactStore([peer(2, muted: true)]);
      final attempts = <String?>[];
      var fail = true;
      final chats =
          ConversationsProvider(
              wakeUpMute: (value) async {
                attempts.add(value);
                if (fail) throw StateError('prefs refused');
              },
            )
            ..contactStore = store
            ..setCurrentUserId(store.userId!)
            ..hydrateFromStore();
      await Future<void>.delayed(Duration.zero);
      expect(attempts, [kWakeUpMutedForever]);

      fail = false;
      chats.updateUnreadCount(chats.conversations.single.id, 1);
      await Future<void>.delayed(Duration.zero);

      expect(attempts, [kWakeUpMutedForever, kWakeUpMutedForever]);
    });
  });

  // CONT-09: a setting is written to the peer's record whether or not the
  // chat is in the shown list, and a write the store refused is not left
  // standing on the screen.
  group('ConversationsProvider settings write-through (CONT-09)', () {
    test('a pin for a chat deleted here is kept on its record: the next '
        'session reads it once the chat shows again', () async {
      final store = await openContactStore([
        contactRecord(
          2,
          'bob',
          ContactState.friend,
          box: true,
          settings: const ContactSettings(chatHidden: true),
        ),
      ]);
      final chatId = store.byUserId(2)!.chatId!;
      final chats = conversationsOver(store);
      expect(chats.conversations, isEmpty, reason: 'the chat is hidden');

      chats.applyBoxPin(
        chatId,
        BoxPin(at: DateTime.utc(2026, 2), senderId: 2, wireId: 'w7'),
      );
      await store.settled;

      final next = conversationsOver(store)..startConversation(2);
      await store.settled;
      expect(next.conversations.map((c) => c.id), [chatId]);
      expect(next.boxPinOf(chatId)?.wireId, 'w7');
    });

    test('a mute the store refused is taken back off the row', () async {
      SharedPreferences.setMockInitialValues({});
      final kv = _RefusingKv(await PrefsContentKv.open());
      final store = await _storeOver(kv, [
        contactRecord(2, 'bob', ContactState.friend, box: true),
      ]);
      final chats = conversationsOver(store);
      final chatId = chats.conversations.single.id;
      var notified = 0;
      chats.addListener(() => notified++);

      kv.refuseWrites = 1;
      chats.setConversationMute(chatId, 'forever');
      expect(chats.conversations.single.muted, isTrue);
      final before = notified;
      await store.settled;
      await Future<void>.delayed(Duration.zero);

      expect(store.byUserId(2)!.settings.muted, isFalse);
      expect(chats.conversations.single.muted, isFalse);
      expect(notified, greaterThan(before));
    });

    test('a refused mute does not undo a later one that was kept', () async {
      SharedPreferences.setMockInitialValues({});
      final kv = _RefusingKv(await PrefsContentKv.open());
      final store = await _storeOver(kv, [
        contactRecord(2, 'bob', ContactState.friend, box: true),
      ]);
      final chats = conversationsOver(store);
      final chatId = chats.conversations.single.id;

      kv.refuseWrites = 1;
      chats
        ..setConversationMute(chatId, 'forever')
        // The second tap is queued behind the first write; only the first is
        // refused.
        ..setConversationMute(chatId, '1h');
      await store.settled;
      await Future<void>.delayed(Duration.zero);

      expect(chats.conversations.single.muted, isTrue);
      expect(chats.conversations.single.mutedUntil, isNotNull);
    });
  });

  // CONT-08: a chat deleted here stays out of the list while its hide write
  // is still queued; another chat's refresh in that window must not bring it
  // back as an empty row.
  group('ConversationsProvider delete vs a rebuild (CONT-08)', () {
    test('a refresh while the hide is still being written keeps the chat '
        'out', () async {
      SharedPreferences.setMockInitialValues({});
      final kv = _RefusingKv(await PrefsContentKv.open());
      final store = await _storeOver(kv, [
        contactRecord(2, 'bob', ContactState.friend, box: true),
        contactRecord(3, 'carol', ContactState.friend, box: true),
      ]);
      final chats = conversationsOver(store);
      final bob = store.byUserId(2)!.chatId!;
      final carol = store.byUserId(3)!.chatId!;
      expect(chats.conversations.map((c) => c.id), unorderedEquals([bob, carol]));

      kv.hold = Completer<void>();
      chats
        ..deleteConversation(bob)
        ..refreshChats();
      expect(chats.conversations.map((c) => c.id), [carol]);

      kv.hold!.complete();
      await store.settled;
      await Future<void>.delayed(Duration.zero);
      chats.refreshChats();
      expect(chats.conversations.map((c) => c.id), [carol]);
      expect(store.byUserId(2)!.settings.chatHidden, isTrue);
    });

    test('a hide the store refused brings the chat back', () async {
      SharedPreferences.setMockInitialValues({});
      final kv = _RefusingKv(await PrefsContentKv.open());
      final store = await _storeOver(kv, [
        contactRecord(2, 'bob', ContactState.friend, box: true),
      ]);
      final chats = conversationsOver(store);
      final bob = chats.conversations.single.id;

      kv.refuseWrites = 1;
      chats.deleteConversation(bob);
      expect(chats.conversations, isEmpty);
      await store.settled;
      await Future<void>.delayed(Duration.zero);

      expect(chats.conversations.map((c) => c.id), [bob]);
    });
  });
}
