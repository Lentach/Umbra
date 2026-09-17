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
    final cached = _codecs[conversationId];
    if (cached != null) return (codec: cached, failure: null);

    switch (await _store.loadReactionKey(conversationId)) {
      case ReactionKeyFound(:final keyB64):
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

  Future<({ReactionTokenCodec? codec, ReactionKeyFailure? failure})> _create(
    int conversationId, {
    required int peerUserId,
    required int currentEpoch,
  }) async {
    final targets = await _resolveTargets(peerUserId);
    if (targets.isEmpty) {
      return (codec: null, failure: ReactionKeyFailure.refused);
    }

    final key = Uint8List.fromList(
      List<int>.generate(ReactionTokenCodec.keyBytes, (_) => _random.nextInt(256)),
    );
    final keyB64 = base64Encode(key);

    final envelopes = <Map<String, dynamic>>[];
    for (final target in targets) {
      envelopes.add({
        'userId': target.userId,
        'deviceId': target.deviceId,
        'ciphertext': await _encryptFor(target.userId, target.deviceId, keyB64),
      });
    }

    // The server owns the epoch; this is a proposal built on the epoch the
    // preceding fetch already reported. A race loses with `stale_epoch`, and
    // the loser must PULL rather than retry with a key nobody else has.
    final answer = await _request('uploadReactionKey', {
      'conversationId': conversationId,
      'epoch': currentEpoch + 1,
      'envelopes': envelopes,
    });
    if (answer == null || answer['success'] != true) {
      if (answer != null && answer['error'] == 'stale_epoch') {
        final pulled = await _pull(conversationId);
        if (pulled.hasRow || pulled.failure != null) {
          return (codec: pulled.codec, failure: pulled.failure);
        }
      }
      return (codec: null, failure: ReactionKeyFailure.refused);
    }

    final epoch = answer['epoch'];
    final stored = await _store.saveReactionKey(
      conversationId: conversationId,
      epoch: epoch is int ? epoch : currentEpoch + 1,
      keyB64: keyB64,
    );
    if (!stored) {
      // The write is armed, and an unstored key is worse than no key: the
      // server now serves an epoch whose plaintext this device has lost.
      return (codec: null, failure: ReactionKeyFailure.unavailable);
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
  void clear() => _codecs.clear();
}
