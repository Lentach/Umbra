import 'package:fireplace/widgets/media/fullscreen_image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A3-MSG-B-12: a swipe-down dismissal slides the stage off screen for
/// 80-220 ms before it pops. A tap (or Back) in that window already closes
/// the dialog; the slide's own pop must not then close the chat under it.
void main() {
  Future<void> openOverChat(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (chat) => Scaffold(
                  body: Column(
                    children: [
                      const Text('chat page'),
                      ElevatedButton(
                        onPressed: () => showDialog<void>(
                          context: chat,
                          builder: (_) => Dialog(
                            backgroundColor: Colors.transparent,
                            insetPadding: EdgeInsets.zero,
                            child: FullscreenImageViewer(
                              pageKeys: const ['only'],
                              pageBuilder: (_, _) =>
                                  const ColoredBox(color: Colors.red),
                            ),
                          ),
                        ),
                        child: const Text('open'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(FullscreenImageViewer), findsOneWidget);
  }

  testWidgets('a tap during the dismiss slide does not also close the chat', (
    tester,
  ) async {
    await openOverChat(tester);
    final viewer = find.byType(FullscreenImageViewer);

    await tester.fling(viewer, const Offset(0, 300), 1200);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.tapAt(tester.getCenter(viewer));
    await tester.pumpAndSettle();

    expect(viewer, findsNothing);
    expect(find.text('chat page'), findsOneWidget);
  });

  testWidgets('Back during the dismiss slide does not also close the chat', (
    tester,
  ) async {
    await openOverChat(tester);
    final viewer = find.byType(FullscreenImageViewer);

    await tester.fling(viewer, const Offset(0, 300), 1200);
    await tester.pump(const Duration(milliseconds: 10));
    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await tester.pumpAndSettle();

    expect(viewer, findsNothing);
    expect(find.text('chat page'), findsOneWidget);
  });
}
