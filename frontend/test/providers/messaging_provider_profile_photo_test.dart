import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_media_fetcher.dart';
import 'package:fireplace/services/box/box_media_store.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/profile/profile_photo_cache.dart';
import 'package:fireplace/services/profile/profile_photos.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/box_send_harness.dart';
import '../support/contact_seed.dart';
import '../support/profile_photo_fakes.dart';

/// The box as a profile frame meets it: every frame with the mode it was
/// kept as (the harness outbox drops it).
class _ModeOutbox extends SendOutbox {
  final List<BoxSendMode?> modes = [];

  @override
  Future<BoxSendOutcome> deliver(
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
  }) {
    modes.add(mode);
    return super.deliver(to, body, mode: mode);
  }
}

ContactQueue _selfQueue() => ContactQueue(
  rid: boxB64(Uint8List(32)..fillRange(0, 32, 0x10)),
  sid: boxB64(Uint8List(32)..fillRange(0, 32, 0x11)),
  nid: boxB64(Uint8List(16)..fillRange(0, 16, 0x12)),
  authPriv: boxB64(Uint8List(64)..fillRange(0, 64, 0x13)),
  sealPriv: boxB64(Uint8List(32)..fillRange(0, 32, 0x14)),
  sealPub: boxB64(Uint8List(32)..fillRange(0, 32, 0x15)),
);

/// The profile reference a frame the harness box took carries; null for
/// any other envelope.
ProfilePhotoRef? _profileOf(BoxFrame frame) =>
    E2eEnvelope.parseProfile(utf8.decode(frame.signal))?.avatar;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BoxSendHarness h;
  late _ModeOutbox outbox;
  late ContactStore store;
  late ProfilePhotos photos;

  setUp(() async {
    h = await BoxSendHarness.create();
    outbox = _ModeOutbox()
      ..addresses[2] = {1: boxAddress(1), 2: boxAddress(2)};
    store = await openContactStore(
      [contactRecord(2, 'bob', ContactState.friend)],
      resetPrefs: false,
    );
    await store.claimSelfQueue(_selfQueue());
    final crypto = TagMediaCrypto();
    photos = ProfilePhotos(
      store: store,
      outbox: outbox,
      media: BoxMediaFetcher(
        store: MemoryBoxMediaStore(),
        download: outbox.downloadMedia,
      ),
      cache: ProfilePhotoCache(crypto: crypto),
      crypto: crypto,
    );
    h.encryption.lists[2] = enrolledList([1, 2]);
    h.encryption.sessions
      ..add((2, 1))
      ..add((2, 2));
    h.provider
      ..boxOutbox = outbox
      ..profilePhotos = photos
      ..profilePhotoScaler = (picked) async => picked;
  });

  tearDown(() => h.dispose());

  test('a new photo is uploaded once and reaches every live friend device as '
      'one quiet profile frame carrying the same reference', () async {
    final outcome = await h.provider.setOwnProfilePhoto(fakeJpeg(1));
    await h.pump();

    expect(outcome, ProfilePhotoOutcome.done);
    expect(outbox.uploads, hasLength(1));
    expect(
      outbox.uploads.single.$1.sid,
      store.selfQueue!.sid,
      reason: 'the upload is charged to our own queue, naming no friend',
    );
    final sent = outbox.delivered
        .where((d) => _profileOf(d.$2) != null)
        .toList();
    expect({for (final d in sent) d.$1.peerDeviceId}, {1, 2});
    final own = photos.own!;
    expect(own.hasPhoto, isTrue);
    for (final d in sent) {
      expect(_profileOf(d.$2)!.rev, own.rev);
      expect(_profileOf(d.$2)!.mediaId, own.mediaId);
      expect(_profileOf(d.$2)!.key, own.key);
    }
    expect(outbox.modes, everyElement(BoxSendMode.quiet));
  });

  test('a device this one holds no session with is not sent a frame (no '
      'pre-key fetch for a photo)', () async {
    h.encryption.sessions.remove((2, 2));

    await h.provider.setOwnProfilePhoto(fakeJpeg(2));
    await h.pump();

    final to = {
      for (final d in outbox.delivered)
        if (_profileOf(d.$2) != null) d.$1.peerDeviceId,
    };
    expect(to, {1});
  });

  test('a device the verified list does not name live is no one to tell',
      () async {
    h.encryption.lists[2] = enrolledList([1]);

    await h.provider.setOwnProfilePhoto(fakeJpeg(3));
    await h.pump();

    final to = {
      for (final d in outbox.delivered)
        if (_profileOf(d.$2) != null) d.$1.peerDeviceId,
    };
    expect(to, {1});
  });

  test('removing the photo tells every friend device a cleared reference '
      'with a higher counter', () async {
    await h.provider.setOwnProfilePhoto(fakeJpeg(4));
    await h.pump();
    final before = photos.own!.rev;
    outbox.delivered.clear();

    final outcome = await h.provider.removeOwnProfilePhoto();
    await h.pump();

    expect(outcome, ProfilePhotoOutcome.done);
    final cleared = [
      for (final d in outbox.delivered)
        ?_profileOf(d.$2),
    ];
    expect(cleared, hasLength(2));
    for (final ref in cleared) {
      expect(ref.isCleared, isTrue);
      expect(ref.rev, greaterThan(before));
    }
  });

  group('migration of the server photo (release A)', () {
    test('an account with a server photo and no reference moves it once: one '
        'download, one upload, never again', () async {
      var downloads = 0;
      h.provider.legacyOwnPhoto = () async {
        downloads++;
        return fakeJpeg(5);
      };

      await h.provider.syncOwnPhoto();
      await h.pump();
      await h.provider.syncOwnPhoto();
      await h.pump();

      expect(downloads, 1);
      expect(outbox.uploads, hasLength(1));
      expect(photos.own!.hasPhoto, isTrue);
      expect(photos.own!.rev, 1, reason: 'any real change outranks it');
      expect(photos.migrated, isTrue);
      expect(
        outbox.delivered.where((d) => _profileOf(d.$2) != null),
        isNotEmpty,
        reason: 'friends learn it by the same frame',
      );
    });

    test('an account with no server photo is settled at once and never asks '
        'again', () async {
      var asked = 0;
      h.provider.legacyOwnPhoto = () async {
        asked++;
        return null;
      };

      await h.provider.syncOwnPhoto();
      await h.provider.syncOwnPhoto();

      expect(asked, 1);
      expect(photos.own, isNull);
      expect(photos.migrated, isTrue);
      expect(outbox.uploads, isEmpty);
    });

    test('a failed download decides nothing: not marked migrated, nothing '
        'uploaded', () async {
      var asked = 0;
      h.provider.legacyOwnPhoto = () async {
        asked++;
        throw Exception('offline');
      };

      await h.provider.syncOwnPhoto();

      expect(photos.migrated, isFalse);
      expect(photos.own, isNull);
      expect(outbox.uploads, isEmpty);
      expect(asked, 1);
    });

    test('removing the photo before the migration ran settles it: the '
        'server photo is never published afterwards, and friends are told '
        'the removal', () async {
      var asked = 0;
      h.provider.legacyOwnPhoto = () async {
        asked++;
        return fakeJpeg(8);
      };

      expect(await h.provider.removeOwnProfilePhoto(), ProfilePhotoOutcome.done);
      await h.pump();
      await h.provider.syncOwnPhoto();
      await h.pump();

      expect(asked, 0);
      expect(outbox.uploads, isEmpty);
      expect(photos.own!.isCleared, isTrue);
      final told = {
        for (final d in outbox.delivered)
          if (_profileOf(d.$2)?.isCleared ?? false) d.$1.peerDeviceId,
      };
      expect(told, {1, 2});
    });

    test('a removal made while the server photo downloads is not undone by '
        'the migration', () async {
      h.provider.legacyOwnPhoto = () async {
        await h.provider.removeOwnProfilePhoto();
        return fakeJpeg(8);
      };

      await h.provider.syncOwnPhoto();
      await h.pump();

      expect(outbox.uploads, isEmpty);
      expect(photos.own!.isCleared, isTrue);
    });

    test('an account that already has an end-to-end reference is never '
        'migrated', () async {
      await h.provider.setOwnProfilePhoto(fakeJpeg(6));
      await h.pump();
      outbox.uploads.clear();
      var asked = 0;
      h.provider.legacyOwnPhoto = () async {
        asked++;
        return fakeJpeg(7);
      };

      await h.provider.syncOwnPhoto();

      expect(asked, 0);
      expect(outbox.uploads, isEmpty);
    });
  });
}
