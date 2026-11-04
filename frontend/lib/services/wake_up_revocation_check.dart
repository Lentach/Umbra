import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// What `POST /auth/refresh` says about the session it was shown (decision
/// 129, E129a).
enum SessionStanding {
  /// `401 {message: 'Device revoked'}`: the server revoked this device. The
  /// ONLY answer that counts as revoked.
  revoked,

  /// A 200, or any other 401 (a logout, a password change, an expiry): the
  /// device was not revoked, whatever happened to the session.
  notRevoked,

  /// A network error, a timeout, a throttle (429), a 5xx, a body that does
  /// not parse: no verdict. Never read as revoked.
  unknown,
}

/// What one [RevokedWakeUpCheck.run] did.
enum WakeCheckOutcome {
  /// No stored session (logged out, or the store could not be read).
  noSession,

  /// A recent answer or attempt stands; nothing was asked.
  throttled,

  /// The pacing state could not be read, or the attempt stamp could not be
  /// written, so nothing was asked (a check that cannot be paced must not run).
  stateUnavailable,

  /// The server said the device was not revoked.
  notRevoked,

  /// No verdict (see [SessionStanding.unknown]); nothing was changed.
  unknown,

  /// The server said revoked and the push registration was dropped.
  stopped,

  /// The server said revoked and dropping the registration failed; the next
  /// wake-up after the retry gap tries again.
  stopFailed,
}

/// What a check remembers, per session. A new session (another refresh token)
/// starts from nothing.
class WakeCheckState {
  const WakeCheckState({required this.session, this.liveAtMs, this.attemptAtMs});

  /// [RevokedWakeUpCheck.sessionKey] of the refresh token this is about.
  final String session;

  /// When the server last said "not revoked" (epoch ms).
  final int? liveAtMs;

  /// When the last check was started (epoch ms), whatever it ended in.
  final int? attemptAtMs;

  WakeCheckState copyWith({int? liveAtMs, int? attemptAtMs}) => WakeCheckState(
    session: session,
    liveAtMs: liveAtMs ?? this.liveAtMs,
    attemptAtMs: attemptAtMs ?? this.attemptAtMs,
  );

  String toJson() => jsonEncode({
    's': session,
    if (liveAtMs != null) 'l': liveAtMs,
    if (attemptAtMs != null) 'a': attemptAtMs,
  });

  /// Null for anything that is not a state this class wrote.
  static WakeCheckState? tryParse(String? raw) {
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map || map['s'] is! String) return null;
      final live = map['l'];
      final attempt = map['a'];
      return WakeCheckState(
        session: map['s'] as String,
        liveAtMs: live is int ? live : null,
        attemptAtMs: attempt is int ? attempt : null,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Where a check keeps its [WakeCheckState] between wake-ups.
abstract interface class WakeCheckStateStore {
  Future<WakeCheckState?> read();
  Future<void> write(WakeCheckState state);
}

/// Native only (the web worker has its own, in `web-push-sw.js`): a closed,
/// REVOKED device ends its own box wake-ups.
///
/// The box ties no queue to an account or a device (decisions 81, 115), so a
/// friend whose list still names a revoked device keeps filling its old queues
/// and every send wakes the closed phone ("You have a new message" on a device
/// that can read nothing). The server cannot stop that; the device can. On a
/// wake-up it asks the one route that answers a device without a valid access
/// token, `POST /auth/refresh`, whether its stored session belongs to a
/// revoked device and, on the explicit answer only, drops its push
/// registration (FCM `deleteToken`, what a logout does): the push service then
/// answers UNREGISTERED and the box deletes the notifier on its next send.
///
/// Nothing but the explicit answer is "revoked". A transient failure does
/// nothing, and so does every other verdict. Pacing: a "not revoked" answer
/// stands for [liveFor]; any attempt blocks the next for [retryAfter]. The
/// request is the app's own refresh call: it names no queue, token or chat.
class RevokedWakeUpCheck {
  RevokedWakeUpCheck({
    required this.refreshToken,
    required this.probe,
    required this.dropPushRegistration,
    required this.state,
    DateTime Function()? now,
    this.liveFor = const Duration(hours: 24),
    this.retryAfter = const Duration(minutes: 15),
  }) : _now = now ?? DateTime.now;

  /// The stored session's refresh token; null without one (or when the store
  /// cannot be read: no verdict is possible).
  final Future<String?> Function() refreshToken;

  /// Asks the server about [refreshToken]'s session.
  final Future<SessionStanding> Function(String refreshToken) probe;

  /// Drops this install's push registration. Throws when it could not.
  final Future<void> Function() dropPushRegistration;

  final WakeCheckStateStore state;
  final Duration liveFor;
  final Duration retryAfter;
  final DateTime Function() _now;

  Future<WakeCheckOutcome>? _running;

  /// Names a session without being a credential: a prefix of its SHA-256.
  static String sessionKey(String refreshToken) => sha256
      .convert(utf8.encode(refreshToken))
      .toString()
      .substring(0, 16);

  /// One check at a time: wake-ups come in bursts.
  Future<WakeCheckOutcome> run() => _running ??= _run().whenComplete(() {
    _running = null;
  });

  Future<WakeCheckOutcome> _run() async {
    final token = await refreshToken();
    if (token == null || token.isEmpty) return WakeCheckOutcome.noSession;
    final key = sessionKey(token);

    // A store that cannot be read cannot pace the checks either: this wake-up
    // asks nothing (a read that always failed beside a write that works would
    // otherwise ask on every wake-up).
    final WakeCheckState? held;
    try {
      held = await state.read();
    } on Object {
      return WakeCheckOutcome.stateUnavailable;
    }
    final known = held != null && held.session == key
        ? held
        : WakeCheckState(session: key);

    final nowMs = _now().millisecondsSinceEpoch;
    if (_within(known.liveAtMs, nowMs, liveFor) ||
        _within(known.attemptAtMs, nowMs, retryAfter)) {
      return WakeCheckOutcome.throttled;
    }

    // Stamped BEFORE the ask: a check that is killed half-way still paces the
    // next one, and a store that cannot take the stamp cannot pace anything.
    var stamped = known.copyWith(attemptAtMs: nowMs);
    try {
      await state.write(stamped);
    } on Object {
      return WakeCheckOutcome.stateUnavailable;
    }

    final SessionStanding standing;
    try {
      standing = await probe(token);
    } on Object {
      return WakeCheckOutcome.unknown;
    }
    switch (standing) {
      case SessionStanding.revoked:
        try {
          await dropPushRegistration();
          return WakeCheckOutcome.stopped;
        } on Object {
          return WakeCheckOutcome.stopFailed;
        }
      case SessionStanding.notRevoked:
        stamped = stamped.copyWith(liveAtMs: _now().millisecondsSinceEpoch);
        try {
          await state.write(stamped);
        } on Object {
          // The attempt stamp still paces the next ask.
        }
        return WakeCheckOutcome.notRevoked;
      case SessionStanding.unknown:
        return WakeCheckOutcome.unknown;
    }
  }

  /// [at] is a stamp that still holds: not older than [span], and not in the
  /// future (a clock that went back must not park the check for good).
  static bool _within(int? at, int nowMs, Duration span) =>
      at != null && at <= nowMs && nowMs - at < span.inMilliseconds;
}

/// Asks `POST <baseUrl>/auth/refresh` about [refreshToken]'s session and
/// reads only the status and, on a 401, the `message`; the tokens a 2xx
/// carries are never read.
///
/// `Device revoked` is the one answer that means revoked; any other 401 means
/// the session is gone for another reason (not a revocation); every failure
/// to get a clear answer is [SessionStanding.unknown].
Future<SessionStanding> probeSessionStanding({
  required http.Client client,
  required String baseUrl,
  required String refreshToken,
  Duration timeout = const Duration(seconds: 8),
}) async {
  try {
    final response = await client
        .post(
          Uri.parse('$baseUrl/auth/refresh'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': refreshToken}),
        )
        .timeout(timeout);
    // A POST answers 201 Created (Nest's default), a 200 elsewhere: any 2xx is
    // the session being refreshed.
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return SessionStanding.notRevoked;
    }
    if (response.statusCode != 401) return SessionStanding.unknown;
    final body = jsonDecode(response.body);
    if (body is! Map) return SessionStanding.unknown;
    return body['message'] == 'Device revoked'
        ? SessionStanding.revoked
        : SessionStanding.notRevoked;
  } on Object {
    // A timeout, no network, a body that is not JSON.
    return SessionStanding.unknown;
  }
}
