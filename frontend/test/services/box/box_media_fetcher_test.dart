import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:fireplace/services/box/box_media_fetcher.dart';
import 'package:fireplace/services/box/box_media_frame.dart';
import 'package:fireplace/services/box/box_media_store.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _id(int fill) => Uint8List(32)..fillRange(0, 32, fill);

/// A store whose writes fail until [healthy].
class _FlakyStore extends MemoryBoxMediaStore {
  bool healthy = false;

  @override
  Future<void> put(int userId, Uint8List id, Uint8List ciphertext) async {
    if (!healthy) throw StateError('disk full');
    await super.put(userId, id, ciphertext);
  }
}

void main() {
  final start = DateTime.utc(2026, 9, 26, 12);
  final ct = Uint8List.fromList([5, 6, 7, 8]);
  late MemoryBoxMediaStore store;
  late List<Uint8List> downloads;

  /// What the box answers the next download.
  late Future<BoxResult<Uint8List>> Function(Uint8List id) answer;

  setUp(() {
    store = MemoryBoxMediaStore();
    downloads = [];
    answer = (_) async => BoxOk(frameMediaToRung(ct));
  });

  BoxMediaFetcher fetcher({FakeAsync? clock, BoxMediaStore? on}) =>
      BoxMediaFetcher(
        store: on ?? store,
        download: (id) {
          downloads.add(id);
          return answer(id);
        },
        now: clock == null ? null : () => start.add(clock.elapsed),
      );

  group('ciphertextFor', () {
    test('a copy in the store is answered without a download', () async {
      await store.put(1, _id(1), ct);
      expect(await fetcher().ciphertextFor(1, _id(1)), ct);
      expect(downloads, isEmpty);
    });

    test(
      'a miss downloads, unframes, keeps the ciphertext and answers it; the '
      'next call reads the kept copy',
      () async {
        final f = fetcher();
        expect(await f.ciphertextFor(1, _id(1)), ct);
        expect(await store.get(1, _id(1)), ct);
        expect(await f.ciphertextFor(1, _id(1)), ct);
        expect(downloads, hasLength(1));
        expect(downloads.single, _id(1));
      },
    );

    test('the kept copy is per account', () async {
      final f = fetcher();
      await f.ciphertextFor(1, _id(1));
      expect(await store.get(2, _id(1)), isNull);
    });

    test('concurrent calls for one id share one download', () async {
      final gate = Completer<BoxResult<Uint8List>>();
      answer = (_) => gate.future;
      final f = fetcher();
      final a = f.ciphertextFor(1, _id(1));
      final b = f.ciphertextFor(1, _id(1));
      await pumpEventQueue();
      expect(downloads, hasLength(1));
      gate.complete(BoxOk(frameMediaToRung(ct)));
      expect(await a, ct);
      expect(await b, ct);
    });

    test('an answer we cannot read is null and nothing is kept', () async {
      for (final result in <BoxResult<Uint8List>>[
        BoxOk(Uint8List(100)),
        const BoxRefused(BoxCode.notFound),
        const BoxUnknown(BoxUnknownReason.timeout),
      ]) {
        answer = (_) async => result;
        expect(await fetcher().ciphertextFor(1, _id(1)), isNull);
        expect(await store.get(1, _id(1)), isNull);
      }
    });

    test(
      "a body longer than today's largest ciphertext (20 MiB + GCM tag) is "
      'refused and not kept; exactly that size is kept',
      () async {
        final framed = Uint8List(kBoxMediaLadder.last);
        final length = framed.buffer.asByteData();
        answer = (_) async => BoxOk(framed);

        length.setUint32(0, MediaCryptoService.maxCiphertextBytes + 1);
        expect(await fetcher().ciphertextFor(1, _id(1)), isNull);
        expect(await store.get(1, _id(1)), isNull);

        length.setUint32(0, MediaCryptoService.maxCiphertextBytes);
        final kept = await fetcher().ciphertextFor(1, _id(1));
        expect(kept?.length, MediaCryptoService.maxCiphertextBytes);
      },
    );

    test(
      'a 17 MiB file downloads as the 32 MiB rung: the cap applies to the '
      'UNFRAMED ciphertext, which is what is answered and kept',
      () async {
        final big = Uint8List(17 * 1024 * 1024)
          ..[0] = 0xa1
          ..[17 * 1024 * 1024 - 1] = 0xb2;
        final framed = frameMediaToRung(big);
        expect(framed.length, kBoxMediaLadder.last);
        answer = (_) async => BoxOk(framed);

        final got = await fetcher().ciphertextFor(1, _id(1));
        expect(got?.length, big.length);
        expect(got, big);
        final kept = await store.get(1, _id(1));
        expect(kept?.length, big.length);
        expect(kept, big);
      },
    );
  });

  group('prefetch', () {
    test('keeps the copy in the background', () {
      fakeAsync((clock) {
        fetcher(clock: clock).prefetch(1, _id(1), receivedAt: start);
        clock.flushMicrotasks();
        expect(downloads, hasLength(1));
        unawaited(store.get(1, _id(1)).then((kept) => expect(kept, ct)));
        clock.flushMicrotasks();
      });
    });

    test('an id already kept is not downloaded again', () {
      fakeAsync((clock) {
        unawaited(store.put(1, _id(1), ct));
        fetcher(clock: clock).prefetch(1, _id(1), receivedAt: start);
        clock.elapse(const Duration(hours: 1));
        expect(downloads, isEmpty);
      });
    });

    test(
      'one download at a time: the next waits for the one before, and an id '
      'already waiting is not queued twice',
      () {
        fakeAsync((clock) {
          final gates = <Completer<BoxResult<Uint8List>>>[];
          answer = (_) {
            final gate = Completer<BoxResult<Uint8List>>();
            gates.add(gate);
            return gate.future;
          };
          final f = fetcher(clock: clock)
            ..prefetch(1, _id(1), receivedAt: start)
            ..prefetch(1, _id(2), receivedAt: start)
            ..prefetch(1, _id(2), receivedAt: start);
          clock.flushMicrotasks();
          expect(downloads, [_id(1)]);
          gates.single.complete(BoxOk(frameMediaToRung(ct)));
          clock.flushMicrotasks();
          expect(downloads, [_id(1), _id(2)]);
          gates.last.complete(BoxOk(frameMediaToRung(ct)));
          clock.elapse(const Duration(hours: 1));
          expect(downloads, hasLength(2));
          f.dispose();
        });
      },
    );

    test('a viewer asking meanwhile shares the background download', () {
      fakeAsync((clock) {
        final gate = Completer<BoxResult<Uint8List>>();
        answer = (_) => gate.future;
        final f = fetcher(clock: clock)..prefetch(1, _id(1), receivedAt: start);
        clock.flushMicrotasks();
        Uint8List? shown;
        unawaited(f.ciphertextFor(1, _id(1)).then((v) => shown = v));
        clock.flushMicrotasks();
        gate.complete(BoxOk(frameMediaToRung(ct)));
        clock.flushMicrotasks();
        expect(shown, ct);
        expect(downloads, hasLength(1));
      });
    });

    test(
      'no answer is retried after 30 s, 2 min, 10 min, then hourly, until '
      'one lands',
      () {
        fakeAsync((clock) {
          answer = (_) async => const BoxUnknown(BoxUnknownReason.offline);
          fetcher(clock: clock).prefetch(1, _id(1), receivedAt: start);
          clock.flushMicrotasks();
          expect(downloads, hasLength(1));

          var expected = 1;
          for (final wait in const [
            Duration(seconds: 30),
            Duration(minutes: 2),
            Duration(minutes: 10),
            Duration(hours: 1),
            Duration(hours: 1),
          ]) {
            clock.elapse(wait - const Duration(seconds: 1));
            expect(downloads, hasLength(expected), reason: 'before $wait');
            clock.elapse(const Duration(seconds: 1));
            expect(downloads, hasLength(++expected), reason: 'at $wait');
          }

          answer = (_) async => BoxOk(frameMediaToRung(ct));
          clock.elapse(const Duration(hours: 1));
          expect(downloads, hasLength(++expected));
          clock.elapse(const Duration(days: 2));
          expect(downloads, hasLength(expected), reason: 'kept: done');
        });
      },
    );

    test('an id waiting out a retry is not fetched early by a second ask', () {
      fakeAsync((clock) {
        answer = (_) async => const BoxUnknown(BoxUnknownReason.offline);
        final f = fetcher(clock: clock)
          ..prefetch(1, _id(1), receivedAt: start);
        clock.flushMicrotasks();
        f.prefetch(1, _id(1), receivedAt: start);
        clock.elapse(const Duration(seconds: 29));
        expect(downloads, hasLength(1));
        clock.elapse(const Duration(seconds: 1));
        expect(downloads, hasLength(2));
        f.dispose();
      });
    });

    test(
      'a good download the store could not keep is given up, not re-fetched '
      'on the retry ladder for 14 days; the viewer still gets the bytes and '
      'downloads again when shown',
      () {
        fakeAsync((clock) {
          final flaky = _FlakyStore();
          final f = fetcher(clock: clock, on: flaky)
            ..prefetch(1, _id(1), receivedAt: start);
          clock.flushMicrotasks();
          expect(downloads, hasLength(1));
          clock.elapse(const Duration(days: 15));
          expect(downloads, hasLength(1), reason: 'no background re-download');
          expect(clock.pendingTimers, isEmpty);

          Uint8List? shown;
          unawaited(f.ciphertextFor(1, _id(1)).then((c) => shown = c));
          clock.flushMicrotasks();
          expect(shown, ct);
          expect(downloads, hasLength(2));
        });
      },
    );

    test(
      'a rate limit waits at least as long as the box asked, then tries again',
      () {
        fakeAsync((clock) {
          answer = (_) async => const BoxRefused(
            BoxCode.rateLimited,
            retryAfter: Duration(minutes: 5),
          );
          fetcher(clock: clock).prefetch(1, _id(1), receivedAt: start);
          clock.elapse(const Duration(minutes: 4, seconds: 59));
          expect(downloads, hasLength(1));
          clock.elapse(const Duration(seconds: 1));
          expect(downloads, hasLength(2));
        });
      },
    );

    test('media the box no longer holds (or never did) is given up', () {
      fakeAsync((clock) {
        answer = (_) async => const BoxRefused(BoxCode.notFound);
        fetcher(clock: clock).prefetch(1, _id(1), receivedAt: start);
        clock.elapse(const Duration(days: 3));
        expect(downloads, hasLength(1));
      });
    });

    test('a body that does not unframe is given up, not retried', () {
      fakeAsync((clock) {
        answer = (_) async => BoxOk(Uint8List(100));
        fetcher(clock: clock).prefetch(1, _id(1), receivedAt: start);
        clock.elapse(const Duration(days: 3));
        expect(downloads, hasLength(1));
      });
    });

    test(
      'once 14 days have passed since the message arrived the box has '
      'dropped the file (D8): no download at all',
      () {
        fakeAsync((clock) {
          final f = fetcher(clock: clock)
            ..prefetch(
              1,
              _id(1),
              receivedAt: start.subtract(const Duration(days: 14)),
            );
          clock.flushMicrotasks();
          expect(downloads, isEmpty);
          f.prefetch(
            1,
            _id(2),
            receivedAt: start.subtract(
              const Duration(days: 14) - const Duration(seconds: 1),
            ),
          );
          clock.flushMicrotasks();
          expect(downloads, [_id(2)]);
        });
      },
    );

    test('a retry that comes due after the 14 days never downloads', () {
      fakeAsync((clock) {
        answer = (_) async => const BoxUnknown(BoxUnknownReason.timeout);
        fetcher(clock: clock).prefetch(
          1,
          _id(1),
          receivedAt: start.subtract(
            const Duration(days: 14) - const Duration(seconds: 90),
          ),
        );
        clock.elapse(const Duration(seconds: 30));
        expect(downloads, hasLength(2));
        clock.elapse(const Duration(days: 1));
        expect(downloads, hasLength(2));
      });
    });

    test('dispose cancels the pending retry and the queue', () {
      fakeAsync((clock) {
        final gate = Completer<BoxResult<Uint8List>>();
        answer = (_) => gate.future;
        final f = fetcher(clock: clock)
          ..prefetch(1, _id(1), receivedAt: start)
          ..prefetch(1, _id(2), receivedAt: start);
        clock.flushMicrotasks();
        gate.complete(const BoxUnknown(BoxUnknownReason.timeout));
        f.dispose();
        clock.flushMicrotasks();
        expect(clock.pendingTimers, isEmpty, reason: 'no retry after dispose');
        clock.elapse(const Duration(days: 1));
        expect(downloads, [_id(1)]);
        expect(clock.pendingTimers, isEmpty);
      });
    });
  });
}
