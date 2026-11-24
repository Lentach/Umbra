import 'dart:async';

import 'package:fake_async/fake_async.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FriendsProvider invitation state', () {
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
    });

    FriendsProvider provider() => FriendsProvider()
      ..contactStore = store
      ..setCurrentUserId(1);

    Future<void> put(int id, ContactState state) async {
      unawaited(
        store.update(
          id,
          (_) => ContactRecord(
            userId: id,
            username: 'u$id',
            tag: id.toString().padLeft(4, '0'),
            state: state,
            boxOrigin: ContactBoxOrigin(
              at: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
            ),
          ),
        ),
      );
      await store.settled;
    }

    test('tracks send, accept, and decline actions until their result',
        () async {
      final friends = provider()
        ..boxSendRequest = ((_) async => FirstContactSend.failed)
        ..boxAcceptRequest = ((_) async => FirstContactAccept.failed)
        ..boxDeclineRequest = ((_) async => throw StateError('no box'));

      friends
        ..searchUsers('u2#0002')
        ..onSearchUsersResult([
          {'id': 2, 'username': 'u2', 'tag': '0002'},
        ])
        ..sendFriendRequest(2);
      expect(friends.sendActionFor(2), InvitationActionStatus.inFlight);
      await pumpEventQueue();
      expect(friends.sendActionFor(2), isNull);
      expect(friends.consumeInvitationFailure()?.action, InvitationAction.send);

      friends.acceptFriendRequest(-10);
      expect(friends.invitationActionFor(-10), InvitationActionStatus.inFlight);
      await pumpEventQueue();
      expect(friends.invitationActionFor(-10), isNull);
      expect(
        friends.consumeInvitationFailure()?.action,
        InvitationAction.accept,
      );

      friends.rejectFriendRequest(-11);
      expect(friends.invitationActionFor(-11), InvitationActionStatus.inFlight);
      await pumpEventQueue();
      expect(friends.invitationActionFor(-11), isNull);
      expect(
        friends.consumeInvitationFailure()?.action,
        InvitationAction.decline,
      );
    });

    test('a send the box refused at its ceiling fails as "servers busy", '
        'any other failed send as a plain failure (plan D2)', () async {
      for (final (answer, reason) in [
        (FirstContactSend.busy, InvitationFailure.serversBusy),
        (FirstContactSend.failed, 'send_failed'),
      ]) {
        final friends = provider()
          ..boxSendRequest = ((_) async => answer)
          ..searchUsers('u2#0002')
          ..onSearchUsersResult([
            {'id': 2, 'username': 'u2', 'tag': '0002'},
          ])
          ..sendFriendRequest(2);
        await pumpEventQueue();
        final failure = friends.consumeInvitationFailure();
        expect(failure?.action, InvitationAction.send);
        expect(failure?.reason, reason);
      }
    });

    test('a finished step releases only its own key', () async {
      final friends = provider()
        ..boxAcceptRequest = ((_) async => FirstContactAccept.failed)
        ..boxDeclineRequest = ((_) => Completer<void>().future)
        ..boxSendRequest = ((_) => Completer<FirstContactSend>().future);
      await put(8, ContactState.pendingIn);
      friends
        ..searchUsers('u2#0002')
        ..onSearchUsersResult([
          {'id': 2, 'username': 'u2', 'tag': '0002'},
        ])
        ..sendFriendRequest(2)
        ..rejectFriendRequest(-11)
        ..acceptFriendRequest(-10);

      await pumpEventQueue();

      expect(friends.invitationActionFor(-10), isNull);
      expect(friends.invitationActionFor(-11), InvitationActionStatus.inFlight);
      expect(friends.sendActionFor(2), InvitationActionStatus.inFlight);
    });

    test('a declined row stays until the box drops it; a failure leaves it',
        () async {
      await put(2, ContactState.pendingIn);
      var fail = true;
      final friends = provider()
        ..boxDeclineRequest = ((userId) async {
          if (fail) throw StateError('no box');
          await store.remove(userId);
        });
      expect(friends.friendRequests, hasLength(1));

      friends.rejectFriendRequest(-2);
      expect(friends.invitationActionFor(-2), InvitationActionStatus.inFlight);
      expect(friends.friendRequests, hasLength(1));
      await pumpEventQueue();
      expect(friends.invitationActionFor(-2), isNull);
      expect(friends.friendRequests, hasLength(1));
      expect(friends.consumeInvitationFailure()?.reason, 'reject_failed');

      fail = false;
      friends.rejectFriendRequest(-2);
      await pumpEventQueue();
      expect(friends.invitationActionFor(-2), isNull);
      expect(friends.friendRequests, isEmpty);
      expect(friends.consumeInvitationFailure(), isNull);
    });

    test('an outgoing friendship made clears the send, outcome and toast',
        () async {
      await put(2, ContactState.pendingOut);
      final friends = provider()
        ..boxSendRequest = ((_) => Completer<FirstContactSend>().future);
      friends
        ..searchUsers('u2#0002')
        ..onSearchUsersResult([
          {'id': 2, 'username': 'u2', 'tag': '0002'},
        ])
        ..sendFriendRequest(2);
      expect(friends.sendActionFor(2), InvitationActionStatus.inFlight);
      await put(2, ContactState.friend);

      friends.onBoxFriendshipMade(2, outgoing: true);

      final outcome = friends.acceptedOutcomeForPeer(2);
      expect(friends.sendActionFor(2), isNull);
      expect(friends.sentRequests, isEmpty);
      expect(friends.acceptedOutcomesFor(InvitationDirection.outgoing), [
        outcome,
      ]);
      expect(outcome?.direction, InvitationDirection.outgoing);
      expect(outcome?.requestId, -2);
      expect(outcome?.conversationId, localConversationIdFor(2));
      final accepted = friends.consumePendingFriendAccepted();
      expect(accepted?.name, 'u2');
      expect(accepted?.peerUserId, 2);
      expect(accepted?.conversationId, localConversationIdFor(2));
    });

    test('the plain accepter gets an incoming outcome and no sender toast',
        () async {
      await put(2, ContactState.pendingIn);
      final friends = provider()
        ..boxAcceptRequest = ((_) => Completer<FirstContactAccept>().future)
        ..acceptFriendRequest(-2);
      expect(friends.invitationActionFor(-2), InvitationActionStatus.inFlight);
      await put(2, ContactState.friend);
      var notifications = 0;
      friends.addListener(() => notifications++);

      friends.onBoxFriendshipMade(2, outgoing: false);

      expect(notifications, 1);
      expect(friends.invitationActionFor(-2), isNull);
      expect(friends.friendRequests, isEmpty);
      expect(
        friends.acceptedOutcomeForPeer(2)?.direction,
        InvitationDirection.incoming,
      );
      expect(friends.consumePendingFriendAccepted(), isNull);

      friends.clearAcceptedOutcome(2);
      expect(friends.acceptedOutcomeForPeer(2), isNull);
    });

    test('reconnect preserves outcomes but fresh connect removes them',
        () async {
      await put(2, ContactState.friend);
      final friends = provider()
        ..boxSendRequest = ((_) => Completer<FirstContactSend>().future)
        ..boxAcceptRequest = ((_) => Completer<FirstContactAccept>().future)
        ..onBoxFriendshipMade(2, outgoing: false);
      friends
        ..searchUsers('u3#0003')
        ..onSearchUsersResult([
          {'id': 3, 'username': 'u3', 'tag': '0003'},
        ])
        ..sendFriendRequest(3)
        ..acceptFriendRequest(-4);
      expect(friends.sendActionFor(3), InvitationActionStatus.inFlight);
      expect(friends.invitationActionFor(-4), InvitationActionStatus.inFlight);

      friends.onConnect(true);
      expect(friends.acceptedOutcomeForPeer(2), isNotNull);
      expect(friends.sendActionFor(3), isNull);
      expect(friends.invitationActionFor(-4), isNull);

      friends.onConnect(false);
      expect(friends.acceptedOutcomeForPeer(2), isNull);
    });

    // CONT-03: one box step per row. A second tap, or a tap after a
    // reconnect gave the button back, must not start a second step.
    group('a second tap while the box step runs (CONT-03)', () {
      test('a second accept starts no second accept', () async {
        final calls = <int>[];
        final answer = Completer<FirstContactAccept>();
        final friends = provider()
          ..boxAcceptRequest = ((id) {
            calls.add(id);
            return answer.future;
          })
          ..acceptFriendRequest(-10)
          ..acceptFriendRequest(-10);
        answer.complete(FirstContactAccept.accepted);
        await pumpEventQueue();

        expect(calls, [10]);
        expect(friends.invitationActionFor(-10), isNull);
        expect(friends.consumeInvitationFailure(), isNull);
      });

      test('a decline while the accept runs is ignored', () async {
        var declines = 0;
        final answer = Completer<FirstContactAccept>();
        provider()
          ..boxAcceptRequest = ((_) => answer.future)
          ..boxDeclineRequest = ((_) async => declines++)
          ..acceptFriendRequest(-10)
          ..rejectFriendRequest(-10);
        answer.complete(FirstContactAccept.accepted);
        await pumpEventQueue();

        expect(declines, 0);
      });

      test('a second send to the same stranger starts no second send',
          () async {
        var sends = 0;
        final answer = Completer<FirstContactSend>();
        final friends = provider()
          ..boxSendRequest = ((_) {
            sends++;
            return answer.future;
          })
          ..searchUsers('u2#0002')
          ..onSearchUsersResult([
            {'id': 2, 'username': 'u2', 'tag': '0002'},
          ])
          ..sendFriendRequest(2)
          ..sendFriendRequest(2);
        answer.complete(FirstContactSend.sent);
        await pumpEventQueue();

        expect(sends, 1);
        expect(friends.sendActionFor(2), isNull);
      });

      test('a tap after a reconnect joins the accept still running',
          () async {
        final calls = <int>[];
        final answer = Completer<FirstContactAccept>();
        final friends = provider()
          ..boxAcceptRequest = ((id) {
            calls.add(id);
            return answer.future;
          })
          ..acceptFriendRequest(-10)
          ..onConnect(true)
          ..setCurrentUserId(1);
        expect(friends.invitationActionFor(-10), isNull);
        friends.acceptFriendRequest(-10);
        expect(
          friends.invitationActionFor(-10),
          InvitationActionStatus.inFlight,
        );
        answer.complete(FirstContactAccept.accepted);
        await pumpEventQueue();

        expect(calls, [10]);
        expect(friends.invitationActionFor(-10), isNull);
      });

      test('the next accept after the first ended starts again', () async {
        var calls = 0;
        final friends = provider()
          ..boxAcceptRequest = ((_) async {
            calls++;
            return FirstContactAccept.failed;
          })
          ..acceptFriendRequest(-10);
        await pumpEventQueue();
        friends.acceptFriendRequest(-10);
        await pumpEventQueue();

        expect(calls, 2);
      });
    });

    // CONT-12: a UI search the server answered with an `error` is owed no
    // answer; it must not stay at the head of the queue and take the next
    // (empty) answer meant for a lookup.
    group('a UI search that never gets its answer (CONT-12)', () {
      test('is dropped after the lookup timeout, so a later empty answer '
          'reaches the lookup that asked', () {
        fakeAsync((async) {
          final sent = <String>[];
          final friends = provider()
            ..setEmitCallback((event, data) => sent.add(event))
            ..searchUsers('ghost#0009');

          // The server answered it with `error` instead: nothing arrives.
          async.elapse(const Duration(seconds: 11));

          List<Object?>? answer;
          var done = false;
          unawaited(
            friends.lookupHandle('u2#0002').then((a) {
              answer = a;
              done = true;
            }),
          );
          async.flushMicrotasks();
          friends.onSearchUsersResult(<dynamic>[]);
          async.flushMicrotasks();

          expect(done, isTrue, reason: "the empty answer is the lookup's");
          expect(answer, isEmpty);
        });
      });

      test('ends with an empty result, so the screen stops searching', () {
        fakeAsync((async) {
          final friends = provider()
            ..setEmitCallback((event, data) {})
            ..searchUsers('ghost#0009');
          expect(friends.searchResults, isNull);

          async.elapse(const Duration(seconds: 11));

          expect(friends.searchResults, isEmpty);
        });
      });

      test('an answered UI search leaves no timer behind', () {
        fakeAsync((async) {
          final friends = provider()
            ..setEmitCallback((event, data) {})
            ..searchUsers('u2#0002')
            ..onSearchUsersResult([
              {'id': 2, 'username': 'u2', 'tag': '0002'},
            ]);

          expect(async.nonPeriodicTimerCount, 0);
          expect(friends.searchResults, hasLength(1));
        });
      });
    });
  });
}
