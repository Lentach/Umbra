// Phrase-sealed identity backup (multi-device spec §12 amendment (lxxviii)).
//
// The 12-word recovery phrase stops being a mere reset-shortener and becomes
// a KEY BACKUP: the server holds `IK`, `registrationId` and the DAK only as
// an AES-256-GCM blob sealed under a key derived from the phrase. The
// 128-bit CSPRNG entropy of the phrase is the guarantee.
//
//   version 1  PBKDF2-HMAC-SHA256(phrase, salt, 600k). Written by clients up
//              to 0.2.89, which ALSO sent the phrase to the server in
//              plaintext — such a blob is only as blind as that was. Still
//              READ here so an old backup opens.
//   version 2  HKDF-SHA256 seal key (`RecoveryPhrase.deriveSealKey`), plan B7:
//              the phrase never leaves the device, so the server cannot
//              derive the key. `iterations` is 0 (no stretching).
//
// Signed/one-time prekeys are deliberately NOT in the blob: they are
// regenerated on restore and peers re-key.

import 'dart:convert';
import 'dart:typed_data';

import '../encryption/content_sealer.dart';
import '../passcode_kdf.dart';
import '../recovery_phrase.dart';

/// Work factor of a VERSION-1 backup key (read path only since plan B7). Same
/// OWASP floor the passcode verifier uses.
const int kIdentityBackupKdfIterations = 600000;

/// The blob format [IdentityBackupCodec.seal] writes.
const int kIdentityBackupBlobVersion = 2;

/// The GCM open failed: the phrase does not derive the key this blob was
/// sealed under. The ONLY authentication signal a caller may treat as
/// "wrong phrase" — and it costs no server-side attempt.
class IdentityBackupWrongPhrase implements Exception {
  @override
  String toString() => 'IdentityBackupWrongPhrase';
}

/// The blob opened (or was being built) but its content is not a valid
/// backup: damaged wire fields, malformed JSON, an unknown version. Distinct
/// from [IdentityBackupWrongPhrase] so the UI never blames the user's phrase
/// for server-side damage.
class IdentityBackupCorrupt implements Exception {
  IdentityBackupCorrupt(this.reason);
  final String reason;
  @override
  String toString() => 'IdentityBackupCorrupt($reason)';
}

/// The plaintext of the backup blob, exactly the spec's shape:
/// `{ v:1, userId, identity: <identity_record_v1 string>, dak: <dak_record_v1 string|null> }`.
///
/// The records ride VERBATIM as the strings the stores persist — a restore
/// writes them back rather than re-deriving, so nothing this codec does can
/// drift from the store formats.
class IdentityBackupPayload {
  const IdentityBackupPayload({
    required this.userId,
    required this.identity,
    required this.dak,
  });

  static const int version = 1;

  final int userId;

  /// The `identity_record_v1` JSON string (`{pair, registrationId}`).
  final String identity;

  /// The `dak_record_v1_<uid>` JSON string, or null when the account held no
  /// DAK at seal time (backup made before linking was enabled).
  final String? dak;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': version,
    'userId': userId,
    'identity': identity,
    'dak': dak,
  };

  static IdentityBackupPayload fromJson(Object? decoded) {
    if (decoded is! Map ||
        decoded['v'] != version ||
        decoded['userId'] is! int ||
        decoded['identity'] is! String ||
        (decoded['dak'] != null && decoded['dak'] is! String)) {
      throw IdentityBackupCorrupt('payload_shape');
    }
    return IdentityBackupPayload(
      userId: decoded['userId'] as int,
      identity: decoded['identity'] as String,
      dak: decoded['dak'] as String?,
    );
  }
}

/// The wire form `setRecoveryKey.backup` carries: `base64(iv12 || ct)` plus
/// the derivation parameters the restore needs to re-derive the key.
class SealedIdentityBackup {
  const SealedIdentityBackup({
    required this.blob,
    required this.salt,
    required this.iterations,
    this.version = kIdentityBackupBlobVersion,
  });

  final String blob;
  final String salt;
  final int iterations;

  /// The blob format ([kIdentityBackupBlobVersion] for everything written
  /// now). NOT the payload's own `v`.
  final int version;

  Map<String, dynamic> toWire() => <String, dynamic>{
    'blob': blob,
    'salt': salt,
    'iterations': iterations,
    'version': version,
  };
}

/// Seals and unseals the identity backup.
///
/// Both primitives are injectable for the same reason [PasscodeKdf] and
/// [ContentSealer] are abstract: the flutter_test binding has no webcrypto
/// native on this host, and the tests that matter here are about the state
/// machine and the failure taxonomy, not the cipher. Production always uses
/// the real PBKDF2 (version-1 read path) + AES-GCM pair.
class IdentityBackupCodec {
  IdentityBackupCodec({PasscodeKdf? kdf, ContentSealer? sealer})
    : _kdf = kdf ?? const Pbkdf2PasscodeKdf(),
      _sealer = sealer ?? AesGcmContentSealer();

  final PasscodeKdf _kdf;
  final ContentSealer _sealer;

  /// Derives the VERSION-1 32-byte backup key. The phrase goes through
  /// [RecoveryPhrase.normalize] so seal and unseal cannot drift; the result
  /// is lowercase ASCII (English BIP39 wordlist), for which the spec's NFKD
  /// normalization is the identity function.
  Future<Uint8List> _deriveKeyV1(
    String phrase,
    Uint8List salt,
    int iterations,
  ) => _kdf.derive(
    passcode: RecoveryPhrase.normalize(phrase),
    salt: salt,
    iterations: iterations,
  );

  Future<SealedIdentityBackup> seal(
    IdentityBackupPayload payload,
    String phrase,
  ) async {
    final salt = generatePasscodeSalt();
    final key = RecoveryPhrase.deriveSealKey(phrase, salt);
    final sealed = await _sealer.seal(
      key,
      Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson()))),
    );
    if (sealed == null) {
      // A refused seal is a local cipher failure, never a phrase problem.
      throw IdentityBackupCorrupt('seal_failed');
    }
    return SealedIdentityBackup(
      blob: base64Encode(sealed),
      salt: base64Encode(salt),
      iterations: 0,
    );
  }

  Future<IdentityBackupPayload> unseal({
    required String blob,
    required String salt,
    required int iterations,
    required String phrase,
    int version = 1,
  }) async {
    // Parameter sanity BEFORE the KDF: a hostile or damaged answer must not
    // buy an unbounded derivation, and a malformed field is server-side
    // damage — never the user's phrase. An absent `version` is 1: the server
    // of every older build never sent one.
    if (version != 1 && version != 2) {
      throw IdentityBackupCorrupt('version');
    }
    if (version == 2
        ? iterations != 0
        : (iterations < 1 || iterations > 5000000)) {
      throw IdentityBackupCorrupt('iterations');
    }
    final Uint8List saltBytes;
    final Uint8List sealedBytes;
    try {
      saltBytes = base64Decode(salt);
      sealedBytes = base64Decode(blob);
    } catch (_) {
      throw IdentityBackupCorrupt('base64');
    }
    if (saltBytes.length != 16 || sealedBytes.length < 13) {
      throw IdentityBackupCorrupt('lengths');
    }
    final key = version == 2
        ? RecoveryPhrase.deriveSealKey(phrase, saltBytes)
        : await _deriveKeyV1(phrase, saltBytes, iterations);
    final plain = await _sealer.unseal(key, sealedBytes);
    if (plain == null) {
      // GCM authentication failure = the derived key is not the blob's key.
      throw IdentityBackupWrongPhrase();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plain));
    } catch (_) {
      throw IdentityBackupCorrupt('json');
    }
    return IdentityBackupPayload.fromJson(decoded);
  }
}
