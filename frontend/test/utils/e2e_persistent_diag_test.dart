import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fireplace/utils/e2e_diag_log.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';

/// Tests for the durable failure-class diagnostic store [E2ePersistentDiag].
///
/// It mirrors events into the in-memory [E2eDiagLog] ring AND persists a
/// capped tail to SharedPreferences (key `e2e_diag_persist_v1`) so failure
/// events survive ring eviction and app restart.
///
/// Static-state caveat: `E2ePersistentDiag` holds static `_cache`/`_prefs`
/// and `E2eDiagLog` holds a static ring. Both are reset between tests by
/// clearing them and re-`init()`-ing against a fresh mock store in `setUp`.
/// The persistence write in `record` is fire-and-forget (`.ignore()`), so we
/// pump the event queue before reading the raw prefs list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const persistKey = 'e2e_diag_persist_v1';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await E2ePersistentDiag.clear();
    E2eDiagLog.clear();
    await E2ePersistentDiag.init();
  });

  tearDown(() async {
    await E2ePersistentDiag.clear();
    E2eDiagLog.clear();
  });

  test('record then entries contains a line with the step name and data',
      () {
    E2ePersistentDiag.record('Decryption failed', {'msgId': 42});

    expect(E2ePersistentDiag.entries, hasLength(1));
    final line = E2ePersistentDiag.entries.single;
    expect(line, contains('Decryption failed'));
    expect(line, contains('42'));
    // Date-stamped MM-DD HH:MM:SS prefix with the "step | {data}" tail.
    expect(
      line,
      matches(RegExp(r'^\d{2}-\d{2} \d{2}:\d{2}:\d{2} Decryption failed \| ')),
    );
  });

  test('record also mirrors into E2eDiagLog.entries', () {
    E2ePersistentDiag.record('Reset session', {'peer': 7});

    expect(E2eDiagLog.entries, hasLength(1));
    final mirrored = E2eDiagLog.entries.single;
    expect(mirrored, contains('Reset session'));
    expect(mirrored, contains('7'));
    // The persistent store also holds it.
    expect(E2ePersistentDiag.entries.single, contains('Reset session'));
  });

  test('cap keeps exactly 80 entries, newest retained and oldest dropped',
      () {
    for (var i = 0; i < 120; i++) {
      E2ePersistentDiag.record('evt', {'n': i});
    }

    expect(E2ePersistentDiag.entries, hasLength(80));
    // Oldest 40 (n 0..39) evicted; newest (n 119) retained.
    expect(E2ePersistentDiag.entries.first, contains('40'));
    expect(E2ePersistentDiag.entries.last, contains('119'));
    for (final line in E2ePersistentDiag.entries) {
      expect(line, contains('evt'));
    }
    // No trace of a dropped early entry remains.
    expect(
      E2ePersistentDiag.entries.any((l) => l.contains('{n: 0}')),
      isFalse,
    );
  });

  test('init() reloads a pre-seeded SharedPreferences list into the cache',
      () async {
    // Simulate a restart: the persisted store already holds prior events, the
    // in-memory cache is empty. init() must hydrate the cache from storage.
    final seeded = <String>[
      '07-07 10:00:00 Decryption failed | {msgId: 1}',
      '07-07 10:00:01 Reset session | {peer: 2}',
    ];
    SharedPreferences.setMockInitialValues({persistKey: seeded});
    await E2ePersistentDiag.clear();
    // clear() empties the persisted list too, so re-seed after clearing the
    // static cache to model a genuine cold start with the old prefs intact.
    SharedPreferences.setMockInitialValues({persistKey: seeded});

    await E2ePersistentDiag.init();

    expect(E2ePersistentDiag.entries, equals(seeded));
  });

  test('record writes through to SharedPreferences (raw getStringList lands)',
      () async {
    E2ePersistentDiag.record('Decryption failed', {'msgId': 99});
    E2ePersistentDiag.record('Reset session', {'peer': 3});

    // The write is fire-and-forget; let the microtask/event queue drain.
    await Future<void>.delayed(Duration.zero);

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(persistKey);
    expect(raw, isNotNull);
    expect(raw, hasLength(2));
    expect(raw!.first, contains('Decryption failed'));
    expect(raw.first, contains('99'));
    expect(raw.last, contains('Reset session'));
    expect(raw.last, contains('3'));
    // The persisted copy matches the in-memory cache view.
    expect(raw, equals(E2ePersistentDiag.entries));
  });

  test('entries getter returns an unmodifiable view', () {
    E2ePersistentDiag.record('evt', {'n': 1});
    expect(
      () => E2ePersistentDiag.entries.add('tampered'),
      throwsUnsupportedError,
    );
  });

  test('clear() empties both the cache and the persisted list', () async {
    E2ePersistentDiag.record('Decryption failed', {'msgId': 5});
    await Future<void>.delayed(Duration.zero);

    expect(E2ePersistentDiag.entries, isNotEmpty);

    await E2ePersistentDiag.clear();

    expect(E2ePersistentDiag.entries, isEmpty);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(persistKey), isEmpty);
  });
  // recordDeduped — the DECRYPT_DECISION repeat-dedupe
  // (docs/design/terminal-duplicate-retirement.md §4). The durable log is the
  // owner's only field evidence and is cap-80: a known-terminal row re-burning
  // a slot every boot evicts real failures. These pin the dedupe's exact
  // boundaries — what it MUST suppress, what it must NEVER suppress, and that
  // suppression is never permanent.

  List<String> matchFor(int msgId, String kind) => [
    '{msgId: $msgId,',
    ' kind: $kind,',
  ];

  Map<String, dynamic> decision(int msgId, String kind) => {
    'msgId': msgId,
    'senderId': 2,
    'kind': kind,
    'rule': kind,
  };

  test('an identical (msgId, kind) repeat is routed to the ring only',
      () async {
    E2ePersistentDiag.recordDeduped(
      'DECRYPT_DECISION',
      decision(19102, 'duplicate'),
      matchAll: matchFor(19102, 'duplicate'),
    );
    final ringBefore = E2eDiagLog.entries.length;
    E2ePersistentDiag.recordDeduped(
      'DECRYPT_DECISION',
      decision(19102, 'duplicate'),
      matchAll: matchFor(19102, 'duplicate'),
    );

    expect(
      E2ePersistentDiag.entries
          .where((e) => e.contains('DECRYPT_DECISION'))
          .length,
      1,
      reason: 'the repeat adds no evidence and must not burn a durable slot',
    );
    expect(E2eDiagLog.entries.length, greaterThan(ringBefore),
        reason: 'the repeat stays visible in the ring, full payload');
  });

  test('§5.7 a kind CHANGE for the same msgId still records durably',
      () async {
    E2ePersistentDiag.recordDeduped(
      'DECRYPT_DECISION',
      decision(19102, 'duplicate'),
      matchAll: matchFor(19102, 'duplicate'),
    );
    E2ePersistentDiag.recordDeduped(
      'DECRYPT_DECISION',
      decision(19102, 'badMac'),
      matchAll: matchFor(19102, 'badMac'),
    );

    expect(
      E2ePersistentDiag.entries
          .where((e) => e.contains('DECRYPT_DECISION'))
          .length,
      2,
      reason: 'a different kind for the same row is NEW evidence',
    );
  });

  test('§5.9 a shorter id never dedupes against a longer id it prefixes',
      () async {
    E2ePersistentDiag.recordDeduped(
      'DECRYPT_DECISION',
      decision(19102, 'duplicate'),
      matchAll: matchFor(19102, 'duplicate'),
    );
    E2ePersistentDiag.recordDeduped(
      'DECRYPT_DECISION',
      decision(1910, 'duplicate'),
      matchAll: matchFor(1910, 'duplicate'),
    );

    expect(
      E2ePersistentDiag.entries
          .where((e) => e.contains('DECRYPT_DECISION'))
          .length,
      2,
      reason: 'the trailing delimiter in the match substring is load-bearing: '
          'without it, id 1910 would match the 19102 line and its first-ever '
          'durable would be falsely suppressed',
    );
  });

  test('a different step with coincidentally matching payload never dedupes',
      () async {
    E2ePersistentDiag.record('LEDGER_RECORD_LOST', {
      'msgId': 19102,
      'kind': 'duplicate',
    });
    E2ePersistentDiag.recordDeduped(
      'DECRYPT_DECISION',
      decision(19102, 'duplicate'),
      matchAll: matchFor(19102, 'duplicate'),
    );

    expect(
      E2ePersistentDiag.entries
          .where((e) => e.contains('DECRYPT_DECISION'))
          .length,
      1,
      reason: 'dedupe keys on the step name too, not payload alone',
    );
  });

  test('§5.8 self-heal: eviction past the cap re-arms the durable', () async {
    E2ePersistentDiag.recordDeduped(
      'DECRYPT_DECISION',
      decision(19102, 'duplicate'),
      matchAll: matchFor(19102, 'duplicate'),
    );
    // Push the original entry out of the cap-80 window.
    for (var i = 0; i < E2ePersistentDiag.kMaxEntries; i++) {
      E2ePersistentDiag.record('SEND_FAIL', {'i': i});
    }
    expect(
      E2ePersistentDiag.entries.where((e) => e.contains('DECRYPT_DECISION')),
      isEmpty,
    );

    E2ePersistentDiag.recordDeduped(
      'DECRYPT_DECISION',
      decision(19102, 'duplicate'),
      matchAll: matchFor(19102, 'duplicate'),
    );

    expect(
      E2ePersistentDiag.entries
          .where((e) => e.contains('DECRYPT_DECISION'))
          .length,
      1,
      reason: 'suppression is never permanent — the dedupe state IS the '
          'cache, so rotation re-arms the event',
    );
  });

  group('E2eDiagLog', () {
    test('groups repeated failures by peer and kind', () {
      final groups = E2eDiagLog.groupedFailures([
        '04:17:01 DECRYPT_DECISION | {peerId: 52, kind: duplicate}',
        '04:17:02 DECRYPT_DECISION | {peerId: 52, kind: duplicate}',
        '04:18:02 SEND_FAIL | {recipientId: 8}',
      ]);

      expect(groups, contains('peer 52 · duplicate · 2 messages'));
      expect(groups, contains('peer 8 · failure · 1 messages'));
    });

    test('since filters entries by captured timestamp', () {
      E2eDiagLog.clear();
      E2eDiagLog.add('RECENT', {});

      // A wide window keeps the just-added entry.
      expect(E2eDiagLog.since(const Duration(hours: 24)).length, 1);

      // cutoff == now excludes an entry stamped at/just-before now.
      expect(
        E2eDiagLog.since(Duration.zero).any((e) => e.contains('RECENT')),
        isFalse,
      );

      // Injected clock: a stale entry stamped before the cutoff is dropped,
      // while a fresh one within the window is kept.
      final anchor = DateTime.now();
      expect(
        E2eDiagLog.since(
          const Duration(minutes: 1),
          now: anchor.add(const Duration(hours: 2)),
        ),
        isEmpty,
      );
      expect(
        E2eDiagLog.since(const Duration(hours: 2), now: anchor).length,
        1,
      );
    });
  });
}
