import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/screens/invitations_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Map<String, dynamic> _user(int id, String username) => {
  'id': id,
  'username': username,
  'tag': id.toString().padLeft(4, '0'),
};

Map<String, dynamic> _request({
  required int id,
  required int senderId,
  required String senderName,
  required int receiverId,
  required String receiverName,
  int? conversationId,
  bool? chatReady,
}) => {
  'id': id,
  'sender': _user(senderId, senderName),
  'receiver': _user(receiverId, receiverName),
  'status': 'pending',
  'createdAt': '2026-07-28T12:00:00.000Z',
  'conversationId': ?conversationId,
  'chatReady': ?chatReady,
};

void _seedLoadedEmpty(FriendsProvider friends) {
  friends.onFriendRequestsList([]);
  friends.onSentRequestsList([]);
}

Future<void> _pumpInvitations(
  WidgetTester tester,
  FriendsProvider friends, {
  ConversationsProvider? conversations,
  bool disableAnimations = false,
  Widget? home,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: friends),
        ChangeNotifierProvider.value(
          value: conversations ?? ConversationsProvider(),
        ),
        ChangeNotifierProvider.value(value: ConnectionProvider()),
      ],
      child: MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: home ?? const InvitationsScreen(),
        ),
      ),
    ),
  );
  await tester.pump();
}

void _expectExactlyOnePeerRow(WidgetTester tester, int peerUserId) {
  expect(find.byKey(ValueKey(peerUserId)), findsOneWidget);
}

void _expectRowInSection(
  WidgetTester tester,
  int peerUserId,
  String start,
  String end,
) {
  final row = find.byKey(ValueKey(peerUserId));
  expect(tester.getTopLeft(row).dy, greaterThan(tester.getTopLeft(find.text(start)).dy));
  expect(tester.getTopLeft(row).dy, lessThan(tester.getTopLeft(find.text(end)).dy));
}

class _InvitationRouteHost extends StatelessWidget {
  final ValueChanged<Object?> onPopped;

  const _InvitationRouteHost({required this.onPopped});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          key: const Key('open-invitations'),
          onPressed: () async {
            final result = await Navigator.of(context).push<Object?>(
              MaterialPageRoute<Object?>(
                builder: (_) => const InvitationsScreen(),
              ),
            );
            onPopped(result);
          },
          child: const Text('open'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('one exact search result does not auto-send', (tester) async {
    final friends = FriendsProvider();
    _seedLoadedEmpty(friends);
    final emitted = <String>[];
    friends.setEmitCallback((event, _) => emitted.add(event));

    await _pumpInvitations(tester, friends);
    await tester.enterText(
      find.byKey(const Key('invitation-handle-field')),
      'bob#0002',
    );
    await tester.tap(find.byKey(const Key('invitation-handle-submit')));
    expect(emitted, contains('searchUsers'));

    friends.onSearchUsersResult([_user(2, 'bob')]);
    await tester.pump();

    expect(find.byKey(const Key('invitation-send-2')), findsOneWidget);
    expect(emitted.where((event) => event == 'sendFriendRequest'), isEmpty);
  });

  testWidgets(
    'tapping Send invitation does not pop and friendRequestSent alone adds Sent without duplication',
    (tester) async {
      final friends = FriendsProvider()..setCurrentUserId(1);
      _seedLoadedEmpty(friends);
      Object? popped;
      await _pumpInvitations(
        tester,
        friends,
        home: _InvitationRouteHost(onPopped: (value) => popped = value),
      );
      await tester.tap(find.byKey(const Key('open-invitations')));
      await tester.pumpAndSettle();

      friends.onSearchUsersResult([_user(2, 'bob')]);
      await tester.pump();
      await tester.tap(find.byKey(const Key('invitation-send-2')));
      await tester.pump();
      expect(find.byKey(const Key('invitation-send-progress')), findsOneWidget);

      final request = _request(
        id: 10,
        senderId: 1,
        senderName: 'alice',
        receiverId: 2,
        receiverName: 'bob',
      );
      friends.onFriendRequestSent(request);
      await tester.pump();
      expect(popped, isNull);
      _expectExactlyOnePeerRow(tester, 2);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey(2))).dy,
        greaterThan(tester.getTopLeft(find.text('Sent')).dy),
      );

      friends.onSentRequestsList([request]);
      await tester.pump();
      _expectExactlyOnePeerRow(tester, 2);
    },
  );

  testWidgets('Accept shows in-row progress without success before acceptance',
      (tester) async {
    final friends = FriendsProvider();
    friends.onFriendRequestsList([
      _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
      ),
    ]);
    friends.onSentRequestsList([]);

    await _pumpInvitations(tester, friends);
    await tester.tap(find.text('Accept'));
    await tester.pump();

    _expectExactlyOnePeerRow(tester, 2);
    expect(find.byKey(const Key('invitation-action-progress')), findsOneWidget);
    expect(find.text('Invitation accepted'), findsNothing);

    // The in-flight frame is the assertion. Drain the action so its ack-timeout
    // timer (FriendsProvider bounds every invitation round trip) does not
    // outlive the widget tree.
    friends.clearAll();
    await tester.pump();
  });

  testWidgets(
    'Decline keeps the row mounted and disabled until friendRequestRejected',
    (tester) async {
      final friends = FriendsProvider();
      final request = _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
      );
      friends.onFriendRequestsList([request]);
      friends.onSentRequestsList([]);

      await _pumpInvitations(tester, friends);
      await tester.tap(find.text('Decline'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final row = find.byKey(const ValueKey(2));
      _expectExactlyOnePeerRow(tester, 2);
      expect(
        tester.widget<ElevatedButton>(
          find.descendant(of: row, matching: find.byType(ElevatedButton)),
        ).onPressed,
        isNull,
      );
      expect(
        tester.widget<TextButton>(
          find.descendant(of: row, matching: find.byType(TextButton)),
        ).onPressed,
        isNull,
      );
      expect(find.byKey(const Key('invitation-action-progress')), findsOneWidget);

      friends.onFriendRequestRejected(request);
      await tester.pump();
      expect(find.byKey(const ValueKey(2)), findsNothing);
    },
  );

  testWidgets('friendRequestAccepted stays put and renders ready actions',
      (tester) async {
    final friends = FriendsProvider()..setCurrentUserId(1);
    final request = _request(
      id: 10,
      senderId: 2,
      senderName: 'bob',
      receiverId: 1,
      receiverName: 'alice',
    );
    friends.onFriendRequestsList([request]);
    friends.onSentRequestsList([]);

    await _pumpInvitations(tester, friends);
    friends.onFriendRequestAccepted(
      _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
        conversationId: 44,
        chatReady: true,
      ),
    );
    await tester.pump();

    _expectExactlyOnePeerRow(tester, 2);
    expect(find.text('Invitation accepted'), findsOneWidget);
    expect(find.text('Chat ready'), findsOneWidget);
    expect(find.text('Open chat'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.byType(InvitationsScreen), findsOneWidget);
  });

  testWidgets('accepter renders the accepted row under Waiting for you',
      (tester) async {
    final friends = FriendsProvider()..setCurrentUserId(1);
    friends.onFriendRequestsList([
      _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
      ),
    ]);
    friends.onSentRequestsList([]);
    await _pumpInvitations(tester, friends);

    friends.onFriendRequestAccepted(
      _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
        conversationId: 44,
        chatReady: true,
      ),
    );
    await tester.pump();

    _expectRowInSection(tester, 2, 'Waiting for you', 'Sent');
  });

  testWidgets('sender renders the same accepted payload under Sent',
      (tester) async {
    final friends = FriendsProvider()..setCurrentUserId(1);
    friends.onFriendRequestsList([]);
    friends.onSentRequestsList([
      _request(
        id: 10,
        senderId: 1,
        senderName: 'alice',
        receiverId: 2,
        receiverName: 'bob',
      ),
    ]);
    await _pumpInvitations(tester, friends);

    friends.onFriendRequestAccepted(
      _request(
        id: 10,
        senderId: 1,
        senderName: 'alice',
        receiverId: 2,
        receiverName: 'bob',
        conversationId: 44,
        chatReady: true,
      ),
    );
    await tester.pump();

    _expectExactlyOnePeerRow(tester, 2);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey(2))).dy,
      greaterThan(tester.getTopLeft(find.text('Sent')).dy),
    );
  });

  testWidgets(
    'server order keeps exactly one accepted row in every frame for both sides',
    (tester) async {
      Future<void> exercise({required bool sender}) async {
        final friends = FriendsProvider()..setCurrentUserId(1);
        final conversations = ConversationsProvider()..setCurrentUserId(1);
        final pending = _request(
          id: 10,
          senderId: sender ? 1 : 2,
          senderName: sender ? 'alice' : 'bob',
          receiverId: sender ? 2 : 1,
          receiverName: sender ? 'bob' : 'alice',
        );
        if (sender) {
          friends.onFriendRequestsList([]);
          friends.onSentRequestsList([pending]);
        } else {
          friends.onFriendRequestsList([pending]);
          friends.onSentRequestsList([]);
        }
        await _pumpInvitations(tester, friends, conversations: conversations);
        _expectExactlyOnePeerRow(tester, 2);

        conversations.onConversationsList([]);
        await tester.pump();
        _expectExactlyOnePeerRow(tester, 2);

        friends.onFriendRequestAccepted(
          _request(
            id: 10,
            senderId: sender ? 1 : 2,
            senderName: sender ? 'alice' : 'bob',
            receiverId: sender ? 2 : 1,
            receiverName: sender ? 'bob' : 'alice',
            conversationId: 44,
            chatReady: true,
          ),
        );
        await tester.pump();
        _expectExactlyOnePeerRow(tester, 2);

        friends.onFriendRequestsList([]);
        await tester.pump();
        _expectExactlyOnePeerRow(tester, 2);
        friends.onSentRequestsList([]);
        await tester.pump();
        _expectExactlyOnePeerRow(tester, 2);
      }

      await exercise(sender: false);
      await exercise(sender: true);
    },
  );

  testWidgets('only Open chat pops the peer id and Done only removes the row',
      (tester) async {
    final friends = FriendsProvider()..setCurrentUserId(1);
    _seedLoadedEmpty(friends);
    Object? popped;
    await _pumpInvitations(
      tester,
      friends,
      home: _InvitationRouteHost(onPopped: (value) => popped = value),
    );
    await tester.tap(find.byKey(const Key('open-invitations')));
    await tester.pumpAndSettle();

    void deliverAccepted() => friends.onFriendRequestAccepted(
      _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
        conversationId: 44,
        chatReady: true,
      ),
    );

    deliverAccepted();
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(popped, isNull);
    expect(find.byKey(const ValueKey(2)), findsNothing);

    deliverAccepted();
    await tester.pump();
    await tester.tap(find.text('Open chat'));
    await tester.pumpAndSettle();
    expect(popped, 2);
  });

  testWidgets('chatReady false never renders Chat ready', (tester) async {
    final friends = FriendsProvider()..setCurrentUserId(1);
    friends.onFriendRequestsList([
      _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
      ),
    ]);
    friends.onSentRequestsList([]);
    await _pumpInvitations(tester, friends);

    friends.onFriendRequestAccepted(
      _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
        chatReady: false,
      ),
    );
    await tester.pump();

    expect(find.text('Chat setup needs retry'), findsOneWidget);
    expect(find.text('Create chat'), findsOneWidget);
    expect(find.text('Chat ready'), findsNothing);
  });

  testWidgets('Create chat retries in place and only matching peer flips ready',
      (tester) async {
    final friends = FriendsProvider()..setCurrentUserId(1);
    final emitted = <Map<String, dynamic>>[];
    friends.setEmitCallback(
      (event, data) => emitted.add({'event': event, 'data': data}),
    );
    friends.onFriendRequestsList([
      _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
      ),
      _request(
        id: 11,
        senderId: 3,
        senderName: 'mara',
        receiverId: 1,
        receiverName: 'alice',
      ),
    ]);
    friends.onSentRequestsList([]);
    friends.onFriendRequestAccepted(
      _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
        chatReady: false,
      ),
    );
    friends.onFriendRequestAccepted(
      _request(
        id: 11,
        senderId: 3,
        senderName: 'mara',
        receiverId: 1,
        receiverName: 'alice',
        chatReady: false,
      ),
    );

    await _pumpInvitations(tester, friends);
    final bobRow = find.byKey(const ValueKey(2));
    await tester.tap(
      find.descendant(of: bobRow, matching: find.text('Create chat')),
    );
    await tester.pump();
    expect(
      emitted.where((entry) => entry['event'] == 'ensureInvitationChat'),
      hasLength(1),
    );
    final data = emitted
        .singleWhere((entry) => entry['event'] == 'ensureInvitationChat')['data']
        as Map<String, dynamic>;
    expect(data['peerUserId'], 2);
    expect(find.byType(InvitationsScreen), findsOneWidget);

    friends.onInvitationChatReady({
      'peerUserId': 2,
      'correlationId': data['correlationId'],
      'conversationId': 44,
      'chatReady': true,
    });
    await tester.pump();

    expect(
      find.descendant(of: bobRow, matching: find.text('Chat ready')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey(3)),
        matching: find.text('Chat setup needs retry'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('reduce motion makes invitation state transition instantaneous',
      (tester) async {
    final friends = FriendsProvider();
    friends.onFriendRequestsList([
      _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
      ),
    ]);
    friends.onSentRequestsList([]);

    await _pumpInvitations(tester, friends, disableAnimations: true);
    final switcher = tester.widget<AnimatedSwitcher>(
      find.descendant(
        of: find.byKey(const ValueKey(2)),
        matching: find.byType(AnimatedSwitcher),
      ),
    );
    expect(switcher.duration, Duration.zero);
  });

  testWidgets('semantics distinguish incoming, outgoing, and accepted status',
      (tester) async {
    final friends = FriendsProvider()..setCurrentUserId(1);
    friends.onFriendRequestsList([
      _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
      ),
      _request(
        id: 12,
        senderId: 4,
        senderName: 'nina',
        receiverId: 1,
        receiverName: 'alice',
      ),
    ]);
    friends.onSentRequestsList([
      _request(
        id: 11,
        senderId: 1,
        senderName: 'alice',
        receiverId: 3,
        receiverName: 'mara',
      ),
    ]);
    friends.onFriendRequestAccepted(
      _request(
        id: 12,
        senderId: 4,
        senderName: 'nina',
        receiverId: 1,
        receiverName: 'alice',
        conversationId: 44,
        chatReady: true,
      ),
    );

    final handle = tester.ensureSemantics();
    await _pumpInvitations(tester, friends);

    expect(
      tester
          .getSemantics(find.byKey(const ValueKey(2)))
          .label,
      contains('bob#0002, invitation received, wants to connect'),
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey(3)))
          .label,
      contains('mara#0003, invitation sent, waiting for response'),
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey(4)))
          .label,
      contains('nina#0004, invitation accepted, chat ready'),
    );
    handle.dispose();
  });

  testWidgets('friendRequestFailed resets reject action and shows scoped copy',
      (tester) async {
    final friends = FriendsProvider();
    final request = _request(
      id: 10,
      senderId: 2,
      senderName: 'bob',
      receiverId: 1,
      receiverName: 'alice',
    );
    friends.onFriendRequestsList([request]);
    friends.onSentRequestsList([]);
    await _pumpInvitations(tester, friends);

    await tester.tap(find.text('Decline'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    friends.onFriendRequestFailed({
      'action': 'reject',
      'requestId': 10,
      'recipientId': null,
      'reason': 'reject_failed',
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    _expectExactlyOnePeerRow(tester, 2);
    expect(find.text('Could not decline the invitation'), findsOneWidget);
    expect(
      tester.widget<ElevatedButton>(
        find.descendant(
          of: find.byKey(const ValueKey(2)),
          matching: find.byType(ElevatedButton),
        ),
      ).onPressed,
      isNotNull,
    );
    await tester.pump(const Duration(milliseconds: 2501));
  });

  testWidgets('two inbound requests render as a comb and only the tapped hex '
      'expands its card', (tester) async {
    final friends = FriendsProvider()..setCurrentUserId(1);
    friends.onFriendRequestsList([
      _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
      ),
      _request(
        id: 11,
        senderId: 3,
        senderName: 'mara',
        receiverId: 1,
        receiverName: 'alice',
      ),
    ]);
    friends.onSentRequestsList([]);
    await _pumpInvitations(tester, friends);

    expect(find.byKey(const Key('invitation-waiting-comb')), findsOneWidget);
    expect(find.byKey(const Key('invitation-comb-10')), findsOneWidget);
    expect(find.byKey(const Key('invitation-comb-11')), findsOneWidget);
    // With more than one request nothing auto-expands: no card, no Accept.
    expect(find.text('Accept'), findsNothing);

    await tester.tap(find.byKey(const Key('invitation-comb-10')));
    await tester.pump();
    expect(find.byKey(const ValueKey(2)), findsOneWidget);
    expect(find.byKey(const ValueKey(3)), findsNothing);
    expect(find.text('Accept'), findsOneWidget);

    // Picking the other hex swaps the card rather than stacking a second one.
    await tester.tap(find.byKey(const Key('invitation-comb-11')));
    await tester.pump();
    expect(find.byKey(const ValueKey(3)), findsOneWidget);
    expect(find.byKey(const ValueKey(2)), findsNothing);

    // Tapping the open hex again collapses it.
    await tester.tap(find.byKey(const Key('invitation-comb-11')));
    await tester.pump();
    expect(find.text('Accept'), findsNothing);
  });

  testWidgets('a lone inbound request auto-expands and its hex can collapse '
      'it', (tester) async {
    final friends = FriendsProvider()..setCurrentUserId(1);
    friends.onFriendRequestsList([
      _request(
        id: 10,
        senderId: 2,
        senderName: 'bob',
        receiverId: 1,
        receiverName: 'alice',
      ),
    ]);
    friends.onSentRequestsList([]);
    await _pumpInvitations(tester, friends);

    // The common case pays zero extra taps: the only card is already open.
    expect(find.text('Accept'), findsOneWidget);

    await tester.tap(find.byKey(const Key('invitation-comb-10')));
    await tester.pump();
    expect(find.text('Accept'), findsNothing);
  });

  testWidgets(
    'search results offer add only to strangers: a friend, a requester and '
    'a blocked account get none',
    (tester) async {
      final friends = FriendsProvider()
        ..setCurrentUserId(1)
        ..onFriendsList([_user(2, 'bob')])
        ..onFriendRequestsList([
          _request(
            id: 31,
            senderId: 3,
            senderName: 'cat',
            receiverId: 1,
            receiverName: 'alice',
          ),
        ])
        ..onSentRequestsList([])
        ..onBlockedList([_user(4, 'dan')]);
      await _pumpInvitations(tester, friends);
      friends.onSearchUsersResult([
        _user(2, 'bob'),
        _user(3, 'cat'),
        _user(4, 'dan'),
        _user(5, 'eve'),
      ]);
      await tester.pump();
      for (final id in [2, 3, 4]) {
        expect(
          find.byKey(Key('invitation-send-$id')),
          findsNothing,
          reason: 'known $id',
        );
      }
      expect(find.byKey(const Key('invitation-send-5')), findsOneWidget);
    },
  );

  testWidgets(
    'a raw answer naming only a known contact is not "User not found"',
    (tester) async {
      final friends = FriendsProvider()
        ..setCurrentUserId(1)
        ..onFriendsList([_user(2, 'bob')])
        ..onFriendRequestsList([])
        ..onSentRequestsList([]);
      await _pumpInvitations(tester, friends);
      friends.onSearchUsersResult([_user(2, 'bob')]);
      await tester.pump();
      expect(find.text('User not found'), findsNothing);
      expect(find.byKey(const Key('invitation-send-2')), findsNothing);
    },
  );
}
