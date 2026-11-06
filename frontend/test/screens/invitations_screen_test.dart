import 'dart:async';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/screens/invitations_screen.dart';
import 'package:fireplace/services/box/box_first_contact.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/contact_seed.dart';

Map<String, dynamic> _user(int id, String username) => {
  'id': id,
  'username': username,
  'tag': id.toString().padLeft(4, '0'),
};

/// A real contact store for account 1 holding [records]; the writes need real
/// async, so they run outside the test's fake clock.
Future<ContactStore> _store(
  WidgetTester tester,
  List<ContactRecord> records,
) async => (await tester.runAsync(() => openContactStore(records)))!;

Future<void> _put(
  WidgetTester tester,
  ContactStore store,
  List<ContactRecord> records,
) async {
  await tester.runAsync(() => putContacts(store, records));
}

ContactRecord _incoming(int id, String name) =>
    contactRecord(id, name, ContactState.pendingIn, box: true);

ContactRecord _sent(int id, String name) =>
    contactRecord(id, name, ContactState.pendingOut, box: true);

ContactRecord _friend(int id, String name) =>
    contactRecord(id, name, ContactState.friend, box: true);

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
    'tapping Send invitation does not pop and the box send alone adds Sent without duplication',
    (tester) async {
      final store = await _store(tester, []);
      final answer = Completer<FirstContactSend>();
      final friends = friendsOver(store)
        ..boxSendRequest = ((_) => answer.future);
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

      // The box wrote the pending record, then reported the send.
      await _put(tester, store, [_sent(2, 'bob')]);
      answer.complete(FirstContactSend.sent);
      await tester.pump();
      await tester.pump();
      expect(popped, isNull);
      _expectExactlyOnePeerRow(tester, 2);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey(2))).dy,
        greaterThan(tester.getTopLeft(find.text('Sent')).dy),
      );

      friends.onContactsChanged();
      await tester.pump();
      _expectExactlyOnePeerRow(tester, 2);
    },
  );

  testWidgets('Accept shows in-row progress without success before acceptance',
      (tester) async {
    final store = await _store(tester, [_incoming(2, 'bob')]);
    final friends = friendsOver(store)
      ..boxAcceptRequest = ((_) => Completer<FirstContactAccept>().future);

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
    'Decline keeps the row mounted and disabled until the box has declined',
    (tester) async {
      final store = await _store(tester, [_incoming(2, 'bob')]);
      final declined = Completer<void>();
      final friends = friendsOver(store)
        ..boxDeclineRequest = ((_) => declined.future);

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

      // The box drops the record, then reports the decline.
      await tester.runAsync(() => store.remove(2));
      declined.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey(2)), findsNothing);
    },
  );

  testWidgets('a friendship made stays put and renders ready actions',
      (tester) async {
    final store = await _store(tester, [_incoming(2, 'bob')]);
    final friends = friendsOver(store);

    await _pumpInvitations(tester, friends);
    await _put(tester, store, [_friend(2, 'bob')]);
    friends.onBoxFriendshipMade(2, outgoing: false);
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
    final store = await _store(tester, [_incoming(2, 'bob')]);
    final friends = friendsOver(store);
    await _pumpInvitations(tester, friends);

    await _put(tester, store, [_friend(2, 'bob')]);
    friends.onBoxFriendshipMade(2, outgoing: false);
    await tester.pump();

    _expectRowInSection(tester, 2, 'Waiting for you', 'Sent');
  });

  testWidgets('sender renders the accepted friendship under Sent',
      (tester) async {
    final store = await _store(tester, [_sent(2, 'bob')]);
    final friends = friendsOver(store);
    await _pumpInvitations(tester, friends);

    await _put(tester, store, [_friend(2, 'bob')]);
    friends.onBoxFriendshipMade(2, outgoing: true);
    await tester.pump();

    _expectExactlyOnePeerRow(tester, 2);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey(2))).dy,
      greaterThan(tester.getTopLeft(find.text('Sent')).dy),
    );
  });

  testWidgets(
    'exactly one accepted row in every frame for both sides',
    (tester) async {
      Future<void> exercise({required bool sender}) async {
        final store = await _store(tester, [
          sender ? _sent(2, 'bob') : _incoming(2, 'bob'),
        ]);
        final friends = friendsOver(store);
        await _pumpInvitations(tester, friends);
        _expectExactlyOnePeerRow(tester, 2);

        await _put(tester, store, [_friend(2, 'bob')]);
        friends.onBoxFriendshipMade(2, outgoing: sender);
        await tester.pump();
        _expectExactlyOnePeerRow(tester, 2);

        friends.onContactsChanged();
        await tester.pump();
        _expectExactlyOnePeerRow(tester, 2);
      }

      await exercise(sender: false);
      await exercise(sender: true);
    },
  );

  testWidgets('only Open chat pops the peer id and Done only removes the row',
      (tester) async {
    final store = await _store(tester, [_friend(2, 'bob')]);
    final friends = friendsOver(store);
    Object? popped;
    await _pumpInvitations(
      tester,
      friends,
      home: _InvitationRouteHost(onPopped: (value) => popped = value),
    );
    await tester.tap(find.byKey(const Key('open-invitations')));
    await tester.pumpAndSettle();

    void deliverAccepted() => friends.onBoxFriendshipMade(2, outgoing: false);

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

  testWidgets('reduce motion makes invitation state transition instantaneous',
      (tester) async {
    final store = await _store(tester, [_incoming(2, 'bob')]);
    final friends = friendsOver(store);

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
    final store = await _store(tester, [
      _incoming(2, 'bob'),
      _sent(3, 'mara'),
      _friend(4, 'nina'),
    ]);
    final friends = friendsOver(store)..onBoxFriendshipMade(4, outgoing: false);

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

  testWidgets('a failed decline resets the action and shows scoped copy',
      (tester) async {
    final store = await _store(tester, [_incoming(2, 'bob')]);
    final friends = friendsOver(store)
      ..boxDeclineRequest = ((_) async => throw StateError('no box'));
    await _pumpInvitations(tester, friends);

    await tester.tap(find.text('Decline'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
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
    final store = await _store(tester, [
      _incoming(2, 'bob'),
      _incoming(3, 'mara'),
    ]);
    final friends = friendsOver(store);
    await _pumpInvitations(tester, friends);

    // A box request has id `-userId`.
    expect(find.byKey(const Key('invitation-waiting-comb')), findsOneWidget);
    expect(find.byKey(const Key('invitation-comb--2')), findsOneWidget);
    expect(find.byKey(const Key('invitation-comb--3')), findsOneWidget);
    // With more than one request nothing auto-expands: no card, no Accept.
    expect(find.text('Accept'), findsNothing);

    await tester.tap(find.byKey(const Key('invitation-comb--2')));
    await tester.pump();
    expect(find.byKey(const ValueKey(2)), findsOneWidget);
    expect(find.byKey(const ValueKey(3)), findsNothing);
    expect(find.text('Accept'), findsOneWidget);

    // Picking the other hex swaps the card rather than stacking a second one.
    await tester.tap(find.byKey(const Key('invitation-comb--3')));
    await tester.pump();
    expect(find.byKey(const ValueKey(3)), findsOneWidget);
    expect(find.byKey(const ValueKey(2)), findsNothing);

    // Tapping the open hex again collapses it.
    await tester.tap(find.byKey(const Key('invitation-comb--3')));
    await tester.pump();
    expect(find.text('Accept'), findsNothing);
  });

  testWidgets('a lone inbound request auto-expands and its hex can collapse '
      'it', (tester) async {
    final store = await _store(tester, [_incoming(2, 'bob')]);
    final friends = friendsOver(store);
    await _pumpInvitations(tester, friends);

    // The common case pays zero extra taps: the only card is already open.
    expect(find.text('Accept'), findsOneWidget);

    await tester.tap(find.byKey(const Key('invitation-comb--2')));
    await tester.pump();
    expect(find.text('Accept'), findsNothing);
  });

  testWidgets(
    'search results offer add only to strangers: a friend, a requester and '
    'a blocked account get none',
    (tester) async {
      final store = await _store(tester, [
        _friend(2, 'bob'),
        _incoming(3, 'cat'),
        contactRecord(4, 'dan', ContactState.blocked),
      ]);
      final friends = friendsOver(store);
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
      final store = await _store(tester, [_friend(2, 'bob')]);
      final friends = friendsOver(store);
      await _pumpInvitations(tester, friends);
      friends.onSearchUsersResult([_user(2, 'bob')]);
      await tester.pump();
      expect(find.text('User not found'), findsNothing);
      expect(find.byKey(const Key('invitation-send-2')), findsNothing);
    },
  );
}
