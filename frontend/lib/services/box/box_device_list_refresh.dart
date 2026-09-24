import 'dart:async';
import 'dart:math' as math;

/// How long a failed lookup waits before [BoxDeviceListRefresh] tries it
/// again; the last delay repeats.
const List<Duration> kBoxDeviceListRetryDelays = [
  Duration(seconds: 5),
  Duration(seconds: 30),
  Duration(minutes: 2),
  Duration(minutes: 5),
];

/// Re-verifies every device list a box send reads — the covered peers' and
/// the account's own (metadata-privacy PR3.1 slice (c), owner decision 21) —
/// and ONLY at moments that are not a send: each connect once E2E and the
/// account socket are ready, a contact store that opened late, a list the
/// E2E layer dropped, and this class's own retry backoff. A box send waits
/// for its lists' entries here and never looks a list up itself: a lookup
/// on the account socket timed by a send names the pair (a peer's list) or
/// the sender (the own list) at the moment of an otherwise unlinkable box
/// frame. The price: a device linked mid-session is seen at the next connect
/// (E2E device announcements, slice (e), replace this).
class BoxDeviceListRefresh {
  BoxDeviceListRefresh({
    required Iterable<int> Function() users,
    required Future<void> Function(int userId) fetch,
    List<Duration> retryDelays = kBoxDeviceListRetryDelays,
  }) : _users = users,
       _fetch = fetch,
       _retryDelays = retryDelays;

  final Iterable<int> Function() _users;
  final Future<void> Function(int userId) _fetch;
  final List<Duration> _retryDelays;

  final Map<int, Future<void>> _entries = {};
  final Set<int> _failed = {};
  Timer? _retry;
  int _retries = 0;

  /// This connect's lookup of [userId]'s list — running, done or failed;
  /// null when none has started, which a send must treat as a failure.
  Future<void>? readyFor(int userId) => _entries[userId];

  /// Looks up every list that has no entry yet or whose last lookup failed.
  void refresh() {
    for (final user in _users()) {
      if (_entries.containsKey(user) && !_failed.contains(user)) continue;
      _start(user);
    }
  }

  /// The verified list of [userId] was dropped: look it up again. A list
  /// this connect never looked up is left to [refresh].
  void invalidate(int userId) {
    if (_entries.containsKey(userId)) _start(userId);
  }

  /// A new connect or a logout: every entry goes, and so does a pending retry.
  void reset() {
    _retry?.cancel();
    _retry = null;
    _retries = 0;
    _entries.clear();
    _failed.clear();
  }

  void _start(int user) {
    _failed.remove(user);
    final lookup = Future.sync(() => _fetch(user));
    _entries[user] = lookup;
    unawaited(
      lookup.then(
        (_) {
          if (identical(_entries[user], lookup) && _failed.isEmpty) {
            _retries = 0;
          }
        },
        onError: (Object _) {
          // A lookup a reset or a newer lookup replaced decides nothing.
          if (!identical(_entries[user], lookup)) return;
          _failed.add(user);
          _retry ??= Timer(
            _retryDelays[math.min(_retries, _retryDelays.length - 1)],
            () {
              _retry = null;
              _retries++;
              refresh();
            },
          );
        },
      ),
    );
  }
}
