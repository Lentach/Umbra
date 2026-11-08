import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_backup.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/passcode_fakes.dart';

/// The contact backup carries the photo REFERENCES (decision 138) — the own
/// one and every friend's — never a file and never the own local upload time.
void main() {
  final mediaId = boxB64(
    Uint8List.fromList([for (var i = 0; i < 32; i++) i + 1]),
  );
  final friendMediaId = boxB64(
    Uint8List.fromList([for (var i = 0; i < 32; i++) 100 + i]),
  );
  final key = base64.encode(List.filled(32, 7));
  final iv = base64.encode(List.filled(12, 9));

  ProfilePhotoRef photo(int rev, {String? id, DateTime? at}) => ProfilePhotoRef(
    rev: rev,
    mediaId: id ?? mediaId,
    key: key,
    iv: iv,
    uploadedAt: at,
  );

  ContactRecord friend(int id, {ProfilePhotoRef? avatar}) => ContactRecord(
    userId: id,
    username: 'peer$id',
    tag: '0001',
    avatar: avatar,
    state: ContactState.friend,
  );

  final codec = ContactBackupCodec(
    kdf: FakePasscodeKdf(),
    sealer: FakeContentSealer(),
  );

  Future<ContactBackupPayload> roundTrip(ContactBackupPayload payload) async {
    final (ck, _) = ContactBackupCodec.mintContentKey();
    return codec.openPayload(ck, await codec.sealPayload(ck, payload));
  }

  /// The plaintext the codec sealed — the bytes the server is handed — past
  /// the fake sealer's 4-byte key prefix and the codec's length frame.
  Future<String> plaintextOf(ContactBackupPayload payload) async {
    final (ck, _) = ContactBackupCodec.mintContentKey();
    final framed = base64Decode(await codec.sealPayload(ck, payload)).sublist(4);
    final length =
        (framed[0] << 24) | (framed[1] << 16) | (framed[2] << 8) | framed[3];
    return utf8.decode(framed.sublist(4, 4 + length));
  }

  test("a sealed backup round-trips the own reference AND every friend's", () async {
    final opened = await roundTrip(
      ContactBackupPayload(
        userId: 7,
        self: UserModel(id: 7, username: 'me', tag: '0007', avatar: photo(11)),
        contacts: [
          friend(42, avatar: photo(5, id: friendMediaId)),
          friend(43, avatar: const ProfilePhotoRef.cleared(6)),
          friend(44),
        ],
      ),
    );

    expect(opened.self?.avatar, photo(11));
    final byId = {for (final c in opened.contacts) c.userId: c};
    expect(byId[42]?.avatar, photo(5, id: friendMediaId));
    expect(byId[43]?.avatar?.isCleared, isTrue);
    expect(byId[43]?.avatar?.rev, 6);
    expect(byId[44]?.avatar, isNull);
  });

  test('the own reference is the wire shape only: when it was made is not '
      'in the blob, and a restore has no time', () async {
    final payload = ContactBackupPayload(
      userId: 7,
      self: UserModel(
        id: 7,
        username: 'me',
        tag: '0007',
        avatar: photo(11, at: DateTime.utc(2026, 11)),
      ),
      contacts: const [],
    );

    final plain = jsonDecode(await plaintextOf(payload)) as Map<String, dynamic>;
    expect((plain['self'] as Map)['avatar'], {
      'm': mediaId,
      'k': key,
      'i': iv,
      'r': 11,
    });
    expect(
      (await roundTrip(payload)).self?.avatar?.uploadedAt,
      isNull,
      reason: 'the file is gone with the device; the age is not restorable',
    );
  });

  test('a removed own photo is kept as a clear, never dropped to "none"',
      () async {
    final opened = await roundTrip(
      ContactBackupPayload(
        userId: 7,
        self: UserModel(
          id: 7,
          username: 'me',
          tag: '0007',
          avatar: const ProfilePhotoRef.cleared(12),
        ),
        contacts: const [],
      ),
    );
    expect(opened.self?.avatar?.isCleared, isTrue);
    expect(opened.self?.avatar?.rev, 12);
  });

  test('a backup from before the photo opens with none', () {
    final opened = ContactBackupPayload.fromJson({
      'v': kContactBackupVersion,
      'domain': kContactBackupDomain,
      'userId': 7,
      'self': {'id': 7, 'username': 'me', 'tag': '0007'},
      'contacts': [
        friend(42).toBackupJson(),
      ],
    });
    expect(opened.self?.username, 'me');
    expect(opened.self?.avatar, isNull);
    expect(opened.contacts.single.avatar, isNull);
  });

  test('a reference in a backup that is not spelled exactly is no photo; '
      'the self row and the contact it sits in survive', () {
    final opened = ContactBackupPayload.fromJson({
      'v': kContactBackupVersion,
      'domain': kContactBackupDomain,
      'userId': 7,
      'self': {
        'id': 7,
        'username': 'me',
        'tag': '0007',
        'avatar': {'m': 'short', 'k': key, 'i': iv, 'r': 3},
      },
      'contacts': [
        {
          ...friend(42).toBackupJson(),
          'avatar': {'m': mediaId, 'k': key, 'i': iv, 'r': 0},
        },
      ],
    });
    expect(opened.self?.username, 'me');
    expect(opened.self?.avatar, isNull);
    expect(opened.contacts.single.userId, 42);
    expect(opened.contacts.single.avatar, isNull);
  });
}
