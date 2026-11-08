import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/profile_photo.dart';
import '../box/box_media_fetcher.dart';
import '../box/box_media_frame.dart';
import '../box/box_outbox.dart';
import '../box/box_wire.dart';
import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import '../media_crypto_service.dart';
import 'profile_photo_cache.dart';
import 'profile_photo_codec.dart';

/// How a change of the own photo ended ([ProfilePhotoOutcome.done] is the
/// only one that changed anything).
enum ProfilePhotoOutcome {
  done,

  /// The bytes are no image the platform decodes.
  unreadable,

  /// This device cannot reach the box now: no self-queue to charge the
  /// upload to yet, or the store is closed.
  noRoute,

  /// The box refused the upload (a quota, a size).
  refused,

  /// Anything else: no answer, a store that did not commit.
  failed,
}

/// The profile photo of this account and of its friends (decision 138), as
/// far as the DEVICE keeps it: encrypt, upload once, keep the ciphertext,
/// hold the reference in the contact store, fetch a friend's file and drop
/// what a newer reference replaced. Sending a reference to anyone is the
/// messaging side's (`MessagingProfile`); this knows no friend's queue.
///
/// * The file is a ≤256×256 JPEG ([ProfilePhotoCodec.scale]) sealed with a
///   fresh AES-256-GCM key, padded to a box media rung, and uploaded once —
///   charged to this device's own self-queue, which names no friend.
/// * The own reference — and when it was made, and whether a frame to the
///   friends is still owed — lives in the contact store's self row. Its
///   counter `r` only grows: `max(last + 1, now in ms)`, so a device that
///   lost its row still outruns every reference its account ever sent.
/// * A friend's reference replaces the held one only with a strictly higher
///   counter; its file is downloaded at once ([BoxMediaFetcher], decision 40's
///   retries) and decrypted into the [ProfilePhotoCache] when it lands.
class ProfilePhotos {
  ProfilePhotos({
    required this.store,
    required this.outbox,
    required this.media,
    ProfilePhotoCache? cache,
    MediaCryptoService? crypto,
    DateTime Function()? now,
  }) : cache = cache ?? ProfilePhotoCache.shared,
       _crypto = crypto ?? MediaCryptoService(),
       _now = now ?? DateTime.now;

  /// The box keeps a media file 14 days (D8): a photo is made again once it
  /// is older than this, so a friend that missed the first frames still has
  /// a file to fetch.
  static const Duration kRefreshAfter = Duration(days: 7);

  final ContactStore store;
  final BoxOutbox outbox;
  final BoxMediaFetcher media;
  final ProfilePhotoCache cache;
  final MediaCryptoService _crypto;
  final DateTime Function() _now;

  /// The own reference as the store holds it now (a cleared one included).
  ProfilePhotoRef? get own => store.selfPhoto.avatar;

  /// A frame carrying [own] is still owed to some friend or sibling.
  bool get ownPending => store.selfPhoto.pending;

  /// The one-time move of the server photo was made (or needs none).
  bool get migrated => store.selfPhoto.migrated;

  /// [ProfilePhotoRef.rev] for the next reference after [held]: one past it,
  /// and never behind the clock.
  int _nextRev(ProfilePhotoRef? held) {
    final next = math.max((held?.rev ?? 0) + 1, _now().millisecondsSinceEpoch);
    return math.min(next, ProfilePhotoRef.maxRev);
  }

  // ---------- The own photo ----------

  /// Makes [jpeg] — a sound ≤256 px JPEG ([ProfilePhotoCodec.scale]) — the
  /// account's photo: encrypted, uploaded once, its ciphertext kept here as
  /// the sender's own copy, and a new reference (higher counter, pending
  /// delivery) written to the self row. The file the reference replaced goes.
  Future<ProfilePhotoOutcome> setOwn(Uint8List jpeg) async {
    final userId = store.userId;
    final queue = store.selfQueue;
    if (userId == null || queue == null) return ProfilePhotoOutcome.noRoute;
    if (!ProfilePhotoCodec.isSound(jpeg)) return ProfilePhotoOutcome.unreadable;
    final EncryptedMedia sealed;
    final BoxResult<BoxMediaRef> answer;
    try {
      sealed = await _crypto.encrypt(jpeg);
      if (sealed.ciphertext.length > ProfilePhotoCodec.kMaxCiphertextBytes) {
        return ProfilePhotoOutcome.failed;
      }
      answer = await outbox.uploadMedia(
        ContactOutbound(peerDeviceId: 0, sid: queue.sid, sealPub: queue.sealPub),
        frameMediaToRung(sealed.ciphertext),
      );
    } on Object {
      return ProfilePhotoOutcome.failed;
    }
    final BoxMediaRef uploaded;
    switch (answer) {
      case BoxOk(:final value):
        uploaded = value;
      case BoxRefused():
        return ProfilePhotoOutcome.refused;
      case BoxUnknown():
        return ProfilePhotoOutcome.failed;
    }
    try {
      await media.keep(userId, uploaded.id, sealed.ciphertext);
    } on Object {
      return ProfilePhotoOutcome.failed;
    }
    ProfilePhotoRef? previous;
    ProfilePhotoRef? made;
    final committed = await store.updateSelfPhoto((current) {
      previous = current.avatar;
      made = ProfilePhotoRef(
        rev: _nextRev(current.avatar),
        mediaId: boxB64(uploaded.id),
        key: sealed.keyBase64,
        iv: sealed.ivBase64,
        uploadedAt: _now(),
      );
      return (avatar: made, pending: true, migrated: current.migrated);
    });
    final ref = made;
    if (!committed || ref == null) {
      await _forgetFile(uploaded.id);
      return ProfilePhotoOutcome.failed;
    }
    cache.remember(ref, jpeg);
    await _dropReplaced(previous, ref);
    return ProfilePhotoOutcome.done;
  }

  /// Removes the account's photo: a cleared reference with the next counter,
  /// pending delivery, and the file it replaced gone from this device.
  Future<ProfilePhotoOutcome> clearOwn() async {
    if (store.userId == null) return ProfilePhotoOutcome.noRoute;
    ProfilePhotoRef? previous;
    ProfilePhotoRef? made;
    final committed = await store.updateSelfPhoto((current) {
      previous = current.avatar;
      if (previous == null || previous!.isCleared) return null;
      made = ProfilePhotoRef.cleared(_nextRev(previous), at: _now());
      return (avatar: made, pending: true, migrated: true);
    });
    if (!committed) return ProfilePhotoOutcome.failed;
    final ref = made;
    if (ref != null) await _dropReplaced(previous, ref);
    return ProfilePhotoOutcome.done;
  }

  /// The own photo made again when it is older than [kRefreshAfter]; null
  /// when it is not due (no photo, or no known age — a restored reference
  /// says none and its file is not here to make again).
  Future<ProfilePhotoOutcome?> refreshIfDue() async {
    final ref = own;
    final at = ref?.uploadedAt;
    if (ref == null || !ref.hasPhoto || at == null) return null;
    if (_now().difference(at) <= kRefreshAfter) return null;
    final plain = await _ownPlain(ref);
    if (plain == null) return ProfilePhotoOutcome.failed;
    return setOwn(plain);
  }

  /// The decrypted file the own [ref] names: this device's own copy, else the
  /// box's while it still holds it.
  Future<Uint8List?> _ownPlain(ProfilePhotoRef ref) async {
    final userId = store.userId;
    final id = ref.mediaIdBytes;
    if (userId == null || id == null) return null;
    try {
      final ciphertext = await media.ciphertextFor(userId, id);
      if (ciphertext == null) return null;
      return await _crypto.decrypt(ciphertext, ref.key!, ref.iv!);
    } on Object {
      return null;
    }
  }

  /// Every frame carrying [ref] was taken: nothing is owed any more. A newer
  /// reference that landed meanwhile keeps its own debt.
  Future<void> markAnnounced(ProfilePhotoRef ref) =>
      store.updateSelfPhoto(
        (current) => current.avatar?.rev == ref.rev && current.pending
            ? (avatar: current.avatar, pending: false, migrated: current.migrated)
            : null,
      );

  /// The one-time move of the server photo is over — made, or there was none
  /// to make: it never runs again.
  Future<void> markMigrated() => store.updateSelfPhoto(
    (current) => current.migrated
        ? null
        : (avatar: current.avatar, pending: current.pending, migrated: true),
  );

  // ---------- A friend's photo ----------

  /// A friend's [ref], from its `profile` frame or its request / accept:
  /// kept only for an account that is a FRIEND, and only when it carries a
  /// strictly higher counter than the one held (a late frame never brings
  /// back what a newer one replaced). A photo is then fetched at once and the
  /// replaced file goes. True when the record changed.
  Future<bool> takeFriend(int friendId, ProfilePhotoRef ref) async {
    ProfilePhotoRef? previous;
    var changed = false;
    final committed = await store.update(friendId, (current) {
      if (current == null || current.state != ContactState.friend) return null;
      if (!ref.supersedes(current.avatar)) return null;
      previous = current.avatar;
      changed = true;
      return current.copyWith(avatar: ref);
    });
    if (!committed || !changed) return false;
    fetch(ref);
    await _dropReplaced(previous, ref);
    return true;
  }

  /// This account's own frame from a sibling: the account's newest photo.
  /// Replaces the own reference only with a strictly higher counter; nothing
  /// is owed on it (the sibling sent it to everyone), and [madeAt] — when the
  /// sibling made the file, clamped to now — keeps the weekly clock honest.
  Future<bool> takeSibling(ProfilePhotoRef ref, {DateTime? madeAt}) async {
    ProfilePhotoRef? previous;
    var changed = false;
    final now = _now();
    final at = madeAt == null || madeAt.isAfter(now) ? now : madeAt;
    final committed = await store.updateSelfPhoto((current) {
      if (!ref.supersedes(current.avatar)) return null;
      previous = current.avatar;
      changed = true;
      return (
        avatar: ref.copyWith(uploadedAt: at),
        pending: false,
        migrated: true,
      );
    });
    if (!committed || !changed) return false;
    fetch(ref);
    await _dropReplaced(previous, ref);
    return true;
  }

  /// Fetches [ref]'s file in the background and decrypts it into the cache
  /// when it lands; nothing for a cleared reference.
  void fetch(ProfilePhotoRef ref) {
    final userId = store.userId;
    final id = ref.mediaIdBytes;
    if (userId == null || id == null) return;
    media.prefetch(
      userId,
      id,
      receivedAt: _now(),
      maxBytes: ProfilePhotoCodec.kMaxCiphertextBytes,
      onKept: (ciphertext) => unawaited(cache.ingest(ref, ciphertext)),
    );
  }

  /// The files of every held reference this device has no copy of (a restore
  /// brought the reference, not the file; a download that died with the app):
  /// fetched again while the box could still hold them. One that is gone
  /// stays initials until its owner's next re-send.
  Future<void> fetchMissing() async {
    final userId = store.userId;
    if (userId == null) return;
    final refs = [
      ?own,
      for (final record in store.all) ?record.avatar,
    ];
    for (final ref in refs) {
      final id = ref.mediaIdBytes;
      if (id == null) continue;
      await media.prefetchIfMissing(
        userId,
        id,
        receivedAt: _now(),
        maxBytes: ProfilePhotoCodec.kMaxCiphertextBytes,
        onKept: (ciphertext) => unawaited(cache.ingest(ref, ciphertext)),
      );
    }
  }

  // ---------- Housekeeping ----------

  /// The file [previous] named is no longer anyone's current photo here:
  /// its ciphertext and its decrypted bytes go. A reference is replaced only
  /// by a newer one, so the id never comes back.
  Future<void> _dropReplaced(
    ProfilePhotoRef? previous,
    ProfilePhotoRef replacement,
  ) async {
    final id = previous?.mediaId;
    final bytes = previous?.mediaIdBytes;
    if (id == null || bytes == null || id == replacement.mediaId) return;
    cache.forget(id);
    await _forgetFile(bytes);
  }

  Future<void> _forgetFile(Uint8List id) async {
    final userId = store.userId;
    if (userId == null) return;
    try {
      await media.forget(userId, id);
    } on Object {
      // An unreadable store keeps the stale copy; it is never shown.
    }
  }
}
