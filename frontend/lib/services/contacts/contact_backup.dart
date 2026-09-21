// Server-held contact backup (metadata-privacy PR2.4, G1 decision 5).
//
// The client-owned contact list (PR2.2) is the app's only copy of the graph
// once Phase 4 deletes the server's. A browser that evicts its origin storage
// — which the PWA fleet does, owner-observed — would then lose every contact
// with nothing to restore from. So the server holds ONE opaque blob per
// account: AES-256-GCM under a random content key (CK) it never sees, with CK
// wrapped under a key derived from the account PASSWORD (and, when one has
// been shown to the user, a second wrap under the recovery phrase).
//
// Two properties decide the shape:
//  * The password is the door, not the phrase. Nobody writes the phrase down
//    (owner ruling), so a phrase-only backup is a backup nobody can open.
//  * CK is wrapped, never derived. A password change re-makes only the WRAP,
//    so another device that already holds CK keeps uploading without ever
//    learning the new password — and without a re-encryption of the blob.
//
// What is deliberately NOT in the blob: this device's own queue private keys
// (`ContactRecord.queues`). After a storage loss the identity is gone with the
// same Keystore/origin, so old queue keys serve nothing; the restored device
// re-mints and hands the new capabilities over `outbound[]`. Leaving them out
// also removes a cross-device private-key leak and the multi-device clobber of
// two devices uploading different `queues[]` under one row.
//
// `legacy` (server-side conversation/request ids) is omitted for the opposite
// reason: the server re-supplies it in the first list, so backing it up would
// only let a stale id outlive the row it names.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../models/user_model.dart';
import '../encryption/content_sealer.dart';
import '../passcode_kdf.dart';
import '../recovery_phrase.dart';
import 'contact_record.dart';

/// Work factor for both wrap keys. Same OWASP floor as the passcode verifier
/// and the identity backup, and a separate constant for the same reason: the
/// three must be free to diverge.
const int kContactBackupKdfIterations = 600000;

/// Blob format version. A reader MUST refuse a higher one rather than guess.
const int kContactBackupVersion = 1;

/// Plaintext padding bucket, bytes. AES-GCM is length-preserving, so without
/// this the ciphertext length is a contact counter anyone with a database
/// dump can read. 4 KiB is the smallest bucket that hides the difference
/// between "a handful of contacts" and "dozens" while keeping a typical
/// account's blob to one or two blocks; the design gives the Phase 1 queue
/// seal the same treatment at 16 KiB.
const int kContactBackupPadBlock = 4096;

/// Domain separator inside the sealed payload. Belt and braces against a blob
/// from another feature ever being fed to this opener.
const String kContactBackupDomain = 'fp-contacts';

/// Which secret a wrap of CK was made under.
enum ContactWrapKind {
  password,
  phrase;

  static ContactWrapKind? parse(String raw) {
    for (final k in ContactWrapKind.values) {
      if (k.name == raw) return k;
    }
    return null;
  }
}

/// One wrapped copy of CK. `ct` is `base64(iv12 || GCM(ct||tag))` of the raw
/// 32-byte CK under the key derived from [kind]'s secret and the row's salt.
class ContactBackupWrap {
  const ContactBackupWrap({required this.kind, required this.ct});

  final ContactWrapKind kind;
  final String ct;

  Map<String, dynamic> toJson() => {'kind': kind.name, 'ct': ct};

  static ContactBackupWrap? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = ContactWrapKind.parse(raw['kind'] as String? ?? '');
    final ct = raw['ct'];
    if (kind == null || ct is! String || ct.isEmpty) return null;
    return ContactBackupWrap(kind: kind, ct: ct);
  }
}

/// The server's row as the client sees it. `blob` is opaque to everyone but a
/// holder of CK; `rev` is the optimistic-concurrency token that makes a
/// partial write (new blob beside stale wraps) impossible.
class ContactBackupRow {
  const ContactBackupRow({
    required this.rev,
    required this.salt,
    required this.ckId,
    required this.wraps,
    required this.blob,
  });

  /// Throws [ContactBackupCorrupt] on a shape this build cannot read — the
  /// caller must never treat that as "no backup", which would overwrite it.
  factory ContactBackupRow.fromJson(Map<String, dynamic> j) {
    final rev = j['rev'];
    final salt = j['salt'];
    final ckId = j['ckId'];
    final blob = j['blob'];
    final rawWraps = j['wraps'];
    if (rev is! int ||
        salt is! String ||
        ckId is! String ||
        blob is! String ||
        rawWraps is! List) {
      throw ContactBackupCorrupt('row_shape');
    }
    final wraps = <ContactBackupWrap>[];
    for (final raw in rawWraps) {
      final wrap = ContactBackupWrap.fromJson(raw);
      if (wrap != null) wraps.add(wrap);
    }
    return ContactBackupRow(
      rev: rev,
      salt: salt,
      ckId: ckId,
      wraps: wraps,
      blob: blob,
    );
  }

  final int rev;
  final String salt;
  final String ckId;
  final List<ContactBackupWrap> wraps;
  final String blob;
}

/// The plaintext inside the blob: the device-independent half of every
/// contact record, plus this account's own profile (which the store needs to
/// build a `ConversationModel` offline and which only `conversationsList`
/// otherwise supplies).
class ContactBackupPayload {
  const ContactBackupPayload({
    required this.userId,
    required this.self,
    required this.contacts,
  });

  /// Throws [ContactBackupCorrupt]. A single unreadable contact entry is
  /// SKIPPED, never fatal: restoring 40 of 41 peers beats restoring none.
  factory ContactBackupPayload.fromJson(Object? decoded) {
    if (decoded is! Map ||
        decoded['v'] != kContactBackupVersion ||
        decoded['domain'] != kContactBackupDomain ||
        decoded['userId'] is! int ||
        decoded['contacts'] is! List) {
      throw ContactBackupCorrupt('payload_shape');
    }
    final contacts = <ContactRecord>[];
    for (final raw in decoded['contacts'] as List) {
      if (raw is! Map) continue;
      try {
        contacts.add(ContactRecord.fromJson(Map<String, dynamic>.from(raw)));
      } on Object {
        continue;
      }
    }
    return ContactBackupPayload(
      userId: decoded['userId'] as int,
      self: _userFromJson(decoded['self']),
      contacts: contacts,
    );
  }

  final int userId;
  final UserModel? self;
  final List<ContactRecord> contacts;

  /// Contacts are a SET, not a sequence: they are emitted sorted by
  /// `userId` so two devices holding the same graph in a different insertion
  /// order seal the same plaintext. The no-op guard in
  /// `ContactBackupService.uploadNow` compares this encoding against the
  /// blob the session opened, and an order-dependent encoding would make
  /// every restore look like a change.
  Map<String, dynamic> toJson() => {
    'v': kContactBackupVersion,
    'domain': kContactBackupDomain,
    'userId': userId,
    if (self != null) 'self': _userToJson(self!),
    'contacts': [
      for (final c in [...contacts]..sort((a, b) => a.userId - b.userId))
        c.toBackupJson(),
    ],
  };

  static Map<String, dynamic> _userToJson(UserModel user) => {
    'id': user.id,
    'username': user.username,
    'tag': user.tag,
    if (user.profilePictureUrl != null)
      'profilePictureUrl': user.profilePictureUrl,
  };

  static UserModel? _userFromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      return UserModel.fromJson(Map<String, dynamic>.from(raw));
    } on Object {
      return null;
    }
  }
}

/// The blob or a wrap is present but this build cannot make sense of it:
/// damaged base64, a foreign version, malformed JSON. Distinct from a wrap
/// that simply is not ours, so no surface ever blames the user's password for
/// server-side damage.
class ContactBackupCorrupt implements Exception {
  ContactBackupCorrupt(this.reason);

  final String reason;

  @override
  String toString() => 'ContactBackupCorrupt($reason)';
}

/// Seals and opens the contact backup.
///
/// Both primitives are injectable for the same reason [PasscodeKdf] and
/// [ContentSealer] are: the state machine around this codec — mint, wrap,
/// prune, re-wrap, restore — must be testable on hosts where the webcrypto
/// native library is not set up. Production always uses the real
/// PBKDF2 + AES-GCM pair.
class ContactBackupCodec {
  ContactBackupCodec({PasscodeKdf? kdf, ContentSealer? sealer})
    : _kdf = kdf ?? const Pbkdf2PasscodeKdf(),
      _sealer = sealer ?? AesGcmContentSealer();

  final PasscodeKdf _kdf;
  final ContentSealer _sealer;

  /// 32 random bytes from the platform CSPRNG, and an id for them.
  ///
  /// The id is what lets a device notice that the row it is about to write
  /// into is keyed under a CK it does not hold — the phrase-restore case,
  /// where uploading anyway would leave a blob nobody's wrap can open.
  static (Uint8List ck, String ckId) mintContentKey() {
    final rng = Random.secure();
    final ck = Uint8List(32);
    for (var i = 0; i < ck.length; i++) {
      ck[i] = rng.nextInt(256);
    }
    final idBytes = Uint8List(16);
    for (var i = 0; i < idBytes.length; i++) {
      idBytes[i] = rng.nextInt(256);
    }
    return (ck, _b64url(idBytes));
  }

  /// A fresh 16-byte salt, base64. Minted ONCE per account by whichever
  /// client finds no row; the server refuses every later change to it.
  static String mintSalt() => base64Encode(generatePasscodeSalt());

  /// Derives the 32-byte wrap key for [kind]'s [secret] under the row's
  /// [salt]. A phrase goes through [RecoveryPhrase.normalize] so the wrap and
  /// the unwrap cannot drift on spacing or case.
  ///
  /// Every failure — including the PRIMITIVE refusing outright (an
  /// unavailable webcrypto on a bare VM host, a Keystore fault) — comes back
  /// as [ContactBackupCorrupt]. The KDF throws a plain [UnsupportedError]
  /// there, and letting an `Error` escape an unawaited caller is an
  /// unhandled async error rather than a state this service can report.
  Future<Uint8List> deriveWrapKey({
    required ContactWrapKind kind,
    required String secret,
    required String salt,
  }) async {
    final Uint8List saltBytes;
    try {
      saltBytes = base64Decode(salt);
    } on Object {
      throw ContactBackupCorrupt('salt_base64');
    }
    if (saltBytes.length != 16) throw ContactBackupCorrupt('salt_length');
    try {
      return await _kdf.derive(
        passcode: kind == ContactWrapKind.phrase
            ? RecoveryPhrase.normalize(secret)
            : secret,
        salt: saltBytes,
        iterations: kContactBackupKdfIterations,
      );
    } on Object {
      throw ContactBackupCorrupt('kdf');
    }
  }

  /// Wraps [ck] under [wrapKey].
  Future<ContactBackupWrap> wrap({
    required ContactWrapKind kind,
    required Uint8List wrapKey,
    required Uint8List ck,
  }) async {
    final sealed = await _sealer.seal(wrapKey, ck);
    if (sealed == null) throw ContactBackupCorrupt('wrap_failed');
    return ContactBackupWrap(kind: kind, ct: base64Encode(sealed));
  }

  /// The CK inside [wrap] under [wrapKey], or null when this key is not the
  /// one it was wrapped under. Null is the ONLY "not our wrap" signal; it
  /// costs no server round trip and is never reported as damage.
  Future<Uint8List?> unwrap(ContactBackupWrap wrap, Uint8List wrapKey) async {
    final Uint8List sealed;
    try {
      sealed = base64Decode(wrap.ct);
    } on Object {
      return null;
    }
    if (sealed.length < 13) return null;
    final ck = await _sealer.unseal(wrapKey, sealed);
    if (ck == null || ck.length != 32) return null;
    return ck;
  }

  /// Seals [payload] under [ck], PADDED to a fixed bucket.
  ///
  /// AES-GCM is length-preserving, so an unpadded blob's byte length divided
  /// by the ~200-400 bytes a contact record costs is a direct estimate of
  /// how many contacts the account has — readable from a `pg_dump` with no
  /// key at all, and visibly growing or shrinking across two dumps. That is
  /// exactly the metadata this PR series exists to remove, so the plaintext
  /// is padded to a multiple of [kContactBackupPadBlock] first. The same
  /// 16 KiB discipline the design gives the Phase 1 queue seal.
  ///
  /// Framing: a 4-byte big-endian length inside the SEALED region, then the
  /// JSON, then zeros. The length rides under the GCM tag, so a truncated or
  /// tampered frame fails authentication rather than mis-parsing.
  Future<String> sealPayload(Uint8List ck, ContactBackupPayload payload) async {
    final json = utf8.encode(jsonEncode(payload.toJson()));
    final framed = _pad(Uint8List.fromList(json));
    final sealed = await _sealer.seal(ck, framed);
    if (sealed == null) throw ContactBackupCorrupt('seal_failed');
    return base64Encode(sealed);
  }

  /// `uint32be(length) || body || zero padding` to the next whole block.
  static Uint8List _pad(Uint8List body) {
    final total = 4 + body.length;
    final blocks = (total + kContactBackupPadBlock - 1) ~/
        kContactBackupPadBlock;
    final out = Uint8List(blocks * kContactBackupPadBlock);
    out[0] = (body.length >> 24) & 0xff;
    out[1] = (body.length >> 16) & 0xff;
    out[2] = (body.length >> 8) & 0xff;
    out[3] = body.length & 0xff;
    out.setRange(4, 4 + body.length, body);
    return out;
  }

  /// Inverse of [_pad]. A length that does not fit the frame is damage, not
  /// a wrong key — GCM already authenticated these bytes.
  static Uint8List _unpad(Uint8List framed) {
    if (framed.length < 4) throw ContactBackupCorrupt('frame');
    final length =
        (framed[0] << 24) | (framed[1] << 16) | (framed[2] << 8) | framed[3];
    if (length < 0 || 4 + length > framed.length) {
      throw ContactBackupCorrupt('frame');
    }
    return Uint8List.sublistView(framed, 4, 4 + length);
  }

  /// Opens [blob] with [ck]. Throws [ContactBackupCorrupt] — including when
  /// GCM refuses, which here means the row is keyed under a different CK
  /// than the caller believes, not that a user typed something wrong.
  Future<ContactBackupPayload> openPayload(Uint8List ck, String blob) async {
    final Uint8List sealed;
    try {
      sealed = base64Decode(blob);
    } on Object {
      throw ContactBackupCorrupt('blob_base64');
    }
    if (sealed.length < 13) throw ContactBackupCorrupt('blob_length');
    final plain = await _sealer.unseal(ck, sealed);
    if (plain == null) throw ContactBackupCorrupt('blob_auth');
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(_unpad(plain)));
    } on ContactBackupCorrupt {
      rethrow;
    } on Object {
      throw ContactBackupCorrupt('blob_json');
    }
    return ContactBackupPayload.fromJson(decoded);
  }

  static String _b64url(Uint8List bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
