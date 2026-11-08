import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/contact_seed.dart';

/// A friend's photo moves without the set of chats changing (decision 138):
/// the chat already shown takes the photo its contact record holds now.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProfilePhotoRef photo(int rev, {int idFill = 1}) => ProfilePhotoRef(
    rev: rev,
    mediaId: boxB64(Uint8List(32)..fillRange(0, 32, idFill)),
    key: base64.encode(List.filled(32, 7)),
    iv: base64.encode(List.filled(12, 9)),
  );

  ContactRecord friend(int id, {ProfilePhotoRef? avatar, bool muted = false}) =>
      contactRecord(
        id,
        'peer$id',
        ContactState.friend,
        box: true,
        settings: ContactSettings(muted: muted),
      ).copyWith(avatar: avatar);

  test("a friend's new photo replaces the peer of the chat on the next "
      'refresh; the chat set is unchanged', () async {
    final store = await openContactStore([friend(2), friend(3)]);
    final chats = conversationsOver(store);
    var told = 0;
    chats.addListener(() => told++);
    final ids = chats.conversations.map((c) => c.id).toList();
    expect(chats.conversations.map((c) => c.userTwo.avatar), [null, null]);

    await putContacts(store, [friend(2, avatar: photo(5))]);
    chats.refreshChats();

    expect(chats.conversations.map((c) => c.id), ids);
    final bob = chats.conversations.firstWhere((c) => c.userTwo.id == 2);
    final cara = chats.conversations.firstWhere((c) => c.userTwo.id == 3);
    expect(bob.userTwo.avatar, photo(5));
    expect(cara.userTwo.avatar, isNull, reason: 'only the one that moved');
    expect(told, 1);
  });

  test('a refresh with no change tells nobody', () async {
    final store = await openContactStore([friend(2, avatar: photo(5))]);
    final chats = conversationsOver(store);
    var told = 0;
    chats.addListener(() => told++);

    chats.refreshChats();
    chats.refreshChats();
    expect(told, 0);
    expect(chats.conversations.single.userTwo.avatar, photo(5));
  });

  test('a newer photo, a removal and a record without one each replace the '
      'shown peer', () async {
    final store = await openContactStore([friend(2, avatar: photo(5))]);
    final chats = conversationsOver(store);

    await putContacts(store, [friend(2, avatar: photo(6, idFill: 2))]);
    chats.refreshChats();
    expect(chats.conversations.single.userTwo.avatar, photo(6, idFill: 2));

    await putContacts(store, [
      friend(2, avatar: const ProfilePhotoRef.cleared(7)),
    ]);
    chats.refreshChats();
    expect(chats.conversations.single.userTwo.avatar?.isCleared, isTrue);
    expect(chats.conversations.single.userTwo.avatar?.rev, 7);

    await putContacts(store, [friend(2)]);
    chats.refreshChats();
    expect(chats.conversations.single.userTwo.avatar, isNull);
  });

  test("the rest of the shown row is kept: only the peer's photo moves",
      () async {
    final store = await openContactStore([friend(2, muted: true)]);
    final chats = conversationsOver(store);
    final before = chats.conversations.single;
    expect(before.muted, isTrue);

    // The record now says "not muted" (a setting write that landed after the
    // row was shown): the shown row keeps its own; only the photo moves.
    await putContacts(store, [friend(2, avatar: photo(5))]);
    chats.refreshChats();

    final after = chats.conversations.single;
    expect(after.id, before.id);
    expect(after.userOne, same(before.userOne));
    expect(after.createdAt, before.createdAt);
    expect(after.muted, before.muted);
    expect(after.userTwo.username, before.userTwo.username);
    expect(after.userTwo.avatar, photo(5));
  });

  test('a chat that is not shown yet is built with the photo the record '
      'holds', () async {
    final store = await openContactStore([friend(2, avatar: photo(5))]);
    final chats = conversationsOver(store);
    expect(chats.conversations.single.userTwo.avatar, photo(5));

    await putContacts(store, [friend(4, avatar: photo(8, idFill: 4))]);
    chats.refreshChats();
    final added = chats.conversations.firstWhere((c) => c.userTwo.id == 4);
    expect(added.userTwo.avatar, photo(8, idFill: 4));
    expect(
      chats.conversations.firstWhere((c) => c.userTwo.id == 2).userTwo.avatar,
      photo(5),
    );
  });
}
