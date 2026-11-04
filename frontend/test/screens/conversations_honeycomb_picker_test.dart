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
import 'package:fireplace/screens/conversations_screen.dart';
import 'package:fireplace/screens/invitations_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/chat_honeycomb_picker.dart';
import 'package:fireplace/widgets/hex_avatar.dart';
import 'package:flutter/material.dart';
import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/contacts/contact_backup_service.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/contact_seed.dart';
import '../support/passcode_fakes.dart';

class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider(this._user);

  final UserModel _user;

  @override
  UserModel? get currentUser => _user;

  @override
  String? get token => 'test-token';

  @override
  Future<void> ensureSessionReady() async {}
}

class _FakeConnectionProvider extends ConnectionProvider {
  /// The screen wires a store of its own (never opened here); the providers
  /// under test already read the seeded one, which this keeps.
  @override
  void setProviders({
    required EncryptionProvider encryption,
    required FriendsProvider friends,
    required ConversationsProvider conversations,
    required MessagingProvider messaging,
    ContactStore? contactStore,
    ContactBackupService? contactBackup,
    BoxClient Function(String baseUrl)? boxClient,
    Future<int?> Function()? storedSessionDeviceId,
  }) => super.setProviders(
    encryption: encryption,
    friends: friends,
    conversations: conversations,
    messaging: messaging,
    contactStore: friends.contactStore,
  );

  @override
  Future<void> connect(
    int userId,
    String token,
    String baseUrl, {
    bool immediate = false,
  }) async {}
}

Widget _host({
  required FriendsProvider friends,
  required ConversationsProvider conversations,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(
        create: (_) =>
            _FakeAuthProvider(UserModel(id: 1, username: 'Marta', tag: '0007')),
      ),
      ChangeNotifierProvider<ConnectionProvider>(
        create: (_) => _FakeConnectionProvider(),
      ),
      ChangeNotifierProvider.value(value: friends),
      ChangeNotifierProvider.value(value: conversations),
      ChangeNotifierProvider<SettingsProvider>.value(
        value: SettingsProvider(initialThemePreference: 'dark'),
      ),
      ChangeNotifierProvider(create: (_) => EncryptionProvider()),
      ChangeNotifierProvider(create: (_) => MessagingProvider()),
      // The Chats header carries the Passcode Lock padlock, so the screen
      // needs the provider; a memory-backed one keeps this suite off disk.
      ChangeNotifierProvider(
        create: (_) => PasscodeProvider(
          store: MemoryPasscodeStore(),
          kdf: FakePasscodeKdf(),
        ),
      ),
    ],
    child: MaterialApp(
      theme: RpgTheme.themeDataDarkGray,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(800, 600),
          disableAnimations: true,
        ),
        child: const ConversationsScreen(),
      ),
    ),
  );
}

/// Account 1 (Marta) with [friends] in a real contact store: Ada (2) has the
/// chat 42 from before the box, an [invite] is an inbound box request from
/// Nina (5).
Future<({FriendsProvider friends, ConversationsProvider conversations})>
_session(
  WidgetTester tester, {
  List<UserModel> friends = const [],
  bool invite = false,
}) async {
  final store = (await tester.runAsync(
    () => openContactStore([
      for (final user in friends)
        contactRecord(
          user.id,
          user.username,
          ContactState.friend,
          chatId: user.id == 2 ? 42 : null,
        ),
      if (invite) contactRecord(5, 'Nina', ContactState.pendingIn, box: true),
    ], selfName: 'Marta'),
  ))!;
  return (
    friends: friendsOver(store),
    conversations: conversationsOver(store),
  );
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('conversations-new-chat-button')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the Chats plus opens a honeycomb and opens its conversation', (
    tester,
  ) async {
    final s = await _session(
      tester,
      friends: [
        UserModel(id: 2, username: 'Ada', tag: '0002'),
        UserModel(id: 3, username: 'Borys', tag: '0003'),
      ],
    );
    final conversations = s.conversations;
    await tester.pumpWidget(
      _host(friends: s.friends, conversations: conversations),
    );
    await tester.pump();

    await _openPicker(tester);

    expect(find.byKey(const Key('chat-honeycomb-picker')), findsOneWidget);
    expect(find.byType(ChatHoneycombPicker), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ChatHoneycombPicker),
        matching: find.byType(HexAvatar),
      ),
      findsNWidgets(2),
    );

    await tester.tap(find.byKey(const Key('chat-picker-friend-2')));
    await tester.pump();

    expect(conversations.activeConversationId, 42);
  });

  testWidgets('the picker gives an empty friend list a useful state', (
    tester,
  ) async {
    final s = await _session(tester);
    await tester.pumpWidget(
      _host(friends: s.friends, conversations: s.conversations),
    );
    await tester.pump();

    await _openPicker(tester);

    expect(find.byKey(const Key('chat-honeycomb-empty-state')), findsOneWidget);
    expect(find.text('No friends yet'), findsOneWidget);
    expect(find.text('Add a friend to start a chat.'), findsOneWidget);
  });

  testWidgets('reduce motion renders the picker entrance immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataDarkGray,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            disableAnimations: true,
          ),
          child: const ChatHoneycombPicker(friends: []),
        ),
      ),
    );

    expect(
      tester
          .widget<FadeTransition>(
            find.descendant(
              of: find.byType(ChatHoneycombPicker),
              matching: find.byType(FadeTransition),
            ),
          )
          .opacity
          .value,
      1,
    );
  });

  testWidgets('reduce motion turned on mid-entrance snaps the picker to its '
      'end state', (tester) async {
    Widget host({required bool reduceMotion}) => MaterialApp(
      theme: RpgTheme.themeDataDarkGray,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(390, 844),
          disableAnimations: reduceMotion,
        ),
        child: const ChatHoneycombPicker(friends: []),
      ),
    );

    await tester.pumpWidget(host(reduceMotion: false));
    await tester.pump(const Duration(milliseconds: 60));

    double opacity() => tester
        .widget<FadeTransition>(
          find.descendant(
            of: find.byType(ChatHoneycombPicker),
            matching: find.byType(FadeTransition),
          ),
        )
        .opacity
        .value;

    expect(opacity(), lessThan(1), reason: 'entrance should be mid-flight');

    // The reduce-motion check must run on EVERY dependency change, not be
    // latched by the one-shot entrance guard: a user switching the setting on
    // mid-animation has to see it honored (playbook §9).
    await tester.pumpWidget(host(reduceMotion: true));
    await tester.pump();

    expect(opacity(), 1);
  });

  _pickerNameTests();
}

// A comb of bare avatars is unreadable the moment someone has no picture:
// every such terminal is one initial. The name is the identifier.
void _pickerNameTests() {
  testWidgets('every picker terminal is captioned with its username', (
    tester,
  ) async {
    final s = await _session(
      tester,
      friends: [
        UserModel(id: 2, username: 'Ada', tag: '0002'),
        UserModel(id: 3, username: 'Borys', tag: '0003'),
      ],
    );
    await tester.pumpWidget(
      _host(friends: s.friends, conversations: s.conversations),
    );
    await tester.pump();
    await _openPicker(tester);

    for (final name in ['Ada', 'Borys']) {
      expect(
        find.descendant(
          of: find.byType(ChatHoneycombPicker),
          matching: find.text(name),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('an inbound invitation is a comb terminal that opens the queue', (
    tester,
  ) async {
    final s = await _session(
      tester,
      friends: [UserModel(id: 2, username: 'Ada', tag: '0002')],
      invite: true,
    );
    await tester.pumpWidget(
      _host(friends: s.friends, conversations: s.conversations),
    );
    await tester.pump();
    await _openPicker(tester);

    // The "+" badge counts inbound invitations; the sheet behind it has to be
    // able to answer one, and has to name who is waiting.
    expect(
      find.descendant(
        of: find.byType(ChatHoneycombPicker),
        matching: find.text('Nina'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ChatHoneycombPicker),
        matching: find.text('Pending'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('chat-picker-invitations-hint')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('chat-picker-invite-5')));
    // Not pumpAndSettle: the invitation queue paints skeletonizer shimmer,
    // which never reaches a settled frame.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(InvitationsScreen), findsOneWidget);
  });

  testWidgets('no invitations leaves the comb free of the invitation hint', (
    tester,
  ) async {
    final s = await _session(
      tester,
      friends: [UserModel(id: 2, username: 'Ada', tag: '0002')],
    );
    await tester.pumpWidget(
      _host(friends: s.friends, conversations: s.conversations),
    );
    await tester.pump();
    await _openPicker(tester);

    expect(find.byKey(const Key('chat-picker-invitations-hint')), findsNothing);
    expect(find.byKey(const Key('chat-picker-invite-5')), findsNothing);
  });

  testWidgets('the comb LEADS with the add socket and it opens the '
      'invitations screen', (tester) async {
    final s = await _session(
      tester,
      friends: [
        UserModel(id: 2, username: 'Ada', tag: '0002'),
        UserModel(id: 3, username: 'Borys', tag: '0003'),
      ],
    );
    await tester.pumpWidget(
      _host(friends: s.friends, conversations: s.conversations),
    );
    await tester.pump();
    await _openPicker(tester);

    // First cell, not last: with many friends a trailing socket sits below
    // the fold and the invite door disappears (owner ruling 2026-08-04).
    final socket = tester.getTopLeft(
      find.byKey(const Key('chat-picker-invite-new')),
    );
    for (final id in const [2, 3]) {
      final friend = tester.getTopLeft(
        find.byKey(Key('chat-picker-friend-$id')),
      );
      expect(
        socket.dy < friend.dy || socket.dx < friend.dx,
        isTrue,
        reason: 'the add socket must precede friend $id in the comb',
      );
    }

    await tester.tap(find.byKey(const Key('chat-picker-invite-new')));
    // Not pumpAndSettle: the invitation queue paints skeletonizer shimmer,
    // which never reaches a settled frame.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(InvitationsScreen), findsOneWidget);
  });

  testWidgets('the empty picker offers the same invite door as a button', (
    tester,
  ) async {
    final s = await _session(tester);
    await tester.pumpWidget(
      _host(friends: s.friends, conversations: s.conversations),
    );
    await tester.pump();
    await _openPicker(tester);

    // No lone dashed socket in an otherwise empty comb: the empty state
    // carries the door instead.
    expect(find.byKey(const Key('chat-picker-invite-new')), findsNothing);

    await tester.tap(find.byKey(const Key('chat-picker-invite-empty')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(InvitationsScreen), findsOneWidget);
  });
}
