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
    test('onConnect(false) clears the search and the accepted toast', () {
      final provider = FriendsProvider();
      provider.onSearchUsersResult([
        {'id': 4, 'username': 'dave'},
      ]);
      expect(provider.searchResults, isNotEmpty);

      provider.onConnect(false);

      expect(provider.friends, isEmpty);
      expect(provider.friendRequests, isEmpty);
      expect(provider.pendingRequestsCount, 0);
      expect(provider.blockedUsers, isEmpty);
      expect(provider.searchResults, isNull);
      expect(provider.consumePendingFriendAccepted(), isNull);
    });

    test('with no contact store every list is empty', () {
      final provider = FriendsProvider()..setCurrentUserId(1);

      expect(provider.friends, isEmpty);
      expect(provider.blockedUsers, isEmpty);
      expect(provider.friendRequests, isEmpty);
      expect(provider.sentRequests, isEmpty);
      expect(provider.pendingRequestsCount, 0);
      expect(provider.isFriend(2), isFalse);
    });

    test('onBoxFriendshipEnded purges only the named peer', () {
      final provider = FriendsProvider()..setCurrentUserId(1);
      final purged = <int>[];
      provider.onRemoveConversationsForUser = purged.add;

      provider.onBoxFriendshipEnded(2);

      expect(purged, [2]);
    });

    test('onBoxFriendshipEnded ignores our OWN id — it would purge every chat',
        () {
      // `removeConversationsForUser` matches `userOne.id == id || userTwo.id == id`
      // and we are a participant in EVERY one of our conversations, so acting on
      // our own id destroys the decrypted plaintext of the whole local history —
      // irreversibly, because the ratchet consumed the message keys.
      final provider = FriendsProvider()..setCurrentUserId(1);
      final purged = <int>[];
      provider.onRemoveConversationsForUser = purged.add;

      provider.onBoxFriendshipEnded(1);

      expect(purged, isEmpty);
    });
  });

  group('FriendsProvider invitation round trips', () {
    test('a dropped accept ack releases the row and reports a failure', () {
      fakeAsync((async) {
        final provider = FriendsProvider()
          ..boxAcceptRequest = ((_) => Completer<FirstContactAccept>().future);
        provider.acceptFriendRequest(-8);

        expect(provider.invitationActionFor(-8), InvitationActionStatus.inFlight);

        // No answer ever arrives: nothing else in the app would ever clear
        // this, so the row stayed spinning forever.
        async.elapse(const Duration(seconds: 21));

        expect(provider.invitationActionFor(-8), isNull);
        final failure = provider.consumeInvitationFailure();
        expect(failure, isNotNull);
        expect(failure!.action, InvitationAction.accept);
        expect(failure.requestId, -8);
        provider.dispose();
      });
    });

    test('an answer inside the window cancels the timeout', () {
      fakeAsync((async) {
        final provider = FriendsProvider()
          ..boxDeclineRequest = ((_) async {});
        provider.rejectFriendRequest(-8);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 21));

        expect(provider.invitationActionFor(-8), isNull);
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
      // Relative to now: a box request is shown for 30 d (decision 54), so a
      // fixed date stops showing it once the calendar passes it.
      boxOrigin: box
          ? ContactBoxOrigin(
              at: DateTime.now()
                  .toUtc()
                  .subtract(const Duration(days: 1))
                  .add(Duration(minutes: id)),
            )
          : null,
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

    group('lists read the store', () {
      test('box records show as friends, requests (-userId) and blocked',
          () async {
        await seed([
          record(7, ContactState.friend),
          record(8, ContactState.pendingIn),
          record(9, ContactState.pendingOut),
          record(10, ContactState.blocked),
          // A pending record with no box origin is no box request.
          record(11, ContactState.pendingIn, box: false),
        ]);
        final friends = provider();

        expect(friends.friends.map((u) => u.id), [7]);
        expect(friends.isFriend(7), isTrue);
        expect(friends.friendRequests.map((r) => r.id), [-8]);
        expect(
          friends.friendRequests.single,
          isA<FriendRequestModel>()
              .having((r) => r.sender.id, 'sender', 8)
              .having((r) => r.receiver.id, 'receiver', 1),
        );
        expect(friends.sentRequests.single.id, -9);
        expect(friends.sentRequests.single.receiver.id, 9);
        expect(friends.blockedUsers.map((u) => u.id), [10]);
        expect(friends.pendingRequestsCount, 1);
      });

      test('a record gone from the store leaves the lists', () async {
        await seed([record(7, ContactState.friend)]);
        final friends = provider();
        expect(friends.isFriend(7), isTrue);

        await store.remove(7);

        expect(friends.friends, isEmpty);
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

      test('a send with no box wired fails and emits nothing', () async {
        final friends = provider()
          ..searchUsers('u2#0002')
          ..onSearchUsersResult([bob])
          ..sendFriendRequest(2);
        await pumpEventQueue();

        expect(sends(), isEmpty);
        expect(friends.sendActionFor(2), isNull);
        expect(friends.consumeInvitationFailure()?.reason, 'send_failed');
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

      test('a user with no search entry fails without asking the box', () async {
        final seen = <Object>[];
        final friends = searched(FirstContactSend.sent, seen)
          ..sendFriendRequest(5);
        await pumpEventQueue();

        expect(seen, isEmpty);
        expect(sends(), isEmpty);
        expect(friends.consumeInvitationFailure()?.reason, 'send_failed');
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
              ),
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

      group('a friend from before the box', () {
        const queue = ContactQueue(
          rid: 'r',
          sid: 's',
          nid: 'n',
          authPriv: 'a',
          sealPriv: 'sp',
          sealPub: 'p',
        );
        ContactRecord preBox({bool route = true}) {
          final r = record(7, ContactState.friend, box: false);
          return route ? r.copyWith(queues: const [queue]) : r;
        }

        for (final block in [false, true]) {
          test(
            '${block ? 'a block' : 'an unfriend'} of one with a box route ends '
            'on the box only',
            () async {
              await seed([preBox()]);
              final ended = <(int, bool)>[];
              final friends = provider()
                ..boxEndFriendship = ((userId, {required block}) async =>
                    ended.add((userId, block)));

              expect(
                block ? await friends.blockUser(7) : await friends.unfriend(7),
                isTrue,
              );

              expect(ended, [(7, block)]);
              expect(events(), isEmpty);
            },
          );
        }

        test('a block of one with no route is local: the record turns '
            'blocked, nothing is emitted', () async {
          await seed([preBox(route: false)]);
          var boxEnds = 0;
          final purged = <int>[];
          final friends = provider()
            ..boxEndFriendship = ((userId, {required block}) async => boxEnds++)
            ..onRemoveConversationsForUser = purged.add;

          expect(await friends.blockUser(7), isTrue);

          expect(boxEnds, 0);
          expect(events(), isEmpty);
          expect(purged, [7]);
          expect(
            store.byUserId(7),
            isA<ContactRecord>()
                .having((r) => r.state, 'state', ContactState.blocked)
                .having((r) => r.username, 'username', 'u7')
                .having((r) => r.queues, 'queues', isEmpty)
                .having((r) => r.boxOrigin, 'boxOrigin', isNull),
          );
          expect(friends.blockedUsers.map((u) => u.id), [7]);
          expect(friends.friends, isEmpty);
        });

        test('an unfriend of one with no route removes the record, nothing '
            'is emitted', () async {
          await seed([preBox(route: false)]);
          var boxEnds = 0;
          final purged = <int>[];
          final friends = provider()
            ..boxEndFriendship = ((userId, {required block}) async => boxEnds++)
            ..onRemoveConversationsForUser = purged.add;

          expect(await friends.unfriend(7), isTrue);

          expect(boxEnds, 0);
          expect(events(), isEmpty);
          expect(purged, [7]);
          expect(store.byUserId(7), isNull);
          expect(friends.friends, isEmpty);
        });

        test('a box end that failed leaves the record', () async {
          await seed([preBox()]);
          final friends = provider()
            ..boxEndFriendship = ((userId, {required block}) async =>
                throw StateError('a sibling was not told'));

          expect(await friends.unfriend(7), isFalse);
          expect(events(), isEmpty);
          expect(store.byUserId(7)?.state, ContactState.friend);
        });
      });

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
