import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/contact_seed.dart';

/// The peer of a request shows NO photo, whatever its record holds (decision
/// 53): the verified profile at accept is where the photo comes from. A
/// friend's own photo is shown as ever.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final photo = ProfilePhotoRef(
    rev: 5,
    mediaId: boxB64(Uint8List.fromList([for (var i = 0; i < 32; i++) i + 1])),
    key: base64.encode(List.filled(32, 7)),
    iv: base64.encode(List.filled(12, 9)),
  );
  const legacy = '/media/avatars/old.jpg';

  ContactRecord withPhoto(ContactRecord r) =>
      r.copyWith(avatar: photo, avatarUrl: legacy);

  test('the peer of an incoming request has no photo of either kind, '
      'although its record holds both', () async {
    final store = await openContactStore([
      withPhoto(contactRecord(2, 'bob', ContactState.pendingIn, box: true)),
    ]);
    expect(store.byUserId(2)!.avatar, photo, reason: 'the record keeps it');

    final request = friendsOver(store).friendRequests.single;
    expect(request.sender.id, 2);
    expect(request.sender.avatar, isNull);
    expect(request.sender.profilePictureUrl, isNull);
    expect(request.sender.username, 'bob', reason: 'only the photo is cut');
  });

  test('the peer of a sent request has no photo of either kind', () async {
    final store = await openContactStore([
      withPhoto(contactRecord(3, 'cara', ContactState.pendingOut, box: true)),
    ]);

    final request = friendsOver(store).sentRequests.single;
    expect(request.receiver.id, 3);
    expect(request.receiver.avatar, isNull);
    expect(request.receiver.profilePictureUrl, isNull);
  });

  test('a cleared reference on a request is no photo either', () async {
    final store = await openContactStore([
      contactRecord(2, 'bob', ContactState.pendingIn, box: true).copyWith(
        avatar: const ProfilePhotoRef.cleared(6),
      ),
    ]);
    expect(friendsOver(store).friendRequests.single.sender.avatar, isNull);
  });

  test('a friend of the same store keeps both photos', () async {
    final store = await openContactStore([
      withPhoto(contactRecord(2, 'bob', ContactState.pendingIn, box: true)),
      withPhoto(contactRecord(4, 'dan', ContactState.friend, box: true)),
      withPhoto(contactRecord(5, 'eve', ContactState.pendingOut, box: true)),
    ]);
    final friends = friendsOver(store);

    final friend = friends.friends.single;
    expect(friend.id, 4);
    expect(friend.avatar, photo);
    expect(friend.profilePictureUrl, legacy);
    expect(friends.friendRequests.single.sender.avatar, isNull);
    expect(friends.sentRequests.single.receiver.avatar, isNull);
  });

  test('the photo shows once the request is accepted and the contact is a '
      'friend', () async {
    final store = await openContactStore([
      withPhoto(contactRecord(2, 'bob', ContactState.pendingIn, box: true)),
    ]);
    final friends = friendsOver(store);
    expect(friends.friendRequests.single.sender.avatar, isNull);

    await putContacts(store, [
      withPhoto(contactRecord(2, 'bob', ContactState.friend, box: true)),
    ]);
    expect(friends.friendRequests, isEmpty);
    expect(friends.friends.single.avatar, photo);
    expect(friends.friends.single.profilePictureUrl, legacy);
  });

  test('a blocked contact keeps the photo its record holds', () async {
    final store = await openContactStore([
      withPhoto(contactRecord(6, 'fay', ContactState.blocked, box: true)),
    ]);
    expect(friendsOver(store).blockedUsers.single.avatar, photo);
  });
}
