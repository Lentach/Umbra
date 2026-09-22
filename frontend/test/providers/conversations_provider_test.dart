import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/models/conversation_model.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/services/push_sw_channel_stub.dart';

class _RecordingPushSwChannel implements PushSwChannel {
  final List<Map<String, Object?>> messages = [];
  @override
  Future<bool> postMessage(Map<String, Object?> message) async {
    messages.add(message);
    return true;
  }
}

void main() {
  group('ConversationsProvider', () {
    ConversationsProvider buildProviderWithSampleData() {
      final provider = ConversationsProvider();
      final userA = UserModel(id: 1, username: 'alice', tag: '0001');
      final userB = UserModel(id: 2, username: 'bob', tag: '0002');
      final conv1 = ConversationModel(
        id: 10,
        userOne: userA,
        userTwo: userB,
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final conv2 = ConversationModel(
        id: 11,
        userOne: userB,
        userTwo: userA,
        createdAt: DateTime.utc(2026, 1, 2),
      );

      provider.onConnect(false);
      provider
        ..openConversation(conv1.id)
        ..updateLastMessage(
          conv1.id,
          MessageModel(
            id: 100,
            content: 'Hello',
            senderId: userA.id,
            senderUsername: userA.username,
            conversationId: conv1.id,
            createdAt: DateTime.utc(2026, 1, 1, 12),
          ),
        )
        ..updateUnreadCount(conv1.id, 1);

      // Inject conversations directly into internal list for testing
      provider
        ..clearAll()
        ..onConversationsList([
          {
            'id': conv1.id,
            'userOne': {
              'id': userA.id,
              'username': userA.username,
              'tag': userA.tag,
            },
            'userTwo': {
              'id': userB.id,
              'username': userB.username,
              'tag': userB.tag,
            },
            'createdAt': conv1.createdAt.toIso8601String(),
            'unreadCount': 1,
          },
          {
            'id': conv2.id,
            'userOne': {
              'id': userB.id,
              'username': userB.username,
              'tag': userB.tag,
            },
            'userTwo': {
              'id': userA.id,
              'username': userA.username,
              'tag': userA.tag,
            },
            'createdAt': conv2.createdAt.toIso8601String(),
            'unreadCount': 0,
          },
        ]);

      return provider;
    }

    test('onConnect(false) clears all state', () {
      final provider = buildProviderWithSampleData();

      provider.onConnect(false);

      expect(provider.conversations, isEmpty);
      expect(provider.activeConversationId, isNull);
      expect(provider.lastMessages, isEmpty);
      expect(provider.unreadCounts, isEmpty);
      expect(provider.pendingOpenConversationId, isNull);
      expect(provider.pendingNotificationConversationId, isNull);
      expect(provider.activeConversationDeletedByOther, isFalse);
      expect(provider.errorMessage, isNull);
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
        expect(provider.activeConversationDeletedByOther, isFalse);
        expect(provider.errorMessage, isNull);
      },
    );

    test(
      'removeConversationsForUser removes conversations and clears active if needed',
      () {
        final provider = ConversationsProvider();
        final userA = UserModel(id: 1, username: 'alice', tag: '0001');
        final userB = UserModel(id: 2, username: 'bob', tag: '0002');

        final conv1 = ConversationModel(
          id: 10,
          userOne: userA,
          userTwo: userB,
          createdAt: DateTime.utc(2026, 1, 1),
        );
        final conv2 = ConversationModel(
          id: 11,
          userOne: userA,
          userTwo: userA,
          createdAt: DateTime.utc(2026, 1, 2),
        );

        provider.onConversationsList([
          {
            'id': conv1.id,
            'userOne': {
              'id': userA.id,
              'username': userA.username,
              'tag': userA.tag,
            },
            'userTwo': {
              'id': userB.id,
              'username': userB.username,
              'tag': userB.tag,
            },
            'createdAt': conv1.createdAt.toIso8601String(),
            'unreadCount': 0,
          },
          {
            'id': conv2.id,
            'userOne': {
              'id': userA.id,
              'username': userA.username,
              'tag': userA.tag,
            },
            'userTwo': {
              'id': userA.id,
              'username': userA.username,
              'tag': userA.tag,
            },
            'createdAt': conv2.createdAt.toIso8601String(),
            'unreadCount': 0,
          },
        ]);

        provider.openConversation(conv1.id);
        provider.removeConversationsForUser(userB.id);

        expect(provider.conversations.length, 1);
        expect(provider.conversations.first.id, conv2.id);
        expect(provider.activeConversationId, isNull);
      },
    );

    test(
      'deleteConversation removes conversation optimistically and emits',
      () {
        final provider = buildProviderWithSampleData();
        final emitted = <Map<String, dynamic>>[];
        provider.setEmitCallback((event, data) {
          if (event == 'deleteConversationOnly') {
            emitted.add(Map<String, dynamic>.from(data as Map));
          }
        });

        provider.deleteConversation(10);

        expect(provider.conversations.length, 1);
        expect(provider.conversations.first.id, 11);
        expect(provider.lastMessages.containsKey(10), isFalse);
        expect(emitted.length, 1);
        expect(emitted.first['conversationId'], 10);
      },
    );

    test(
      'onConversationsList ignores empty snapshot when local list is populated',
      () {
        final provider = buildProviderWithSampleData();
        expect(provider.conversations, isNotEmpty);

        provider.onConversationsList([]);

        expect(provider.conversations, isNotEmpty);
        expect(provider.conversations.length, 2);
      },
    );

    Map<String, dynamic> convJson(
      int id,
      UserModel a,
      UserModel b,
      int unread,
    ) {
      return {
        'id': id,
        'userOne': {'id': a.id, 'username': a.username, 'tag': a.tag},
        'userTwo': {'id': b.id, 'username': b.username, 'tag': b.tag},
        'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
        'unreadCount': unread,
      };
    }

    test(
      'onConversationsList trusts server unread so a read clears a stale-high count',
      () {
        final provider = ConversationsProvider();
        final userA = UserModel(id: 1, username: 'alice', tag: '0001');
        final userB = UserModel(id: 2, username: 'bob', tag: '0002');
        provider.onConnect(false);
        provider.onConversationsList([convJson(10, userA, userB, 3)]);
        expect(provider.getUnreadCount(10), 3);
        // Read on the server (unread -> 0) must clear the badge, not stick at 3
        // (the old max() merge left it stuck — the reported bug).
        provider.onConversationsList([convJson(10, userA, userB, 0)]);
        expect(provider.getUnreadCount(10), 0);
      },
    );

    test('onConversationsList keeps the active conversation badge at 0', () {
      final provider = ConversationsProvider();
      final userA = UserModel(id: 1, username: 'alice', tag: '0001');
      final userB = UserModel(id: 2, username: 'bob', tag: '0002');
      provider.onConnect(false);
      provider.setActiveConversation(10);
      // Even a snapshot reporting unread for the open chat shows 0 (being read).
      provider.onConversationsList([convJson(10, userA, userB, 3)]);
      expect(provider.getUnreadCount(10), 0);
    });

    test(
      'onConversationsList surfaces unread received after reading (no missed mail)',
      () {
        final provider = ConversationsProvider();
        final userA = UserModel(id: 1, username: 'alice', tag: '0001');
        final userB = UserModel(id: 2, username: 'bob', tag: '0002');
        provider.onConnect(false);
        // Opened & read, then left the conversation.
        provider
          ..openConversation(10)
          ..closeConversation();
        expect(provider.getUnreadCount(10), 0);
        // A message arrives while backgrounded (surfaced only via a snapshot, no
        // live newMessage event): the badge MUST show it, never be held at 0.
        provider.onConversationsList([convJson(10, userA, userB, 1)]);
        expect(provider.getUnreadCount(10), 1);
      },
    );

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

    test(
      'onDisappearingTimerUpdated updates conversationDisappearingTimer',
      () {
        final provider = buildProviderWithSampleData();
        provider.openConversation(10);

        provider.onDisappearingTimerUpdated({
          'conversationId': 10,
          'seconds': 300,
        });

        expect(provider.conversationDisappearingTimer, 300);
      },
    );

    test(
      'onDisappearingTimerUpdated turning OFF (seconds null) clears the timer',
      () {
        final provider = buildProviderWithSampleData();
        provider.openConversation(10);

        // Peer turns it ON, then OFF. Before the copyWith clear-flag fix the OFF
        // echo (seconds: null) was swallowed by the null-merge idiom and the old
        // timer persisted locally — the non-initiating device kept stamping TTLs.
        provider.onDisappearingTimerUpdated({
          'conversationId': 10,
          'seconds': 300,
        });
        expect(provider.conversationDisappearingTimer, 300);

        provider.onDisappearingTimerUpdated({
          'conversationId': 10,
          'seconds': null,
        });
        expect(provider.conversationDisappearingTimer, isNull);
      },
    );

    group('pushClientState (server push suppression)', () {
      test(
        'setClientVisible false emits pushClientState with clientVisible false',
        () {
          final provider = ConversationsProvider();
          final pushStates = <Map<String, dynamic>>[];
          provider.setEmitCallback((event, data) {
            if (event == 'pushClientState') {
              pushStates.add(Map<String, dynamic>.from(data as Map));
            }
          });
          provider.onConnect(false);
          provider.openConversation(42);
          pushStates.clear();

          provider.setClientVisible(false);

          expect(
            pushStates.single,
            {'clientVisible': false},
            reason: 'the server learns visibility, never which chat is open',
          );
        },
      );

      test('setClientVisible false is idempotent (no duplicate emits)', () {
        final provider = ConversationsProvider();
        provider.onConnect(false);
        provider.openConversation(1);
        var pushAfterSetup = 0;
        provider.setEmitCallback((event, _) {
          if (event == 'pushClientState') pushAfterSetup++;
        });

        provider.setClientVisible(false);
        expect(pushAfterSetup, 1);
        provider.setClientVisible(false);
        expect(pushAfterSetup, 1);
      });

      test(
        'opening or closing a chat tells the server nothing (PR0.2)',
        () {
          final provider = ConversationsProvider();
          final pushStates = <Map<String, dynamic>>[];
          provider.setEmitCallback((event, data) {
            if (event == 'pushClientState') {
              pushStates.add(Map<String, dynamic>.from(data as Map));
            }
          });
          provider.onConnect(false);
          pushStates.clear();

          provider
            ..openConversation(99)
            ..closeConversation();

          expect(
            pushStates,
            isEmpty,
            reason: "which chat is open is not the server's business, and "
                'visibility did not change',
          );
        },
      );

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
    });

    // Spec §12 (xxxvii). A throttled `pinMessage` is refused BEFORE the server
    // handler runs, so the server cannot say what was pinned before — only this
    // device knows what its optimistic pin overwrote.
    group('a refused pin restores what the optimistic pin overwrote', () {
      MessageModel preview(int id) => MessageModel(
        id: id,
        content: 'msg $id',
        senderId: 1,
        senderUsername: 'alice',
        conversationId: 10,
        createdAt: DateTime.utc(2026, 1, 1, 12),
      );

      ConversationsProvider seeded() {
        final provider = ConversationsProvider();
        provider.onConnect(false);
        provider.onConversationsList([
          {
            'id': 10,
            'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
            'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
            'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          },
        ]);
        return provider;
      }

      ConversationModel only(ConversationsProvider p) =>
          p.conversations.firstWhere((c) => c.id == 10);

      test('restores the PREVIOUS pin, not "unpinned"', () {
        final provider = seeded();
        // A different message was already pinned. This is the whole point of
        // the test: reverting to null would look correct on a conversation
        // that started unpinned, and would silently destroy this pin.
        provider.onMessagePinned({
          'conversationId': 10,
          'pinnedMessageId': 41,
          'pinnedMessage': {
            'id': 41,
            'content': 'msg 41',
            'senderId': 1,
            'conversationId': 10,
            'createdAt': DateTime.utc(2026, 1, 1, 12).toIso8601String(),
          },
        });

        provider.setPinnedPreviewOptimistic(10, 77, preview(77));
        expect(only(provider).pinnedMessageId, 77);

        provider.onPinMessageFailed({
          'conversationId': 10,
          'reason': 'rate_limited',
        });

        expect(only(provider).pinnedMessageId, 41);
        expect(only(provider).pinnedMessagePreview?.id, 41);
      });

      test('restores UNPINNED when nothing was pinned before', () {
        final provider = seeded();
        provider.setPinnedPreviewOptimistic(10, 77, preview(77));
        expect(only(provider).pinnedMessageId, 77);

        provider.onPinMessageFailed({'conversationId': 10});

        expect(only(provider).pinnedMessageId, isNull);
        expect(only(provider).pinnedMessagePreview, isNull);
      });

      test('a settled pin is not undone by a LATER unrelated refusal', () {
        final provider = seeded();
        provider.setPinnedPreviewOptimistic(10, 77, preview(77));
        // The server accepted it, so the snapshot has nothing left to undo.
        provider.onMessagePinned({'conversationId': 10, 'pinnedMessageId': 77});

        provider.onPinMessageFailed({'conversationId': 10});

        expect(
          only(provider).pinnedMessageId,
          77,
          reason:
              'a stale snapshot must not survive the authoritative event that '
              'settled it, or an unrelated later refusal reverts a real pin',
        );
      });

      test('two optimistic pins in a row still revert to the SERVER state', () {
        final provider = seeded();
        provider.setPinnedPreviewOptimistic(10, 77, preview(77));
        // Second tap before the first settles: the snapshot must still hold
        // the server-known state (unpinned), never the first optimistic pin.
        provider.setPinnedPreviewOptimistic(10, 88, preview(88));

        provider.onPinMessageFailed({'conversationId': 10});

        expect(only(provider).pinnedMessageId, isNull);
      });

      test('an authoritative refresh supersedes a stranded snapshot', () {
        final provider = seeded();
        provider.setPinnedPreviewOptimistic(10, 77, preview(77));
        // The settling event never arrives — the socket dropped between the
        // server committing and emitting, or the pin was rejected on the bare
        // `error` event that no pin code listens to. The snapshot is stranded.
        provider.onConversationsList([
          {
            'id': 10,
            'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
            'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
            'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
            'pinnedMessageId': 55,
          },
        ]);
        expect(only(provider).pinnedMessageId, 55);

        // A LATER refusal must not rewind past the refresh.
        provider.onPinMessageFailed({'conversationId': 10});

        expect(
          only(provider).pinnedMessageId,
          55,
          reason:
              'the server list is authoritative over any optimistic pin still '
              'waiting for an answer, so its snapshot is superseded',
        );
      });
    });

    /// Same class as the refused pin above, and the reason it was owed: the
    /// throttle guard refuses `setDisappearingTimer` BEFORE the handler runs,
    /// so the refusal cannot carry the timer it displaced. Until this landed the
    /// refused device kept showing a timer the server and the peer never had —
    /// a user believing messages will vanish when they will not.
    group('a refused disappearing timer restores what it overwrote', () {
      ConversationsProvider seeded({int? timer}) {
        final provider = ConversationsProvider();
        provider.onConnect(false);
        provider.onConversationsList([
          {
            'id': 10,
            'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
            'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
            'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
            'disappearingTimer': ?timer,
          },
        ]);
        return provider;
      }

      ConversationModel only(ConversationsProvider p) =>
          p.conversations.firstWhere((c) => c.id == 10);

      test('restores the PREVIOUS timer, not "off"', () {
        final provider = seeded(timer: 3600);
        provider.setDisappearingTimer(10, 60);
        expect(only(provider).disappearingTimer, 60);

        provider.onDisappearingTimerFailed({
          'conversationId': 10,
          'reason': 'rate_limited',
        });

        expect(
          only(provider).disappearingTimer,
          3600,
          reason:
              'reverting to null would look right on a conversation that '
              'started with no timer, and silently disable this one',
        );
      });

      test('restores OFF when there was no timer before', () {
        final provider = seeded();
        provider.setDisappearingTimer(10, 60);
        expect(only(provider).disappearingTimer, 60);

        provider.onDisappearingTimerFailed({'conversationId': 10});

        expect(only(provider).disappearingTimer, isNull);
      });

      test('a settled timer is not undone by a LATER unrelated refusal', () {
        final provider = seeded(timer: 3600);
        provider.setDisappearingTimer(10, 60);
        provider.onDisappearingTimerUpdated({
          'conversationId': 10,
          'seconds': 60,
        });

        provider.onDisappearingTimerFailed({'conversationId': 10});

        expect(
          only(provider).disappearingTimer,
          60,
          reason: 'the server accepted it; there is nothing left to undo',
        );
      });

      test('an authoritative refresh supersedes a stranded snapshot', () {
        final provider = seeded(timer: 3600);
        provider.setDisappearingTimer(10, 60);
        // The settling event never arrives and the snapshot is stranded.
        provider.onConversationsList([
          {
            'id': 10,
            'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
            'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
            'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
            'disappearingTimer': 900,
          },
        ]);

        provider.onDisappearingTimerFailed({'conversationId': 10});

        expect(
          only(provider).disappearingTimer,
          900,
          reason: 'the server list is authoritative over a pending optimism',
        );
      });
    });

    group('mute survives unrelated conversation mutations', () {
      ConversationsProvider mutedProvider() {
        final provider = ConversationsProvider();
        provider.onConnect(false);
        provider.onConversationsList([
          {
            'id': 10,
            'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
            'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
            'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
            'muted': true,
            'mutedUntil': DateTime.utc(2026, 6, 1).toIso8601String(),
          },
        ]);
        return provider;
      }

      ConversationModel only(ConversationsProvider p) =>
          p.conversations.firstWhere((c) => c.id == 10);

      test('onMessagePinned keeps muted and mutedUntil', () {
        final provider = mutedProvider();
        provider.onMessagePinned({'conversationId': 10, 'pinnedMessageId': 77});

        expect(only(provider).pinnedMessageId, 77);
        expect(only(provider).muted, isTrue);
        expect(only(provider).mutedUntil, DateTime.utc(2026, 6, 1));
      });

      test('onMessageUnpinned clears the pin and keeps mute', () {
        final provider = mutedProvider();
        provider.onMessagePinned({'conversationId': 10, 'pinnedMessageId': 77});
        provider.onMessageUnpinned({'conversationId': 10});

        expect(only(provider).pinnedMessageId, isNull);
        expect(only(provider).pinnedMessagePreview, isNull);
        expect(only(provider).muted, isTrue);
      });

      test('setDisappearingTimer keeps mute and can clear the timer', () {
        final provider = mutedProvider();
        provider.setDisappearingTimer(10, 3600);
        expect(only(provider).disappearingTimer, 3600);
        expect(only(provider).muted, isTrue);

        provider.setDisappearingTimer(10, null);
        expect(only(provider).disappearingTimer, isNull);
        expect(only(provider).muted, isTrue);
      });

      test('onConversationMuteUpdated can clear mutedUntil', () {
        final provider = mutedProvider();
        provider.onConversationMuteUpdated({
          'conversationId': 10,
          'muted': false,
          'mutedUntil': null,
        });

        expect(only(provider).muted, isFalse);
        expect(only(provider).mutedUntil, isNull);
      });
    });
  });
}
