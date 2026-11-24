import 'dart:async';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/services/gif_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/gif_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [GifService] whose every request is held until the test answers it.
class _HeldGifService extends GifService {
  final List<({String? query, int offset, Completer<List<GifModel>> gate})>
  calls = [];

  Future<List<GifModel>> _hold(String? query, int offset) {
    final gate = Completer<List<GifModel>>();
    calls.add((query: query, offset: offset, gate: gate));
    return gate.future;
  }

  @override
  Future<List<GifModel>> fetchTrending({int limit = 25, int offset = 0}) =>
      _hold(null, offset);

  @override
  Future<List<GifModel>> search(
    String query, {
    int limit = 25,
    int offset = 0,
  }) => _hold(query, offset);
}

List<GifModel> _gifs(String prefix, int n) => [
  for (var i = 0; i < n; i++)
    GifModel(
      id: '$prefix$i',
      previewUrl: 'https://gif.test/$prefix$i.gif',
      fullUrl: 'https://gif.test/full-$prefix$i.gif',
    ),
];

Finder _preview(String id) => find.byWidgetPredicate(
  (w) =>
      w is Image &&
      w.image is NetworkImage &&
      (w.image as NetworkImage).url == 'https://gif.test/$id.gif',
);

void main() {
  late _HeldGifService service;

  Future<void> pumpSheet(WidgetTester tester) async {
    service = _HeldGifService();
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataLight,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            height: 520,
            child: GifPickerSheet(service: service, onGifSelected: (_) {}),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> scrollToEnd(WidgetTester tester) async {
    // The grid builds lazily, so its extent grows as it is scrolled.
    for (var i = 0; i < 10; i++) {
      await tester.drag(find.byType(GridView), const Offset(0, -600));
      await tester.pump();
    }
  }

  testWidgets('a slow search cannot overwrite the trending the user cleared to', (
    tester,
  ) async {
    await pumpSheet(tester);
    service.calls[0].gate.complete(_gifs('t', 4));
    await settle(tester);

    await type(tester, 'cat');
    expect(service.calls[1].query, 'cat');

    await type(tester, '');
    expect(service.calls[2].query, isNull);

    // Trending answers first, then the stale search.
    service.calls[2].gate.complete(_gifs('u', 4));
    await settle(tester);
    service.calls[1].gate.complete(_gifs('c', 4));
    await settle(tester);

    expect(_preview('u0'), findsOneWidget);
    expect(_preview('c0'), findsNothing);
  });

  testWidgets('a load-more that started under the old query is dropped', (
    tester,
  ) async {
    await pumpSheet(tester);
    service.calls[0].gate.complete(_gifs('t', 25));
    await settle(tester);

    await scrollToEnd(tester);
    expect(service.calls[1].offset, 25);

    await type(tester, 'dog');
    expect(service.calls[2].query, 'dog');
    service.calls[2].gate.complete(_gifs('d', 4));
    await settle(tester);

    service.calls[1].gate.complete(_gifs('old', 25));
    await settle(tester);

    expect(_preview('d0'), findsOneWidget);
    expect(_preview('old0'), findsNothing);
    expect(find.byType(GridView), findsOneWidget);
    final grid = tester.widget<GridView>(find.byType(GridView));
    expect((grid.childrenDelegate as SliverChildBuilderDelegate).estimatedChildCount, 4);
  });

  testWidgets('a load-more that returned nothing is asked again at the same offset', (
    tester,
  ) async {
    await pumpSheet(tester);
    service.calls[0].gate.complete(_gifs('t', 25));
    await settle(tester);

    await scrollToEnd(tester);
    expect(service.calls[1].offset, 25);
    service.calls[1].gate.complete(<GifModel>[]);
    await settle(tester);

    await tester.drag(find.byType(GridView), const Offset(0, 4000));
    await tester.pump();
    await scrollToEnd(tester);

    expect(service.calls, hasLength(3));
    expect(service.calls[2].offset, 25);
  });
}
