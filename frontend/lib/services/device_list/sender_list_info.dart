// The §5.2 layer-2 E2E cross-check (spec §12 amendment (vii), settled by
// (xv)/(xvi)).
//
// `senderListInfo` is a small object the SENDER puts inside the E2E plaintext:
// "this is the version and hash of my own device list, and of yours, as I know
// them". The server never sees, stores or validates it — it rides inside the
// ciphertext — so it can expose a server that serves the two parties DIFFERENT
// but individually-valid, DAK-signed views of a device list (a split view).
//
// The discipline that makes it safe is the whole point (amendment (xvi)):
//
//   * A bare claim NEVER changes trust and NEVER alarms (invariant I7). It is
//     peer-supplied data, and an attacker who could inject it could otherwise
//     weaponise our own warning UI against us.
//   * A claim OLDER than what we hold is a CANDIDATE freeze signal. It becomes
//     a real signal only when our OWN independently-verified, DAK-signed data
//     agrees that the peer is stuck.
//   * A claim NEWER than we hold buys AT MOST ONE rate-limited re-fetch and is
//     then discarded. (Matrix requires one key query in flight per user for
//     exactly this reason: a parallel re-fetch lets a stale answer overwrite a
//     fresh one.)
//   * Skew about OUR OWN devices is benign — it means our devices have not
//     finished syncing — and renders a calm "syncing" state, never the
//     identity-changed surface (amendment (xvii)).
//
// The hash is SHA-256 over the byte-exact DAK-signed `listCanonical` as it was
// transported, never a re-serialization: an unstable encoding would produce
// phantom mismatches, which is precisely why Matrix signs canonical JSON.

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The sender's claimed view of both parties' device lists.
class SenderListInfo {
  const SenderListInfo({
    this.ownVersion,
    this.ownListHash,
    this.peerVersion,
    this.peerListHash,
  });

  /// The sender's view of ITS OWN list (from the recipient's seat: the peer's).
  final int? ownVersion;
  final String? ownListHash;

  /// The sender's view of the RECIPIENT's list (from the recipient's seat: ours).
  final int? peerVersion;
  final String? peerListHash;

  bool get isEmpty =>
      ownVersion == null &&
      ownListHash == null &&
      peerVersion == null &&
      peerListHash == null;

  /// SHA-256, base64, over the canonical bytes exactly as transported.
  /// A party we hold no verified list for is reported ABSENT, never as
  /// version 0 — "I do not know" and "you have nothing" are different claims.
  static String hashListCanonical(String listCanonical) =>
      base64Encode(sha256.convert(utf8.encode(listCanonical)).bytes);

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (ownVersion != null) 'ownVersion': ownVersion,
    if (ownListHash != null) 'ownListHash': ownListHash,
    if (peerVersion != null) 'peerVersion': peerVersion,
    if (peerListHash != null) 'peerListHash': peerListHash,
  };

  /// Tolerant by construction: any malformed field is simply absent, because a
  /// hostile or older peer must never be able to make this throw on a receive
  /// path that is holding someone's message.
  static SenderListInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ownVersion = raw['ownVersion'];
    final peerVersion = raw['peerVersion'];
    final ownHash = raw['ownListHash'];
    final peerHash = raw['peerListHash'];
    final info = SenderListInfo(
      ownVersion: ownVersion is int ? ownVersion : null,
      ownListHash: ownHash is String && ownHash.isNotEmpty ? ownHash : null,
      peerVersion: peerVersion is int ? peerVersion : null,
      peerListHash: peerHash is String && peerHash.isNotEmpty ? peerHash : null,
    );
    return info.isEmpty ? null : info;
  }
}

/// What the receiver should DO about a claim. Never "alarm" on its own: the
/// alarm-worthy outcome requires independent confirmation, which is why
/// [SenderListInfoOutcome.peerListFrozen] is only ever produced after our own
/// signed data agreed.
enum SenderListInfoOutcome {
  /// Nothing to do: the claim matches what we hold, or carries nothing usable.
  consistent,

  /// The peer claims a NEWER version of a list than we hold. Refresh once,
  /// rate-limited, then discard the claim. Not a security signal: a peer that
  /// legitimately linked a device is the common case.
  refreshPeerList,

  /// The peer's view of OUR OWN devices lags ours. Benign — our devices are
  /// still syncing. Render the calm state, never the identity surface.
  ownDevicesSyncing,

  /// The peer claims an OLDER version of ITS OWN list than we hold, AND our own
  /// verified data confirms the mismatch. This is the split-view signal.
  peerListFrozen,
}

/// Compares a received claim against DAK-verified state the receiver already
/// holds. Pure: it decides, it never fetches, alarms or renders.
class SenderListInfoChecker {
  /// [ourVersionOfPeer]/[ourHashOfPeer] — what WE verified about the sender.
  /// [ourOwnVersion]/[ourOwnHash] — what WE verified about ourselves.
  /// A null on our side means "we hold nothing verified", which can never be
  /// evidence of anything: the outcome is [SenderListInfoOutcome.consistent].
  static SenderListInfoOutcome evaluate({
    required SenderListInfo? claim,
    required int? ourVersionOfPeer,
    required String? ourHashOfPeer,
    required int? ourOwnVersion,
    required String? ourOwnHash,
  }) {
    if (claim == null || claim.isEmpty) return SenderListInfoOutcome.consistent;

    // The sender's claim about ITS OWN list, checked against ours.
    final claimedPeerVersion = claim.ownVersion;
    if (claimedPeerVersion != null && ourVersionOfPeer != null) {
      if (claimedPeerVersion > ourVersionOfPeer) {
        // Newer than we know: at most one re-fetch, then discard (xvi).
        return SenderListInfoOutcome.refreshPeerList;
      }
      if (claimedPeerVersion < ourVersionOfPeer) {
        // Candidate freeze. Independent confirmation is the version WE verified
        // from DAK-signed data — the claim alone never gets us here.
        return SenderListInfoOutcome.peerListFrozen;
      }
      // Same version, different bytes: the server served one of us a forgery
      // that nonetheless verified, or our canonical encoding drifted. Either
      // way it is a real inconsistency between two signed views.
      final claimedHash = claim.ownListHash;
      if (claimedHash != null &&
          ourHashOfPeer != null &&
          claimedHash != ourHashOfPeer) {
        return SenderListInfoOutcome.peerListFrozen;
      }
    }

    // The sender's claim about OUR list. Our own devices disagreeing is never
    // an attack signal we surface as one (xvii).
    final claimedOwnVersion = claim.peerVersion;
    if (claimedOwnVersion != null && ourOwnVersion != null) {
      // Either direction is benign: the peer saw a newer version of us than we
      // hold (our own devices are behind) or an older one (its view has not
      // caught up). Both are "still syncing", never a security surface.
      if (claimedOwnVersion != ourOwnVersion) {
        return SenderListInfoOutcome.ownDevicesSyncing;
      }
      final claimedOwnHash = claim.peerListHash;
      if (claimedOwnHash != null &&
          ourOwnHash != null &&
          claimedOwnHash != ourOwnHash) {
        return SenderListInfoOutcome.ownDevicesSyncing;
      }
    }

    return SenderListInfoOutcome.consistent;
  }
}
