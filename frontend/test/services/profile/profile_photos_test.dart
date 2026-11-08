import 'dart:typed_data';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/services/box/box_media_fetcher.dart';
import 'package:fireplace/services/box/box_media_frame.dart';
import 'package:fireplace/services/box/box_media_store.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/media_crypto_service.dart'
    show EncryptedMedia;
import 'package:fireplace/services/profile/profile_photo_cache.dart';
import 'package:fireplace/services/profile/profile_photos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/box_send_harness.dart' show SendOutbox;
import '../../support/profile_photo_fakes.dart';

/// The box as the photos see it: uploads can be refused or fail, and every
/// download is recorded.
class _Outbox extends SendOutbox {
  final List<Uint8List> downloads = [];
  BoxResult<BoxMediaRef>? uploadAnswer;
  bool uploadThrows = false;

  @override
  Future<BoxResult<BoxMediaRef>> uploadMedia(
    ContactOutbound to,
    Uint8List framed,
  ) async {
    if (uploadThrows) throw StateError('network');
    final answer = uploadAnswer;
    if (answer != null) {
      uploads.add((to, framed));
      return answer;
    }
    return super.uploadMedia(to, framed);
  }

  @override
  Future<BoxResult<Uint8List>> downloadMedia(Uint8List id) {
    downloads.add(id);
    return super.downloadMedia(id);
  }
}

class _FlakyMediaStore extends MemoryBoxMediaStore {
  bool failPut = false;

  @override
  Future<void> put(int userId, Uint8List id, Uint8List ciphertext) async {
    if (failPut) throw StateError('disk full');
    await super.put(userId, id, ciphertext);
  }
}

class _NoBackendCrypto extends TagMediaCrypto {
  @override
  Future<EncryptedMedia> encrypt(Uint8List bytes) async =>
      throw UnsupportedError('webcrypto native unavailable');
}

ContactQueue _selfQueue() => ContactQueue(
  rid: boxB64(Uint8List(32)..fillRange(0, 32, 0x10)),
  sid: boxB64(Uint8List(32)..fillRange(0, 32, 0x11)),
  nid: boxB64(Uint8List(16)..fillRange(0, 16, 0x12)),
  authPriv: boxB64(Uint8List(64)..fillRange(0, 64, 0x13)),
  sealPriv: boxB64(Uint8List(32)..fillRange(0, 32, 0x14)),
  sealPub: boxB64(Uint8List(32)..fillRange(0, 32, 0x15)),
);

bool _contains(Uint8List haystack, Uint8List needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var same = true;
    for (var j = 0; j < needle.length && same; j++) {
      same = haystack[i + j] == needle[j];
    }
    if (same) return true;
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime clock;
  late ContentKv kv;
  late ContactStore store;
  late _Outbox outbox;
  late _FlakyMediaStore files;
  late BoxMediaFetcher fetcher;
  late TagMediaCrypto crypto;
  late TagMediaCrypto friendCrypto;
  late ProfilePhotoCache cache;
  late ProfilePhotos photos;
  final plain = fakeJpeg(1);

  Future<ContactStore> openStore({
    bool selfRow = true,
    bool queue = true,
    bool fresh = false,
  }) async {
    if (fresh) {
      SharedPreferences.setMockInitialValues({});
      kv = await PrefsContentKv.open();
    }
    final opened = ContactStore(
      open: () async => kv,
      selfProfile: selfRow
          ? () => UserModel(id: 1, username: 'alice', tag: '0001')
          : null,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await opened.open(1);
    await opened.settled;
    if (queue) await opened.claimSelfQueue(_selfQueue());
    return opened;
  }

  ProfilePhotos buildPhotos() => ProfilePhotos(
    store: store,
    outbox: outbox,
    media: fetcher,
    cache: cache,
    crypto: crypto,
    now: () => clock,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = await PrefsContentKv.open();
    clock = DateTime.utc(2026, 11, 8, 12);
    outbox = _Outbox();
    files = _FlakyMediaStore();
    crypto = TagMediaCrypto();
    friendCrypto = TagMediaCrypto();
    cache = ProfilePhotoCache(crypto: crypto)..bind(store: files, userId: 1);
    fetcher = BoxMediaFetcher(
      store: files,
      download: outbox.downloadMedia,
      now: () => clock,
    );
    store = await openStore();
    photos = buildPhotos();
  });

  tearDown(() {
    fetcher.dispose();
    cache.dispose();
  });

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await pumpEventQueue();
    }
  }

  Future<void> befriend(int id, {ContactState state = ContactState.friend}) =>
      store.update(
        id,
        (_) => ContactRecord(
          userId: id,
          username: 'peer$id',
          tag: id.toString().padLeft(4, '0'),
          state: state,
        ),
      );

  /// A friend's photo as its sender made it, with the file on the box.
  Future<ProfilePhotoRef> onBox(int seed, {required int rev}) async {
    final sealed = await sealPhoto(
      friendCrypto,
      fakeJpeg(seed),
      rev: rev,
      idFill: seed,
    );
    outbox.media[mediaIdOf(seed)] = frameMediaToRung(sealed.ciphertext);
    return sealed.ref;
  }

  group('setOwn', () {
    test('the photo is encrypted, uploaded ONCE to the own self-queue, kept '
        "as this device's copy and referenced from the self row", () async {
      expect(await photos.setOwn(plain), ProfilePhotoOutcome.done);

      final (to, framed) = outbox.uploads.single;
      expect(to.sid, store.selfQueue!.sid);
      expect(to.sealPub, store.selfQueue!.sealPub);
      expect(to.peerDeviceId, 0);

      final own = photos.own!;
      expect(own.hasPhoto, isTrue);
      expect(own.uploadedAt, clock);
      expect(own.rev, clock.millisecondsSinceEpoch);
      expect(photos.ownPending, isTrue, reason: 'friends are still owed it');

      // What the box holds opens, under the reference's key, to the photo —
      // and holds no viewable copy of it.
      final ciphertext = unframeMedia(framed)!;
      expect(await crypto.decrypt(ciphertext, own.key!, own.iv!), plain);
      expect(_contains(framed, plain), isFalse);
      expect(crypto.encrypted.single, plain);

      // The sender's own copy rests as ciphertext, never as the photo.
      expect(await files.get(1, own.mediaIdBytes!), ciphertext);
      expect(cache.bytesFor(own), plain);
    });

    test('the reference names the file the box answered', () async {
      await photos.setOwn(plain);
      final stored = outbox.media.keys.single;
      expect(photos.own!.mediaId, stored);
    });

    test('a second photo replaces the first: a strictly higher counter even '
        'in the same millisecond, a new key, a new file — and the replaced '
        'file is gone from this device', () async {
      await photos.setOwn(plain);
      final first = photos.own!;
      await photos.setOwn(fakeJpeg(2));
      final second = photos.own!;

      expect(second.rev, first.rev + 1);
      expect(second.mediaId, isNot(first.mediaId));
      expect(second.key, isNot(first.key));
      expect(second.iv, isNot(first.iv));
      expect(outbox.uploads, hasLength(2));
      expect(await files.has(1, first.mediaIdBytes!), isFalse);
      expect(await files.has(1, second.mediaIdBytes!), isTrue);
      expect(cache.bytesFor(first), isNull);
      expect(cache.bytesFor(second), fakeJpeg(2));
    });

    test('the counter never trails the clock: a later photo takes the '
        'millisecond when that is ahead', () async {
      await photos.setOwn(plain);
      final first = photos.own!.rev;
      clock = clock.add(const Duration(days: 1));
      await photos.setOwn(fakeJpeg(2));
      expect(photos.own!.rev, clock.millisecondsSinceEpoch);
      expect(photos.own!.rev, greaterThan(first + 1));
    });

    test('a device that lost its row still outruns what the account sent '
        'before: the counter starts at the clock', () async {
      await photos.setOwn(plain);
      expect(photos.own!.rev, greaterThan(1700000000000));
    });

    test('bytes that are no sound JPEG are unreadable: nothing uploaded, '
        'nothing changed', () async {
      for (final bad in [
        Uint8List(0),
        Uint8List.fromList([1, 2, 3, 4, 5, 6]),
        jpegHeader(5000, 5000),
      ]) {
        expect(await photos.setOwn(bad), ProfilePhotoOutcome.unreadable);
      }
      expect(outbox.uploads, isEmpty);
      expect(photos.own, isNull);
      expect(crypto.encrypts, 0);
    });

    test('no self-queue to charge the upload to: noRoute, nothing sent',
        () async {
      store = await openStore(queue: false, fresh: true);
      photos = buildPhotos();
      expect(await photos.setOwn(plain), ProfilePhotoOutcome.noRoute);
      expect(outbox.uploads, isEmpty);
      expect(photos.own, isNull);
    });

    test('a closed store is noRoute for every change', () async {
      store.close();
      expect(await photos.setOwn(plain), ProfilePhotoOutcome.noRoute);
      expect(await photos.clearOwn(), ProfilePhotoOutcome.noRoute);
      expect(outbox.uploads, isEmpty);
    });

    test('the box refusing the upload leaves the photo as it was', () async {
      await photos.setOwn(plain);
      final held = photos.own;
      outbox.uploadAnswer = const BoxRefused(BoxCode.invalidPayload);
      expect(await photos.setOwn(fakeJpeg(2)), ProfilePhotoOutcome.refused);
      expect(photos.own, held);
      expect(await files.has(1, held!.mediaIdBytes!), isTrue);
    });

    test('no answer, a throw, or a missing crypto backend is failed, and '
        'nothing changed', () async {
      outbox.uploadAnswer = const BoxUnknown(BoxUnknownReason.timeout);
      expect(await photos.setOwn(plain), ProfilePhotoOutcome.failed);

      outbox
        ..uploadAnswer = null
        ..uploadThrows = true;
      expect(await photos.setOwn(plain), ProfilePhotoOutcome.failed);

      crypto = _NoBackendCrypto();
      photos = buildPhotos();
      outbox.uploadThrows = false;
      expect(await photos.setOwn(plain), ProfilePhotoOutcome.failed);
      expect(photos.own, isNull);
      expect(photos.ownPending, isFalse);
    });

    test('a device store that cannot keep the copy is failed: the reference '
        'is not written', () async {
      files.failPut = true;
      expect(await photos.setOwn(plain), ProfilePhotoOutcome.failed);
      expect(photos.own, isNull);
    });

    test('a file over the 256 KiB rung is failed, never uploaded', () async {
      final huge = jpegHeader(64, 64, tail: List.filled(300 * 1024, 1));
      expect(await photos.setOwn(huge), ProfilePhotoOutcome.failed);
      expect(outbox.uploads, isEmpty);
      expect(photos.own, isNull);
    });

    test('when the reference cannot be written the uploaded file is not '
        'left on the device', () async {
      store = await openStore(selfRow: false, fresh: true);
      photos = buildPhotos();
      expect(await photos.setOwn(plain), ProfilePhotoOutcome.failed);
      expect(photos.own, isNull);
      final uploaded = Uint8List(32)..[0] = 1;
      expect(await files.has(1, uploaded), isFalse);
    });
  });

  group('clearOwn', () {
    test('the photo becomes a clear with a higher counter, owed to friends; '
        'the file it replaced is gone', () async {
      await photos.setOwn(plain);
      final held = photos.own!;

      expect(await photos.clearOwn(), ProfilePhotoOutcome.done);
      final own = photos.own!;
      expect(own.isCleared, isTrue);
      expect(own.rev, greaterThan(held.rev));
      expect(own.uploadedAt, clock);
      expect(photos.ownPending, isTrue);
      expect(photos.migrated, isTrue, reason: 'a removed photo is not '
          'migrated back from the server');
      expect(await files.has(1, held.mediaIdBytes!), isFalse);
      expect(cache.bytesFor(held), isNull);
    });

    test('a clear is a photo that is no more: the weekly clock ignores it',
        () async {
      await photos.setOwn(plain);
      await photos.clearOwn();
      clock = clock.add(const Duration(days: 30));
      expect(await photos.refreshIfDue(), isNull);
    });

    test('clearing what is already clear, or never was, changes nothing',
        () async {
      expect(await photos.clearOwn(), ProfilePhotoOutcome.done);
      expect(photos.own, isNull);
      expect(photos.ownPending, isFalse);

      await photos.setOwn(plain);
      await photos.clearOwn();
      final cleared = photos.own;
      clock = clock.add(const Duration(minutes: 5));
      await photos.clearOwn();
      expect(photos.own, cleared);
    });
  });

  group('refreshIfDue: the box keeps a file 14 days, the photo is made '
      'again after 7', () {
    Future<void> after(Duration d) async => clock = clock.add(d);

    test('not due at 6 days, nor at exactly 7', () async {
      await photos.setOwn(plain);
      await after(const Duration(days: 6));
      expect(await photos.refreshIfDue(), isNull);
      await after(const Duration(days: 1));
      expect(await photos.refreshIfDue(), isNull, reason: 'exactly 7 d');
      expect(outbox.uploads, hasLength(1));
    });

    test('due 1 ms past 7 days: a NEW file under a NEW key, a higher '
        'counter, owed again, the same photo', () async {
      await photos.setOwn(plain);
      final first = photos.own!;
      await photos.markAnnounced(first);
      expect(photos.ownPending, isFalse);
      await after(const Duration(days: 7, milliseconds: 1));

      expect(await photos.refreshIfDue(), ProfilePhotoOutcome.done);
      final second = photos.own!;
      expect(second.rev, greaterThan(first.rev));
      expect(second.mediaId, isNot(first.mediaId));
      expect(second.key, isNot(first.key));
      expect(second.iv, isNot(first.iv));
      expect(second.uploadedAt, clock);
      expect(photos.ownPending, isTrue);
      expect(outbox.uploads, hasLength(2));
      expect(crypto.encrypted.last, plain, reason: 'the same photo');
      expect(await files.has(1, first.mediaIdBytes!), isFalse);
      expect(cache.bytesFor(second), plain);
    });

    test('due at 8 days', () async {
      await photos.setOwn(plain);
      await after(const Duration(days: 8));
      expect(await photos.refreshIfDue(), ProfilePhotoOutcome.done);
      expect(outbox.uploads, hasLength(2));
    });

    test('once made again it is not due again', () async {
      await photos.setOwn(plain);
      await after(const Duration(days: 8));
      await photos.refreshIfDue();
      expect(await photos.refreshIfDue(), isNull);
      await after(const Duration(days: 6));
      expect(await photos.refreshIfDue(), isNull);
      expect(outbox.uploads, hasLength(2));
    });

    test('no photo, or one with no known age, is not due however long ago',
        () async {
      expect(await photos.refreshIfDue(), isNull);
      final restored = ProfilePhotoRef(
        rev: 5,
        mediaId: mediaIdOf(9),
        key: (await sealPhoto(friendCrypto, plain)).ref.key!,
        iv: (await sealPhoto(friendCrypto, plain)).ref.iv!,
      );
      await store.updateSelfPhoto(
        (_) => (avatar: restored, pending: false, migrated: true),
      );
      await after(const Duration(days: 365));
      expect(await photos.refreshIfDue(), isNull);
      expect(outbox.uploads, isEmpty);
    });

    test('a file that is nowhere any more is failed, and the held reference '
        'stays', () async {
      await photos.setOwn(plain);
      final held = photos.own!;
      await files.delete(1, held.mediaIdBytes!);
      outbox.media.clear();
      await after(const Duration(days: 8));

      expect(await photos.refreshIfDue(), ProfilePhotoOutcome.failed);
      expect(photos.own, held);
      expect(outbox.uploads, hasLength(1));
    });

    test('with the device copy gone but the box still holding it, the box '
        'copy is made again', () async {
      await photos.setOwn(plain);
      await files.delete(1, photos.own!.mediaIdBytes!);
      await after(const Duration(days: 8));
      expect(await photos.refreshIfDue(), ProfilePhotoOutcome.done);
      expect(crypto.encrypted.last, plain);
    });
  });

  group('takeFriend', () {
    test("a friend's photo is kept on its record and its file is fetched "
        'and shown', () async {
      await befriend(2);
      final ref = await onBox(0x21, rev: 5);

      expect(await photos.takeFriend(2, ref), isTrue);
      expect(store.byUserId(2)!.avatar, ref);

      await settle();
      expect(cache.bytesFor(ref), fakeJpeg(0x21));
      expect(await files.has(1, ref.mediaIdBytes!), isTrue);
    });

    test("only a FRIEND's: a request, a blocked or former contact or a "
        'stranger gets no photo and nothing is downloaded', () async {
      final ref = await onBox(0x21, rev: 5);
      var id = 10;
      for (final state in [
        ContactState.pendingIn,
        ContactState.pendingOut,
        ContactState.blocked,
        ContactState.former,
      ]) {
        await befriend(++id, state: state);
        expect(await photos.takeFriend(id, ref), isFalse, reason: '$state');
        expect(store.byUserId(id)!.avatar, isNull, reason: '$state');
      }
      expect(await photos.takeFriend(99, ref), isFalse);
      expect(store.byUserId(99), isNull, reason: 'no record is made for it');
      await settle();
      expect(outbox.downloads, isEmpty);
    });

    test('only a STRICTLY higher counter replaces: an equal or lower one '
        'changes nothing and fetches nothing', () async {
      await befriend(2);
      final held = await onBox(0x21, rev: 5);
      await photos.takeFriend(2, held);
      await settle();
      final downloads = outbox.downloads.length;

      final tie = await onBox(0x22, rev: 5);
      final older = await onBox(0x23, rev: 4);
      expect(await photos.takeFriend(2, tie), isFalse);
      expect(await photos.takeFriend(2, older), isFalse);
      await settle();

      expect(store.byUserId(2)!.avatar, held);
      expect(outbox.downloads, hasLength(downloads));
      expect(await files.has(1, held.mediaIdBytes!), isTrue);
    });

    test('a newer photo replaces the old one: the replaced file is dropped '
        'from the device and the new one fetched', () async {
      await befriend(2);
      final first = await onBox(0x21, rev: 5);
      final second = await onBox(0x22, rev: 6);
      await photos.takeFriend(2, first);
      await settle();

      expect(await photos.takeFriend(2, second), isTrue);
      await settle();

      expect(store.byUserId(2)!.avatar, second);
      expect(await files.has(1, first.mediaIdBytes!), isFalse);
      expect(cache.bytesFor(first), isNull);
      expect(cache.bytesFor(second), fakeJpeg(0x22));
    });

    test('a late older frame never brings back a replaced photo', () async {
      await befriend(2);
      final first = await onBox(0x21, rev: 5);
      final second = await onBox(0x22, rev: 6);
      await photos.takeFriend(2, first);
      await photos.takeFriend(2, second);
      await settle();
      outbox.downloads.clear();

      expect(await photos.takeFriend(2, first), isFalse);
      await settle();
      expect(store.byUserId(2)!.avatar, second);
      expect(outbox.downloads, isEmpty);
      expect(await files.has(1, first.mediaIdBytes!), isFalse);
      expect(cache.bytesFor(first), isNull);
    });

    test('a newer reference to the SAME file keeps the file', () async {
      await befriend(2);
      final first = await onBox(0x21, rev: 5);
      await photos.takeFriend(2, first);
      await settle();

      final resent = first.copyWith(rev: 6);
      expect(await photos.takeFriend(2, resent), isTrue);
      await settle();
      expect(await files.has(1, first.mediaIdBytes!), isTrue);
      expect(cache.bytesFor(resent), fakeJpeg(0x21));
    });

    test('a cleared reference with a higher counter removes the photo: the '
        'record is cleared and the replaced ciphertext is deleted', () async {
      await befriend(2);
      final first = await onBox(0x21, rev: 5);
      await photos.takeFriend(2, first);
      await settle();
      outbox.downloads.clear();

      expect(await photos.takeFriend(2, const ProfilePhotoRef.cleared(6)), isTrue);
      await settle();

      final held = store.byUserId(2)!.avatar!;
      expect(held.isCleared, isTrue);
      expect(held.rev, 6);
      expect(await files.has(1, first.mediaIdBytes!), isFalse);
      expect(cache.bytesFor(first), isNull);
      expect(outbox.downloads, isEmpty, reason: 'a clear names no file');
    });

    test('after a clear, a late older photo frame does not resurrect it',
        () async {
      await befriend(2);
      final first = await onBox(0x21, rev: 5);
      await photos.takeFriend(2, first);
      await photos.takeFriend(2, const ProfilePhotoRef.cleared(7));
      await settle();
      outbox.downloads.clear();

      final late = await onBox(0x22, rev: 6);
      expect(await photos.takeFriend(2, late), isFalse);
      expect(await photos.takeFriend(2, first), isFalse);
      await settle();

      expect(store.byUserId(2)!.avatar?.isCleared, isTrue);
      expect(store.byUserId(2)!.avatar?.rev, 7);
      expect(outbox.downloads, isEmpty);
      expect(await files.has(1, late.mediaIdBytes!), isFalse);
      expect(cache.bytesFor(late), isNull);
    });

    test('a photo after a clear needs a higher counter and is shown',
        () async {
      await befriend(2);
      await photos.takeFriend(2, const ProfilePhotoRef.cleared(7));
      final again = await onBox(0x22, rev: 8);
      expect(await photos.takeFriend(2, again), isTrue);
      await settle();
      expect(cache.bytesFor(again), fakeJpeg(0x22));
    });

    test("a file that does not open under the reference's key is never "
        'shown', () async {
      await befriend(2);
      final real = await onBox(0x21, rev: 5);
      final lying = ProfilePhotoRef(
        rev: 5,
        mediaId: real.mediaId!,
        key: (await sealPhoto(friendCrypto, plain, idFill: 3)).ref.key!,
        iv: real.iv!,
      );
      await photos.takeFriend(2, lying);
      await settle();
      expect(cache.bytesFor(lying), isNull);
    });

    test('a friend naming a file bigger than a photo gets no file kept',
        () async {
      await befriend(2);
      final ciphertext = Uint8List(300 * 1024);
      outbox.media[mediaIdOf(0x31)] = frameMediaToRung(ciphertext);
      final ref = (await sealPhoto(friendCrypto, plain, idFill: 0x31, rev: 5)).ref;

      expect(await photos.takeFriend(2, ref), isTrue);
      await settle();
      expect(await files.has(1, ref.mediaIdBytes!), isFalse);
      expect(cache.bytesFor(ref), isNull);
    });
  });

  group('takeSibling', () {
    test("a sibling's newer photo becomes the own one; nothing is owed, "
        'the file is fetched, the made-at time is kept', () async {
      await photos.setOwn(plain);
      final mine = photos.own!;
      final theirs = await onBox(0x41, rev: mine.rev + 100);
      final madeAt = clock.subtract(const Duration(days: 2));

      expect(await photos.takeSibling(theirs, madeAt: madeAt), isTrue);
      await settle();

      final own = photos.own!;
      expect(own.mediaId, theirs.mediaId);
      expect(own.rev, theirs.rev);
      expect(own.uploadedAt, madeAt);
      expect(photos.ownPending, isFalse);
      expect(photos.migrated, isTrue);
      expect(cache.bytesFor(own), fakeJpeg(0x41));
      expect(await files.has(1, mine.mediaIdBytes!), isFalse);
    });

    test('an equal or older reference is not taken', () async {
      await photos.setOwn(plain);
      final mine = photos.own!;
      for (final rev in [mine.rev, mine.rev - 1, 1]) {
        final ref = await onBox(0x42, rev: rev);
        expect(await photos.takeSibling(ref), isFalse, reason: 'r$rev');
      }
      expect(photos.own, mine);
      await settle();
      expect(outbox.downloads, isEmpty);
    });

    test('a made-at in the future is the clock; none is the clock', () async {
      final ref = await onBox(0x43, rev: 100);
      await photos.takeSibling(
        ref,
        madeAt: clock.add(const Duration(days: 3)),
      );
      expect(photos.own!.uploadedAt, clock);

      final next = await onBox(0x44, rev: 101);
      await photos.takeSibling(next);
      expect(photos.own!.uploadedAt, clock);
    });

    test("a sibling's removal is taken as a clear and drops the file",
        () async {
      await photos.setOwn(plain);
      final mine = photos.own!;
      expect(
        await photos.takeSibling(ProfilePhotoRef.cleared(mine.rev + 1)),
        isTrue,
      );
      expect(photos.own!.isCleared, isTrue);
      expect(await files.has(1, mine.mediaIdBytes!), isFalse);
      await settle();
      expect(outbox.downloads, isEmpty);
    });

    test('a photo that arrives after the account removed it does not '
        'resurrect it', () async {
      await photos.setOwn(plain);
      await photos.clearOwn();
      final cleared = photos.own!;
      final late = await onBox(0x45, rev: cleared.rev - 1);
      expect(await photos.takeSibling(late), isFalse);
      expect(photos.own, cleared);
    });

    test('its made-at keeps the weekly clock honest: a photo a sibling made '
        '8 days ago is made again now', () async {
      final theirs = await onBox(0x46, rev: 100);
      await photos.takeSibling(
        theirs,
        madeAt: clock.subtract(const Duration(days: 8)),
      );
      await settle();
      expect(await photos.refreshIfDue(), ProfilePhotoOutcome.done);
      expect(crypto.encrypted.last, fakeJpeg(0x46));
      expect(photos.own!.mediaId, isNot(theirs.mediaId));
    });

    test('it settles a debt the older own reference left', () async {
      await photos.setOwn(plain);
      expect(photos.ownPending, isTrue);
      final theirs = await onBox(0x47, rev: photos.own!.rev + 1);
      await photos.takeSibling(theirs);
      expect(photos.ownPending, isFalse);
    });
  });

  group('markAnnounced / markMigrated', () {
    test('the debt is paid for the reference it was owed on', () async {
      await photos.setOwn(plain);
      await photos.markAnnounced(photos.own!);
      expect(photos.ownPending, isFalse);
      expect(photos.own!.hasPhoto, isTrue);
    });

    test('a newer reference that landed meanwhile keeps its own debt',
        () async {
      await photos.setOwn(plain);
      final announced = photos.own!;
      await photos.setOwn(fakeJpeg(2));
      await photos.markAnnounced(announced);
      expect(photos.ownPending, isTrue);
    });

    test('the one-time move is marked once and keeps the photo and the debt',
        () async {
      await photos.setOwn(plain);
      expect(photos.migrated, isFalse);
      final held = photos.own;
      await photos.markMigrated();
      await photos.markMigrated();
      expect(photos.migrated, isTrue);
      expect(photos.own, held);
      expect(photos.ownPending, isTrue);
    });
  });

  group('fetch / fetchMissing', () {
    test('a cleared reference names no file to fetch', () async {
      photos.fetch(const ProfilePhotoRef.cleared(5));
      await settle();
      expect(outbox.downloads, isEmpty);
    });

    test('fetch downloads the file, keeps its ciphertext and shows the '
        'photo', () async {
      final ref = await onBox(0x51, rev: 5);
      photos.fetch(ref);
      await settle();
      expect(cache.bytesFor(ref), fakeJpeg(0x51));
      expect(await files.has(1, ref.mediaIdBytes!), isTrue);
    });

    test('fetchMissing fetches the files of held references this device '
        'has no copy of — and only those', () async {
      await photos.setOwn(plain); // own copy: on the device
      await befriend(2);
      await befriend(3);
      await befriend(4);
      await befriend(5);
      final missing = await onBox(0x61, rev: 5);
      final kept = await onBox(0x62, rev: 5);
      final gone = (await sealPhoto(friendCrypto, plain, idFill: 0x63, rev: 5)).ref;
      await store.update(
        2,
        (c) => c!.copyWith(avatar: missing),
      );
      await store.update(3, (c) => c!.copyWith(avatar: kept));
      await store.update(4, (c) => c!.copyWith(avatar: gone));
      await store.update(
        5,
        (c) => c!.copyWith(avatar: const ProfilePhotoRef.cleared(9)),
      );
      await files.put(
        1,
        kept.mediaIdBytes!,
        unframeMedia(outbox.media[kept.mediaId!]!)!,
      );
      outbox.downloads.clear();

      await photos.fetchMissing();
      await settle();

      expect(
        outbox.downloads.map(boxB64),
        unorderedEquals([missing.mediaId, gone.mediaId]),
        reason: 'not the own file, not the kept one, not a clear',
      );
      expect(cache.bytesFor(missing), fakeJpeg(0x61));
      expect(cache.bytesFor(gone), isNull, reason: 'gone from the box: initials');
    });

    test('a restored own reference whose file is gone is not an error',
        () async {
      final ref = (await sealPhoto(friendCrypto, plain, idFill: 0x71, rev: 5)).ref;
      await store.updateSelfPhoto(
        (_) => (avatar: ref, pending: false, migrated: true),
      );
      await photos.fetchMissing();
      await settle();
      expect(cache.bytesFor(ref), isNull);
      expect(photos.own, ref);
    });
  });
}
