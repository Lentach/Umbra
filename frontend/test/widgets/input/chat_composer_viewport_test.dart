import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/widgets/input/chat_composer_viewport.dart';
import 'package:fireplace/widgets/input/composer_keyboard_signals.dart';
import 'package:fireplace/utils/web_keyboard_inset.dart';

void main() {
  // Every global the viewport reads is a process-wide singleton; a leaked
  // value silently drives later tests. Reset all of them plus the shared-source
  // override after each test.
  tearDown(() {
    composerKeyboardCollapseGuard.value = false;
    setSharedKeyboardInsetSourceForTest(null);
  });

  testWidgets('applies list bottom padding at least composer height', (
    tester,
  ) async {
    double? capturedPadding;

    await tester.pumpWidget(
      MaterialApp(
        home: ChatComposerViewport(
          messageListBuilder: (bottom) {
            capturedPadding = bottom;
            return ListView(
              reverse: true,
              padding: EdgeInsets.only(bottom: bottom),
              children: const [Text('msg')],
            );
          },
          composer: const SizedBox(
            height: 48,
            child: ColoredBox(color: Colors.red),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(capturedPadding, isNotNull);
    expect(capturedPadding!, greaterThanOrEqualTo(48));
  });

  testWidgets('increases list bottom padding when composer grows', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: _GrowingComposerHarness()));
    await tester.pumpAndSettle();

    final listViewBefore = tester.widget<ListView>(find.byType(ListView));
    final paddingBefore = listViewBefore.padding as EdgeInsets;
    expect(paddingBefore.bottom, greaterThanOrEqualTo(48));

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();

    final listViewAfter = tester.widget<ListView>(find.byType(ListView));
    final paddingAfter = listViewAfter.padding as EdgeInsets;
    expect(paddingAfter.bottom, greaterThan(paddingBefore.bottom));
  });

  testWidgets('genuine dismiss collapses the keyboard inset immediately', (
    tester,
  ) async {
    composerKeyboardCollapseGuard.value = false;
    var padding = 0.0;
    await tester.pumpWidget(_insetHarness(300, onPadding: (p) => padding = p));
    await tester.pumpAndSettle();
    expect(padding, greaterThanOrEqualTo(48 + 300));

    await tester.pumpWidget(_insetHarness(0, onPadding: (p) => padding = p));
    await tester.pump(); // no timer wait — collapse must be immediate
    expect(padding, lessThan(48 + 300));
    expect(padding, greaterThanOrEqualTo(48));
  });
  testWidgets(
    'single-step dismiss eases the composer PAINT down while layout collapses',
    (tester) async {
      composerKeyboardCollapseGuard.value = false;
      var padding = 0.0;
      await tester.pumpWidget(_insetHarness(300, onPadding: (p) => padding = p));
      await tester.pumpAndSettle();
      final screenBottom = tester.getSize(find.byType(MaterialApp)).height;
      final raisedBottom = tester.getBottomLeft(find.byKey(_composerKey)).dy;
      expect(raisedBottom, moreOrLessEquals(screenBottom - 300, epsilon: 0.01));

      await tester.pumpWidget(_insetHarness(0, onPadding: (p) => padding = p));
      // Layout half: padding collapses in the SAME frame (Symptom B guard)...
      expect(padding, moreOrLessEquals(48, epsilon: 0.01));
      // ...paint half: the composer still PAINTS at the old raised position.
      expect(
        tester.getBottomLeft(find.byKey(_composerKey)).dy,
        moreOrLessEquals(raisedBottom, epsilon: 0.01),
      );

      // Mid-slide: strictly between the raised and resting positions.
      await tester.pump(const Duration(milliseconds: 100));
      final midway = tester.getBottomLeft(find.byKey(_composerKey)).dy;
      expect(midway, greaterThan(raisedBottom));
      expect(midway, lessThan(screenBottom));

      // Slide over (~200ms): painted exactly at the layout position.
      await tester.pumpAndSettle();
      expect(
        tester.getBottomLeft(find.byKey(_composerKey)).dy,
        moreOrLessEquals(screenBottom, epsilon: 0.01),
      );
    },
  );

  testWidgets('reduce motion skips the dismiss slide entirely', (tester) async {
    composerKeyboardCollapseGuard.value = false;
    var padding = 0.0;
    await tester.pumpWidget(
      _insetHarness(300, onPadding: (p) => padding = p, reduceMotion: true),
    );
    await tester.pumpAndSettle();
    final screenBottom = tester.getSize(find.byType(MaterialApp)).height;

    await tester.pumpWidget(
      _insetHarness(0, onPadding: (p) => padding = p, reduceMotion: true),
    );
    // Instant: painted at the collapsed layout position in the same frame.
    expect(
      tester.getBottomLeft(find.byKey(_composerKey)).dy,
      moreOrLessEquals(screenBottom, epsilon: 0.01),
    );
    expect(padding, moreOrLessEquals(48, epsilon: 0.01));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('send bounce defers the collapse for the debounce window', (
    tester,
  ) async {
    composerKeyboardCollapseGuard.value = true;
    var padding = 0.0;
    await tester.pumpWidget(_insetHarness(300, onPadding: (p) => padding = p));
    await tester.pumpAndSettle();
    expect(padding, greaterThanOrEqualTo(48 + 300));

    await tester.pumpWidget(_insetHarness(0, onPadding: (p) => padding = p));
    await tester.pump(const Duration(milliseconds: 100));
    expect(padding, greaterThanOrEqualTo(48 + 300)); // deferred: no drop/flash

    await tester.pump(const Duration(milliseconds: 500));
    expect(padding, lessThan(48 + 300)); // collapsed after the 450ms debounce
  });

  testWidgets(
    'active shared source inset drives layout while MediaQuery inset stays 0',
    (tester) async {
      // iOS WebKit reports MediaQuery.viewInsets.bottom = 0 with the keyboard
      // up, so the composer must follow the visualViewport-derived shared
      // source instead (the max(flutterInset, sharedInset) branch).
      final fake = _FakeInsetSource(350);
      setSharedKeyboardInsetSourceForTest(fake);
      var padding = 0.0;
      await tester.pumpWidget(_insetHarness(0, onPadding: (p) => padding = p));
      await tester.pumpAndSettle();

      expect(_composerBottom(tester), moreOrLessEquals(350, epsilon: 0.01));
      // List clearance folds the same inset in on top of the composer height.
      expect(padding, greaterThanOrEqualTo(48 + 350 - 0.01));
    },
  );

  testWidgets(
    'bounce self-correct: a keyboard returning within the debounce window never drops the composer',
    (tester) async {
      composerKeyboardCollapseGuard.value = true;
      await tester.pumpWidget(_insetHarness(300, onPadding: (_) {}));
      await tester.pumpAndSettle();
      expect(_composerBottom(tester), moreOrLessEquals(300, epsilon: 0.01));

      // Keyboard blips down (iOS send-button bounce); guard armed -> deferred.
      await tester.pumpWidget(_insetHarness(0, onPadding: (_) {}));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_composerBottom(tester), moreOrLessEquals(300, epsilon: 0.01));

      // Keyboard returns before the 450ms window elapses.
      await tester.pumpWidget(_insetHarness(300, onPadding: (_) {}));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_composerBottom(tester), moreOrLessEquals(300, epsilon: 0.01));

      // The deferred collapse timer now fires, but the live inset re-grows in
      // the same build: the composer must never have dropped below 300.
      await tester.pump(const Duration(milliseconds: 500));
      expect(_composerBottom(tester), moreOrLessEquals(300, epsilon: 0.01));
    },
  );

  group('composerBottomPanelPinned', () {
    // composerBottomPanelPinned is a process-global singleton shared by every
    // ChatComposerViewport. A leaked `true` would silently pin later composer
    // tests to bottom:0; always restore the default false after each test.
    tearDown(() => composerBottomPanelPinned.value = false);

    testWidgets(
        'unpinned composer sits at the keyboard inset; pinning drops it to bottom:0',
        (tester) async {
      composerBottomPanelPinned.value = false;
      await tester.pumpWidget(_pinHarness(300));
      await tester.pumpAndSettle();

      expect(_pinComposerBottom(tester), moreOrLessEquals(300, epsilon: 0.01));

      composerBottomPanelPinned.value = true;
      await tester.pump();

      expect(_pinComposerBottom(tester), moreOrLessEquals(0, epsilon: 0.01));
    });

    testWidgets(
        'pinning shrinks the list bottom padding by exactly the keyboard inset',
        (tester) async {
      composerBottomPanelPinned.value = false;
      var padding = 0.0;
      await tester.pumpWidget(_pinHarness(300, onPadding: (p) => padding = p));
      await tester.pumpAndSettle();
      final unpinnedPadding = padding;

      composerBottomPanelPinned.value = true;
      await tester.pump();
      final pinnedPadding = padding;

      // The pin removes the keyboard inset from the composer position, so the
      // clearance handed to the message list drops by exactly that inset
      // (300), independent of the measured composer height.
      expect(
        unpinnedPadding - pinnedPadding,
        moreOrLessEquals(300, epsilon: 0.01),
      );
    });

    testWidgets(
        'with no keyboard inset the composer stays at bottom:0 whether pinned or not',
        (tester) async {
      composerBottomPanelPinned.value = false;
      await tester.pumpWidget(_pinHarness(0));
      await tester.pumpAndSettle();
      expect(_pinComposerBottom(tester), moreOrLessEquals(0, epsilon: 0.01));

      composerBottomPanelPinned.value = true;
      await tester.pump();
      expect(_pinComposerBottom(tester), moreOrLessEquals(0, epsilon: 0.01));
    });
  });
}

class _GrowingComposerHarness extends StatefulWidget {
  const _GrowingComposerHarness();

  @override
  State<_GrowingComposerHarness> createState() =>
      _GrowingComposerHarnessState();
}

class _GrowingComposerHarnessState extends State<_GrowingComposerHarness> {
  double _composerHeight = 48;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ChatComposerViewport(
        messageListBuilder: (bottom) => ListView(
          reverse: true,
          padding: EdgeInsets.only(bottom: bottom),
          children: const [Text('msg')],
        ),
        composer: SizedBox(
          height: _composerHeight,
          child: const ColoredBox(color: Colors.red),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _composerHeight = 120),
        child: const Icon(Icons.expand_more),
      ),
    );
  }
}

Widget _insetHarness(
  double inset, {
  required ValueChanged<double> onPadding,
  bool reduceMotion = false,
}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          viewInsets: EdgeInsets.only(bottom: inset),
          disableAnimations: reduceMotion,
        ),
        child: Scaffold(
          // Production uses resizeToAvoidBottomInset:false so the composer
          // viewport owns the keyboard inset; default true would let Scaffold
          // consume the bottom inset before the viewport reads it.
          resizeToAvoidBottomInset: false,
          body: ChatComposerViewport(
            messageListBuilder: (bottom) {
              onPadding(bottom);
              return ListView(
                reverse: true,
                padding: EdgeInsets.only(bottom: bottom),
                children: const [Text('m')],
              );
            },
            composer: const SizedBox(
              key: _composerKey,
              height: 48,
              child: ColoredBox(color: Color(0xFFFF0000)),
            ),
          ),
        ),
      ),
    ),
  );
}

const _composerKey = Key('viewport-test-composer');

double _composerBottom(WidgetTester tester) {
  final positioned = tester.widget<Positioned>(
    find
        .ancestor(
          of: find.byKey(_composerKey),
          matching: find.byType(Positioned),
        )
        .first,
  );
  return positioned.bottom!;
}

/// Fake iOS-WebKit shared inset source: [isActive] true with a caller-driven
/// inset, so the viewport's visualViewport branch is exercisable on the VM.
class _FakeInsetSource implements KeyboardInsetSource {
  _FakeInsetSource(double initial) : _inset = ValueNotifier<double>(initial);

  final ValueNotifier<double> _inset;

  @override
  ValueNotifier<double> get inset => _inset;

  @override
  bool get isActive => true;

  @override
  void dispose() {}
}

// Key on the composer child so the composer's own Positioned can be located via
// find.ancestor (the message list's Positioned.fill is a sibling, not an
// ancestor, and the diagnostics overlay never mounts off iOS WebKit).
const _pinComposerKey = Key('pin-test-composer');

double _pinComposerBottom(WidgetTester tester) {
  final positioned = tester.widget<Positioned>(
    find
        .ancestor(
          of: find.byKey(_pinComposerKey),
          matching: find.byType(Positioned),
        )
        .first,
  );
  return positioned.bottom!;
}

Widget _pinHarness(double inset, {ValueChanged<double>? onPadding}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(viewInsets: EdgeInsets.only(bottom: inset)),
        child: Scaffold(
          // Production uses resizeToAvoidBottomInset:false so the composer
          // viewport owns the keyboard inset; default true would let Scaffold
          // consume the bottom inset before the viewport reads it.
          resizeToAvoidBottomInset: false,
          body: ChatComposerViewport(
            messageListBuilder: (bottom) {
              onPadding?.call(bottom);
              return ListView(
                reverse: true,
                padding: EdgeInsets.only(bottom: bottom),
                children: const [Text('m')],
              );
            },
            composer: const SizedBox(
              key: _pinComposerKey,
              height: 48,
              child: ColoredBox(color: Color(0xFFFF0000)),
            ),
          ),
        ),
      ),
    ),
  );
}
