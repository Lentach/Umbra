import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../utils/e2e_envelope.dart';
import '../contacts/contact_record.dart';

/// Why [FriendGate] kept a friend frame from being written.
enum FriendGateRefusal {
  /// The caller took no permit: it fails closed.
  noPermit,

  /// The target is not an address this friend holds NOW (the stored one of
  /// that device, or a request address already served).
  unknownAddress,

  /// A calm hold waits for the person's tap.
  calmHeld,

  /// The one labelling of untagged addresses has not run on an open store.
  unlabelled,

  /// The journal has not been judged once this session.
  journalUnjudged,

  /// The frame was sealed under another identity than the one pinned now.
  permitIdentity,

  /// The address was learned under another identity than the one pinned.
  staleAddress,

  /// The address is no longer stale (a probe has nothing to prove).
  notStale,
}

/// The right to seal ONE round of frames for a friend, taken synchronously
/// BEFORE Signal encrypts ([FriendGate.permitFor]). It captures the account
/// identity pinned for the friend at that moment; the write lets a frame out
/// only while that is still the pinned one.
final class FriendPermit {
  FriendPermit._(
    this.friend,
    this._identity, {
    required this.goodbye,
    bool? firstPin,
  }) : firstPin = firstPin ?? _identity == null;

  /// The permit of a stand-in outbox that has no gate (a test double that is
  /// not the box session): it adopts whatever session it seals on.
  FriendPermit.ungated(this.friend)
    : _identity = null,
      firstPin = true,
      goodbye = true;

  /// A permit for [friend] captured under [identity], for a test's stand-in
  /// box.
  @visibleForTesting
  FriendPermit.forTest(this.friend, {String? identity, this.goodbye = false})
    : _identity = identity,
      firstPin = identity == null;

  final int friend;

  /// No identity was pinned when the permit was taken: the pin its own
  /// encrypt makes is the one it stands for ([admitsSession]).
  final bool firstPin;

  /// An account-delete goodbye: exempt from the journal clause only.
  final bool goodbye;

  String? _identity;

  /// The identity this permit seals under (base64); null until a first pin.
  String? get identity => _identity;

  /// Asked inside the encrypt's serialized step with the remote identity of
  /// the session about to seal: a session of another identity than the
  /// permit's is refused (a whisper of an old install can bring an old
  /// session state back). A [firstPin] permit takes the session's identity
  /// as its own.
  bool admitsSession(String? sessionIdentity) {
    if (_identity == null) {
      _identity = sessionIdentity;
      return true;
    }
    return sessionIdentity == _identity;
  }
}

/// The right to write THE probe of a stale address: one `queue_handoff` of a
/// fresh queue to that address and nothing else. It is NOT a [FriendPermit]
/// (type-level): every message, receipt, typing, timer, profile and upload
/// path takes a [FriendPermit], so none can be offered this one; the only
/// seal that takes it builds the handoff itself ([handoffJson]).
final class ProbePermit {
  ProbePermit._(
    this.friend,
    this.identity, {
    required this.device,
    required this.targetSid,
    required this.handoffSid,
    required this.handoffSealPub,
  });

  final int friend;

  /// The pinned identity (base64) this probe seals under.
  final String identity;
  final int device;

  /// The stale address the probe is written to.
  final String targetSid;

  /// The queue handed over (Z) and its seal key.
  final String handoffSid;
  final String handoffSealPub;

  /// The only plaintext this permit seals.
  String get handoffJson => jsonEncode(
    E2eEnvelope.buildQueueHandoff(sid: handoffSid, sealPub: handoffSealPub),
  );

  /// Asked inside the encrypt's serialized step with the remote identity of
  /// the session about to seal: only a session of the pinned identity seals.
  bool admitsSession(String? sessionIdentity) =>
      sessionIdentity != null && sessionIdentity == identity;
}

/// The one rule for writing to a friend's queue: a frame leaves only when
/// its target is current for the friend's pinned identity. Pure and
/// synchronous, so the check and the write share one step.
final class FriendGate {
  FriendGate({
    required Iterable<ContactOutbound> Function(int friend) addressesOf,
    required String? Function(int friend)? anchorOf,
    required bool Function() journalJudged,
    bool Function()? labelled,
  }) : _addressesOf = addressesOf,
       _anchorOf = anchorOf,
       _journalJudged = journalJudged,
       _labelled = labelled;

  /// Every address held for a friend NOW: the stored one per device and the
  /// request addresses already served.
  final Iterable<ContactOutbound> Function(int friend) _addressesOf;

  /// The pinned account identity, answered without an await. Without a
  /// mirror (a test's bare session) no identity clause applies.
  final String? Function(int friend)? _anchorOf;

  final bool Function() _journalJudged;

  /// Whether the one labelling of untagged addresses ran on an OPEN store in
  /// this process. Until it did, a missing tag means "not yet labelled", not
  /// "learned under another identity": messages wait and nothing is probed.
  /// Null (a bare test session): no such clause.
  final bool Function()? _labelled;

  bool get _unlabelled => _labelled != null && !_labelled();

  /// Whether a calm hold is pending for a friend (`MessagingProvider`). A
  /// red hold before the acknowledge does NOT close the gate.
  bool Function(int friend)? calmHeld;

  ContactOutbound? _held(int friend, String sid) =>
      _addressesOf(friend).where((a) => a.sid == sid).firstOrNull;

  /// A permit to seal for [friend], or null while the gate is closed (then
  /// nothing is sealed and no ratchet moves): a calm hold is pending, the
  /// journal is unjudged (a [goodbye] is exempt from that), or one of [to]
  /// is not a current address of the friend.
  FriendPermit? permitFor(
    int friend, {
    Iterable<ContactOutbound> to = const [],
    bool goodbye = false,
  }) {
    if (calmHeld?.call(friend) ?? false) return null;
    if (!goodbye && (!_journalJudged() || _unlabelled)) return null;
    final anchor = _anchorOf?.call(friend);
    for (final target in to) {
      final held = _held(friend, target.sid);
      if (held == null) return null;
      if (_stale(anchor, held)) return null;
    }
    return FriendPermit._(friend, anchor, goodbye: goodbye);
  }

  /// Whether a probe of [stale] may be prepared now: no calm hold pending,
  /// the journal judged, an anchor pinned and [stale] still held, stale and
  /// unproven. Asked BEFORE a probe queue is minted, so a closed gate mints
  /// nothing.
  bool probeOpen(int friend, ContactOutbound stale) {
    if (calmHeld?.call(friend) ?? false) return false;
    if (!_journalJudged() || _unlabelled) return false;
    final anchor = _anchorOf?.call(friend);
    final held = _held(friend, stale.sid);
    return anchor != null && held != null && _foreign(anchor, held);
  }

  /// The permit of THE probe: the handoff of `z` (a queue minted for it) to
  /// the stale [stale] address, sealed on the session under the pinned
  /// identity. Null while [probeOpen] is false. It can carry nothing else
  /// ([ProbePermit]).
  ProbePermit? probePermitFor(
    int friend, {
    required ContactOutbound stale,
    required String handoffSid,
    required String handoffSealPub,
  }) {
    if (!probeOpen(friend, stale)) return null;
    return ProbePermit._(
      friend,
      _anchorOf!(friend)!,
      device: stale.peerDeviceId,
      targetSid: stale.sid,
      handoffSid: handoffSid,
      handoffSealPub: handoffSealPub,
    );
  }

  /// Why the probe under [permit] may NOT be written now; null when it may.
  /// The probe is the ONLY write allowed to a stale address, so this is not
  /// [refusalOf]: the target must still be that very stale address, with a
  /// calm hold not pending, the journal judged and the permit's identity the
  /// pinned one.
  FriendGateRefusal? refusalOfProbe(ProbePermit permit, String sid) {
    final friend = permit.friend;
    if (sid != permit.targetSid) return FriendGateRefusal.unknownAddress;
    final held = _held(friend, sid);
    if (held == null) return FriendGateRefusal.unknownAddress;
    if (calmHeld?.call(friend) ?? false) return FriendGateRefusal.calmHeld;
    if (!_journalJudged()) return FriendGateRefusal.journalUnjudged;
    final anchor = _anchorOf?.call(friend);
    if (anchor == null || permit.identity != anchor) {
      return FriendGateRefusal.permitIdentity;
    }
    if (_unlabelled) return FriendGateRefusal.unlabelled;
    if (!_foreign(anchor, held)) return FriendGateRefusal.notStale;
    return null;
  }

  bool _stale(String? anchor, ContactOutbound held) =>
      _anchorOf != null && anchor != null && held.idk != anchor;

  /// Learned under ANOTHER identity: a tag that differs from the pin. An
  /// untagged address is not foreign (not yet labelled): only a foreign one
  /// may ever be probed.
  bool _foreign(String? anchor, ContactOutbound held) =>
      _anchorOf != null &&
      anchor != null &&
      held.idk != null &&
      held.idk != anchor;

  /// Whether [address] was learned under another identity than the one
  /// pinned for [friend] now: it is stale, and only a request address
  /// already served may stand in for it (no lookup is made for it).
  bool isStale(int friend, ContactOutbound address) =>
      _stale(_anchorOf?.call(friend), address);

  /// Whether [address] carries a tag that differs from the pin: the only
  /// kind a probe may be sent to.
  bool isForeign(int friend, ContactOutbound address) =>
      _foreign(_anchorOf?.call(friend), address);

  /// The permit of a first-contact request, taken once its PreKey is sealed
  /// (the pin that encrypt made is the anchor now): the null-anchor rule
  /// (an untagged address is accepted), no journal clause.
  FriendPermit requestPermit(int friend) => FriendPermit._(
    friend,
    _anchorOf?.call(friend),
    goodbye: true,
    firstPin: true,
  );

  /// Why a frame sealed under [permit] may NOT be written to [sid] now;
  /// null when it may. Called after every await, in the same synchronous
  /// step as the write, and re-reads the friend's addresses.
  FriendGateRefusal? refusalOf(FriendPermit? permit, String sid) {
    if (permit == null) return FriendGateRefusal.noPermit;
    final friend = permit.friend;
    final held = _held(friend, sid);
    if (held == null) return FriendGateRefusal.unknownAddress;
    if (calmHeld?.call(friend) ?? false) return FriendGateRefusal.calmHeld;
    if (!permit.goodbye && (!_journalJudged() || _unlabelled)) {
      return _unlabelled
          ? FriendGateRefusal.unlabelled
          : FriendGateRefusal.journalUnjudged;
    }
    final anchorOf = _anchorOf;
    if (anchorOf == null) return null;
    final anchor = anchorOf(friend);
    if (permit.identity != anchor) return FriendGateRefusal.permitIdentity;
    if (held.idk != anchor && !(permit.firstPin && held.idk == null)) {
      return FriendGateRefusal.staleAddress;
    }
    return null;
  }
}
