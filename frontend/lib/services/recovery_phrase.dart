import 'dart:convert';
import 'dart:typed_data';

import 'package:bip39_mnemonic/bip39_mnemonic.dart';

import 'device_link/link_crypto.dart' show hkdfSha256;

/// Recovery phrase generation and checking (multi-device spec §6.2.1).
///
/// The phrase is minted HERE, on the user's device, and shown once. Since plan
/// B7 (Option V) it NEVER leaves the device: the server is sent only
/// [deriveAuthSecret] (to store an Argon2id verifier of it), and the identity
/// backup is sealed under [deriveSealKey], which the server never receives and
/// cannot compute from the authSecret. It is never written to local storage: a
/// phrase kept on the device would be lost by exactly the event it exists to
/// recover from.
///
/// The phrase is 128 bits of CSPRNG entropy, so no slow KDF is needed: a
/// domain-separated HKDF-SHA256 gives two independent 32-byte outputs.
///
/// BIP39 with its checksum is deliberate. A mistyped phrase is caught locally,
/// before it costs one of the few server-side attempts the lockout allows.
class RecoveryPhrase {
  const RecoveryPhrase._();

  /// 12 words from 128 bits of CSPRNG entropy (`Random.secure`), plus the
  /// 4-bit BIP39 checksum.
  static List<String> generate() =>
      Mnemonic.generate(Language.english, length: MnemonicLength.words12).words;

  /// Normalizes user input: lowercase, collapsed whitespace, trimmed. Typing a
  /// phrase back in is error-prone and none of that noise is meaningful.
  static String normalize(String input) =>
      input.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// HKDF `info` labels. A different label is a different, unrelated key:
  /// knowing the authSecret (which the server holds a verifier of) tells
  /// nothing about the seal key, and vice versa.
  static const String authInfo = 'umbra/recovery/auth/v1';
  static const String sealInfo = 'umbra/recovery/seal/v2';

  static Uint8List _derive(String phrase, String info, Uint8List suffix) =>
      hkdfSha256(
        ikm: Uint8List.fromList(utf8.encode(normalize(phrase))),
        info: Uint8List.fromList(<int>[...utf8.encode(info), ...suffix]),
        length: 32,
      );

  /// The proof the server verifies, as base64 of 32 bytes: what
  /// `setRecoveryKey`, `resetIdentityRequest` and `POST /auth/recover` send
  /// INSTEAD of the phrase.
  static String deriveAuthSecret(String phrase) =>
      base64Encode(_derive(phrase, authInfo, Uint8List(0)));

  /// The AES-256 key of a version-2 identity backup. [salt] is the blob's own
  /// random salt, folded into the HKDF info so a re-sealed backup never reuses
  /// a key. Never sent anywhere.
  static Uint8List deriveSealKey(String phrase, Uint8List salt) =>
      _derive(phrase, sealInfo, salt);

  /// Whether [input] is a well-formed 12-word English BIP39 phrase.
  ///
  /// Fails closed: an unknown word, the wrong length, or a bad checksum are all
  /// simply "not valid". This is a typo guard, never an authorization decision
  /// — only the server can decide whether a phrase is the account's.
  static bool isValid(String input) {
    final normalized = normalize(input);
    if (normalized.isEmpty) return false;
    if (normalized.split(' ').length != MnemonicLength.words12.words) {
      return false;
    }
    try {
      Mnemonic.fromSentence(normalized, Language.english);
      return true;
    } catch (_) {
      return false;
    }
  }
}
