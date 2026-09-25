import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fireplace/services/box/box_device_list_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

class _Refused implements Exception {}

void main() {
  late List<int> covered;
  late List<int> fetched;
  late Set<int> failing;
  late List<int> prebuilt;
  late Set<int> prebuildFailing;
  Completer<void>? prebuildHold;
  late BoxDeviceListRefresh lists;

  setUp(() {
    covered = [2, 3];
    fetched = [];
    failing = {};
    prebuilt = [];
    prebuildFailing = {};
    prebuildHold = null;
    lists = BoxDeviceListRefresh(
      users: () => covered,
      fetch: (peer) async {
        fetched.add(peer);
        if (failing.contains(peer)) throw _Refused();
      },
      prebuild: (peer) async {
        prebuilt.add(peer);
        await prebuildHold?.future;
        if (prebuildFailing.contains(peer)) throw _Refused();
      },
      retryDelays: const [Duration(seconds: 5), Duration(seconds: 30)],
    );
  });

  /// Whether [peer]'s entry is there and finished without an error.
  Future<bool> ready(int peer) async {
    final entry = lists.readyFor(peer);
    if (entry == null) return false;
    try {
      await entry;
      return true;
    } on _Refused {
      return false;
    }
  }

  test('a refresh fetches every covered peer once; a second refresh does not '
      'fetch a peer it already verified', () async {
    lists.refresh();
    expect(await ready(2), isTrue);
    expect(await ready(3), isTrue);
    lists.refresh();
    await pumpEventQueue();
    expect(fetched, [2, 3]);
  });

  test('a peer no refresh covered has no entry — a send must fail, not fetch', () {
    lists.refresh();
    expect(lists.readyFor(4), isNull);
  });

  test('a failed fetch is retried on its own backoff, not before', () {
    fakeAsync((clock) {
      failing.add(2);
      lists.refresh();
      clock.flushMicrotasks();
      expect(fetched, [2, 3]);

      clock.elapse(const Duration(seconds: 4));
      expect(fetched, [2, 3]);

      failing.clear();
      clock.elapse(const Duration(seconds: 1));
      expect(fetched, [2, 3, 2]);
      var ok = false;
      unawaited(lists.readyFor(2)!.then((_) => ok = true));
      clock.flushMicrotasks();
      expect(ok, isTrue);
    });
  });

  test('each further failure waits longer', () {
    fakeAsync((clock) {
      failing.add(2);
      lists.refresh();
      clock.elapse(const Duration(seconds: 5));
      expect(fetched, [2, 3, 2]);

      clock.elapse(const Duration(seconds: 29));
      expect(fetched, [2, 3, 2]);
      clock.elapse(const Duration(seconds: 1));
      expect(fetched, [2, 3, 2, 2]);
    });
  });

  test('a lookup that went through starts the backoff over', () {
    fakeAsync((clock) {
      failing.add(2);
      lists.refresh();
      clock.elapse(const Duration(seconds: 5));
      failing.clear();
      clock.elapse(const Duration(seconds: 30));
      expect(fetched, [2, 3, 2, 2]);

      failing.add(2);
      lists.invalidate(2);
      clock.elapse(const Duration(seconds: 5));
      expect(fetched, [2, 3, 2, 2, 2, 2]);
    });
  });

  test('an explicit refresh (the next connect event) re-fetches a failed peer '
      'without waiting for the backoff', () async {
    failing.add(2);
    lists.refresh();
    expect(await ready(2), isFalse);
    failing.clear();
    lists.refresh();
    expect(await ready(2), isTrue);
    expect(fetched, [2, 3, 2]);
  });

  test('reset drops every entry and cancels the pending retry', () {
    fakeAsync((clock) {
      failing.add(2);
      lists.refresh();
      clock.flushMicrotasks();
      lists.reset();
      expect(lists.readyFor(2), isNull);
      expect(lists.readyFor(3), isNull);
      clock.elapse(const Duration(minutes: 5));
      expect(fetched, [2, 3]);
    });
  });

  test('a fetch that fails after a reset schedules no retry', () {
    fakeAsync((clock) {
      final gate = Completer<void>();
      final slow = BoxDeviceListRefresh(
        users: () => [2],
        fetch: (peer) async {
          fetched.add(peer);
          await gate.future;
          throw _Refused();
        },
        retryDelays: const [Duration(seconds: 5)],
      )
        ..refresh()
        ..reset();
      gate.complete();
      clock.elapse(const Duration(minutes: 1));
      expect(fetched, [2]);
      expect(slow.readyFor(2), isNull);
    });
  });

  test('an invalidated list is fetched again; a peer never refreshed is not '
      'fetched by an invalidation', () async {
    lists.refresh();
    await pumpEventQueue();
    lists
      ..invalidate(2)
      ..invalidate(4);
    await pumpEventQueue();
    expect(fetched, [2, 3, 2]);
  });

  test('an entry is ready only once the session pre-build after its lookup '
      'has finished (decision 38)', () {
    fakeAsync((clock) {
      final hold = prebuildHold = Completer<void>();
      lists.refresh();
      clock.flushMicrotasks();
      expect(fetched, [2, 3]);
      expect(prebuilt, [2, 3]);
      var ok = false;
      unawaited(lists.readyFor(2)!.then((_) => ok = true));
      clock.flushMicrotasks();
      expect(ok, isFalse);

      hold.complete();
      clock.flushMicrotasks();
      expect(ok, isTrue);
    });
  });

  test('a failed lookup pre-builds nothing', () async {
    failing.add(2);
    lists.refresh();
    expect(await ready(2), isFalse);
    expect(await ready(3), isTrue);
    expect(prebuilt, [3]);
  });

  test('a failed pre-build fails the entry and is retried on the backoff: '
      'the list and the pre-build both run again', () {
    fakeAsync((clock) {
      prebuildFailing.add(2);
      lists.refresh();
      clock.flushMicrotasks();
      Object? error;
      unawaited(lists.readyFor(2)!.catchError((Object e) => error = e));
      clock.flushMicrotasks();
      expect(error, isA<_Refused>());

      clock.elapse(const Duration(seconds: 4));
      expect(prebuilt, [2, 3]);
      prebuildFailing.clear();
      clock.elapse(const Duration(seconds: 1));
      expect(fetched, [2, 3, 2]);
      expect(prebuilt, [2, 3, 2]);
      var ok = false;
      unawaited(lists.readyFor(2)!.then((_) => ok = true));
      clock.flushMicrotasks();
      expect(ok, isTrue);
    });
  });

  test("a user's next pass (a rebuild request's invalidation) waits for the "
      'pre-build still running, then looks up and pre-builds again', () {
    fakeAsync((clock) {
      final hold = prebuildHold = Completer<void>();
      lists.refresh();
      clock.flushMicrotasks();
      lists.invalidate(2);
      clock.flushMicrotasks();
      expect(fetched, [2, 3]);
      expect(prebuilt, [2, 3]);

      hold.complete();
      clock.flushMicrotasks();
      expect(fetched, [2, 3, 2]);
      expect(prebuilt, [2, 3, 2]);
    });
  });
}
