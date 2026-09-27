import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/models/invitation_state.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/models/user_model.dart';

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

    test(
      'a search answer naming a friend shows only the strangers (decision 4)',
      () {
        final provider = FriendsProvider()
          ..onFriendsList([
            {'id': 2, 'username': 'bob'},
          ])
          ..onSearchUsersResult([
            {'id': 2, 'username': 'bob'},
            {'id': 4, 'username': 'dave'},
          ]);

        expect(provider.searchResults, [
          isA<UserModel>().having((u) => u.id, 'id', 4),
        ]);
      },
    );

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
}
