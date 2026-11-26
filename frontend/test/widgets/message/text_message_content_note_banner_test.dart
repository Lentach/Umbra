import 'package:fireplace/config/app_config.dart';
import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/message/anti_quantum_note_card.dart';
import 'package:fireplace/widgets/message/text_message_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _FakeUrlLauncher extends UrlLauncherPlatform {
  final List<String> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

MessageModel _msg({required String content, String? linkPreviewUrl}) =>
    MessageModel(
      id: 1,
      content: content,
      senderId: 1,
      senderUsername: 'alice',
      conversationId: 1,
      createdAt: DateTime(2026, 5, 23),
      deliveryStatus: MessageDeliveryStatus.sent,
      messageType: MessageType.text,
      linkPreviewUrl: linkPreviewUrl,
      linkPreviewTitle: linkPreviewUrl == null ? null : 'Example Title',
    );

Widget _wrap(MessageModel message) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: RpgTheme.themeDataLight,
  home: Scaffold(
    body: Center(
      child: TextMessageContent(
        message: message,
        isMine: true,
        textColor: Colors.black,
        isDark: false,
        maxWidth: 280,
      ),
    ),
  ),
);

void main() {
  // In the widget-test VM AppConfig.baseUrl resolves to http://<host>:3000, so
  // building the content from it is what makes note detection fire.
  const hex = '0123456789abcdef0123456789abcdef';
  final noteUrl = '${AppConfig.baseUrl}/note/$hex#abcABC012_-';

  testWidgets(
    'note-URL message renders the banner and suppresses text + preview card',
    (tester) async {
      final message = _msg(
        content: noteUrl,
        linkPreviewUrl: 'https://example.com/page',
      );
      await tester.pumpWidget(_wrap(message));
      await tester.pumpAndSettle();

      // Banner card present.
      expect(find.byKey(const Key('anti-quantum-note-card')), findsOneWidget);
      expect(find.byType(AntiQuantumNoteCard), findsOneWidget);

      // Title + subtitle texts visible.
      final l10n = AppLocalizations.of(
        tester.element(find.byType(AntiQuantumNoteCard)),
      );
      expect(find.text(l10n.antiQuantumNoteTitle), findsOneWidget);
      expect(find.text(l10n.antiQuantumNoteCardSubtitle), findsOneWidget);

      // Banner GestureDetector is tappable (tap opens the reveal URL; the
      // url_launcher platform channel is unavailable in tests, so we only
      // assert the handler is wired, not the launch itself).
      final gesture = tester.widget<GestureDetector>(
        find.byKey(const Key('anti-quantum-note-card')),
      );
      expect(gesture.onTap, isNotNull);

      // Raw note-URL link body is suppressed (banner replaces the text).
      expect(find.text(noteUrl), findsNothing);

      // No preview-card URL text even though linkPreviewUrl is set.
      expect(find.text('https://example.com/page'), findsNothing);
    },
  );

  testWidgets(
    'ordinary URL message renders text + preview card, no banner',
    (tester) async {
      final message = _msg(
        content: 'https://example.com',
        linkPreviewUrl: 'https://example.com/page',
      );
      await tester.pumpWidget(_wrap(message));
      await tester.pumpAndSettle();

      // No banner.
      expect(find.byKey(const Key('anti-quantum-note-card')), findsNothing);
      expect(find.byType(AntiQuantumNoteCard), findsNothing);

      // Link body rendered as a RichText carrying the message URL text.
      expect(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText() == 'https://example.com',
        ),
        findsOneWidget,
      );

      // Preview card URL text rendered.
      expect(find.text('https://example.com/page'), findsOneWidget);
    },
  );

  // A3-MSG-A-02: the card's address comes from the peer's envelope unchecked.
  testWidgets('the preview card opens only an http(s) address', (tester) async {
    final previous = UrlLauncherPlatform.instance;
    final launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = previous);

    for (final url in [
      'tel:+48123456789',
      'market://details?id=x',
      'intent://x#Intent;scheme=http;end',
      'https://',
      'http://[bad',
    ]) {
      await tester.pumpWidget(_wrap(_msg(content: 'hi', linkPreviewUrl: url)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Example Title'));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: url);
    }
    expect(launcher.launched, isEmpty);

    await tester.pumpWidget(
      _wrap(_msg(content: 'hi', linkPreviewUrl: 'HTTPS://example.com/page')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Example Title'));
    await tester.pump();
    expect(launcher.launched, ['https://example.com/page']);
  });
}
