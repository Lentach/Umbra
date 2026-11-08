import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:flutter_test/flutter_test.dart';

/// The photo a friend sent end to end (decision 138) rides its contact record
/// as the reference only: what is persisted, what a backup restores, what a
/// screen reads through [ContactRecord.toUser].
void main() {
  final mediaId = boxB64(
    Uint8List.fromList([for (var i = 0; i < 32; i++) i + 1]),
  );
  final key = base64.encode(List.filled(32, 7));
  final iv = base64.encode(List.filled(12, 9));

  ProfilePhotoRef photo(int rev) =>
      ProfilePhotoRef(rev: rev, mediaId: mediaId, key: key, iv: iv);

  ContactRecord record({ProfilePhotoRef? avatar, String? avatarUrl}) =>
      ContactRecord(
        userId: 2,
        username: 'bob',
        tag: '0002',
        avatarUrl: avatarUrl,
        avatar: avatar,
        state: ContactState.friend,
      );

  /// What a disk read sees: the record through real JSON.
  ContactRecord reread(ContactRecord r) => ContactRecord.fromJson(
    jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
  );

  test('the reference is persisted as its wire shape and read back', () {
    final r = record(avatar: photo(7));
    expect(r.toJson()['avatar'], {'m': mediaId, 'k': key, 'i': iv, 'r': 7});
    expect(reread(r).avatar, photo(7));
  });

  test('a removed photo is persisted as {r, x: 1} and read back cleared', () {
    final r = record(avatar: const ProfilePhotoRef.cleared(8));
    expect(r.toJson()['avatar'], {'r': 8, 'x': 1});
    final back = reread(r).avatar;
    expect(back?.isCleared, isTrue);
    expect(back?.rev, 8);
  });

  test('a friend who never sent one has no `avatar` key, and none is read', () {
    final r = record();
    expect(r.toJson().containsKey('avatar'), isFalse);
    expect(reread(r).avatar, isNull);
  });

  test('a stored reference that is not spelled exactly reads as no photo '
      'and costs the contact nothing else', () {
    for (final bad in <Object?>[
      'x',
      5,
      <Object?>[],
      {'r': 0, 'm': mediaId, 'k': key, 'i': iv},
      {'r': 3, 'm': 'short', 'k': key, 'i': iv},
      {'r': 3, 'm': mediaId, 'k': 'short', 'i': iv},
      {'r': 3, 'x': 1, 'm': mediaId},
    ]) {
      final json = record(avatar: photo(3)).toJson()..['avatar'] = bad;
      final back = ContactRecord.fromJson(json);
      expect(back.avatar, isNull, reason: '$bad');
      expect(back.userId, 2, reason: '$bad');
      expect(back.username, 'bob', reason: '$bad');
      expect(back.state, ContactState.friend, reason: '$bad');
    }
  });

  test('the local upload time of a reference is never persisted on a friend '
      'record', () {
    final at = DateTime.utc(2026, 11, 8);
    final r = record(avatar: photo(7).copyWith(uploadedAt: at));
    expect((r.toJson()['avatar'] as Map).containsKey('at'), isFalse);
    expect(reread(r).avatar?.uploadedAt, isNull);
  });

  test('toUser carries the reference beside the legacy path', () {
    final user = record(
      avatar: photo(7),
      avatarUrl: '/media/avatars/old.jpg',
    ).toUser();
    expect(user.avatar, photo(7));
    expect(user.profilePictureUrl, '/media/avatars/old.jpg');
    expect(record().toUser().avatar, isNull);
  });

  test('a server profile refresh never wipes the end-to-end photo', () {
    final refreshed = record(
      avatar: photo(7),
      avatarUrl: '/media/avatars/old.jpg',
    ).withProfile(UserModel(id: 2, username: 'bobby', tag: '0002'));
    expect(refreshed.username, 'bobby');
    expect(refreshed.avatarUrl, isNull);
    expect(refreshed.avatar, photo(7));
  });

  test('copyWith sets and clears the reference', () {
    final r = record(avatar: photo(7));
    expect(r.copyWith(avatar: photo(9)).avatar?.rev, 9);
    expect(r.copyWith(username: 'x').avatar, photo(7));
    expect(r.copyWith(clearAvatar: true).avatar, isNull);
  });

  group('the contact backup', () {
    test('keeps the reference as its wire shape, about a hundred bytes', () {
      final backup = record(avatar: photo(7)).toBackupJson();
      expect(backup['avatar'], {'m': mediaId, 'k': key, 'i': iv, 'r': 7});
      expect(jsonEncode(backup['avatar']).length, lessThan(160));
    });

    test('a restore round-trips it', () {
      final restored = ContactRecord.fromJson(
        jsonDecode(jsonEncode(record(avatar: photo(7)).toBackupJson()))
            as Map<String, dynamic>,
      );
      expect(restored.avatar, photo(7));
    });

    test('a removed photo survives the backup too: a restore never brings '
        'the file back', () {
      final restored = ContactRecord.fromJson(
        jsonDecode(
              jsonEncode(
                record(
                  avatar: const ProfilePhotoRef.cleared(8),
                  avatarUrl: '/media/avatars/old.jpg',
                ).toBackupJson(),
              ),
            )
            as Map<String, dynamic>,
      );
      expect(restored.avatar?.isCleared, isTrue);
      expect(restored.avatar?.rev, 8);
    });

    test('a friend without one has no `avatar` key in the backup', () {
      expect(record().toBackupJson().containsKey('avatar'), isFalse);
    });
  });
}
