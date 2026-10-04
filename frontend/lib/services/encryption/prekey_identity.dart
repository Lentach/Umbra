import 'dart:convert';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Whether a `"{type}:{base64}"` Signal ciphertext can only have come from a
/// holder of the identity [identityPublicKeyBase64] (metadata-privacy PR3.1
/// sibling queues).
///
/// A request queue is public, so anyone can seal a frame into it that NAMES
/// our account and one of its device ids; and the identity store is TOFU, so
/// libsignal would accept a PreKey message under any identity key — and
/// replace the real sibling session while doing it. Own devices share the
/// account identity, so a PreKey message must carry exactly that key.
///
/// A whisper message is not judged here: its MAC is keyed by the session it
/// names, so only a holder of that session can produce one the decrypt
/// accepts. False for anything unparseable.
bool ciphertextMatchesIdentity(
  String ciphertext,
  String identityPublicKeyBase64,
) {
  final colon = ciphertext.indexOf(':');
  if (colon < 0) return false;
  final type = int.tryParse(ciphertext.substring(0, colon));
  if (type == CiphertextMessage.whisperType) return true;
  if (type != CiphertextMessage.prekeyType) return false;
  try {
    final message = PreKeySignalMessage(
      base64Decode(ciphertext.substring(colon + 1)),
    );
    return base64Encode(message.getIdentityKey().serialize()) ==
        identityPublicKeyBase64;
  } on Object {
    return false;
  }
}

/// Whether decrypting the `"{type}:{base64}"` Signal ciphertext would
/// REPLACE the session [record] holds (metadata-privacy decision 37, E37a).
///
/// Mirrors libsignal_protocol_dart 0.8.2 `SessionBuilder.processV3`
/// (`session_builder.dart:56-76`), which archives the current state exactly
/// when the record is not fresh and neither its current nor any archived
/// state matches the PreKey message's `(version, baseKey)`. So a first
/// contact (a fresh record) replaces nothing, and neither does an
/// initiator's repeat: it keeps sending PreKey messages under the SAME base
/// key until it is answered.
///
/// False for a whisper message and for anything unparseable (the decrypt
/// refuses that on its own).
bool preKeyWouldReplace(SessionRecord record, String ciphertext) {
  final colon = ciphertext.indexOf(':');
  if (colon < 0) return false;
  if (int.tryParse(ciphertext.substring(0, colon)) !=
      CiphertextMessage.prekeyType) {
    return false;
  }
  final PreKeySignalMessage message;
  try {
    message = PreKeySignalMessage(
      base64Decode(ciphertext.substring(colon + 1)),
    );
  } on Object {
    return false;
  }
  return !record.isFresh() &&
      !record.hasSessionState(
        message.getMessageVersion(),
        message.getBaseKey().serialize(),
      );
}

/// Whether the `"{type}:{base64}"` PreKey message comes from a device that
/// MINTED A NEW IDENTITY since [record] was built (decision 88: a friend's
/// device lost its storage and its login re-minted): [record] knows that
/// device under another identity, and no ARCHIVED state ever held this one.
///
/// This alone does NOT tell a re-mint from a revoked device of the friend
/// minting a fresh key of its own (it holds our queue's sid, and with key
/// warnings off the decrypt absorbs any new identity). The caller takes the
/// handoff only for a friend whose held list is NOT enrolled: single-device
/// by construction, so no revoked device of it exists (decision 37's threat).
///  * The new identity in the CURRENT state (an earlier handoff of it was
///    refused after the decrypt moved the session) still counts: that
///    refusal must not lock the restored device out for good.
///  * An identity this record moved AWAY from (archived) never counts: a
///    device holding an account's identity from before its reset must not
///    take the address back.
///
/// False for a whisper message, a fresh record and anything unparseable.
bool preKeyFromNewIdentity(SessionRecord record, String ciphertext) {
  final colon = ciphertext.indexOf(':');
  if (colon < 0 || record.isFresh()) return false;
  if (int.tryParse(ciphertext.substring(0, colon)) !=
      CiphertextMessage.prekeyType) {
    return false;
  }
  final String identity;
  try {
    identity = base64Encode(
      PreKeySignalMessage(
        base64Decode(ciphertext.substring(colon + 1)),
      ).getIdentityKey().serialize(),
    );
  } on Object {
    return false;
  }
  String? identityOf(SessionState state) {
    final key = state.getRemoteIdentityKey();
    return key == null ? null : base64Encode(key.serialize());
  }

  final archived = [
    for (final s in record.previousSessionStates) ?identityOf(s),
  ];
  if (archived.contains(identity)) return false;
  return [?identityOf(record.sessionState), ...archived].any(
    (known) => known != identity,
  );
}

/// Who can have sealed a FRIEND's account-bearing frame into our public
/// request queue (metadata-privacy item 5, E20c).
enum FriendFrameIdentity {
  /// A whisper message (its MAC is keyed by a session we hold), or a PreKey
  /// message carrying the friend's pinned account identity.
  matches,

  /// A PreKey message, and this device pinned no identity for that account
  /// yet: nothing here can say whose key it carries.
  noAnchor,

  /// A PreKey message under any other key, or nothing parseable.
  foreign,
}

/// [ciphertextMatchesIdentity] against a friend's pinned account identity
/// [anchorBase64] (null: none pinned).
FriendFrameIdentity friendFrameIdentity(
  String ciphertext,
  String? anchorBase64,
) {
  final colon = ciphertext.indexOf(':');
  final type = colon < 0 ? null : int.tryParse(ciphertext.substring(0, colon));
  if (type == CiphertextMessage.whisperType) return FriendFrameIdentity.matches;
  if (type != CiphertextMessage.prekeyType) return FriendFrameIdentity.foreign;
  if (anchorBase64 == null) return FriendFrameIdentity.noAnchor;
  return ciphertextMatchesIdentity(ciphertext, anchorBase64)
      ? FriendFrameIdentity.matches
      : FriendFrameIdentity.foreign;
}
