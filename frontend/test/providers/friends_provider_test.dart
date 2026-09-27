import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fireplace/models/friend_request_model.dart';
import 'package:fireplace/models/invitation_state.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/services/box/box_first_contact.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('FriendsProvider', () {
    test('onConnect(false) clears all state and blockedByUserIds', () {
      final provider = FriendsProvider();
      provider.onFriendsList([
        {'id': 1, 'username': 'alice'},
      ]);
      provider.onFriendRequestsList([
        {
          'id': 5,
          'sender': {'id': 2, 'username': 'bob'},
          'receiver': {'id': 1, 'username': 'alice'},
          'status': 'pending',
          'createdAt': '2026-01-01T00:00:00.000Z',
        },
      ]);
      provider.onPendingRequestsCount({'count': 1});
      provider.onBlockedList([
        {'id': 3, 'username': 'carol'},
      ]);
      provider.onYouWereBlocked({'userId': 42});
      provider.onSearchUsersResult([
        {'id': 4, 'username': 'dave'},
      ]);
      expect(provider.friends, isNotEmpty);
      expect(provider.blockedByUserIds, isNotEmpty);

      provider.onConnect(false);

      expect(provider.friends, isEmpty);
      expect(provider.friendRequests, isEmpty);
      expect(provider.pendingRequestsCount, 0);
      expect(provider.blockedUsers, isEmpty);
      expect(provider.blockedByUserIds, isEmpty);
      expect(provider.searchResults, isNull);
      expect(provider.consumePendingFriendAccepted(), isNull);
    });

    test(
      'sentRequestsList populates sent requests and account resets clear them',
      () {
        final provider = FriendsProvider();
        final sentRequest = [
          {
            'id': 6,
            'sender': {'id': 1, 'username': 'alice'},
            'receiver': {'id': 2, 'username': 'bob'},
            'status': 'pending',
            'createdAt': '2026-01-01T00:00:00.000Z',
          },
        ];

        provider.onSentRequestsList(sentRequest);

        expect(provider.sentRequests, hasLength(1));
        expect(provider.sentRequests.single.id, 6);
        expect(provider.sentRequests.single.receiver.username, 'bob');

        provider.onConnect(false);

        expect(provider.sentRequests, isEmpty);

        provider.onSentRequestsList(sentRequest);
        expect(provider.sentRequests, hasLength(1));

        provider.clearAll();

        expect(provider.sentRequests, isEmpty);
      },
    );

    test('onConnect(true) clears blockedByUserIds', () {
      final provider = FriendsProvider();

      // Use the proper API to add a blocked-by entry
      provider.onYouWereBlocked({'userId': 42});
      expect(provider.blockedByUserIds, contains(42));

      provider.onConnect(true);

      expect(provider.blockedByUserIds, isEmpty);
      expect(provider.searchResults, isNull);
      expect(provider.consumePendingFriendAccepted(), isNull);
    });

    test('onYouWereBlocked adds to blockedByUserIds and removes friend', () {
      final provider = FriendsProvider();
      provider.onConnect(false);

      final user = UserModel(id: 5, username: 'bob', tag: '0005');
      final friendJson = {
        'id': user.id,
        'username': user.username,
        'tag': user.tag,
      };

      provider.onFriendsList([friendJson]);
      expect(provider.friends.length, 1);

      provider.onYouWereBlocked({'userId': user.id});

      expect(provider.blockedByUserIds.contains(user.id), isTrue);
      expect(provider.friends, isEmpty);
    });

    test('onFriendsList ignores empty snapshot when local friends exist', () {
      final provider = FriendsProvider();
      final alice = UserModel(id: 1, username: 'alice', tag: '0001');

      provider.onFriendsList([
        {'id': alice.id, 'username': alice.username, 'tag': alice.tag},
      ]);
      expect(provider.friends.length, 1);

      provider.onFriendsList([]);

      expect(provider.friends.length, 1);
      expect(provider.friends.first.id, alice.id);
    });

    test('onBlockedList removes blocked friends from friends list', () {
      final provider = FriendsProvider();

      final alice = UserModel(id: 1, username: 'alice', tag: '0001');
      final bob = UserModel(id: 2, username: 'bob', tag: '0002');

      provider.onFriendsList([
        {'id': alice.id, 'username': alice.username, 'tag': alice.tag},
        {'id': bob.id, 'username': bob.username, 'tag': bob.tag},
      ]);
      expect(provider.friends.length, 2);

      provider.onBlockedList([
        {'id': bob.id, 'username': bob.username, 'tag': bob.tag},
      ]);

      expect(provider.blockedUsers.length, 1);
      expect(provider.blockedUsers.first.id, bob.id);
      expect(provider.friends.length, 1);
      expect(provider.friends.first.id, alice.id);
    });

    test('onUnfriended purges only the named peer', () {
      final provider = FriendsProvider();
      provider.setCurrentUserId(1);
      provider.onFriendsList([
        {'id': 2, 'username': 'bob', 'tag': '0002'},
        {'id': 3, 'username': 'carol', 'tag': '0003'},
      ]);
      final purged = <int>[];
      provider.onRemoveConversationsForUser = purged.add;

      provider.onUnfriended({'userId': 2});

      expect(purged, [2]);
      expect(provider.friends.map((f) => f.id), [3]);
    });

    test('onUnfriended ignores our OWN id — it would purge every chat', () {
      // `removeConversationsForUser` matches `userOne.id == id || userTwo.id == id`
      // and we are a participant in EVERY one of our conversations, so acting on
      // our own id destroys the decrypted plaintext of the whole local history —
      // irreversibly, because the ratchet consumed the message keys. Production
      // echoed our own id back to us until 2026-08-05, so this stays pinned.
      final provider = FriendsProvider();
      provider.setCurrentUserId(1);
      provider.onFriendsList([
        {'id': 2, 'username': 'bob', 'tag': '0002'},
      ]);
      final purged = <int>[];
      provider.onRemoveConversationsForUser = purged.add;

      provider.onUnfriended({'userId': 1});

      expect(purged, isEmpty);
      expect(provider.friends.map((f) => f.id), [2]);
    });
  });

  group('FriendsProvider invitation round trips', () {
    Map<String, dynamic> request({int id = 10}) => {
      'id': id,
      'sender': {'id': 2, 'username': 'bob'},
      'receiver': {'id': 1, 'username': 'alice'},
      'status': 'pending',
      'createdAt': '2026-01-01T00:00:00.000Z',
    };

    test('a re-emitted newFriendRequest does not duplicate the row', () {
      final provider = FriendsProvider();
      provider.onNewFriendRequest(request());
      provider.onNewFriendRequest(request());

      expect(provider.friendRequests, hasLength(1));
      provider.dispose();
    });

    test('a dropped accept ack releases the row and reports a failure', () {
      fakeAsync((async) {
        final provider = FriendsProvider();
        provider.onFriendRequestsList([request()]);
        provider.acceptFriendRequest(10);

        expect(provider.invitationActionFor(10), InvitationActionStatus.inFlight);

        // No ack ever arrives while the socket stays connected: nothing else in
        // the app would ever clear this, so the row stayed spinning forever.
        async.elapse(const Duration(seconds: 21));

        expect(provider.invitationActionFor(10), isNull);
        final failure = provider.consumeInvitationFailure();
        expect(failure, isNotNull);
        expect(failure!.action, InvitationAction.accept);
        expect(failure.requestId, 10);
        provider.dispose();
      });
    });

    test('an ack inside the window cancels the timeout', () {
      fakeAsync((async) {
        final provider = FriendsProvider();
        final payload = request();
        provider.onFriendRequestsList([payload]);
        provider.rejectFriendRequest(10);
        provider.onFriendRequestRejected(payload);

        async.elapse(const Duration(seconds: 21));

        expect(provider.invitationActionFor(10), isNull);
        expect(provider.consumeInvitationFailure(), isNull);
        provider.dispose();
      });
    });
  });

  group('FriendsProvider box first contact', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late ContactStore store;
    late List<(String, dynamic)> emitted;

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
      emitted = [];
    });

    FriendsProvider provider() => FriendsProvider()
      ..contactStore = store
      ..setCurrentUserId(1)
      ..setEmitCallback((event, data) => emitted.add((event, data)));

    Iterable<String> events() => emitted.map((e) => e.$1);

    ContactRecord record(
      int id,
      ContactState state, {
      bool box = true,
      int? requestId,
    }) => ContactRecord(
      userId: id,
      username: 'u$id',
      tag: id.toString().padLeft(4, '0'),
      state: state,
      legacy: ContactLegacy(requestId: requestId),
      boxOrigin: box ? ContactBoxOrigin(at: DateTime.utc(2026, 9, id)) : null,
    );

    Future<void> seed(List<ContactRecord> records) async {
      for (final r in records) {
        unawaited(store.update(r.userId, (_) => r));
      }
      await store.settled;
    }

    Map<String, dynamic> user(int id) => {
      'id': id,
      'username': 'u$id',
      'tag': id.toString().padLeft(4, '0'),
    };

    Map<String, dynamic> serverRequest(int id, int from) => {
      'id': id,
      'sender': user(from),
      'receiver': user(1),
      'status': 'pending',
      'createdAt': '2026-09-01T00:00:00.000Z',
    };

    group('server lists (E15g)', () {
      test('a friendsList omitting a box friend leaves its record', () async {
        await seed([
          record(7, ContactState.friend),
          record(3, ContactState.friend, box: false),
        ]);

        provider().onFriendsList([user(2)]);
        await store.settled;

        expect(
          store.byUserId(7),
          isA<ContactRecord>()
              .having((r) => r.state, 'state', ContactState.friend)
              .having((r) => r.boxOrigin, 'boxOrigin', isNotNull),
        );
        // A server friend the list omits is still swept.
        expect(store.byUserId(3), isNull);
      });

      test(
        'a friendRequestsList omitting a box request leaves its record',
        () async {
          await seed([
            record(8, ContactState.pendingIn),
            record(11, ContactState.pendingIn, box: false, requestId: 70),
          ]);

          provider().onFriendRequestsList([serverRequest(71, 4)]);
          await store.settled;

          expect(store.byUserId(8)?.state, ContactState.pendingIn);
          expect(store.byUserId(11), isNull);
        },
      );
    });

    group('unions', () {
      test('box records join the server lists, requests as -userId', () async {
        await seed([
          record(7, ContactState.friend),
          record(8, ContactState.pendingIn),
          record(9, ContactState.pendingOut),
          record(10, ContactState.blocked),
          // Box-made but carrying a server request id: the server lists it.
          record(12, ContactState.pendingIn, requestId: 80),
        ]);
        final friends = provider()
          ..onFriendsList([user(2), user(7)])
          ..onFriendRequestsList([serverRequest(70, 4)])
          ..onSentRequestsList([])
          ..onPendingRequestsCount({'count': 1});

        expect(friends.friends.map((u) => u.id), [2, 7]);
        expect(friends.isFriend(7), isTrue);
        expect(friends.friendRequests.map((r) => r.id), [70, -8]);
        expect(
          friends.friendRequests.last,
          isA<FriendRequestModel>()
              .having((r) => r.sender.id, 'sender', 8)
              .having((r) => r.receiver.id, 'receiver', 1),
        );
        expect(friends.sentRequests.single.id, -9);
        expect(friends.sentRequests.single.receiver.id, 9);
        expect(friends.blockedUsers.map((u) => u.id), [10]);
        expect(friends.pendingRequestsCount, 2);
      });

      test('a box record gone from the store leaves the lists', () async {
        await seed([record(7, ContactState.friend)]);
        final friends = provider()..onFriendsList([user(2)]);
        expect(friends.isFriend(7), isTrue);

        await store.remove(7);

        expect(friends.friends.map((u) => u.id), [2]);
        expect(friends.isFriend(7), isFalse);
      });
    });

    group('box request actions', () {
      for (final (result, reason) in [
        (FirstContactAccept.accepted, null),
        (FirstContactAccept.unverified, 'unverified'),
        (FirstContactAccept.failed, 'accept_failed'),
      ]) {
        test('accepting -userId answers ${result.name} with no server event',
            () async {
          final answer = Completer<FirstContactAccept>();
          final asked = <int>[];
          final friends = provider()
            ..boxAcceptRequest = (userId) {
              asked.add(userId);
              return answer.future;
            }
            ..acceptFriendRequest(-8);

          expect(friends.invitationActionFor(-8), InvitationActionStatus.inFlight);
          answer.complete(result);
          await pumpEventQueue();

          expect(asked, [8]);
          expect(events(), isEmpty);
          expect(friends.invitationActionFor(-8), isNull);
          expect(
            friends.consumeInvitationFailure(),
            reason == null
                ? isNull
                : isA<InvitationFailure>()
                      .having((f) => f.action, 'action', InvitationAction.accept)
                      .having((f) => f.requestId, 'requestId', -8)
                      .having((f) => f.reason, 'reason', reason),
          );
        });
      }

      test('an unwired box accept fails without a server event', () async {
        final friends = provider()..acceptFriendRequest(-8);
        await pumpEventQueue();

        expect(events(), isEmpty);
        expect(friends.invitationActionFor(-8), isNull);
        expect(friends.consumeInvitationFailure()?.reason, 'accept_failed');
      });

      test('declining -userId goes to the box, never the server', () async {
        final asked = <int>[];
        final friends = provider()
          ..boxDeclineRequest = ((userId) async => asked.add(userId))
          ..rejectFriendRequest(-8);
        await pumpEventQueue();

        expect(asked, [8]);
        expect(events(), isEmpty);
        expect(friends.invitationActionFor(-8), isNull);
        expect(friends.consumeInvitationFailure(), isNull);
      });
    });

    group('sendFriendRequest', () {
      final bob = {...user(2), 'devices': const ['d1']};

      FriendsProvider searched(FirstContactSend result, List<Object> seen) =>
          provider()
            ..boxSendRequest = (entry) async {
              seen.add(entry);
              return result;
            }
            ..searchUsers('u2#0002')
            ..onSearchUsersResult([bob]);

      Iterable<(String, dynamic)> sends() =>
          emitted.where((e) => e.$1 == 'sendFriendRequest');

      test('sent over the box: the raw entry goes, no server event', () async {
        final seen = <Object>[];
        final friends = searched(FirstContactSend.sent, seen)
          ..sendFriendRequest(2);
        expect(friends.sendActionFor(2), InvitationActionStatus.inFlight);
        await pumpEventQueue();

        expect(seen, [containsPair('devices', ['d1'])]);
        expect(sends(), isEmpty);
        expect(friends.sendActionFor(2), isNull);
        expect(friends.consumeInvitationFailure(), isNull);
      });

      test('oldPath sends the server event', () async {
        final friends = searched(FirstContactSend.oldPath, [])
          ..sendFriendRequest(2);
        await pumpEventQueue();

        expect(sends().single.$2, {'recipientId': 2});
        expect(friends.sendActionFor(2), InvitationActionStatus.inFlight);
      });

      test('failed releases the row and reports send_failed', () async {
        final friends = searched(FirstContactSend.failed, [])
          ..sendFriendRequest(2);
        await pumpEventQueue();

        expect(sends(), isEmpty);
        expect(friends.sendActionFor(2), isNull);
        expect(
          friends.consumeInvitationFailure(),
          isA<InvitationFailure>()
              .having((f) => f.action, 'action', InvitationAction.send)
              .having((f) => f.recipientId, 'recipientId', 2)
              .having((f) => f.reason, 'reason', 'send_failed'),
        );
      });

      test('a user with no search entry takes the server path', () async {
        final seen = <Object>[];
        searched(FirstContactSend.sent, seen).sendFriendRequest(5);
        await pumpEventQueue();

        expect(seen, isEmpty);
        expect(sends().single.$2, {'recipientId': 5});
      });
    });

    group('lookupHandle', () {
      Map<String, dynamic> hit(int id) => user(id);

      test('gets its answer; the UI search state is untouched', () async {
        final friends = provider();
        var notified = 0;
        friends.addListener(() => notified++);

        final lookup = friends.lookupHandle('U2#0002');
        friends.onSearchUsersResult([hit(2)]);

        expect(await lookup, [hit(2)]);
        final (event, payload) = emitted.single;
        expect(event, 'searchUsers');
        expect(payload, {'handle': 'U2#0002'});
        expect(friends.searchResults, isNull);
        expect(friends.searchEntryFor(2), isNull);
        expect(notified, 0);
      });

      test('an answer matching a later search means earlier ones were lost',
          () async {
        final friends = provider();
        final lost = friends.lookupHandle('u3#0003');
        final found = friends.lookupHandle('u2#0002');

        friends.onSearchUsersResult([hit(2)]);

        expect(await lost, isNull);
        expect(await found, [hit(2)]);
      });

      test('an empty answer goes to the oldest search', () async {
        final friends = provider();
        final lookup = friends.lookupHandle('u3#0003');
        friends
          ..searchUsers('u4#0004')
          ..onSearchUsersResult([]);

        expect(await lookup, isEmpty);
        expect(friends.searchResults, isNull);

        friends.onSearchUsersResult([hit(4)]);
        expect(friends.searchResults?.single.id, 4);
      });

      test('a UI search answered between lookups shows only its own', () async {
        final friends = provider()..searchUsers('u4#0004');
        final lookup = friends.lookupHandle('u2#0002');

        friends.onSearchUsersResult([hit(4)]);
        expect(friends.searchResults?.single.id, 4);
        expect(friends.searchEntryFor(4), hit(4));

        friends.onSearchUsersResult([hit(2)]);
        expect(await lookup, [hit(2)]);
        expect(friends.searchResults?.single.id, 4);
      });

      test('a timed-out lookup leaves the queue', () {
        fakeAsync((async) {
          final friends = FriendsProvider()
            ..setEmitCallback((event, data) => emitted.add((event, data)));
          List<Object?>? answer = const [];
          unawaited(
            friends
                .lookupHandle('u3#0003', timeout: const Duration(seconds: 1))
                .then((value) => answer = value),
          );
          friends.searchUsers('u4#0004');

          async.elapse(const Duration(seconds: 1));
          expect(answer, isNull);

          // The empty answer is the UI search's now: "not found".
          friends.onSearchUsersResult([]);
          expect(friends.searchResults, isEmpty);
        });
      });

      test('a new socket completes a pending lookup with null', () async {
        final friends = provider();
        final lookup = friends.lookupHandle('u2#0002');

        friends.onConnect(true);

        expect(await lookup, isNull);
      });
    });

    group('box friendship', () {
      test('made outgoing: local chat outcome and the accepted toast', () async {
        await seed([record(7, ContactState.friend)]);
        final friends = provider()..onBoxFriendshipMade(7, outgoing: true);

        expect(
          friends.acceptedOutcomeForPeer(7),
          isA<InvitationOutcome>()
              .having(
                (o) => o.direction,
                'direction',
                InvitationDirection.outgoing,
              )
              .having(
                (o) => o.conversationId,
                'conversationId',
                localConversationIdFor(7),
              )
              .having((o) => o.chatReady, 'chatReady', isTrue),
        );
        expect(friends.consumePendingFriendAccepted()?.peerUserId, 7);
      });

      test('unfriending a box friend ends it on the box only', () async {
        await seed([record(7, ContactState.friend)]);
        final ended = <(int, bool)>[];
        final purged = <int>[];
        final friends = provider()
          ..boxEndFriendship = ((userId, {required block}) async =>
              ended.add((userId, block)))
          ..onRemoveConversationsForUser = purged.add;
        expect(await friends.unfriend(7), isTrue);

        expect(ended, [(7, false)]);
        expect(purged, [7]);
        expect(events(), isEmpty);
      });

      test(
        'an unfriend over the box our other devices could not be told of '
        'reports the failure and keeps the chat',
        () async {
          await seed([record(7, ContactState.friend)]);
          final purged = <int>[];
          final friends = provider()
            ..boxEndFriendship = ((userId, {required block}) async =>
                throw StateError('a sibling was not told'))
            ..onRemoveConversationsForUser = purged.add;

          expect(await friends.unfriend(7), isFalse);
          expect(await friends.blockUser(7), isFalse);
          expect(purged, isEmpty);
          expect(events(), isEmpty);
        },
      );

      test('unblocking a box-blocked contact deletes it locally', () async {
        await seed([record(10, ContactState.blocked)]);
        final friends = provider()..unblockUser(10);
        await store.settled;

        expect(store.byUserId(10), isNull);
        expect(friends.blockedUsers, isEmpty);
        expect(events(), isEmpty);
      });

      test(
        'unblocking a box-blocked contact that still holds an undeleted queue '
        'hides it and keeps the queue for the next expiry pass',
        () async {
          const queue = ContactQueue(
            rid: 'r',
            sid: 's',
            nid: 'n',
            authPriv: 'a',
            sealPriv: 'sp',
            sealPub: 'p',
          );
          await seed([
            record(10, ContactState.blocked).copyWith(queues: const [queue]),
          ]);
          final friends = provider()..unblockUser(10);
          await store.settled;
          await pumpEventQueue();

          final kept = store.byUserId(10);
          expect(kept?.state, ContactState.former);
          expect(kept?.queues.single.rid, 'r');
          expect(friends.blockedUsers, isEmpty);
          expect(events(), isEmpty);
        },
      );
    });
  });
}
