import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:fireplace/services/wake_up_revocation_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-memory [WakeCheckStateStore]; [failWrites] models a store that refuses.
class _MemoryState implements WakeCheckStateStore {
  WakeCheckState? held;
  bool failWrites = false;
  int writes = 0;

  @override
  Future<WakeCheckState?> read() async => held;

  @override
  Future<void> write(WakeCheckState state) async {
    if (failWrites) throw StateError('refused');
    writes++;
    held = state;
  }
}

void main() {
  group('decision 130 (E130a): a closed, revoked device ends its own wake-ups',
      () {
    late DateTime now;
    late _MemoryState state;
    late List<String> probed;
    late int drops;
    var answer = SessionStanding.notRevoked;
    String? token = 'RT-1';
    Error? dropFailure;

    RevokedWakeUpCheck check() => RevokedWakeUpCheck(
      refreshToken: () async => token,
      probe: (t) async {
        probed.add(t);
        return answer;
      },
      dropPushRegistration: () async {
        if (dropFailure != null) throw dropFailure!;
        drops++;
      },
      state: state,
      now: () => now,
    );

    setUp(() {
      now = DateTime.utc(2026, 11, 4, 12);
      state = _MemoryState();
      probed = [];
      drops = 0;
      answer = SessionStanding.notRevoked;
      token = 'RT-1';
      dropFailure = null;
    });

    test('the explicit "revoked" answer drops the push registration, once', () async {
      answer = SessionStanding.revoked;

      expect(await check().run(), WakeCheckOutcome.stopped);

      expect(drops, 1);
      expect(probed, ['RT-1']);
    });

    test('not revoked does nothing but remember it', () async {
      expect(await check().run(), WakeCheckOutcome.notRevoked);

      expect(drops, 0);
      expect(state.held!.liveAtMs, now.millisecondsSinceEpoch);
    });

    test('no verdict (a network error, a timeout, a throttle, a 5xx) does nothing — it is never read as revoked', () async {
      answer = SessionStanding.unknown;

      expect(await check().run(), WakeCheckOutcome.unknown);

      expect(drops, 0);
      // Not "live" either: the next ask is only paced, not waived.
      expect(state.held!.liveAtMs, isNull);
      expect(state.held!.attemptAtMs, now.millisecondsSinceEpoch);
    });

    test('a probe that throws is no verdict', () async {
      final thrower = RevokedWakeUpCheck(
        refreshToken: () async => 'RT-1',
        probe: (_) async => throw const FormatException('boom'),
        dropPushRegistration: () async => drops++,
        state: state,
        now: () => now,
      );

      expect(await thrower.run(), WakeCheckOutcome.unknown);
      expect(drops, 0);
    });

    test('without a session (logged out, or an unreadable store) nothing is asked', () async {
      token = null;
      expect(await check().run(), WakeCheckOutcome.noSession);
      token = '';
      expect(await check().run(), WakeCheckOutcome.noSession);

      expect(probed, isEmpty);
      expect(drops, 0);
    });

    group('pacing', () {
      test('"not revoked" stands for 24 hours, then it is asked again', () async {
        await check().run();

        now = now.add(const Duration(hours: 24) - const Duration(minutes: 1));
        expect(await check().run(), WakeCheckOutcome.throttled);
        expect(probed, hasLength(1));

        now = now.add(const Duration(minutes: 2));
        answer = SessionStanding.revoked;
        expect(await check().run(), WakeCheckOutcome.stopped);
        expect(probed, hasLength(2));
      });

      test('an attempt with no verdict blocks the next for fifteen minutes', () async {
        answer = SessionStanding.unknown;
        await check().run();

        now = now.add(const Duration(minutes: 14));
        expect(await check().run(), WakeCheckOutcome.throttled);
        expect(probed, hasLength(1));

        now = now.add(const Duration(minutes: 2));
        expect(await check().run(), WakeCheckOutcome.unknown);
        expect(probed, hasLength(2));
      });

      test('a revoked answer whose drop failed is tried again after the gap, not at once', () async {
        answer = SessionStanding.revoked;
        dropFailure = StateError('deleteToken refused');

        expect(await check().run(), WakeCheckOutcome.stopFailed);
        expect(await check().run(), WakeCheckOutcome.throttled);

        now = now.add(const Duration(minutes: 16));
        dropFailure = null;
        expect(await check().run(), WakeCheckOutcome.stopped);
        expect(drops, 1);
      });

      test('a new session (another refresh token) starts from nothing', () async {
        await check().run();
        token = 'RT-2';

        expect(await check().run(), WakeCheckOutcome.notRevoked);
        expect(probed, ['RT-1', 'RT-2']);
      });

      test('the stamp is written BEFORE the ask, so a check cut short still paces the next', () async {
        final release = Completer<SessionStanding>();
        final hung = RevokedWakeUpCheck(
          refreshToken: () async => 'RT-1',
          probe: (_) => release.future,
          dropPushRegistration: () async => drops++,
          state: state,
          now: () => now,
        );

        final running = hung.run();
        await pumpEventQueue();

        expect(state.held!.attemptAtMs, now.millisecondsSinceEpoch);
        // The process dies here: a fresh check (the next wake-up) is paced.
        expect(await check().run(), WakeCheckOutcome.throttled);
        release.complete(SessionStanding.notRevoked);
        await running;
      });

      test('a store that cannot take the stamp cannot pace, so nothing is asked', () async {
        state.failWrites = true;

        expect(await check().run(), WakeCheckOutcome.stateUnavailable);

        expect(probed, isEmpty);
        expect(drops, 0);
      });

      test('a store that cannot be read cannot pace, so nothing is asked', () async {
        final unreadable = RevokedWakeUpCheck(
          refreshToken: () async => 'RT-1',
          probe: (t) async {
            probed.add(t);
            return SessionStanding.revoked;
          },
          dropPushRegistration: () async => drops++,
          state: _ThrowingRead(),
          now: () => now,
        );

        expect(await unreadable.run(), WakeCheckOutcome.stateUnavailable);
        expect(probed, isEmpty);
        expect(drops, 0);
      });

      test('a clock that went back does not park the check for good', () async {
        await check().run();
        now = now.subtract(const Duration(days: 2));
        answer = SessionStanding.revoked;

        expect(await check().run(), WakeCheckOutcome.stopped);
      });

      test('a burst of wake-ups makes one check', () async {
        final release = Completer<SessionStanding>();
        final slow = RevokedWakeUpCheck(
          refreshToken: () async => 'RT-1',
          probe: (t) {
            probed.add(t);
            return release.future;
          },
          dropPushRegistration: () async => drops++,
          state: state,
          now: () => now,
        );

        final all = [slow.run(), slow.run(), slow.run()];
        await pumpEventQueue();
        release.complete(SessionStanding.revoked);

        expect(await Future.wait(all), everyElement(WakeCheckOutcome.stopped));
        expect(probed, hasLength(1));
        expect(drops, 1);
      });
    });

    test('the session key names a session without being a credential', () {
      final key = RevokedWakeUpCheck.sessionKey('RT-1');

      expect(key, hasLength(16));
      expect(key, isNot(contains('RT-1')));
      expect(RevokedWakeUpCheck.sessionKey('RT-1'), key);
      expect(RevokedWakeUpCheck.sessionKey('RT-2'), isNot(key));
    });

    test('the state survives its own encoding, and anything else is nothing', () {
      const state = WakeCheckState(
        session: 'abc',
        liveAtMs: 5,
        attemptAtMs: 7,
      );

      final back = WakeCheckState.tryParse(state.toJson())!;
      expect((back.session, back.liveAtMs, back.attemptAtMs), ('abc', 5, 7));
      expect(WakeCheckState.tryParse(null), isNull);
      expect(WakeCheckState.tryParse('not json'), isNull);
      expect(WakeCheckState.tryParse('[1]'), isNull);
      expect(WakeCheckState.tryParse('{"l": 5}'), isNull);
    });
  });

  group('probeSessionStanding reads only the explicit "Device revoked"', () {
    Future<SessionStanding> ask(
      Future<http.Response> Function(http.Request) handler, {
      Duration timeout = const Duration(seconds: 8),
    }) => probeSessionStanding(
      client: MockClient(handler),
      baseUrl: 'https://umbra.test',
      refreshToken: 'RT-1',
      timeout: timeout,
    );

    http.Response json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

    test('401 {message: Device revoked} is revoked', () async {
      expect(
        await ask((_) async => json(401, {'message': 'Device revoked'})),
        SessionStanding.revoked,
      );
    });

    test('a 2xx (the real server answers a POST 201) and every other readable 401 are "not revoked"', () async {
      for (final status in [200, 201]) {
        expect(
          await ask((_) async => json(status, {'access_token': 'a'})),
          SessionStanding.notRevoked,
          reason: '$status',
        );
      }
      for (final message in [
        'Invalid refresh token',
        'Refresh token expired',
        'Unauthorized',
      ]) {
        expect(
          await ask((_) async => json(401, {'message': message})),
          SessionStanding.notRevoked,
          reason: message,
        );
      }
    });

    test('a throttle, a server error, a redirect and a 4xx other than 401 are no verdict', () async {
      for (final status in [400, 403, 404, 429, 500, 502, 503, 302]) {
        expect(
          await ask((_) async => http.Response('{}', status)),
          SessionStanding.unknown,
          reason: '$status',
        );
      }
    });

    test('a 401 whose body is not JSON, or not an object, is no verdict', () async {
      expect(
        await ask((_) async => http.Response('<html>', 401)),
        SessionStanding.unknown,
      );
      expect(
        await ask((_) async => http.Response('"Device revoked"', 401)),
        SessionStanding.unknown,
      );
    });

    test('no network is no verdict', () async {
      expect(
        await ask((_) async => throw http.ClientException('offline')),
        SessionStanding.unknown,
      );
    });

    test('a timeout is no verdict', () {
      fakeAsync((async) {
        SessionStanding? got;
        unawaited(
          ask((_) => Completer<http.Response>().future).then((v) => got = v),
        );
        async
          ..elapse(const Duration(seconds: 9))
          ..flushMicrotasks();
        expect(got, SessionStanding.unknown);
      });
    });

    test("it is the app's own refresh call: POST /auth/refresh with the refresh token and nothing else", () async {
      late http.Request seen;
      await ask((request) async {
        seen = request;
        return json(200, {});
      });

      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://umbra.test/auth/refresh');
      expect(jsonDecode(seen.body), {'refresh_token': 'RT-1'});
      expect(seen.headers.keys.map((k) => k.toLowerCase()), ['content-type']);
    });
  });
}

class _ThrowingRead implements WakeCheckStateStore {
  @override
  Future<WakeCheckState?> read() async => throw StateError('unreadable');

  @override
  Future<void> write(WakeCheckState state) async {}
}
