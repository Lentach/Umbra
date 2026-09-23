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
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/conversation_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/passcode_fakes.dart';

/// Multi-device spec amendment (lxxxviii) A1: the chat list's preview of an
/// `[encrypted]` last message. The server's `conversationsList` serves every
/// E2E row that way, and only a LIVE event in the current session replaces it,
/// so after any restart the list must look up the plaintext this install
/// already holds. The rule:
///   1. plaintext held for that id → the real text (or media label);
///   2. else a PEER row, still unread, that this install can read → "New
///      message";
///   3. else nothing — a read row, an OWN row, or a row this install can never
///      read (the live reproduction of 2026-09-23 showed "Wiadomość
///      zaszyfrowana" there).
///
/// Falsification: drop the plaintext lookup → a read or own chat stops showing
/// its text; drop the unread term → a read row claims to be new; drop the
/// unreadable term (A-F1) → a row from before the boundary claims to be new.
class _FakeAuthProvider extends AuthProvider {
  @override
  UserModel? get currentUser =>
      UserModel(id: 7, username: 'Marta', tag: '0007');

  @override
  String? get token => 'test-token';

  @override
  Future<void> ensureSessionReady() async {}
}

class _FakeConnectionProvider extends ConnectionProvider {
  @override
  Future<void> connect(
    int userId,
    String token,
    String baseUrl, {
    bool immediate = false,
  }) async {}
}

const _me = 7;

Map<String, dynamic> _conv(
  int id,
  String peer, {
  String content = '[encrypted]',
  bool own = false,
  int unread = 0,
  DateTime? at,
}) => {
  'id': id,
  'userOne': {'id': _me, 'username': 'Marta', 'tag': '0007'},
  'userTwo': {'id': id + 100, 'username': peer, 'tag': '0${id + 100}'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'disappearingTimer': null,
  'unreadCount': unread,
  'lastMessage': {
    'id': id * 10,
    'senderId': own ? _me : id + 100,
    'senderUsername': own ? 'Marta' : peer,
    'content': content,
    'conversationId': id,
    'deliveryStatus': 'DELIVERED',
    'messageType': 'TEXT',
    'createdAt': (at ?? DateTime.now()).toUtc().toIso8601String(),
  },
};

/// Boots a REAL encryption stack for [_me] (so plaintext is read back from the
/// store, exactly as after a restart: nothing is in RAM), seals [stored] as the
/// decrypt pass would, optionally records the identity boundary [since], then
/// mounts the chat list.
Future<AppLocalizations> _pump(
  WidgetTester tester, {
  required List<Map<String, dynamic>> conversations,
  Map<int, String> stored = const {},
  DateTime? since,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  SharedPreferences.setMockInitialValues({});
  final service = EncryptionService();
  final encryption = EncryptionProvider(service: service);
  encryption.setEmitCallback((event, data) {
    if (event == 'checkOwnKeyBundle') {
      encryption.onOwnKeyBundleStatus({'exists': false});
    }
  });
  await tester.runAsync(() async {
    await encryption.initializeE2E(_me);
    await pumpEventQueue(times: 200);
    for (final entry in stored.entries) {
      await encryption.saveDecryptedContent(entry.key, {
        'content': entry.value,
        'messageType': 'TEXT',
      });
    }
    if (since != null) {
      final bundle = await service.getKeyBundleForReupload();
      final own = bundle!['identityPublicKey'] as String;
      await service.recordOwnIdentityReplacedFromServer(
        since.toIso8601String(),
        replacedTo: own,
      );
    }
  });
  final messaging = MessagingProvider()..setCurrentUserId(_me);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(
          create: (_) => _FakeAuthProvider(),
        ),
        ChangeNotifierProvider<ConnectionProvider>(
          create: (_) => _FakeConnectionProvider(),
        ),
        ChangeNotifierProvider(create: (_) => FriendsProvider()),
        ChangeNotifierProvider(
          create: (_) => ConversationsProvider()
            ..setCurrentUserId(_me)
            ..onConversationsList(conversations),
        ),
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(initialThemePreference: 'light'),
        ),
        ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
        ChangeNotifierProvider<MessagingProvider>.value(value: messaging),
        ChangeNotifierProvider(
          create: (_) => PasscodeProvider(
            store: MemoryPasscodeStore(),
            kdf: FakePasscodeKdf(),
          ),
        ),
      ],
      child: MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const MediaQuery(
          data: MediaQueryData(size: Size(400, 800), disableAnimations: true),
          child: ConversationsScreen(),
        ),
      ),
    ),
  );
  // The screen wires encryption into messaging after the first frame, exactly
  // as production does; the stored plaintext is then read asynchronously.
  await tester.pump();
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();
  return AppLocalizations.of(tester.element(find.byType(ConversationsScreen)));
}

Finder _tile(String peer) => find.widgetWithText(ConversationTile, peer);

/// The tile's preview line reads [text] (the empty string = no preview).
Finder _preview(String peer, String text) => find.descendant(
  of: _tile(peer),
  matching: find.byWidgetPredicate(
    (w) => w is Text && w.textSpan?.toPlainText() == text,
  ),
);

void main() {
  final since = DateTime.now().toUtc().subtract(const Duration(minutes: 10));

  testWidgets('held plaintext wins; only an unread peer row without it is '
      'new; a read or own row without it shows nothing', (tester) async {
    final l10n = await _pump(
      tester,
      conversations: [
        _conv(20, 'Ola'),
        _conv(21, 'Piotr', own: true),
        _conv(22, 'Zosia', unread: 1),
        _conv(23, 'Adam'),
        _conv(24, 'Ewa', own: true, unread: 1),
      ],
      stored: {200: 'see you at eight', 210: 'my own words'},
    );

    expect(_preview('Ola', 'see you at eight'), findsOneWidget);
    expect(_preview('Piotr', 'my own words'), findsOneWidget);
    expect(_preview('Zosia', l10n.newMessagePreview), findsOneWidget);
    expect(_preview('Adam', ''), findsOneWidget, reason: 'read, no plaintext');
    expect(_preview('Ewa', ''), findsOneWidget, reason: 'own, no plaintext');
    expect(
      find.text(l10n.encryptedMessage, findRichText: true),
      findsNothing,
    );
  });

  testWidgets('an unread peer row from before the boundary shows nothing; '
      'the same row after it is new', (tester) async {
    final l10n = await _pump(
      tester,
      since: since,
      conversations: [
        _conv(20, 'Ola', unread: 1, at: since.subtract(const Duration(hours: 1))),
        _conv(
          21,
          'Piotr',
          content: '[Decryption failed]',
          unread: 1,
          at: since.subtract(const Duration(hours: 2)),
        ),
        _conv(22, 'Zosia', unread: 1, at: since.add(const Duration(minutes: 1))),
      ],
    );

    expect(_preview('Ola', ''), findsOneWidget);
    expect(_preview('Piotr', ''), findsOneWidget);
    expect(_preview('Zosia', l10n.newMessagePreview), findsOneWidget);
    expect(
      find.text(l10n.messageUnreadableOnThisDevice, findRichText: true),
      findsNothing,
    );
  });
}
