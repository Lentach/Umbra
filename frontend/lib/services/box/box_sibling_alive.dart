import 'package:clock/clock.dart';

import '../contacts/contact_store.dart';

/// How often at most this device sends each sibling `alive` (decision 103).
const Duration kSiblingAliveEvery = Duration(hours: 24);

/// How long a sibling may stay silent before the primary asks to unlink it
/// (decision 101 B).
const Duration kSiblingSilentAfter = Duration(days: 30);

/// How long "Keep" keeps that question away for one device.
const Duration kSiblingKeepFor = Duration(days: 30);

/// The finest step a heard mark moves in: a frame from a sibling heard
/// within it writes nothing. Silence is counted in days.
const Duration kSiblingHeardStep = Duration(hours: 1);

/// The account's primary as the Devices screen derives it: the lowest live
/// device id, the row login resolves to and the only one offered a revoke.
/// Null for an empty list.
int? primaryDeviceOf(Iterable<int> live) =>
    live.isEmpty ? null : live.reduce((a, b) => a < b ? a : b);

/// Decision 101 B: the primary asks to unlink a sibling heard from last
/// more than [kSiblingSilentAfter] ago, unless the user kept it and that
/// keep still runs. A sibling with no heard mark is never asked about: it
/// is first known when the pass sees it ([BoxSiblingAlive.known]).
bool siblingUnlinkDue({
  required bool primary,
  required DateTime? heardAt,
  required DateTime? keptUntil,
  required DateTime now,
}) =>
    primary &&
    heardAt != null &&
    now.difference(heardAt) > kSiblingSilentAfter &&
    (keptUntil == null || !now.isBefore(keptUntil));

/// Decisions 101 B and 103 on this install: when each own sibling was last
/// heard on our self-queue, the daily `alive` this device owes each one, and
/// the user's "Keep". Every decision reads [ContactStore]'s `boxalive_v1`
/// row; a closed store knows nothing and writes nothing.
class BoxSiblingAlive {
  BoxSiblingAlive({required ContactStore store, DateTime Function()? now})
    : _store = store,
      _now = now ?? clock.now;

  final ContactStore _store;
  final DateTime Function() _now;

  /// One pass at a time: a connect asks for it from several places.
  bool _passing = false;

  DateTime get now => _now().toUtc();

  /// When sibling [deviceId] was last heard (or first known here).
  DateTime? heardAt(int deviceId) => _store.siblingHeardAt(deviceId);

  /// Starts a pass unless one is running; [endPass] ends it.
  bool beginPass() {
    if (_passing) return false;
    _passing = true;
    return true;
  }

  void endPass() => _passing = false;

  /// An authenticated frame from sibling [deviceId] was read now. True when
  /// the mark moved on disk; a mark less than [kSiblingHeardStep] old stays.
  Future<bool> heard(int deviceId) {
    final at = now;
    final held = heardAt(deviceId);
    if (held != null && at.difference(held) < kSiblingHeardStep) {
      return Future.value(false);
    }
    return _store.markSiblingHeard(deviceId, at);
  }

  /// [siblings] are the live own siblings now: one never heard is first
  /// known now, and an entry for any other device goes.
  Future<bool> known(Set<int> siblings) =>
      _store.noteSiblingsKnown(siblings, now);

  /// The [siblings] this device owes an `alive`: none sent yet, or the last
  /// one [kSiblingAliveEvery] ago or more.
  List<int> aliveDue(Iterable<int> siblings) {
    final at = now;
    return [
      for (final id in siblings)
        if (_store.siblingPresence(id)?.aliveSentAt case final sent
            when sent == null || at.difference(sent) >= kSiblingAliveEvery)
          id,
    ];
  }

  /// The box took this device's `alive` for [deviceId].
  Future<bool> aliveSent(int deviceId) =>
      _store.markSiblingAliveSent(deviceId, now);

  /// Sibling [deviceId] sent `alive`, `sync_req`, `sync_resp` or `relay`:
  /// its build reads `relay` (E101b).
  Future<bool> readsRelays(int deviceId) =>
      _store.markSiblingReadsRelays(deviceId);

  /// Whether every one of [siblings] was heard sending a frame only a build
  /// that reads `relay` sends (E101b). True for none: nothing to relay to.
  bool allReadRelays(Iterable<int> siblings) => siblings.every(
    (id) => _store.siblingPresence(id)?.readsRelays ?? false,
  );

  /// The user kept [deviceId]: not asked again for [kSiblingKeepFor].
  Future<bool> keep(int deviceId) =>
      _store.keepSibling(deviceId, now.add(kSiblingKeepFor));

  /// The first of [live] (lowest id) the primary should ask to unlink, or
  /// null — always null unless [self] is the primary of [live].
  int? unlinkDue({required int self, required List<int> live}) {
    final primary = primaryDeviceOf(live) == self;
    if (!primary) return null;
    final at = now;
    final siblings = [
      for (final id in live)
        if (id != self) id,
    ]..sort();
    for (final id in siblings) {
      final presence = _store.siblingPresence(id);
      if (siblingUnlinkDue(
        primary: primary,
        heardAt: presence?.heardAt,
        keptUntil: presence?.keptUntil,
        now: at,
      )) {
        return id;
      }
    }
    return null;
  }
}
