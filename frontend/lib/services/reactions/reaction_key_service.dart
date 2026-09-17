import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../encryption_service.dart';
import 'reaction_key_lookup.dart';
import 'reaction_token_codec.dart';

/// One device of one participant, the address a wrapped key is sealed to.
typedef ReactionKeyTarget = ({int userId, int deviceId});

/// Why [ReactionKeyService.ensureCodec] could not produce a codec.
enum ReactionKeyFailure {
  /// The local store could not answer (locked vault, corrupt row, store
  /// failure). NOT an absence: nothing is created and nothing is rotated.
  unavailable,

  /// The server has no row for this device at the current epoch, and this
  /// client was told not to create one (or creating it was refused).
  noKeyYet,

  /// The wrapped key exists but this device could not open it.
  undecryptable,

  /// The server refused the upload, or the socket never answered.
  refused,
}

/// What one mailbox read can answer.
///
/// `hasRow: false` with no failure is the ONLY answer that lets a caller
/// consider creating a key, and `epoch` is always the server's current epoch
/// so the create path needs no second round trip.
typedef _PullOutcome = ({
  ReactionTokenCodec? codec,
  ReactionKeyFailure? failure,
  int epoch,
  bool hasRow,
});

/// Acquires the per-conversation `K_react` this device needs to read and write
/// blinded reaction tokens (`docs/design/reaction-privacy.md` §3.1).
///
/// The order is deliberate and is the whole design:
///   1. LOCAL first. The key persists because a Signal-wrapped mailbox row can
///      be opened exactly once; re-pulling every launch is not an option.
///   2. PULL. A device that was offline, or did not exist when the key was
///      made, reads its own mailbox row and decrypts it with the session to the
///      UPLOADING device (which the server attributes — a client-claimed
///      sender would point this device at the wrong session).
///   3. CREATE, only when the server says there is no key at all.
///
/// Everything here is injected rather than reached for: the socket
/// request/response, the fan-out target resolution that already lives in the
/// send path, and the two Signal operations. That keeps this class testable
/// without a socket, a provider or a platform, which is the only way the
/// refusal paths below get covered at all.
class ReactionKeyService {
  ReactionKeyService({
    required EncryptionService store,
    required Future<Map<String, dynamic>?> Function(
      String event,
      Map<String, dynamic> payload,
    )
    request,
    required Future<List<ReactionKeyTarget>> Function(int peerUserId)
    resolveTargets,
    required Future<String> Function(
      int userId,
      int deviceId,
      String plaintext,
    )
    encryptFor,
    required Future<String> Function(
      int senderUserId,
      int senderDeviceId,
      String ciphertext,
    )
    decryptFrom,
    Random? random,
  }) : _store = store,
       _request = request,
       _resolveTargets = resolveTargets,
       _encryptFor = encryptFor,
       _decryptFrom = decryptFrom,
       _random = random ?? Random.secure();

  final EncryptionService _store;
  final Future<Map<String, dynamic>?> Function(
    String event,
    Map<String, dynamic> payload,
  )
  _request;
  final Future<List<ReactionKeyTarget>> Function(int peerUserId)
  _resolveTargets;
  final Future<String> Function(int userId, int deviceId, String plaintext)
  _encryptFor;
  final Future<String> Function(
    int senderUserId,
    int senderDeviceId,
    String ciphertext,
  )
  _decryptFrom;
  final Random _random;

  /// Codecs already built this session, so a chat that renders 50 rows pays
  /// the reverse-map build once.
  final Map<int, ReactionTokenCodec> _codecs = <int, ReactionTokenCodec>{};

  /// The acquisition currently running for a conversation, shared by everyone
  /// who asks while it is in flight.
  ///
  /// This is not an optimisation, it is a correctness requirement. A mailbox
  /// row can be decrypted exactly ONCE — the Signal message key is spent by
  /// the first success — so two parallel pulls would have the second answer
  /// `DuplicateMessage`, reporting `undecryptable` for a conversation whose
  /// key is perfectly healthy. The render path asks once per message row, so
  /// fifty simultaneous callers is the NORMAL case here, not a race.
  final Map<
    int,
    Future<({ReactionTokenCodec? codec, ReactionKeyFailure? failure})>
  >
  _inFlight = {};

  /// The codec for [conversationId] if it is already in memory, else null.
  ///
  /// Synchronous and side-effect free, for `build` paths: a widget must never
  /// start a socket round trip while laying out.
  ReactionTokenCodec? cachedCodec(int conversationId) => _codecs[conversationId];

  /// The codec for [conversationId], or the reason there is none.
  ///
  /// [mayCreate] is the destructive switch. Creating a key advances the
  /// server-assigned epoch, and a NEW epoch orphans every chip written under
  /// the old one for both participants' other devices — so a render path must
  /// pass false and only a deliberate act (the user reacting) may pass true.
  Future<({ReactionTokenCodec? codec, ReactionKeyFailure? failure})> ensureCodec(
    int conversationId, {
    required int peerUserId,
    bool mayCreate = false,
  }) async {
    // A mutex, not a best-effort share. Two `mayCreate` callers — an ordinary
    // double tap — used to fall past a single `await` and run two acquisitions
    // at once; the provider then handed both the SAME mailbox ciphertext, the
    // first decrypt spent the Signal message key, and the second answered
    // `undecryptable` for a key that was perfectly healthy. The loop re-checks
    // after every wait because the winner may have produced the codec.
    while (true) {
      final cached = _codecs[conversationId];
      if (cached != null) return (codec: cached, failure: null);

      final running = _inFlight[conversationId];
      if (running == null) break;
      final first = await running;
      // The running attempt answers for this caller too, UNLESS it was not
      // allowed to create and this caller is: then this caller takes its own
      // turn rather than inheriting a `noKeyYet` it could have fixed.
      if (first.codec != null || !mayCreate) return first;
      // Loop: `_inFlight` may already hold a NEW attempt started by another
      // waiter that woke first. Falling through here is what let two
      // acquisitions overlap.
    }

    final attempt = _acquire(
      conversationId,
      peerUserId: peerUserId,
      mayCreate: mayCreate,
    );
    // Registered with no await in between, so no caller can slip past the
    // check above and start a second attempt.
    _share(conversationId, attempt);
    try {
      return await attempt;
    } finally {
      // Only ever unregister OUR attempt: a blind `remove` deleted a later
      // attempt's entry and let a third caller start yet another one.
      if (identical(_inFlight[conversationId], attempt)) {
        _inFlight.remove(conversationId);
      }
    }
  }

  /// Publishes [attempt] as THE attempt for [conversationId].
  ///
  /// Deliberately not inlined: a bare `_inFlight[id] = future` inside an
  /// async body reads as a dropped future to both the analyzer and a human,
  /// when it is the opposite — the future is awaited by the caller and shared
  /// with everyone who arrives while it runs.
  void _share(
    int conversationId,
    Future<({ReactionTokenCodec? codec, ReactionKeyFailure? failure})> attempt,
  ) {
    _inFlight[conversationId] = attempt;
  }

  Future<({ReactionTokenCodec? codec, ReactionKeyFailure? failure})> _acquire(
    int conversationId, {
    required int peerUserId,
    required bool mayCreate,
  }) async {
    switch (await _store.loadReactionKey(conversationId)) {
      case ReactionKeyFound(:final keyB64):
        // Measured like a pulled key is. HMAC accepts any key length, so a
        // truncated record would mint well-formed tokens that nobody else
        // agrees with — every reaction from this device showing as a
        // placeholder to everyone, with no error anywhere. `unavailable`, not
        // absent: the record may yet be recoverable and must not authorise a
        // re-key.
        if (!_isValidKey(keyB64)) {
          return (codec: null, failure: ReactionKeyFailure.unavailable);
        }
        return (codec: _remember(conversationId, keyB64), failure: null);
      case ReactionKeyUnavailable():
        // Locked vault, corrupt row, dead store. Never create over this: the
        // key may be sitting right there, readable the moment it unlocks.
        return (codec: null, failure: ReactionKeyFailure.unavailable);
      case ReactionKeyAbsent():
        break;
    }

    final pulled = await _pull(conversationId);
    if (pulled.hasRow || pulled.failure != null) {
      return (codec: pulled.codec, failure: pulled.failure);
    }

    if (!mayCreate) return (codec: null, failure: ReactionKeyFailure.noKeyYet);

    // Create the conversation's FIRST key only (owner ruling 2026-09-17).
    //
    // `epoch == 0` means no key has ever existed here, so minting one orphans
    // nothing. A non-zero epoch with no row for this device means something
    // else entirely: this device was linked AFTER the key was distributed.
    // Minting there would advance the epoch and blank every existing chip for
    // both participants' other devices — devices that can still READ the
    // messages those chips sit on, which this one cannot (the server answers
    // `none_for_device` for anything predating the link). Trading their
    // working reactions for ours is a bad deal, so this device waits for the
    // uploader's same-epoch top-up and shows placeholders until then.
    if (pulled.epoch != 0) {
      return (codec: null, failure: ReactionKeyFailure.noKeyYet);
    }
    // `_pull` already told us the server's epoch, so creating costs no second
    // round trip.
    return _create(
      conversationId,
      peerUserId: peerUserId,
      currentEpoch: pulled.epoch,
    );
  }

  /// Reads this device's mailbox row.
  ///
  /// `hasRow: false` with no failure means "the server has no row for this
  /// device", which is the only answer that lets a caller consider creating
  /// one. `epoch` is always the server's current epoch, so the create path
  /// needs no second fetch.
  Future<_PullOutcome> _pull(int conversationId) async {
    final answer = await _request('fetchReactionKey', {
      'conversationId': conversationId,
    });
    if (answer == null || answer['error'] != null) {
      // `error` present is a REFUSAL; a null ciphertext without it is the
      // legitimate "no row for this device". Conflating them would render
      // placeholder chips forever instead of retrying.
      return (
        codec: null,
        failure: ReactionKeyFailure.refused,
        epoch: 0,
        hasRow: false,
      );
    }
    final rawEpoch = answer['epoch'];
    final epoch = rawEpoch is int ? rawEpoch : 0;
    final ciphertext = answer['ciphertext'];
    final senderUserId = answer['senderUserId'];
    final senderDeviceId = answer['senderDeviceId'];
    if (ciphertext is! String ||
        senderUserId is! int ||
        senderDeviceId is! int) {
      return (codec: null, failure: null, epoch: epoch, hasRow: false);
    }

    final String keyB64;
    try {
      keyB64 = await _decryptFrom(senderUserId, senderDeviceId, ciphertext);
    } on Object catch (_) {
      // The row exists and this device cannot open it — a spent ratchet step,
      // most likely. Deliberately NOT treated as an absence: re-keying here
      // would orphan chips for a peer who is perfectly healthy.
      return (
        codec: null,
        failure: ReactionKeyFailure.undecryptable,
        epoch: epoch,
        hasRow: true,
      );
    }
    if (!_isValidKey(keyB64)) {
      return (
        codec: null,
        failure: ReactionKeyFailure.undecryptable,
        epoch: epoch,
        hasRow: true,
      );
    }

    // The bool is LOAD-BEARING on this side, more than on the create side.
    // The decrypt above SPENT the Signal message key, so if the store write
    // fails the plaintext exists only in this process: the next launch reads
    // Absent, pulls the same row, hits DuplicateMessage and answers
    // `undecryptable` for good — chips orphaned with no way back. Reporting
    // `unavailable` instead keeps the door open: the caller retries, and the
    // store may well answer next time (a locked vault unlocks).
    final stored = await _store.saveReactionKey(
      conversationId: conversationId,
      epoch: epoch,
      keyB64: keyB64,
    );
    if (!stored) {
      return (
        codec: null,
        failure: ReactionKeyFailure.unavailable,
        epoch: epoch,
        hasRow: true,
      );
    }
    return (
      codec: _remember(conversationId, keyB64),
      failure: null,
      epoch: epoch,
      hasRow: true,
    );
  }

  /// Mints the conversation's first `K_react` and publishes it.
  ///
  /// ORDER IS THE WHOLE POINT. The upload is what advances the server's
  /// epoch, and the fan-out deliberately never addresses this device, so
  /// there is no mailbox row to recover from: if the key were published
  /// before being stored, a lost ack would leave the server serving an epoch
  /// whose only plaintext copy died with this call — and the epoch-0 gate
  /// would then refuse to re-key, forever. So the key is persisted FIRST and
  /// rolled back on every refusal, which is the direction that cannot lose
  /// data: a stored-but-unpublished key is simply retried, and a stored key
  /// the server rejected is deleted before anyone relies on it.
  Future<({ReactionTokenCodec? codec, ReactionKeyFailure? failure})> _create(
    int conversationId, {
    required int peerUserId,
    required int currentEpoch,
  }) async {
    final key = Uint8List.fromList(
      List<int>.generate(
        ReactionTokenCodec.keyBytes,
        (_) => _random.nextInt(256),
      ),
    );
    final keyB64 = base64Encode(key);
    final epoch = currentEpoch + 1;

    final List<ReactionKeyTarget> targets;
    final envelopes = <Map<String, dynamic>>[];
    try {
      targets = await _resolveTargets(peerUserId);
      if (targets.isEmpty) {
        // No addressable device set. Refusing costs the user one snackbar;
        // publishing to a guessed address costs the conversation its epoch.
        return (codec: null, failure: ReactionKeyFailure.refused);
      }
      for (final target in targets) {
        envelopes.add({
          'userId': target.userId,
          'deviceId': target.deviceId,
          'ciphertext': await _encryptFor(
            target.userId,
            target.deviceId,
            keyB64,
          ),
        });
      }
    } on Object catch (_) {
      // `ensureSession`/`encrypt` throw for real, routine reasons — a peer
      // device with no key bundle, an unanswered pre-key fetch, an
      // uninitialised stack. Converted into a failure code so the sealed enum
      // stays total and the tap reports itself instead of dying as an
      // unhandled async error (which showed the user a dead tap).
      return (codec: null, failure: ReactionKeyFailure.refused);
    }

    // Persist BEFORE publishing (see the doc comment). Nothing has been
    // announced yet, so a failure here is free to retry.
    if (!await _store.saveReactionKey(
      conversationId: conversationId,
      epoch: epoch,
      keyB64: keyB64,
    )) {
      return (codec: null, failure: ReactionKeyFailure.unavailable);
    }

    // The server owns the epoch; this is a proposal built on the epoch the
    // preceding fetch already reported. A race loses with `stale_epoch`, and
    // the loser must PULL rather than retry with a key nobody else has.
    final answer = await _request('uploadReactionKey', {
      'conversationId': conversationId,
      'epoch': epoch,
      'envelopes': envelopes,
    });
    if (answer == null || answer['success'] != true) {
      // Roll back: a key the server never accepted must not survive, because
      // `loadReactionKey` would answer `Found` on every later launch and the
      // real key would never be pulled.
      await _store.dropReactionKey(conversationId);
      if (answer != null && answer['error'] == 'stale_epoch') {
        final pulled = await _pull(conversationId);
        if (pulled.hasRow || pulled.failure != null) {
          return (codec: pulled.codec, failure: pulled.failure);
        }
      }
      return (codec: null, failure: ReactionKeyFailure.refused);
    }

    // The server assigns the epoch. If it differs from the proposal, re-stamp
    // the record so the stored epoch matches what the mailbox says.
    final assigned = answer['epoch'];
    if (assigned is int && assigned != epoch) {
      await _store.saveReactionKey(
        conversationId: conversationId,
        epoch: assigned,
        keyB64: keyB64,
      );
    }
    return (codec: _remember(conversationId, keyB64), failure: null);
  }

  // (see the top-level `_PullOutcome` for what a mailbox read can answer)

  static bool _isValidKey(String keyB64) {
    try {
      return base64Decode(keyB64).length == ReactionTokenCodec.keyBytes;
    } on Object catch (_) {
      return false;
    }
  }

  ReactionTokenCodec _remember(int conversationId, String keyB64) {
    final codec = ReactionTokenCodec(
      Uint8List.fromList(base64Decode(keyB64)),
    );
    _codecs[conversationId] = codec;
    return codec;
  }

  /// Drops cached codecs (logout, account switch).
  ///
  /// In-flight attempts are dropped from the map too, so a request answered
  /// after a logout cannot hand the NEXT account a codec keyed by a
  /// conversation id it may well reuse.
  void clear() {
    _codecs.clear();
    _inFlight.clear();
  }
}
