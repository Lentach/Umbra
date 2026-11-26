import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/services/push_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/web_push_request_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/l10n.dart';

void main() {
  // A3-MISC-5: the failure line is the translated sentence alone, never a
  // trailing raw exception.
  testWidgets('a failed request shows only the translated sentence', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showWebPushRequestFeedback(
              context,
              const WebPushRequestResult(WebPushRequestStatus.failed),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump();

    expect(find.text(l10n.webPushEnableFailed), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}
