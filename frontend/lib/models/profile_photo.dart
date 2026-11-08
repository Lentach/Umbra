import 'dart:convert';

import 'package:flutter/foundation.dart' show Uint8List, immutable;

import '../services/box/box_wire.dart' show boxB64Decode, kBoxMediaIdBytes;

/// One account's profile photo as it travels end to end (decision 138):
/// the reference `av = {m, k, i, r}` to ONE encrypted file in the box's
/// media store, or the cleared state `{r, x: 1}`. The file is a ≤256×256
/// JPEG sealed under a fresh AES-256-GCM key, padded to a box media rung and
/// uploaded once; the box holds no viewable copy, and the key travels only
/// inside the E2E envelope.
///
/// [rev] is a per-account counter that only grows: a receiver keeps the
/// reference with the highest one it ever saw, so a late older frame never
/// brings back a photo the account replaced or removed.
@immutable
class ProfilePhotoRef {
  /// A photo: [mediaId] the box's 43-char base64url id, [key] the standard
  /// base64 of the 32-byte file key, [iv] the standard base64 of its 12-byte
  /// nonce. Spelled as [fromWire] requires; a hand-built one that is not
  /// would never parse on the other side.
  const ProfilePhotoRef({
    required int rev,
    required String mediaId,
    required String key,
    required String iv,
    DateTime? uploadedAt,
  }) : this._(
         rev: rev,
         mediaId: mediaId,
         key: key,
         iv: iv,
         uploadedAt: uploadedAt,
       );
  const ProfilePhotoRef._({
    required this.rev,
    this.mediaId,
    this.key,
    this.iv,
    this.uploadedAt,
  });

  /// The account removed its photo at [rev].
  const ProfilePhotoRef.cleared(int rev, {DateTime? at})
    : this._(rev: rev, uploadedAt: at);

  /// The largest counter a JSON number carries exactly on web.
  static const int maxRev = 9007199254740991;

  static final RegExp _b64 = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

  final int rev;
  final String? mediaId;
  final String? key;
  final String? iv;

  /// When this device (or, for a sibling's frame, the sender) made the file:
  /// the box keeps it 14 days (D8), so a photo is uploaded again once it is
  /// older than 7. Local bookkeeping of the own reference only — never on
  /// the wire, and absent from every received friend reference.
  final DateTime? uploadedAt;

  bool get isCleared => mediaId == null;
  bool get hasPhoto => mediaId != null;

  /// The 32-byte box media id; null for a cleared reference.
  Uint8List? get mediaIdBytes {
    final id = mediaId;
    return id == null ? null : boxB64Decode(id, kBoxMediaIdBytes);
  }

  /// Whether this reference replaces [held]: only a strictly higher counter
  /// does (a tie keeps what is held).
  bool supersedes(ProfilePhotoRef? held) => held == null || rev > held.rev;

  ProfilePhotoRef copyWith({int? rev, DateTime? uploadedAt}) =>
      ProfilePhotoRef._(
        rev: rev ?? this.rev,
        mediaId: mediaId,
        key: key,
        iv: iv,
        uploadedAt: uploadedAt ?? this.uploadedAt,
      );

  /// `{m, k, i, r}` or `{r, x: 1}` — the wire shape, nothing local.
  Map<String, dynamic> toWire() => hasPhoto
      ? {'m': mediaId, 'k': key, 'i': iv, 'r': rev}
      : {'r': rev, 'x': 1};

  /// The wire shape plus `at` (ms since the epoch): what the device's own
  /// records keep.
  Map<String, dynamic> toJson() => {
    ...toWire(),
    if (uploadedAt != null) 'at': uploadedAt!.millisecondsSinceEpoch,
  };

  /// A reference as a peer states it, or null for anything not spelled
  /// exactly: `r` an int in `1..maxRev`; a photo needs `m` a canonical
  /// 32-byte box id, `k` the canonical base64 of 32 bytes and `i` of 12;
  /// a cleared one is `x: 1` with none of them. Peer data bound for this
  /// device's disk and its media fetcher: a malformed reference is dropped
  /// whole, never partly read.
  static ProfilePhotoRef? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final rev = raw['r'];
    if (rev is! int || rev < 1 || rev > maxRev) return null;
    if (raw.containsKey('x')) {
      if (raw['x'] != 1 ||
          raw.containsKey('m') ||
          raw.containsKey('k') ||
          raw.containsKey('i')) {
        return null;
      }
      return ProfilePhotoRef.cleared(rev);
    }
    final mediaId = raw['m'];
    final key = raw['k'];
    final iv = raw['i'];
    if (mediaId is! String ||
        boxB64Decode(mediaId, kBoxMediaIdBytes) == null ||
        !_isBase64Of(key, 32) ||
        !_isBase64Of(iv, 12)) {
      return null;
    }
    return ProfilePhotoRef(
      rev: rev,
      mediaId: mediaId,
      key: key as String,
      iv: iv as String,
    );
  }

  /// [fromWire] plus this device's own `at`.
  static ProfilePhotoRef? fromJson(Object? raw) {
    final ref = fromWire(raw);
    if (ref == null || raw is! Map) return ref;
    final at = raw['at'];
    return at is int && at > 0
        ? ref.copyWith(
            uploadedAt: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
          )
        : ref;
  }

  static bool _isBase64Of(Object? value, int bytes) {
    if (value is! String || !_b64.hasMatch(value)) return false;
    try {
      final decoded = base64.decode(value);
      return decoded.length == bytes && base64.encode(decoded) == value;
    } on FormatException {
      return false;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ProfilePhotoRef &&
      other.rev == rev &&
      other.mediaId == mediaId &&
      other.key == key &&
      other.iv == iv &&
      other.uploadedAt == uploadedAt;

  @override
  int get hashCode => Object.hash(rev, mediaId, key, iv, uploadedAt);

  @override
  String toString() =>
      hasPhoto ? 'ProfilePhotoRef(r$rev, $mediaId)' : 'ProfilePhotoRef(r$rev, cleared)';
}
