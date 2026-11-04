import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/contacts_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/widgets/contact_network_view.dart';
import 'package:fireplace/widgets/main_tab_screen_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/contact_seed.dart';

/// AuthProvider fake: only [currentUser] matters to the Contacts tab.
class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider(this._user);

  final UserModel? _user;

  @override
  UserModel? get currentUser => _user;
}

Future<Widget> _host(
  WidgetTester tester, {
  required List<String> friendNames,
  SettingsProvider? settings,
}) async {
  // The store is prefs-backed like the settings are: it must not reset them.
  final store = (await tester.runAsync(
    () => openContactStore([
      for (var i = 0; i < friendNames.length; i++)
        ContactRecord(
          userId: 100 + i,
          username: friendNames[i],
          tag: '0001',
          state: ContactState.friend,
        ),
    ], resetPrefs: false),
  ))!;
  final friends = friendsOver(store);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(
        create: (_) =>
            _FakeAuthProvider(UserModel(id: 1, username: 'Marta', tag: '0007')),
      ),
      ChangeNotifierProvider.value(value: friends),
      ChangeNotifierProvider(create: (_) => ConversationsProvider()),
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings ?? SettingsProvider(initialThemePreference: 'dark'),
      ),
    ],
    child: MaterialApp(
      theme: RpgTheme.themeDataDarkGray,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          disableAnimations: true,
        ),
        child: const ContactsScreen(),
      ),
    ),
  );
}

/// Search now lives in the header capsule: the magnifier opens it.
Future<void> _openSearch(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.search));
  await tester.pumpAndSettle();
}

void main() {
  const names = ['ada', 'borys', 'borys24', 'celina'];

  // SettingsProvider reads preferences in its constructor.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the magnifier swaps the title for the search field', (
    tester,
  ) async {
    await tester.pumpWidget(await _host(tester, friendNames: names));
    await tester.pumpAndSettle();

    expect(find.text('Contacts'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await _openSearch(tester);

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Contacts'), findsNothing);
    // The view toggle keeps its slot so a query survives a view switch.
    expect(find.byIcon(Icons.format_list_bulleted), findsOneWidget);
  });

  testWidgets('no search band eats vertical space', (tester) async {
    await tester.pumpWidget(await _host(tester, friendNames: names));
    await tester.pumpAndSettle();

    // Content clears the header and nothing else (the old 54px search band
    // is gone); MediaQuery padding.top is 0 in this host.
    final view = tester.widget<ContactNetworkView>(
      find.byType(ContactNetworkView),
    );
    expect(view.safeInsets.top, MainTabScreenHeader.clearance);

    await _openSearch(tester);
    final searching = tester.widget<ContactNetworkView>(
      find.byType(ContactNetworkView),
    );
    expect(searching.safeInsets.top, MainTabScreenHeader.clearance);
  });

  testWidgets('search filters the network view', (tester) async {
    await tester.pumpWidget(await _host(tester, friendNames: names));
    await tester.pumpAndSettle();

    for (final name in names) {
      expect(find.text(name), findsOneWidget);
    }

    await _openSearch(tester);
    await tester.enterText(find.byType(TextField), 'bo');
    await tester.pumpAndSettle();

    expect(find.text('borys'), findsOneWidget);
    expect(find.text('borys24'), findsOneWidget);
    expect(find.text('ada'), findsNothing);
    expect(find.text('celina'), findsNothing);
  });

  testWidgets('the same query filters the classic list', (tester) async {
    await tester.pumpWidget(await _host(tester, friendNames: names));
    await tester.pumpAndSettle();

    await _openSearch(tester);
    await tester.enterText(find.byType(TextField), 'celi');
    await tester.pumpAndSettle();

    // Toggle to the classic list without closing search; the query carries.
    await tester.tap(find.byIcon(Icons.format_list_bulleted));
    await tester.pumpAndSettle();

    expect(find.text('celina'), findsOneWidget);
    expect(find.text('ada'), findsNothing);
    expect(find.text('borys'), findsNothing);
  });

  testWidgets('close restores the title and the full set', (tester) async {
    await tester.pumpWidget(await _host(tester, friendNames: names));
    await tester.pumpAndSettle();

    await _openSearch(tester);
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No matching contacts'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('Contacts'), findsOneWidget);
    for (final name in names) {
      expect(find.text(name), findsOneWidget);
    }
  });

  testWidgets('escape closes the search field', (tester) async {
    await tester.pumpWidget(await _host(tester, friendNames: names));
    await tester.pumpAndSettle();

    await _openSearch(tester);
    await tester.enterText(find.byType(TextField), 'ada');
    await tester.pumpAndSettle();
    expect(find.text('celina'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('celina'), findsOneWidget);
  });

  testWidgets('no search entry point without contacts', (tester) async {
    await tester.pumpWidget(await _host(tester, friendNames: const []));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.search), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('No contacts yet'), findsOneWidget);
  });

  testWidgets('the view choice survives leaving and reopening the tab', (
    tester,
  ) async {
    final settings = SettingsProvider(initialThemePreference: 'dark');
    await tester.pumpWidget(
      await _host(tester, friendNames: names, settings: settings),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ContactNetworkView), findsOneWidget);

    await tester.tap(find.byIcon(Icons.format_list_bulleted));
    await tester.pumpAndSettle();
    expect(find.byType(ContactNetworkView), findsNothing);
    expect(settings.contactsListView, isTrue);
    expect(
      (await SharedPreferences.getInstance()).getBool('contacts_list_view'),
      isTrue,
    );

    // Remount with a FRESH provider: the choice has to come back off disk,
    // not out of the instance that is still in memory.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(await _host(tester, friendNames: names));
    await tester.pumpAndSettle();
    expect(find.byType(ContactNetworkView), findsNothing);
    expect(find.byIcon(Icons.hub_outlined), findsOneWidget);
  });

  testWidgets('a stored list choice is restored on a cold start', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'contacts_list_view': true});
    await tester.pumpWidget(await _host(tester, friendNames: names));
    await tester.pumpAndSettle();

    expect(find.byType(ContactNetworkView), findsNothing);
    expect(find.byIcon(Icons.hub_outlined), findsOneWidget);
  });
}
