part of 'contact_store.dart';

const int _siblingsVersion = 1;

/// What a sibling-row write came to.
enum SiblingWrite {
  /// On disk (or already there).
  stored,

  /// Nothing could be decided now — the store is closed (a passcode re-lock,
  /// logout) or the write did not commit; the same write may succeed later.
  retryLater,

  /// Never: a newer build owns the row, or the write names something that is
  /// not current (an ack of a self-queue sid this device no longer holds).
  refused,
}

/// Another live device of this account, as this device knows it (metadata-
/// privacy PR3.1 sibling queues, owner decisions 26/27). [sid]/[sealPub] are
/// the sibling's SELF-queue, learned from its `queue_handoff`, null until one
/// arrived; [ackedSelfSid] is which of THIS device's self-queue sids that
/// sibling confirmed with a `queue_handoff_ack`.
class SiblingAddress {
  const SiblingAddress({
    required this.deviceId,
    this.sid,
    this.sealPub,
    this.ackedSelfSid,
  });

  final int deviceId;
  final String? sid;
  final String? sealPub;
  final String? ackedSelfSid;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    if (sid != null) 'sid': sid,
    if (sealPub != null) 'sealPub': sealPub,
    if (ackedSelfSid != null) 'ackedSelfSid': ackedSelfSid,
  };

  /// Null for an entry this build cannot read; the rest of the row stands.
  static SiblingAddress? _fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final deviceId = raw['deviceId'];
    final sid = raw['sid'];
    final sealPub = raw['sealPub'];
    final acked = raw['ackedSelfSid'];
    if (deviceId is! int) return null;
    if (sid is! String? || sealPub is! String? || acked is! String?) {
      return null;
    }
    // An address is both halves or neither.
    if ((sid == null) != (sealPub == null)) return null;
    return SiblingAddress(
      deviceId: deviceId,
      sid: sid,
      sealPub: sealPub,
      ackedSelfSid: acked,
    );
  }
}

/// A self-queue this device replaced on rotation (E6): still subscribed and
/// read for the box TTL ([kBoxRedeliveryWindow]) after [since], then
/// deleted. Never earlier: a sibling may still send into it — a copy built
/// before it learned the new address, a second tab working from an older
/// row — and a `send` to a deleted sid is answered ok, so anything sent
/// there after the delete would be lost without a trace. What a revoked
/// device sends into it meanwhile is finished unread (its origin is
/// revoked).
class RetiringSelfQueue {
  const RetiringSelfQueue({required this.queue, required this.since});

  final ContactQueue queue;
  final DateTime since;

  Map<String, dynamic> toJson() => {
    ...queue.toJson(),
    'since': since.millisecondsSinceEpoch,
  };

  /// Null for an entry this build cannot read; the rest of the row stands.
  static RetiringSelfQueue? _fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final since = raw['since'];
    if (since is! int) return null;
    try {
      return RetiringSelfQueue(
        queue: ContactQueue.fromJson(raw),
        since: DateTime.fromMillisecondsSinceEpoch(since, isUtc: true),
      );
    } on Object {
      return null;
    }
  }
}

/// The `boxsib_v1` row: this device's self-queue (private halves), the ones
/// it is retiring, and what it knows of every sibling.
class _SiblingBook {
  const _SiblingBook({
    this.self,
    this.retiring = const [],
    this.siblings = const [],
  });

  static const _SiblingBook empty = _SiblingBook();

  final ContactQueue? self;
  final List<RetiringSelfQueue> retiring;
  final List<SiblingAddress> siblings;

  _SiblingBook withSelf(ContactQueue? queue) =>
      _SiblingBook(self: queue, retiring: retiring, siblings: siblings);

  _SiblingBook withSiblings(Iterable<SiblingAddress> kept) => _SiblingBook(
    self: self,
    retiring: retiring,
    siblings: kept.toList(),
  );

  /// [deviceId]'s entry rewritten by [change] (from an empty one if absent).
  _SiblingBook withSibling(
    int deviceId,
    SiblingAddress Function(SiblingAddress current) change,
  ) {
    final current =
        siblings.where((s) => s.deviceId == deviceId).firstOrNull ??
        SiblingAddress(deviceId: deviceId);
    return withSiblings(
      [
        for (final s in siblings)
          if (s.deviceId != deviceId) s,
        change(current),
      ]..sort((a, b) => a.deviceId.compareTo(b.deviceId)),
    );
  }

  Map<String, dynamic> toJson() => {
    'v': _siblingsVersion,
    if (self != null) 'self': self!.toJson(),
    if (retiring.isNotEmpty)
      'retiring': [for (final r in retiring) r.toJson()],
    'siblings': [for (final s in siblings) s.toJson()],
  };

  /// Null = a NEWER build's row, off limits. Absent, garbage or a web row
  /// whose seal key was lost reads as [empty]: replaceable, because the swap
  /// re-learns every address (decision 28) and a fresh self-queue is handed
  /// off again.
  static _SiblingBook? decode(Object? raw) {
    if (raw is! String) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return empty;
      final v = decoded['v'];
      if (v is int && v > _siblingsVersion) return null;
      ContactQueue? self;
      try {
        final rawSelf = decoded['self'];
        if (rawSelf != null) {
          self = ContactQueue.fromJson(rawSelf as Map<String, dynamic>);
        }
      } on Object {
        self = null;
      }
      final rawRetiring = decoded['retiring'];
      final rawSiblings = decoded['siblings'];
      return _SiblingBook(
        self: self,
        retiring: [
          if (rawRetiring is List)
            for (final r in rawRetiring) ?RetiringSelfQueue._fromJson(r),
        ],
        siblings: [
          if (rawSiblings is List)
            for (final s in rawSiblings) ?SiblingAddress._fromJson(s),
        ],
      );
    } on Object {
      return empty;
    }
  }
}

/// This device's box SELF-queue and its siblings' self-queue addresses, one
/// row `e2e_<uid>_boxsib_v1` (owner decision 28). OUTSIDE `contact_v1_` for
/// the `boxreq_v1` reasons — the history file copies that family verbatim
/// and a second install importing these private halves would take the queue
/// over — and NO backup carries it: after a storage loss the swap re-learns
/// it. Same kv, lock, `_generation` close semantics and newer-build refusal
/// as every other row here; never fires [ContactStore.onChanged].
extension ContactStoreSiblings on ContactStore {
  /// This device's self-queue as last read or claimed; null when there is
  /// none, or the row is unreadable (replaceable) or a newer build's.
  ContactQueue? get selfQueue => _siblingBook.self;

  /// Every sibling this device knows of, by device id.
  List<SiblingAddress> get siblings => List.unmodifiable(_siblingBook.siblings);

  /// Self-queues this device replaced and has not deleted yet (E6).
  List<RetiringSelfQueue> get retiringSelfQueues =>
      List.unmodifiable(_siblingBook.retiring);

  /// A NEWER build wrote the row: it is never overwritten.
  bool get siblingsUnsupported => _siblingsUnsupported;

  /// Stores [candidate] as this device's self-queue UNLESS a readable one is
  /// already on disk (another tab claimed first), which is kept and
  /// returned; the caller deletes its own from the box. Null when nothing
  /// could be decided (closed, uncommitted, a newer build's row).
  Future<ContactQueue?> claimSelfQueue(ContactQueue candidate) async {
    ContactQueue? kept;
    final outcome = await _updateSiblings((book) {
      kept = book.self ?? candidate;
      return book.self == null ? book.withSelf(candidate) : book;
    });
    return outcome == SiblingWrite.stored ? kept : null;
  }

  /// Forgets the self-queue [rid] (the box refused it). A row holding a
  /// DIFFERENT queue is left alone; sibling addresses always stay.
  Future<bool> dropSelfQueue(String rid) async =>
      await _updateSiblings(
        (book) => book.self?.rid == rid ? book.withSelf(null) : book,
      ) ==
      SiblingWrite.stored;

  /// Sibling [deviceId]'s self-queue is ([sid], [sealPub]) — its newest
  /// handoff replaces any older address; what it acknowledged stays.
  Future<SiblingWrite> learnSibling(
    int deviceId, {
    required String sid,
    required String sealPub,
  }) => _updateSiblings(
    (book) => book.withSibling(
      deviceId,
      (s) => SiblingAddress(
        deviceId: deviceId,
        sid: sid,
        sealPub: sealPub,
        ackedSelfSid: s.ackedSelfSid,
      ),
    ),
  );

  /// Sibling [deviceId] acknowledged self-queue [sid]: recorded only when
  /// [sid] is this device's CURRENT self-queue on disk; an ack of any other
  /// is [SiblingWrite.refused] — the sibling holds a stale address, and the
  /// caller hands it the current one ([forgetSiblingAck]).
  Future<SiblingWrite> markSiblingAcked(int deviceId, String sid) =>
      _updateSiblings((book) {
        if (book.self?.sid != sid) return null;
        return book.withSibling(
          deviceId,
          (s) => SiblingAddress(
            deviceId: deviceId,
            sid: s.sid,
            sealPub: s.sealPub,
            ackedSelfSid: sid,
          ),
        );
      });

  /// Sibling [deviceId] acknowledged a self sid that is NOT current: an
  /// older handoff overtook the newer one (the two travel through different
  /// queues, which the box does not order), so it sends into a queue we
  /// replaced, which is deleted once its TTL ends. What it acknowledged is
  /// forgotten, so the swap hands it the current one again. No entry is
  /// made for a device without one.
  Future<SiblingWrite> forgetSiblingAck(int deviceId) =>
      _updateSiblings((book) {
        if (!book.siblings.any((s) => s.deviceId == deviceId)) return book;
        return book.withSibling(
          deviceId,
          (s) => SiblingAddress(
            deviceId: deviceId,
            sid: s.sid,
            sealPub: s.sealPub,
          ),
        );
      });

  /// Keeps an entry for sibling [deviceId] — adding an empty one if there is
  /// none — BEFORE this device hands it our self-queue: every device that may
  /// hold our self sid has an entry, so its revocation is seen (E6) even if
  /// it never answered.
  Future<SiblingWrite> noteSibling(int deviceId) =>
      _updateSiblings((book) => book.withSibling(deviceId, (s) => s));

  /// Drops every sibling entry whose device the own verified list no longer
  /// names live ([live]), when nothing needs rotating (E7).
  Future<SiblingWrite> pruneSiblings(Set<int> live) => _updateSiblings(
    (book) => book.withSiblings(
      book.siblings.where((s) => live.contains(s.deviceId)),
    ),
  );

  /// Rotation (E6), ONE write: [next] becomes the self-queue, the one it
  /// [replaces] (by rid) starts retiring at [now], and every sibling entry
  /// outside [live] is dropped. Null — the caller deletes [next] from the
  /// box — when the self-queue on disk is not [replaces] (another tab
  /// rotated or replaced it first) or nothing could be decided.
  Future<ContactQueue?> rotateSelfQueue(
    ContactQueue next, {
    required String replaces,
    required Set<int> live,
    required DateTime now,
  }) async {
    final outcome = await _updateSiblings((book) {
      final old = book.self;
      if (old == null || old.rid != replaces) return null;
      return _SiblingBook(
        self: next,
        retiring: [
          ...book.retiring,
          RetiringSelfQueue(queue: old, since: now),
        ],
        siblings: [
          for (final s in book.siblings)
            if (live.contains(s.deviceId)) s,
        ],
      );
    });
    return outcome == SiblingWrite.stored ? next : null;
  }

  /// Forgets retiring self-queue [rid] (deleted from the box).
  Future<SiblingWrite> dropRetiringSelfQueue(String rid) => _updateSiblings(
    (book) => _SiblingBook(
      self: book.self,
      retiring: [
        for (final r in book.retiring)
          if (r.queue.rid != rid) r,
      ],
      siblings: book.siblings,
    ),
  );

  /// Read-modify-write of the row under the account lock, from GROUND TRUTH.
  /// [mutate] returns the book to keep (the same content = no write) or null
  /// to refuse.
  Future<SiblingWrite> _updateSiblings(
    _SiblingBook? Function(_SiblingBook current) mutate,
  ) {
    final kv = _kv;
    final userId = _userId;
    if (kv == null || userId == null) {
      return Future.value(SiblingWrite.retryLater);
    }
    final generation = _generation;
    var outcome = SiblingWrite.retryLater;
    return _serial(
      () => _lock(ContactStore.lockName(userId), () async {
        if (_generation != generation) return false;
        final key = ContactStore.siblingsKey(userId);
        final raw = (await ContactStore._readWhere(kv, (k) => k == key))[key];
        final current = _SiblingBook.decode(raw);
        if (current == null) {
          outcome = SiblingWrite.refused;
          return false;
        }
        final next = mutate(current);
        if (next == null) {
          outcome = SiblingWrite.refused;
          if (_generation == generation) _siblingBook = current;
          return false;
        }
        final encoded = jsonEncode(next.toJson());
        if (encoded != raw && !await kv.setString(key, encoded)) return false;
        if (_generation == generation) _siblingBook = next;
        outcome = SiblingWrite.stored;
        return true;
      }),
    ).then((_) => outcome);
  }
}
