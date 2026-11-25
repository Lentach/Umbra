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
import 'package:fireplace/screens/chat_detail_screen.dart';
import 'package:fireplace/screens/contacts_screen.dart';
import 'package:fireplace/screens/conversations_screen.dart';
import 'package:fireplace/screens/main_shell.dart';
import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/contacts/contact_backup_service.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/contact_seed.dart';
import '../support/l10n.dart';
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

Widget _shell({
  required Size size,
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
        data: MediaQueryData(size: size, disableAnimations: true),
        child: const MainShell(),
      ),
    ),
  );
}

/// Account 1 with Ada (2) as a friend who has the chat 42 from before the box.
Future<({FriendsProvider friends, ConversationsProvider conversations})>
_session(WidgetTester tester) async {
  final store = (await tester.runAsync(
    () => openContactStore([
      contactRecord(2, 'Ada', ContactState.friend, chatId: 42),
    ], selfName: 'Marta'),
  ))!;
  return (
    friends: friendsOver(store),
    conversations: conversationsOver(store),
  );
}

/// Contacts tab -> Ada's card -> Message.
Future<void> _messageAda(WidgetTester tester) async {
  await tester.tap(find.text(l10n.contacts));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Ada'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(l10n.userCardMessage));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // A2-CON-2: on a wide window the chat pane lives on the Chats tab, which
  // stayed hidden behind Contacts, so Message opened nothing.
  testWidgets('wide window: Message from a contact card lands on the Chats '
      'tab with that chat open', (tester) async {
    final s = await _session(tester);
    await tester.pumpWidget(
      _shell(
        size: const Size(800, 600),
        friends: s.friends,
        conversations: s.conversations,
      ),
    );
    await tester.pump();

    await _messageAda(tester);

    expect(s.conversations.activeConversationId, 42);
    expect(find.byType(ConversationsScreen), findsOneWidget);
    expect(find.byType(ContactsScreen), findsNothing);
    expect(find.byType(ChatDetailScreen), findsOneWidget);
  });

  testWidgets('narrow window: Message pushes the chat route over the tab', (
    tester,
  ) async {
    final s = await _session(tester);
    await tester.pumpWidget(
      _shell(
        size: const Size(390, 844),
        friends: s.friends,
        conversations: s.conversations,
      ),
    );
    await tester.pump();

    await _messageAda(tester);

    expect(s.conversations.activeConversationId, 42);
    expect(find.byType(ChatDetailScreen), findsOneWidget);
    expect(find.byType(ConversationsScreen), findsNothing);
  });

  testWidgets('wide window: a friend with no open chat yet opens on the Chats '
      'tab too, and only one screen consumes the pending open', (
    tester,
  ) async {
    final store = (await tester.runAsync(
      () => openContactStore([
        contactRecord(3, 'Borys', ContactState.friend, box: true, chatId: 77),
      ], selfName: 'Marta'),
    ))!;
    // Deleted on this device: no row in the list, the record keeps the chat.
    final conversations = conversationsOver(store)..deleteConversation(77);
    await tester.pump();
    await tester.pumpWidget(
      _shell(
        size: const Size(800, 600),
        friends: friendsOver(store),
        conversations: conversations,
      ),
    );
    await tester.pump();

    await tester.tap(find.text(l10n.contacts));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Borys'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.userCardMessage));
    await tester.pumpAndSettle();

    expect(conversations.pendingOpenConversationId, isNull);
    expect(conversations.activeConversationId, 77);
    expect(find.byType(ConversationsScreen), findsOneWidget);
    expect(find.byType(ContactsScreen), findsNothing);
  });
}
