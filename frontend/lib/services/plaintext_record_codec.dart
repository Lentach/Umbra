import 'dart:convert';
import 'dart:typed_data';

/// The on-disk shape of a persisted decrypted-message record, and the only
/// place that knows it.
///
/// A record has two halves with different requirements:
///
///  * **Metadata** (`_`-prefixed) must stay readable WITHOUT a key. Every sweep
///    selects on it — purge one conversation, drop expired plaintext, age out
///    old history — and decrypting up to 2000 records to answer "which of these
///    belong to conversation 7" is not viable. What it reveals to someone
///    already holding the device (which conversation, roughly when) is far less
///    than the message text.
///  * **Payload** is the message text, media keys and link preview: the part
///    that matters, and the part encrypted at rest.
///
/// Two formats therefore live on disk at once, and both must stay readable:
///
/// ```
/// legacy    {"content":"hi","_cid":7,"_savedAt":123}
/// sealed    {"v":1,"kid":"k2","iv":"<b64>","ct":"<b64>","_cid":7,"_savedAt":123}
/// ```
///
/// Legacy records are migrated by an INCREMENTAL, RESUMABLE re-seal, not by a
/// single atomic rewrite and not lazily on read.
///
/// Not atomic, because each record is the only copy of a message and a mass
/// rewrite of up to 2000 of them is exactly the operation that must not
/// half-fail (see the dropped-write case in `EncryptionService`). So the sweep
/// works in small batches, gates every write on its commit result, leaves the
/// legacy record untouched when a write is refused, and retries next launch —
/// the same at-least-once discipline as the purge backlog.
///
/// Not lazy either, and this is the subtle part: re-sealing only what something
/// happened to rewrite would leave the OLDEST records in cleartext, and those
/// are precisely the ones retention destroys first. Their residue would then
/// never be shredded by a key rotation, so the records most likely to be purged
/// would be the ones whose bytes stay readable. Eager beats lazy here for a
/// privacy reason, not a tidiness one.
///
/// ## Why sealing is gated on an "armed" content key
///
/// Read this before wiring the write path. Sealing inverts the durability
/// argument that put these records in localStorage in the first place:
/// localStorage writes are SYNCHRONOUS and survive a tab close, whereas the
/// content key lives in IndexedDB, whose in-flight transactions are ABORTED by
/// a tab close. So the naive order — mint key, encrypt, write record, persist
/// key — can land the ciphertext and lose the key, leaving records that are
/// unreadable forever, silently.
///
/// It also changes the blast radius. Losing one plaintext record costs one
/// message; losing the content key costs EVERY message on the device at once.
///
/// Hence the rule: the key must be persisted AND read back from a fresh
/// transaction before anything is sealed with it. Until then the writer keeps
/// storing cleartext. An unarmed device holds readable plaintext slightly
/// longer, which is recoverable; an armed device whose key never persisted is
/// not. Same bias-late rule as expiry and retention.
///
/// ## What sealing and rotation CANNOT shred — do not over-claim this
///
/// Re-sealing a legacy record writes a NEW value to the SAME localStorage key.
/// The original cleartext value stays in the LevelDB write-ahead log until a
/// compaction nobody can trigger from JS. Destroying a content key therefore
/// only makes residue unrecoverable for records that were sealed from the
/// start — i.e. written after sealing armed.
///
/// Consequence, stated plainly because it is easy to imply otherwise: on every
/// EXISTING install the whole current history has cleartext residue that no key
/// rotation can ever reach. Only a profile that was sealed from its first write
/// gets the full property. The same holds for the mobile legacy secure-store
/// copies that a re-seal writes over.
///
/// So the honest claim after B2 lands is: "new messages are encrypted at rest,
/// and purging them shreds their residue; history that predates sealing is
/// encrypted going forward but its earlier cleartext bytes may persist in the
/// store's log." Not "nothing can be recovered".
class PlaintextRecordCodec {
  const PlaintextRecordCodec._();

  /// Envelope version. Bumped only for a format change older builds cannot
  /// read; the reader refuses unknown versions rather than guessing.
  static const int version = 1;

  static const String versionKey = 'v';
  static const String keyIdKey = 'kid';
  static const String ivKey = 'iv';
  static const String ciphertextKey = 'ct';

  /// Metadata keys, kept in the clear. Owned here so the codec and every sweep
  /// agree on one spelling — a divergence would silently orphan records.
  static const String conversationIdKey = '_cid';
  static const String savedAtKey = '_savedAt';
  static const String createdAtKey = '_createdAt';
  static const String expiresAtKey = '_expiresAt';
  static const String disappearAfterKey = '_disappearAfter';

  /// The message's wire id (metadata-privacy PR2.1, `E2eEnvelope.msgId`).
  /// Listed as metadata so the codec's legacy/sealed split keeps it beside
  /// `_cid`; note `EncryptionService.wireIdIndex` decodes the WHOLE record
  /// (on web: unseals it), so it does not rely on that split.
  static const String wireIdKey = '_wid';

  static const Set<String> metadataKeys = {
    conversationIdKey,
    savedAtKey,
    createdAtKey,
    expiresAtKey,
    disappearAfterKey,
    wireIdKey,
  };

  static const Set<String> _envelopeKeys = {
    versionKey,
    keyIdKey,
    ivKey,
    ciphertextKey,
  };

  /// Whether [record] carries a sealed payload.
  ///
  /// Requires BOTH a version and a ciphertext: a record with one and not the
  /// other is corrupt, and treating it as legacy would hand the caller an
  /// envelope where a message should be.
  static bool isSealed(Map<String, dynamic> record) =>
      record[versionKey] is int && record[ciphertextKey] is String;

  /// The cleartext metadata of [record], whatever its format.
  static Map<String, dynamic> metadataOf(Map<String, dynamic> record) => {
    for (final key in metadataKeys)
      if (record.containsKey(key)) key: record[key],
  };

  /// The payload of a LEGACY (unsealed) record: everything that is neither
  /// metadata nor envelope scaffolding.
  static Map<String, dynamic> legacyPayloadOf(Map<String, dynamic> record) => {
    for (final entry in record.entries)
      if (!metadataKeys.contains(entry.key) &&
          !_envelopeKeys.contains(entry.key))
        entry.key: entry.value,
  };

  /// Build the on-disk record for an already-encrypted [ciphertext].
  ///
  /// [metadata] is written in the clear, and anything in it that is not a known
  /// metadata key is DROPPED rather than silently leaked into cleartext.
  static Map<String, dynamic> seal({
    required String keyId,
    required Uint8List iv,
    required Uint8List ciphertext,
    required Map<String, dynamic> metadata,
  }) => {
    versionKey: version,
    keyIdKey: keyId,
    ivKey: base64.encode(iv),
    ciphertextKey: base64.encode(ciphertext),
    ...metadataOf(metadata),
  };

  /// The sealed parts of [record], or null when it is not a readable envelope
  /// of a version this build understands.
  ///
  /// Null means "do not touch it". A caller must NEVER fall back to reading the
  /// record as cleartext, because a corrupt envelope is not a legacy record.
  static SealedPayload? sealedPayloadOf(Map<String, dynamic> record) {
    if (!isSealed(record)) return null;
    if (record[versionKey] != version) return null;
    final keyId = record[keyIdKey];
    final iv = record[ivKey];
    final ciphertext = record[ciphertextKey];
    if (keyId is! String || iv is! String || ciphertext is! String) return null;
    try {
      return SealedPayload(
        keyId: keyId,
        iv: Uint8List.fromList(base64.decode(iv)),
        ciphertext: Uint8List.fromList(base64.decode(ciphertext)),
      );
    } catch (_) {
      return null;
    }
  }

  /// Serialise a payload map for encryption.
  static Uint8List encodePayload(Map<String, dynamic> payload) =>
      Uint8List.fromList(utf8.encode(jsonEncode(payload)));

  /// Parse a decrypted payload, or null if it is not a JSON object. Null means
  /// a wrong key or damaged bytes — never an empty message.
  static Map<String, dynamic>? decodePayload(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

/// The encrypted half of a sealed record.
class SealedPayload {
  const SealedPayload({
    required this.keyId,
    required this.iv,
    required this.ciphertext,
  });

  /// Which content key sealed this record. Records outlive any single key, so a
  /// rotation re-seals survivors incrementally instead of atomically — a
  /// half-finished rotation is then resumable state rather than data loss.
  final String keyId;

  final Uint8List iv;
  final Uint8List ciphertext;
}
