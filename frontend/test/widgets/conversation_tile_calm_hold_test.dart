import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/conversation_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/l10n.dart';

Future<void> _pumpTile(
  WidgetTester tester, {
  bool calmHold = false,
  bool isTyping = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: RpgTheme.themeDataDarkGray,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: Scaffold(
      body: MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => MessagingProvider()),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: SizedBox(
          width: 390,
          child: ConversationTile(
            conversationId: 10,
            displayName: 'Alice',
            onTap: () {},
            onDelete: () {},
            calmHold: calmHold,
            isTyping: isTyping,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  const preview = ValueKey('calm-hold-list-preview');

  testWidgets('a calm hold shows the muted preview in place of a message '
      '(a held frame has no row to preview)', (tester) async {
    await _pumpTile(tester, calmHold: true);

    expect(find.byKey(preview), findsOneWidget);
    expect(find.text(l10n.calmHoldListPreview), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(preview)).style?.color,
      RpgTheme.mutedDark,
    );
  });

  testWidgets('no calm hold, no preview', (tester) async {
    await _pumpTile(tester);

    expect(find.byKey(preview), findsNothing);
  });

  testWidgets('typing outranks the calm preview', (tester) async {
    await _pumpTile(tester, calmHold: true, isTyping: true);

    expect(find.byKey(preview), findsNothing);
    expect(find.text(l10n.typing), findsOneWidget);
  });
}
