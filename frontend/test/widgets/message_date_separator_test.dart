import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/widgets/message_date_separator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/l10n.dart';

/// A3-MSG-B-10: a day label counts calendar days, not elapsed 24-hour spans.
/// The 2026 spring clock change in Europe/Warsaw is Sunday 29 March; on a
/// machine in a zone without DST the cases still hold.
Future<String> _label(WidgetTester tester, DateTime date, DateTime now) async {
  late String out;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          out = MessageDateSeparator.dayLabel(context, date, now: now);
          return const SizedBox();
        },
      ),
    ),
  );
  return out;
}

void main() {
  final monday = DateTime(2026, 3, 30, 10);

  testWidgets('Sunday across the clock change is Yesterday', (tester) async {
    expect(
      await _label(tester, DateTime(2026, 3, 29, 12), monday),
      l10n.chatDateYesterday,
    );
  });

  testWidgets('Saturday across the clock change is a date, not Yesterday', (
    tester,
  ) async {
    final label = await _label(tester, DateTime(2026, 3, 28, 12), monday);
    expect(label, isNot(l10n.chatDateYesterday));
    expect(label, isNot(l10n.chatDateToday));
  });

  testWidgets('the same calendar day is Today', (tester) async {
    expect(
      await _label(tester, DateTime(2026, 3, 30, 0, 5), monday),
      l10n.chatDateToday,
    );
  });
}
