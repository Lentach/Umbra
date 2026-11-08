import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The own photo reference lives on the store's self row (decision 138): the
/// reference (a clear included), whether a frame to friends is still owed,
/// and whether the one-time server-photo move was made. A profile refresh
/// from the server never touches it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mediaId = boxB64(
    Uint8List.fromList([for (var i = 0; i < 32; i++) i + 1]),
  );
  final key = base64.encode(List.filled(32, 7));
  final iv = base64.encode(List.filled(12, 9));

  ProfilePhotoRef photo(int rev, {DateTime? at}) => ProfilePhotoRef(
    rev: rev,
    mediaId: mediaId,
    key: key,
    iv: iv,
    uploadedAt: at,
  );

  UserModel profile({
    String name = 'alice',
    String? url,
    ProfilePhotoRef? avatar,
  }) => UserModel(
    id: 1,
    username: name,
    tag: '0001',
    profilePictureUrl: url,
    avatar: avatar,
  );

  late ContentKv kv;

  ContactStore newStore({UserModel? Function()? selfProfile}) => ContactStore(
    open: () async => kv,
    selfProfile: selfProfile,
    lock: <T>(_, action) => action(),
    accepts: (_) => true,
  );

  /// A store for account 1 whose auth profile is [profile], opened and with
  /// its self row written.
  Future<ContactStore> opened({UserModel? Function()? selfProfile}) async {
    final store = newStore(selfProfile: selfProfile ?? profile);
    await store.open(1);
    await store.settled;
    return store;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = await PrefsContentKv.open();
  });

  SelfPhotoState owed(ProfilePhotoRef? avatar) =>
      (avatar: avatar, pending: true, migrated: true);

  test('a fresh account holds no photo, owes nothing, has not migrated', () async {
    final store = await opened();
    expect(store.selfPhoto.avatar, isNull);
    expect(store.selfPhoto.pending, isFalse);
    expect(store.selfPhoto.migrated, isFalse);
  });

  group('updateSelfPhoto', () {
    test('the reference, the debt and the migration flag survive a re-open, '
        'with the time the file was made', () async {
      final store = await opened();
      final at = DateTime.utc(2026, 11, 1, 8);
      expect(
        await store.updateSelfPhoto(
          (_) => (avatar: photo(5, at: at), pending: true, migrated: true),
        ),
        isTrue,
      );
      expect(store.selfPhoto.avatar, photo(5, at: at));

      final again = await opened();
      expect(again.selfPhoto.avatar, photo(5, at: at));
      expect(again.selfPhoto.avatar?.uploadedAt, at);
      expect(again.selfPhoto.pending, isTrue);
      expect(again.selfPhoto.migrated, isTrue);
      expect(again.self?.avatar, photo(5, at: at));
    });

    test('a debt paid and a flag unset are persisted as such', () async {
      final store = await opened();
      await store.updateSelfPhoto((_) => owed(photo(5)));
      await store.updateSelfPhoto(
        (c) => (avatar: c.avatar, pending: false, migrated: c.migrated),
      );
      final again = await opened();
      expect(again.selfPhoto.pending, isFalse);
      expect(again.selfPhoto.migrated, isTrue);
      expect(again.selfPhoto.avatar?.rev, 5);
    });

    test('a cleared reference is held and persisted as a clear', () async {
      final store = await opened();
      await store.updateSelfPhoto((_) => owed(photo(5)));
      await store.updateSelfPhoto(
        (_) => owed(ProfilePhotoRef.cleared(6, at: DateTime.utc(2026, 11, 2))),
      );
      final again = await opened();
      expect(again.selfPhoto.avatar?.isCleared, isTrue);
      expect(again.selfPhoto.avatar?.rev, 6);
    });

    test('handing back no reference removes it (a clear is not "none")',
        () async {
      final store = await opened();
      await store.updateSelfPhoto((_) => owed(photo(5)));
      await store.updateSelfPhoto(
        (_) => (avatar: null, pending: false, migrated: true),
      );
      expect(store.selfPhoto.avatar, isNull);
      expect((await opened()).selfPhoto.avatar, isNull);
    });

    test('mutate returning null changes nothing and is not an error', () async {
      final store = await opened();
      await store.updateSelfPhoto((_) => owed(photo(5)));
      var told = 0;
      store.onSelfAvatarChanged = (_) => told++;
      expect(await store.updateSelfPhoto((_) => null), isTrue);
      expect(store.selfPhoto.avatar, photo(5));
      expect(told, 0);
    });

    test('there is no row to hold it on a store with no account profile: '
        'false, and nothing is held', () async {
      final store = newStore();
      await store.open(1);
      expect(await store.updateSelfPhoto((_) => owed(photo(5))), isFalse);
      expect(store.selfPhoto.avatar, isNull);
    });

    test('a closed store refuses', () async {
      final store = newStore(selfProfile: profile);
      expect(await store.updateSelfPhoto((_) => owed(photo(5))), isFalse);
    });

    test('it reads the row as it is ON DISK: a write another context made '
        'is what mutate sees', () async {
      final first = await opened();
      final other = await opened(); // another tab of this device
      await first.updateSelfPhoto((_) => owed(photo(5)));

      ProfilePhotoRef? seen;
      await other.updateSelfPhoto((current) {
        seen = current.avatar;
        return (avatar: photo(6), pending: true, migrated: true);
      });
      expect(seen?.rev, 5);
      expect((await opened()).selfPhoto.avatar?.rev, 6);
    });
  });

  group('a profile refresh (setSelf / re-open) never costs the photo', () {
    test('a refresh without a reference keeps it, and the flags', () async {
      final store = await opened();
      await store.updateSelfPhoto((_) => owed(photo(5)));

      expect(await store.setSelf(profile(name: 'alice2')), isTrue);
      expect(store.selfPhoto.avatar, photo(5));
      expect(store.selfPhoto.pending, isTrue);
      expect(store.selfPhoto.migrated, isTrue);
      expect(store.self?.username, 'alice2', reason: 'the rest is refreshed');

      final again = await opened(selfProfile: () => profile(name: 'alice2'));
      expect(again.selfPhoto.avatar, photo(5));
      expect(again.selfPhoto.pending, isTrue);
      expect(again.selfPhoto.migrated, isTrue);
    });

    test('the legacy server path is refreshed beside the kept reference',
        () async {
      final store = await opened();
      await store.updateSelfPhoto((_) => owed(photo(5)));
      await store.setSelf(profile(url: '/media/avatars/new.jpg'));
      expect(store.self?.profilePictureUrl, '/media/avatars/new.jpg');
      expect(store.self?.avatar, photo(5));
    });

    test('a re-open under a fresh auth profile keeps what the row holds',
        () async {
      final store = await opened();
      await store.updateSelfPhoto((_) => owed(photo(5)));

      final again = await opened(
        selfProfile: () => profile(url: '/media/avatars/x.jpg'),
      );
      expect(again.selfPhoto.avatar, photo(5));
      expect(again.self?.avatar, photo(5));
      expect(again.selfPhoto.pending, isTrue);
    });

    test('a profile naming a STRICTLY higher counter replaces the held one, '
        'the flags stay', () async {
      final store = await opened();
      await store.updateSelfPhoto((_) => owed(photo(5)));
      await store.setSelf(profile(avatar: photo(6)));
      expect(store.selfPhoto.avatar?.rev, 6);
      expect(store.selfPhoto.pending, isTrue);
      expect(store.selfPhoto.migrated, isTrue);
      expect((await opened()).selfPhoto.avatar?.rev, 6);
    });

    test('a profile naming an equal or a lower counter keeps the held one',
        () async {
      final store = await opened();
      final held = photo(5, at: DateTime.utc(2026, 11));
      await store.updateSelfPhoto((_) => owed(held));
      for (final named in [photo(5), photo(4), photo(1)]) {
        await store.setSelf(profile(avatar: named));
        expect(store.selfPhoto.avatar, held, reason: 'r${named.rev}');
      }
      expect((await opened()).selfPhoto.avatar, held);
    });

    test('a removed photo is not brought back by a profile without one, nor '
        'by an older photo', () async {
      final store = await opened();
      await store.updateSelfPhoto((_) => owed(photo(5)));
      await store.updateSelfPhoto(
        (_) => owed(ProfilePhotoRef.cleared(6, at: DateTime.utc(2026, 11, 2))),
      );

      await store.setSelf(profile());
      expect(store.selfPhoto.avatar?.isCleared, isTrue);
      await store.setSelf(profile(avatar: photo(5)));
      expect(store.selfPhoto.avatar?.isCleared, isTrue);
      expect(store.selfPhoto.avatar?.rev, 6);
      await store.setSelf(profile(avatar: photo(7)));
      expect(store.selfPhoto.avatar?.hasPhoto, isTrue);
      expect(store.selfPhoto.avatar?.rev, 7);
    });

    test('a profile for another account is refused', () async {
      final store = await opened();
      await store.updateSelfPhoto((_) => owed(photo(5)));
      expect(
        await store.setSelf(
          UserModel(id: 2, username: 'eve', tag: '0002', avatar: photo(9)),
        ),
        isFalse,
      );
      expect(store.selfPhoto.avatar, photo(5));
    });
  });

  group('onSelfAvatarChanged', () {
    test('is told the stored reference as the store opens', () async {
      final first = await opened();
      await first.updateSelfPhoto((_) => owed(photo(5)));

      final told = <ProfilePhotoRef?>[];
      final again = newStore(selfProfile: profile)
        ..onSelfAvatarChanged = told.add;
      await again.open(1);
      await again.settled;
      expect(told, isNotEmpty);
      expect(told.first?.rev, 5);
      expect(told.last?.rev, 5);
    });

    test('is told after a change of the photo, a clear and a refresh that '
        'names a newer one — and only then', () async {
      final store = await opened();
      final told = <ProfilePhotoRef?>[];
      store.onSelfAvatarChanged = told.add;

      await store.updateSelfPhoto((_) => owed(photo(5)));
      expect(told.map((r) => r?.rev), [5]);

      await store.updateSelfPhoto(
        (_) => owed(ProfilePhotoRef.cleared(6, at: DateTime.utc(2026, 11, 2))),
      );
      expect(told.last?.isCleared, isTrue);

      await store.setSelf(profile(avatar: photo(9)));
      expect(told.last?.rev, 9);
      expect(told.last?.hasPhoto, isTrue);
    });

    test('a listener that throws can never fail the store', () async {
      final store = await opened();
      store.onSelfAvatarChanged = (_) => throw StateError('screen gone');
      expect(await store.updateSelfPhoto((_) => owed(photo(5))), isTrue);
      expect(store.selfPhoto.avatar, photo(5));
      expect(await store.setSelf(profile(name: 'x')), isTrue);
    });
  });

  group('a row on disk', () {
    Future<void> writeRow(Map<String, Object?> row) async =>
        kv.setString(ContactStore.selfKey(1), jsonEncode(row));

    test('with a reference not spelled exactly reads as no photo; the row '
        'and the flags are read', () async {
      await writeRow({
        'id': 1,
        'username': 'alice',
        'tag': '0001',
        'avatar': {'m': 'short', 'k': key, 'i': iv, 'r': 4},
        'avPending': true,
        'avMigrated': true,
      });
      final store = newStore();
      await store.open(1);
      expect(store.self?.username, 'alice');
      expect(store.selfPhoto.avatar, isNull);
      expect(store.selfPhoto.pending, isTrue);
      expect(store.selfPhoto.migrated, isTrue);
      expect(store.undeterminedCount, 0);
    });

    test('from before the photo has none, owes nothing, has not migrated',
        () async {
      await writeRow({'id': 1, 'username': 'alice', 'tag': '0001'});
      final store = newStore();
      await store.open(1);
      expect(store.selfPhoto.avatar, isNull);
      expect(store.selfPhoto.pending, isFalse);
      expect(store.selfPhoto.migrated, isFalse);
    });

    test('a stored reference with its time is read whole', () async {
      final at = DateTime.utc(2026, 11, 1, 8);
      await writeRow({
        'id': 1,
        'username': 'alice',
        'tag': '0001',
        'avatar': photo(5, at: at).toJson(),
      });
      final store = newStore();
      await store.open(1);
      expect(store.selfPhoto.avatar, photo(5, at: at));
    });
  });
}
