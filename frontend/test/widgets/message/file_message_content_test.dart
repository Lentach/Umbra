import 'package:fireplace/config/app_config.dart';
import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/message/file_message_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

MessageModel _file(String mediaUrl) => MessageModel(
  id: 1,
  content: 'report.pdf',
  senderId: 2,
  senderUsername: 'bob',
  conversationId: 1,
  createdAt: DateTime(2026, 11, 23),
  messageType: MessageType.file,
  mediaUrl: mediaUrl,
);

Widget _wrap(MessageModel message) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: RpgTheme.themeDataLight,
  home: Scaffold(
    body: Center(
      child: FileMessageContent(message: message, textColor: Colors.black),
    ),
  ),
);

void main() {
  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(FileMessageContent)));

  /// Taps the file row and confirms the download; returns every URL the app
  /// asked the network for. The result toast is still on screen after it.
  Future<List<Uri>> download(WidgetTester tester, String mediaUrl) async {
    final asked = <Uri>[];
    await http.runWithClient(
      () async {
        await tester.pumpWidget(_wrap(_file(mediaUrl)));
        await tester.tap(find.text('report.pdf'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10nOf(tester).download));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      },
      () => MockClient((request) async {
        asked.add(request.url);
        return http.Response('nope', 404);
      }),
    );
    return asked;
  }

  /// Lets the toast's own timer run out.
  Future<void> drain(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 30));

  // The media url of a row comes from the sender's envelope. A file row
  // without a key (an old-path file) must obey the same host rule as every
  // other media fetch: the backend origin or the legacy host, nothing else.
  testWidgets('a keyless file whose url names a foreign host is never fetched',
      (tester) async {
    final asked = await download(tester, 'https://evil.example/track?id=7');

    expect(asked, isEmpty);
    expect(find.text(l10nOf(tester).documentDownloadFailed), findsOneWidget);
    await drain(tester);
  });

  testWidgets('a keyless file on the backend origin is still asked for',
      (tester) async {
    final url = '${AppConfig.baseUrl}/media/old/report.pdf';

    final asked = await download(tester, url);

    expect(asked, [Uri.parse(url)]);
    await drain(tester);
  });
}
