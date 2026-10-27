import 'package:fireplace/widgets/media/fullscreen_image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner reports: a swipe down dismissed a fullscreen VIDEO but did nothing on
/// a still image or GIF (2026-09-14), and moving to the next photo took a
/// close and a reopen (2026-10-27). `frontend/docs/composer-media.md` wants a
/// repro for behaviour here, so this is it — the drag paths, and the zoom /
/// pinch hand-offs that make them safe.
void main() {
  /// Opens a viewer over [pages] (each page shows its own key as text);
  /// changing [pages] afterwards changes the viewer's list in place, like a
  /// message arriving or expiring under it.
  Future<void> openViewer(
    WidgetTester tester, {
    ValueNotifier<List<String>>? pages,
    int initialIndex = 0,
  }) async {
    final keys = pages ?? ValueNotifier(['only']);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => Dialog(
                    backgroundColor: Colors.transparent,
                    insetPadding: EdgeInsets.zero,
                    child: ValueListenableBuilder<List<String>>(
                      valueListenable: keys,
                      builder: (_, current, _) => FullscreenImageViewer(
                        pageKeys: current,
                        initialIndex: initialIndex,
                        pageBuilder: (_, index) => ColoredBox(
                          color: Colors.red,
                          child: Center(child: Text(current[index])),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(FullscreenImageViewer), findsOneWidget);
  }

  final viewer = find.byType(FullscreenImageViewer);

  Future<void> pinchOut(WidgetTester tester) async {
    final center = tester.getCenter(viewer);
    final a = await tester.startGesture(center - const Offset(20, 0));
    final b = await tester.startGesture(center + const Offset(20, 0));
    await a.moveBy(const Offset(-120, 0));
    await b.moveBy(const Offset(120, 0));
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
  }

  /// The pinch a thumb makes: one finger rests, the other travels outward
  /// in small per-frame steps — far enough (500 px) that, were it a one-
  /// finger drag, it would turn the page.
  Future<void> thumbPinch(WidgetTester tester) async {
    final center = tester.getCenter(viewer);
    final still = await tester.startGesture(center - const Offset(300, 0));
    final moving = await tester.startGesture(center - const Offset(250, 0));
    for (var i = 0; i < 50; i++) {
      await moving.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await moving.up();
    await still.up();
    await tester.pumpAndSettle();
  }

  String counter(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('media-viewer-counter')))
      .data!;

  group('swipe down', () {
    testWidgets('dismisses the viewer', (tester) async {
      await openViewer(tester);

      // Past the 0.22-of-viewport threshold, released slowly (no fling).
      await tester.drag(viewer, const Offset(0, 400));
      await tester.pumpAndSettle();

      expect(viewer, findsNothing);
    });

    testWidgets('a downward fling dismisses even on a short travel', (
      tester,
    ) async {
      await openViewer(tester);

      await tester.fling(viewer, const Offset(0, 60), 1200);
      await tester.pumpAndSettle();

      expect(viewer, findsNothing);
    });

    testWidgets('a short slow drag snaps back and keeps the viewer', (
      tester,
    ) async {
      await openViewer(tester);

      await tester.drag(viewer, const Offset(0, 40));
      await tester.pumpAndSettle();

      expect(viewer, findsOneWidget);
    });

    testWidgets('an upward drag never dismisses', (tester) async {
      await openViewer(tester);

      await tester.drag(viewer, const Offset(0, -400));
      await tester.pumpAndSettle();

      expect(viewer, findsOneWidget);
    });

    // If the dismiss recognizer stayed armed while zoomed in, panning a
    // magnified photo would throw the viewer away mid-inspection.
    testWidgets('while zoomed in, dragging pans instead of dismissing', (
      tester,
    ) async {
      await openViewer(tester);
      await pinchOut(tester);

      await tester.drag(viewer, const Offset(0, 400));
      await tester.pumpAndSettle();

      expect(viewer, findsOneWidget);
    });
  });

  group('paging', () {
    testWidgets('a swipe left shows the next page, a swipe right the one '
        'before', (tester) async {
      await openViewer(tester, pages: ValueNotifier(['a', 'b', 'c']));
      expect(counter(tester), '1 / 3');

      await tester.drag(viewer, const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(counter(tester), '2 / 3');
      expect(find.text('b'), findsOneWidget);

      await tester.drag(viewer, const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(counter(tester), '1 / 3');
    });

    // The pager must not hijack the second finger of a pinch: with the
    // default latest-pointer strategy the spreading finger alone is a page
    // drag. A middle page, so a page turn either way would show.
    testWidgets('a two-finger pinch zooms and never turns the page', (
      tester,
    ) async {
      await openViewer(
        tester,
        pages: ValueNotifier(['a', 'b', 'c']),
        initialIndex: 1,
      );

      await thumbPinch(tester);

      expect(counter(tester), '2 / 3');
    });

    testWidgets('while zoomed in, a horizontal drag pans instead of paging', (
      tester,
    ) async {
      await openViewer(tester, pages: ValueNotifier(['a', 'b', 'c']));
      await pinchOut(tester);

      await tester.drag(viewer, const Offset(-500, 0));
      await tester.pumpAndSettle();

      expect(counter(tester), '1 / 3');
    });
  });

  group('the list changes under the open viewer', () {
    testWidgets('it stays on the page it shows when an earlier one goes', (
      tester,
    ) async {
      final pages = ValueNotifier(['a', 'b', 'c']);
      await openViewer(tester, pages: pages, initialIndex: 1);
      expect(find.text('b'), findsOneWidget);

      pages.value = ['b', 'c'];
      await tester.pumpAndSettle();

      expect(counter(tester), '1 / 2');
      expect(find.text('b'), findsOneWidget);
    });

    testWidgets('it closes when the page on screen goes (deleted, expired)', (
      tester,
    ) async {
      final pages = ValueNotifier(['a', 'b', 'c']);
      await openViewer(tester, pages: pages, initialIndex: 1);

      pages.value = ['a', 'c'];
      await tester.pumpAndSettle();

      expect(viewer, findsNothing);
    });

    testWidgets('a new page arriving does not move the viewer', (
      tester,
    ) async {
      final pages = ValueNotifier(['a', 'b']);
      await openViewer(tester, pages: pages, initialIndex: 1);

      pages.value = ['a', 'b', 'c'];
      await tester.pumpAndSettle();

      expect(counter(tester), '2 / 3');
      expect(find.text('b'), findsOneWidget);
    });
  });
}
