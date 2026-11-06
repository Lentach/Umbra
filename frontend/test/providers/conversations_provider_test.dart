import 'dart:async';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/models/conversation_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/push_sw_channel_stub.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/chat_seed.dart';

class _RecordingPushSwChannel implements PushSwChannel {
  final List<Map<String, Object?>> messages = [];
  @override
  Future<bool> postMessage(Map<String, Object?> message) async {
    messages.add(message);
    return true;
  }
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
      expect(provider.errorMessage, isNull);
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
        expect(provider.errorMessage, isNull);
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
}
