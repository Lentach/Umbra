// User-held history backup (metadata-privacy PR2.3).
//
// PR2.4 puts the CONTACT graph on the server, sealed. Message HISTORY cannot
// go there: after Phase 4 the server holds no messages at all, and the
// decrypted plaintext on this device is the only surviving copy of a
// consumed-ratchet message (`frontend/docs/e2e-invariants.md`). So history's
// backup is a FILE the user holds, sealed under a passphrase only they know.
//
// The codec is a deliberate copy of `IdentityBackupCodec`'s shape —
// PBKDF2-HMAC-SHA256 at 600k over a fresh 16-byte salt, AES-256-GCM,
// injectable primitives, and the same two-exception taxonomy. Two different
// answers to "it did not open" is the whole point: a wrong PASSPHRASE is the
// user's to fix, damage is not, and a surface that conflates them teaches
// people to retype a passphrase that was never wrong.
//
// The payload carries records VERBATIM — the exact strings the content store
// persists, keys included. A restore writes them back rather than re-deriving
// anything, so nothing here can drift from the store's formats.

import 'dart:convert';
import 'dart:typed_data';

import '../encryption/content_sealer.dart';
import '../passcode_kdf.dart';

/// Work factor. Same OWASP floor as the passcode verifier and the identity
/// backup; a separate constant because the three must be free to diverge.
const int kHistoryBackupKdfIterations = 600000;

/// Payload format version. A reader MUST refuse a higher one.
const int kHistoryBackupVersion = 1;

/// Domain separator inside the sealed payload.
const String kHistoryBackupDomain = 'fp-history';

/// Magic string in the CLEARTEXT file envelope, so "this is not an Umbra
/// backup" is answered before a 600k derivation is spent on it.
const String kHistoryBackupMagic = 'umbra-history-backup';

/// Extension for the exported file.
const String kHistoryBackupFileExtension = 'umbrabak';

/// The GCM open failed: the passphrase does not derive this file's key. The
/// ONLY signal a surface may render as "wrong passphrase".
class HistoryBackupWrongPassphrase implements Exception {
  @override
  String toString() => 'HistoryBackupWrongPassphrase';
}

/// The file is not a readable Umbra backup: wrong magic, damaged base64, a
/// version this build cannot read, malformed JSON. Never the user's fault.
class HistoryBackupCorrupt implements Exception {
  HistoryBackupCorrupt(this.reason);

  final String reason;

  @override
  String toString() => 'HistoryBackupCorrupt($reason)';
}

/// The file opened and is genuine, but it belongs to another account.
///
/// Refusing is not pedantry: the record keys are namespaced by user id, so
/// writing them under the signed-in account would create rows that account's
/// own sweeps never reach and whose ciphertext its identity cannot open.
class HistoryBackupForeignAccount implements Exception {
  @override
  String toString() => 'HistoryBackupForeignAccount';
}

/// What a backup contains: the two content-store families, verbatim.
class HistoryBackupPayload {
  const HistoryBackupPayload({
    required this.userId,
    required this.records,
    required this.contacts,
  });

  /// Throws [HistoryBackupCorrupt] on anything this build cannot read.
  factory HistoryBackupPayload.fromJson(Object? decoded) {
    if (decoded is! Map ||
        decoded['v'] != kHistoryBackupVersion ||
        decoded['domain'] != kHistoryBackupDomain ||
        decoded['userId'] is! int) {
      throw HistoryBackupCorrupt('payload_shape');
    }
    return HistoryBackupPayload(
      userId: decoded['userId'] as int,
      records: _stringMap(decoded['records']),
      contacts: _stringMap(decoded['contacts']),
    );
  }

  /// The account the rows belong to; the key namespace encodes it too, and
  /// the importer refuses a mismatch rather than re-namespacing.
  final int userId;

  /// `e2e_<uid>_decrypted_*` and `e2e_<uid>_decrypt_raw_v1_*`, key → value.
  final Map<String, String> records;

  /// `e2e_<uid>_contact_v1_*`, key → value.
  final Map<String, String> contacts;

  Map<String, dynamic> toJson() => {
    'v': kHistoryBackupVersion,
    'domain': kHistoryBackupDomain,
    'userId': userId,
    'records': records,
    'contacts': contacts,
  };

  static Map<String, String> _stringMap(Object? raw) {
    if (raw == null) return const {};
    if (raw is! Map) throw HistoryBackupCorrupt('payload_shape');
    final out = <String, String>{};
    raw.forEach((key, value) {
      if (key is String && value is String) out[key] = value;
    });
    return out;
  }
}

/// Seals a [HistoryBackupPayload] into the bytes the user keeps, and back.
///
/// Both primitives are injectable for the same reason [PasscodeKdf] and
/// [ContentSealer] are: the export/import state machine must be testable on
/// hosts without the webcrypto native library. Production always uses the
/// real PBKDF2 + AES-GCM pair.
class HistoryBackupCodec {
  HistoryBackupCodec({PasscodeKdf? kdf, ContentSealer? sealer})
    : _kdf = kdf ?? const Pbkdf2PasscodeKdf(),
      _sealer = sealer ?? AesGcmContentSealer();

  final PasscodeKdf _kdf;
  final ContentSealer _sealer;

  /// The file: a small CLEARTEXT envelope naming the format and the
  /// derivation parameters, wrapped around the sealed payload.
  ///
  /// The parameters must be in the clear — a restore on a device that holds
  /// nothing has no other source for them — and they leak nothing: the salt
  /// is random and the iteration count is a constant of this build.
  Future<Uint8List> seal(
    HistoryBackupPayload payload,
    String passphrase,
  ) async {
    final salt = generatePasscodeSalt();
    final key = await _kdf.derive(
      passcode: passphrase,
      salt: salt,
      iterations: kHistoryBackupKdfIterations,
    );
    final sealed = await _sealer.seal(
      key,
      Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson()))),
    );
    if (sealed == null) {
      // A refused seal is a local cipher failure, never a passphrase problem.
      throw HistoryBackupCorrupt('seal_failed');
    }
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'fp': kHistoryBackupMagic,
          'v': kHistoryBackupVersion,
          'salt': base64Encode(salt),
          'iterations': kHistoryBackupKdfIterations,
          'blob': base64Encode(sealed),
        }),
      ),
    );
  }

  /// Opens file [bytes]. Throws [HistoryBackupCorrupt] for anything that is
  /// not a readable backup and [HistoryBackupWrongPassphrase] for exactly one
  /// thing: GCM refusing the derived key.
  Future<HistoryBackupPayload> open(Uint8List bytes, String passphrase) async {
    final Object? envelope;
    try {
      envelope = jsonDecode(utf8.decode(bytes));
    } on Object {
      throw HistoryBackupCorrupt('envelope_json');
    }
    if (envelope is! Map || envelope['fp'] != kHistoryBackupMagic) {
      throw HistoryBackupCorrupt('not_a_backup');
    }
    if (envelope['v'] != kHistoryBackupVersion) {
      throw HistoryBackupCorrupt('version');
    }
    final iterations = envelope['iterations'];
    // Bounds BEFORE the KDF: a damaged or hostile file must not buy an
    // unbounded derivation on the user's phone.
    if (iterations is! int || iterations < 1 || iterations > 5000000) {
      throw HistoryBackupCorrupt('iterations');
    }
    final salt = envelope['salt'];
    final blob = envelope['blob'];
    if (salt is! String || blob is! String) {
      throw HistoryBackupCorrupt('envelope_shape');
    }
    final Uint8List saltBytes;
    final Uint8List sealedBytes;
    try {
      saltBytes = base64Decode(salt);
      sealedBytes = base64Decode(blob);
    } on Object {
      throw HistoryBackupCorrupt('base64');
    }
    if (saltBytes.length != 16 || sealedBytes.length < 13) {
      throw HistoryBackupCorrupt('lengths');
    }
    final key = await _kdf.derive(
      passcode: passphrase,
      salt: saltBytes,
      iterations: iterations,
    );
    final plain = await _sealer.unseal(key, sealedBytes);
    if (plain == null) throw HistoryBackupWrongPassphrase();
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plain));
    } on Object {
      throw HistoryBackupCorrupt('payload_json');
    }
    return HistoryBackupPayload.fromJson(decoded);
  }
}
