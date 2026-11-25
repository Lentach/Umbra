import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/anti_quantum_note_link.dart';
import 'package:fireplace/widgets/message/anti_quantum_note_reveal_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/l10n.dart';

const _hex = '0123456789abcdef0123456789abcdef';
final _key = base64Url.encode(Uint8List.fromList(List.filled(32, 7)));

AntiQuantumNoteLink _link({int? expiryMs, String key = ''}) {
  final k = key.isEmpty ? _key : key;
  final tail = expiryMs == null ? '' : '&e=$expiryMs';
  return AntiQuantumNoteLink(
    url: 'https://fireplace.ignorelist.com/note/$_hex#$k$tail',
    token: _hex,
    expiresAt:
        expiryMs == null ? null : DateTime.fromMillisecondsSinceEpoch(expiryMs),
  );
}

int _futureMs() =>
    DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch;
int _pastMs() =>
    DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch;

/// Opens the sheet through the production entry point so the real glass
/// sheet route is exercised, mirroring disappearing_timer_sheet_test.dart.
Future<void> _openSheet(
  WidgetTester tester, {
  required AntiQuantumNoteLink link,
  NoteRevealAttempt? attempt,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: RpgTheme.themeDataLight,
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAntiQuantumNoteRevealSheet(
              context,
              link: link,
              attempt: attempt,
            ),
            child: const Text('Open note'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open note'));
  await tester.pumpAndSettle();
}

const _confirmKey = Key('note-reveal-confirm');
const _revealKey = Key('note-reveal-button');
const _cancelKey = Key('note-reveal-cancel');
const _loadingKey = Key('note-reveal-loading');
const _plaintextKey = Key('note-reveal-plaintext');
const _destroyedKey = Key('note-reveal-destroyed');
const _expiredKey = Key('note-reveal-expired');
const _corruptKey = Key('note-reveal-corrupt');
const _invalidKey = Key('note-reveal-invalid-link');
const _networkKey = Key('note-reveal-network-error');
const _retryKey = Key('note-reveal-retry');

void main() {
  testWidgets('opens on the confirm step and NEVER auto-reveals', (
    tester,
  ) async {
    var attempts = 0;
    await _openSheet(
      tester,
      link: _link(expiryMs: _futureMs()),
      attempt: () async {
        attempts++;
        return const NoteRevealed('secret');
      },
    );

    expect(find.byKey(_confirmKey), findsOneWidget);
    expect(find.byKey(_revealKey), findsOneWidget);
    expect(attempts, 0, reason: 'reveal is destructive and must wait for tap');
    expect(find.byKey(_plaintextKey), findsNothing);
  });

  testWidgets('cancel closes without burning: attempt never called', (
    tester,
  ) async {
    var attempts = 0;
    await _openSheet(
      tester,
      link: _link(expiryMs: _futureMs()),
      attempt: () async {
        attempts++;
        return const NoteRevealed('secret');
      },
    );

    await tester.tap(find.byKey(_cancelKey));
    await tester.pumpAndSettle();

    expect(attempts, 0);
    expect(find.byKey(_confirmKey), findsNothing);
    expect(find.text('Open note'), findsOneWidget);
  });

  testWidgets('confirm → loading → revealed selectable plaintext', (
    tester,
  ) async {
    final gate = Completer<NoteRevealOutcome>();
    await _openSheet(
      tester,
      link: _link(expiryMs: _futureMs()),
      attempt: () => gate.future,
    );

    await tester.tap(find.byKey(_revealKey));
    await tester.pump();
    expect(find.byKey(_loadingKey), findsOneWidget);
    // The outgoing confirm child fades for 220ms; past it, only loading stays.
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(_loadingKey), findsOneWidget);
    expect(find.byKey(_confirmKey), findsNothing);

    gate.complete(const NoteRevealed('the launch code is 42'));
    await tester.pumpAndSettle();

    expect(find.byKey(_loadingKey), findsNothing);
    expect(find.byKey(_plaintextKey), findsOneWidget);
    final selectable =
        tester.widget<SelectableText>(find.byKey(_plaintextKey));
    expect(selectable.data, 'the launch code is 42');
  });

  testWidgets('gone before the clock ran out shows DESTROYED (it was read)', (
    tester,
  ) async {
    await _openSheet(
      tester,
      link: _link(expiryMs: _futureMs()),
      attempt: () async => const NoteRevealGone(),
    );

    await tester.tap(find.byKey(_revealKey));
    await tester.pumpAndSettle();

    expect(find.byKey(_destroyedKey), findsOneWidget);
    expect(find.byKey(_expiredKey), findsNothing);
  });

  testWidgets('gone on a legacy link without e= also shows destroyed', (
    tester,
  ) async {
    await _openSheet(
      tester,
      link: _link(),
      attempt: () async => const NoteRevealGone(),
    );

    await tester.tap(find.byKey(_revealKey));
    await tester.pumpAndSettle();

    expect(find.byKey(_destroyedKey), findsOneWidget);
  });

  testWidgets('clock-dead link opens straight in EXPIRED, no confirm, no burn',
      (tester) async {
    var attempts = 0;
    await _openSheet(
      tester,
      link: _link(expiryMs: _pastMs()),
      attempt: () async {
        attempts++;
        return const NoteRevealGone();
      },
    );

    expect(find.byKey(_expiredKey), findsOneWidget);
    expect(find.byKey(_confirmKey), findsNothing);
    expect(find.byKey(_revealKey), findsNothing);
    expect(attempts, 0);
  });

  testWidgets('corrupt outcome shows the distinct corrupt state', (
    tester,
  ) async {
    await _openSheet(
      tester,
      link: _link(expiryMs: _futureMs()),
      attempt: () async => const NoteRevealCorrupt(),
    );

    await tester.tap(find.byKey(_revealKey));
    await tester.pumpAndSettle();

    expect(find.byKey(_corruptKey), findsOneWidget);
  });

  testWidgets('link with a broken fragment key opens in INVALID LINK '
      'and can never reach the destructive attempt', (tester) async {
    var attempts = 0;
    await _openSheet(
      tester,
      // 8-byte key: decodes fine but fails the 32-byte pre-flight.
      link: _link(key: base64Url.encode(List.filled(8, 1))),
      attempt: () async {
        attempts++;
        return const NoteRevealed('never');
      },
    );

    expect(find.byKey(_invalidKey), findsOneWidget);
    expect(find.byKey(_revealKey), findsNothing);
    expect(attempts, 0);
  });

  testWidgets('network failure shows the distinct error state; retry works', (
    tester,
  ) async {
    var attempts = 0;
    await _openSheet(
      tester,
      link: _link(expiryMs: _futureMs()),
      attempt: () async {
        attempts++;
        if (attempts == 1) throw Exception('offline');
        return const NoteRevealed('after retry');
      },
    );

    await tester.tap(find.byKey(_revealKey));
    await tester.pumpAndSettle();

    expect(find.byKey(_networkKey), findsOneWidget);
    expect(find.byKey(_destroyedKey), findsNothing);
    expect(find.byKey(_retryKey), findsOneWidget);

    await tester.tap(find.byKey(_retryKey));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    final selectable =
        tester.widget<SelectableText>(find.byKey(_plaintextKey));
    expect(selectable.data, 'after retry');
  });

  testWidgets('closing any state pops back to the chat instantly', (
    tester,
  ) async {
    await _openSheet(
      tester,
      link: _link(expiryMs: _futureMs()),
      attempt: () async => const NoteRevealed('secret'),
    );

    await tester.tap(find.byKey(_revealKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_plaintextKey), findsOneWidget);

    await tester.tap(find.byKey(const Key('note-reveal-close')));
    await tester.pumpAndSettle();

    expect(find.byKey(_plaintextKey), findsNothing);
    expect(find.text('Open note'), findsOneWidget);
  });

  testWidgets('a second tap while the reveal runs sends no second destructive '
      'request, and the first answer is what the reader sees', (tester) async {
    var attempts = 0;
    final first = Completer<NoteRevealOutcome>();
    await _openSheet(
      tester,
      link: _link(expiryMs: _futureMs()),
      attempt: () {
        attempts++;
        // The server deletes on the first reveal, so a second one is "gone".
        return attempts == 1
            ? first.future
            : Future.value(const NoteRevealGone());
      },
    );

    final button = tester.getCenter(find.byKey(_revealKey));
    await tester.tapAt(button);
    await tester.pump();
    // Inside the 220 ms cross-fade the old button is still on screen.
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(button);
    await tester.pump();

    first.complete(const NoteRevealed('read me once'));
    await tester.pumpAndSettle();

    expect(attempts, 1);
    expect(find.byKey(_destroyedKey), findsNothing);
    final selectable =
        tester.widget<SelectableText>(find.byKey(_plaintextKey));
    expect(selectable.data, 'read me once');
  });

  group('while decrypting the burned note cannot be closed away', () {
    Future<Completer<NoteRevealOutcome>> openRevealing(
      WidgetTester tester,
    ) async {
      final gate = Completer<NoteRevealOutcome>();
      await _openSheet(
        tester,
        link: _link(expiryMs: _futureMs()),
        attempt: () => gate.future,
      );
      await tester.tap(find.byKey(_revealKey));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(_loadingKey), findsOneWidget);
      return gate;
    }

    Future<void> expectStillShowsNote(
      WidgetTester tester,
      Completer<NoteRevealOutcome> gate,
    ) async {
      // The spinner never settles: pump a fixed span, not pumpAndSettle.
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(_loadingKey), findsOneWidget);
      gate.complete(const NoteRevealed('burned and shown'));
      await tester.pumpAndSettle();
      final selectable =
          tester.widget<SelectableText>(find.byKey(_plaintextKey));
      expect(selectable.data, 'burned and shown');
    }

    testWidgets('the X is not offered', (tester) async {
      final gate = await openRevealing(tester);
      expect(find.byKey(const Key('note-reveal-close')), findsNothing);
      gate.complete(const NoteRevealed('x'));
      await tester.pumpAndSettle();
    });

    testWidgets('a tap outside keeps the sheet', (tester) async {
      final gate = await openRevealing(tester);
      await tester.tapAt(const Offset(20, 20));
      await expectStillShowsNote(tester, gate);
    });

    testWidgets('the back button keeps the sheet', (tester) async {
      final gate = await openRevealing(tester);
      await tester.binding.handlePopRoute();
      await expectStillShowsNote(tester, gate);
    });

    testWidgets('a swipe down keeps the sheet', (tester) async {
      final gate = await openRevealing(tester);
      await tester.fling(find.byKey(_loadingKey), const Offset(0, 400), 2000);
      await expectStillShowsNote(tester, gate);
    });
  });

  group('an attempt whose outcome is unknown', () {
    testWidgets('says the note may already be destroyed, not just "no server"', (
      tester,
    ) async {
      await _openSheet(
        tester,
        link: _link(expiryMs: _futureMs()),
        attempt: () async => throw TimeoutException('lost response'),
      );
      await tester.tap(find.byKey(_revealKey));
      await tester.pumpAndSettle();

      expect(find.byKey(_networkKey), findsOneWidget);
      expect(
        find.text(l10n.antiQuantumNoteRevealUnknownOutcomeBody),
        findsOneWidget,
      );
    });

    testWidgets('a retry that finds the note gone does NOT claim someone else '
        'read it', (tester) async {
      var attempts = 0;
      await _openSheet(
        tester,
        link: _link(expiryMs: _futureMs()),
        attempt: () async {
          attempts++;
          // The first POST burned the note; only its answer was lost.
          if (attempts == 1) throw TimeoutException('lost response');
          return const NoteRevealGone();
        },
      );
      await tester.tap(find.byKey(_revealKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_retryKey));
      await tester.pumpAndSettle();

      expect(find.byKey(_destroyedKey), findsNothing);
      expect(find.text(l10n.antiQuantumNoteRevealDestroyedBody), findsNothing);
      expect(find.byKey(const Key('note-reveal-maybe-burned')), findsOneWidget);
      expect(
        find.text(l10n.antiQuantumNoteRevealMaybeBurnedBody),
        findsOneWidget,
      );
    });

    testWidgets('a note gone on the first attempt still reads "already read"', (
      tester,
    ) async {
      await _openSheet(
        tester,
        link: _link(expiryMs: _futureMs()),
        attempt: () async => const NoteRevealGone(),
      );
      await tester.tap(find.byKey(_revealKey));
      await tester.pumpAndSettle();

      expect(find.byKey(_destroyedKey), findsOneWidget);
      expect(find.byKey(const Key('note-reveal-maybe-burned')), findsNothing);
    });
  });
}
