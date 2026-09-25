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
    message = PreKeySignalMessage(base64Decode(ciphertext.substring(colon + 1)));
  } on Object {
    return false;
  }
  return !record.isFresh() &&
      !record.hasSessionState(
        message.getMessageVersion(),
        message.getBaseKey().serialize(),
      );
}
