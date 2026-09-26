import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../media_crypto_service.dart';
import 'box_media_frame.dart';
import 'box_media_store.dart';
import 'box_wire.dart';

/// `GET /box/media/<id>`: `BoxOutbox.downloadMedia`.
typedef BoxMediaDownload = Future<BoxResult<Uint8List>> Function(Uint8List id);

/// How long the box keeps a media file (D8). Past this since the message
/// arrived, a download can only answer not_found.
const Duration kBoxMediaLifetime = Duration(days: 14);

/// Waits after each failed background download: 30 s, 2 min, 10 min, then
/// hourly until [kBoxMediaLifetime] has passed.
const List<Duration> _retryDelays = [
  Duration(seconds: 30),
  Duration(minutes: 2),
  Duration(minutes: 10),
  Duration(hours: 1),
];

enum _Outcome {
  /// The copy is in the store.
  kept,

  /// Not worth a background retry: the box no longer holds the file, holds
  /// bytes that are not a file we sent, or the store could not keep a good
  /// download (a full disk would be re-filled hourly for 14 days).
  gone,

  /// No answer, or a rate limit.
  retry,
}

class _Fetch {
  const _Fetch(this.outcome, {this.ciphertext, this.retryAfter});

  final _Outcome outcome;
  final Uint8List? ciphertext;
  final Duration? retryAfter;
}

class _Job {
  _Job(this.userId, this.id, this.receivedAt);

  final int userId;
  final Uint8List id;
  final DateTime receivedAt;
  int failures = 0;
}

/// Gets each box attachment onto this device (decision 40): [prefetch] as a
/// message arrives, [ciphertextFor] when one is shown. Downloads run on
/// their own queue, never on the reader's chain (E17c): a 20 MiB fetch there
/// would stall every chat.
///
/// Answers the UNFRAMED ciphertext; the caller decrypts it with the key from
/// the message record.
class BoxMediaFetcher {
  BoxMediaFetcher({
    required BoxMediaStore store,
    required BoxMediaDownload download,
    DateTime Function()? now,
  }) : _store = store,
       _download = download,
       _now = now ?? DateTime.now;

  final BoxMediaStore _store;
  final BoxMediaDownload _download;
  final DateTime Function() _now;

  /// One download per id at a time, shared by whoever asks meanwhile.
  final Map<String, Future<_Fetch>> _inFlight = {};

  /// Background jobs in order; [_pending] also holds the ones waiting out a
  /// retry, so an id is never queued twice.
  final Queue<_Job> _queue = Queue();
  final Map<String, _Job> _pending = {};
  final Map<String, Timer> _retries = {};
  bool _draining = false;
  bool _disposed = false;

  /// Ids whose message is destroyed ([forget]): never downloaded or kept
  /// again.
  final Set<String> _forgotten = {};

  static String _key(int userId, Uint8List id) => '$userId:${boxB64(id)}';

  /// The kept copy, else a download (which is then kept). Null when there is
  /// no answer, the box no longer holds the file, or its bytes are not a
  /// file (off the ladder, or longer than any file we send).
  Future<Uint8List?> ciphertextFor(int userId, Uint8List id) async =>
      (await _shared(userId, id)).ciphertext;

  /// Keeps a copy of [id] in the background, one download at a time; never
  /// awaited. Given up once the box can no longer hold it: not_found, or
  /// [kBoxMediaLifetime] after [receivedAt].
  void prefetch(int userId, Uint8List id, {required DateTime receivedAt}) {
    if (_disposed) return;
    final key = _key(userId, id);
    if (_pending.containsKey(key) || _forgotten.contains(key)) return;
    final job = _Job(userId, Uint8List.fromList(id), receivedAt);
    _pending[key] = job;
    _queue.add(job);
    unawaited(_drain());
  }

  /// [prefetch], unless a copy is already kept: the restore path's check
  /// (E17c), which never reads the copy itself. A store that cannot answer
  /// leaves it to the download path, which reads the store first anyway.
  Future<void> prefetchIfMissing(
    int userId,
    Uint8List id, {
    required DateTime receivedAt,
  }) async {
    try {
      if (await _store.has(userId, id)) return;
    } on Object {
      // Unknown: prefetch decides.
    }
    prefetch(userId, id, receivedAt: receivedAt);
  }

  /// Keeps [ciphertext] (unframed) as this device's copy of [id]: the
  /// sender's own, which it never downloads (decision 40).
  Future<void> keep(int userId, Uint8List id, Uint8List ciphertext) =>
      _store.put(userId, id, ciphertext);

  /// Drops this device's copy of [id] and any background download of it:
  /// the message record, which held its only key, is destroyed.
  Future<void> forget(int userId, Uint8List id) async {
    final key = _key(userId, id);
    _forgotten.add(key);
    _retries.remove(key)?.cancel();
    final job = _pending.remove(key);
    if (job != null) _queue.remove(job);
    await _store.delete(userId, id);
  }

  void dispose() {
    _disposed = true;
    for (final timer in _retries.values) {
      timer.cancel();
    }
    _retries.clear();
    _queue.clear();
    _pending.clear();
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final job = _queue.removeFirst();
        final key = _key(job.userId, job.id);
        final expired = !_now().isBefore(
          job.receivedAt.add(kBoxMediaLifetime),
        );
        if (expired) {
          _pending.remove(key);
          continue;
        }
        final fetch = await _shared(job.userId, job.id);
        if (_disposed) return;
        if (fetch.outcome != _Outcome.retry || _forgotten.contains(key)) {
          _pending.remove(key);
          continue;
        }
        final backoff =
            _retryDelays[math.min(job.failures++, _retryDelays.length - 1)];
        final asked = fetch.retryAfter;
        _retries[key] = Timer(
          asked != null && asked > backoff ? asked : backoff,
          () {
            _retries.remove(key);
            if (_disposed) return;
            _queue.add(job);
            unawaited(_drain());
          },
        );
      }
    } finally {
      _draining = false;
    }
  }

  Future<_Fetch> _shared(int userId, Uint8List id) {
    final key = _key(userId, id);
    return _inFlight[key] ??= _loadOnce(key, userId, id);
  }

  /// [_load] always suspends on the store first, so the `finally` runs only
  /// after [_shared] has filed this future under [key].
  Future<_Fetch> _loadOnce(String key, int userId, Uint8List id) async {
    try {
      return await _load(userId, id);
    } finally {
      // The removed entry is this very future: never awaited here.
      unawaited(_inFlight.remove(key));
    }
  }

  Future<_Fetch> _load(int userId, Uint8List id) async {
    final key = _key(userId, id);
    try {
      final kept = await _store.get(userId, id);
      if (kept != null) return _Fetch(_Outcome.kept, ciphertext: kept);
    } on Object {
      // An unreadable store is a miss: the download below replaces the copy.
    }
    final BoxResult<Uint8List> answer;
    try {
      answer = await _download(id);
    } on Object {
      return const _Fetch(_Outcome.retry);
    }
    switch (answer) {
      case BoxOk(:final value):
        // Asking again fetches the same bytes, so these are given up.
        final ciphertext = unframeMedia(value);
        if (ciphertext == null ||
            ciphertext.length > MediaCryptoService.maxCiphertextBytes) {
          return const _Fetch(_Outcome.gone);
        }
        // Destroyed meanwhile: its copy must not come back.
        if (_forgotten.contains(key)) return const _Fetch(_Outcome.gone);
        try {
          await _store.put(userId, id, ciphertext);
        } on Object {
          // The bytes are good; only keeping them failed. Given up here, so a
          // full store is not re-downloaded for 14 days: the viewer's
          // [ciphertextFor] fetches it again when shown.
          return _Fetch(_Outcome.gone, ciphertext: ciphertext);
        }
        return _Fetch(_Outcome.kept, ciphertext: ciphertext);
      // `GET /box/media` is limited per IP: a burst of arrivals waits it out.
      case BoxRefused(code: BoxCode.rateLimited, :final retryAfter):
        return _Fetch(_Outcome.retry, retryAfter: retryAfter);
      case BoxRefused():
        return const _Fetch(_Outcome.gone);
      case BoxUnknown():
        return const _Fetch(_Outcome.retry);
    }
  }
}
