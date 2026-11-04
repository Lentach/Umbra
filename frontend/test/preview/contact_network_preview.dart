// Throwaway visual harness for ContactNetworkView (not part of flutter test).
// Run: flutter run -d web-server -t test/preview/contact_network_preview.dart
// Query parameters: ?theme=cosmic|blue|dark|light|teal&count=0|1|3|8|15|25|40
// Optional: &textScale=1.6&reduceMotion=1&avatars=1&pending=N&invites=N
// screen=1: renders the REAL ContactsScreen (seeded providers) so the
// search bar and both view modes are reviewable without a backend.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/contacts_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/contact_network_view.dart';
import 'package:fireplace/widgets/console_glyphs.dart';
import 'package:fireplace/widgets/glass/glass_bottom_nav.dart';
import 'package:fireplace/widgets/main_tab_screen_header.dart';

import '../support/contact_seed.dart';

void main() => runApp(const ContactNetworkPreviewApp());

ThemeData _theme(String name) => switch (name) {
  'cosmic' => RpgTheme.themeDataCosmic,
  'blue' => RpgTheme.themeDataBlue,
  'light' => RpgTheme.themeDataLight,
  'teal' => RpgTheme.themeDataTealStone,
  _ => RpgTheme.themeDataDarkGray,
};

class ContactNetworkPreviewApp extends StatelessWidget {
  const ContactNetworkPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    final query = Uri.base.queryParameters;
    final theme = query['theme'] ?? 'cosmic';
    final count = int.tryParse(query['count'] ?? '') ?? 1;
    final textScale = double.tryParse(query['textScale'] ?? '') ?? 1;
    final reduceMotion = query['reduceMotion'] == '1';
    // avatars=1: placeholder photos to review the avatar-in-hex rendering.
    final avatars = query['avatars'] == '1';
    final screenMode = query['screen'] == '1';
    // pending=N: inbound friend requests docking at the core.
    final pending = int.tryParse(query['pending'] ?? '') ?? 0;
    // invites=N: outbound invitations still awaiting an answer (ghost cells).
    final invites = int.tryParse(query['invites'] ?? '') ?? 0;
    final contacts = _previewContacts(count, avatars: avatars);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(theme),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: child!,
      ),
      home: screenMode
          ? _seededContactsScreen(contacts, pending, invites)
          : _ContactNetworkPreviewPage(
              contacts: contacts,
              textScale: textScale,
            ),
    );
  }

  /// The real ContactsScreen against a seeded contact store: friends, inbound
  /// and outbound box requests, the local user via an unsigned preview JWT.
  Widget _seededContactsScreen(
    List<UserModel> contacts,
    int pending,
    int invites,
  ) {
    const inviteeNames = ['Iwo', 'Sara', 'Luca', 'Nina', 'Olek'];
    String b64(Map<String, Object> json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    final auth = AuthProvider()
      ..setAccessTokenForTest(
        '${b64({'alg': 'none'})}.'
        '${b64({'sub': 700, 'username': 'Marta', 'tag': '0007', 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.x',
      );
    return SeededStoreHost(
      records: [
        for (final contact in contacts)
          ContactRecord(
            userId: contact.id,
            username: contact.username,
            tag: contact.tag,
            avatarUrl: contact.profilePictureUrl,
            state: ContactState.friend,
          ),
        for (var i = 0; i < pending; i++)
          contactRecord(
            600 + i,
            inviteeNames[i % inviteeNames.length],
            ContactState.pendingIn,
            box: true,
          ),
        for (var i = 0; i < invites; i++)
          contactRecord(
            800 + i,
            inviteeNames[i % inviteeNames.length],
            ContactState.pendingOut,
            box: true,
          ),
      ],
      selfId: 700,
      selfName: 'Marta',
      builder: (context, store) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider.value(value: friendsOver(store)),
          ChangeNotifierProvider(create: (_) => ConversationsProvider()),
          ChangeNotifierProvider(
            create: (_) => SettingsProvider(initialThemePreference: 'dark'),
          ),
        ],
        child: const ContactsScreen(),
      ),
    );
  }
}

class _ContactNetworkPreviewPage extends StatelessWidget {
  const _ContactNetworkPreviewPage({
    required this.contacts,
    required this.textScale,
  });

  final List<UserModel> contacts;
  final double textScale;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final navClearance = padding.bottom + 86;
    final topClearance = padding.top + MainTabScreenHeader.clearance;

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: ContactNetworkView(
              contacts: contacts,
              localNodeLabel: 'Marta',
              localNodeCaption: 'LOCAL NODE',
              emptyTitle: 'No contacts yet',
              emptyMessage: 'Add friends to start',
              onContactTap: (_) {},
              safeInsets: EdgeInsets.fromLTRB(
                12,
                topClearance,
                12,
                navClearance,
              ),
              networkSemanticLabel:
                  'Contact network, ${contacts.length} contacts',
              localNodeSemanticLabel: 'You, local node',
              conversationContactIds: {
                for (final contact in contacts)
                  if (contact.id.isOdd) contact.id,
              },
              mapCaption: 'NODES ${contacts.length.toString().padLeft(2, '0')}',
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: MainTabScreenHeader(
              title: 'Contacts',
              // Mirrors the production list/map toggle for composition review.
              trailing: IconButton(
                onPressed: () {},
                tooltip: 'List view',
                icon: Icon(
                  Icons.format_list_bulleted,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ),
          if (textScale > 1)
            Positioned(
              right: 18,
              bottom: navClearance + 8,
              child: Text(
                'TEXT ${textScale.toStringAsFixed(1)}×',
                style: RpgTheme.bodyFont(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: FireplaceColors.of(context).mutedText,
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: GlassBottomNav(
          currentIndex: 1,
          onTap: (_) {},
          destinations: const [
            GlassNavDestination(
              icon: ConsoleGlyphIcon(ConsoleGlyph.chats),
              label: 'Chat',
            ),
            GlassNavDestination(
              icon: ConsoleGlyphIcon(ConsoleGlyph.contacts),
              label: 'Contacts',
            ),
            GlassNavDestination(
              icon: ConsoleGlyphIcon(ConsoleGlyph.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}

List<UserModel> _previewContacts(int count, {bool avatars = false}) {
  const names = [
    'Ada',
    'Borys',
    'Celina',
    'Damian',
    'Eliza',
    'Filip',
    'Gaja',
    'Hubert',
    'Iga',
    'Jan',
    'Kaja',
    'Leon',
    'Maja',
    'Nikodem',
    'Ola',
    'Piotr',
    'Róża',
    'Szymon',
    'Tola',
    'Ula',
    'Wiktor',
    'Zosia',
  ];
  return [
    for (var index = 0; index < count; index++)
      UserModel(
        id: 100 + index * 7,
        username: index < names.length
            ? names[index]
            : '${names[index % names.length]}${index + 1}',
        tag: (index + 1).toString().padLeft(4, '0'),
        profilePictureUrl: avatars && index % 3 != 2
            ? 'https://picsum.photos/seed/fireplace$index/128'
            : null,
      ),
  ];
}
