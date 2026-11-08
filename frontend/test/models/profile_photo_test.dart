import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:flutter_test/flutter_test.dart';

/// The profile photo reference (decision 138) is peer data bound for this
/// device's disk and its media fetcher: it is read whole or not at all.
void main() {
  final idBytes = Uint8List.fromList([for (var i = 0; i < 32; i++) i + 1]);
  final mediaId = boxB64(idBytes);
  final key = base64.encode(List.filled(32, 7));
  final iv = base64.encode(List.filled(12, 9));

  Map<String, Object?> photo({
    Object? r = 5,
    Object? m,
    Object? k,
    Object? i,
  }) => {'m': m ?? mediaId, 'k': k ?? key, 'i': i ?? iv, 'r': r};

  ProfilePhotoRef made(int rev, {DateTime? at}) => ProfilePhotoRef(
    rev: rev,
    mediaId: mediaId,
    key: key,
    iv: iv,
    uploadedAt: at,
  );

  group('the wire shape', () {
    test('a photo round-trips as exactly {m, k, i, r}', () {
      final ref = made(5);
      expect(ref.toWire(), {'m': mediaId, 'k': key, 'i': iv, 'r': 5});
      final back = ProfilePhotoRef.fromWire(
        jsonDecode(jsonEncode(ref.toWire())),
      );
      expect(back, ref);
      expect(back!.hasPhoto, isTrue);
      expect(back.isCleared, isFalse);
      expect(back.mediaIdBytes, idBytes);
    });

    test('the cleared state round-trips as exactly {r, x: 1}', () {
      const ref = ProfilePhotoRef.cleared(9);
      expect(ref.toWire(), {'r': 9, 'x': 1});
      final back = ProfilePhotoRef.fromWire(
        jsonDecode(jsonEncode(ref.toWire())),
      );
      expect(back, ref);
      expect(back!.isCleared, isTrue);
      expect(back.hasPhoto, isFalse);
      expect(back.mediaIdBytes, isNull);
      expect(back.mediaId, isNull);
      expect(back.key, isNull);
      expect(back.iv, isNull);
    });

    test('the smallest and the largest counter a JSON number carries are '
        'accepted', () {
      expect(ProfilePhotoRef.fromWire(photo(r: 1))?.rev, 1);
      expect(
        ProfilePhotoRef.fromWire(photo(r: ProfilePhotoRef.maxRev))?.rev,
        9007199254740991,
      );
      expect(ProfilePhotoRef.fromWire({'r': 1, 'x': 1}), isNotNull);
      expect(
        ProfilePhotoRef.fromWire({'r': ProfilePhotoRef.maxRev, 'x': 1}),
        isNotNull,
      );
    });

    test('the local upload time never goes on the wire', () {
      final ref = made(5, at: DateTime.utc(2026, 11));
      expect(ref.toWire().keys, unorderedEquals(['m', 'k', 'i', 'r']));
      expect(
        ProfilePhotoRef.cleared(6, at: DateTime.utc(2026, 11)).toWire(),
        {'r': 6, 'x': 1},
      );
      expect(jsonEncode(ref.toWire()), isNot(contains('"at"')));
    });

    test('fromWire ignores an `at` a peer sends: it is local bookkeeping', () {
      final read = ProfilePhotoRef.fromWire({
        ...photo(),
        'at': DateTime.utc(2026, 11).millisecondsSinceEpoch,
      });
      expect(read, isNotNull);
      expect(read!.uploadedAt, isNull);
    });
  });

  group('the device record shape', () {
    test('toJson keeps `at` beside the wire shape, fromJson restores it', () {
      final at = DateTime.utc(2026, 11, 1, 12, 30);
      final ref = made(5, at: at);
      expect(ref.toJson(), {...ref.toWire(), 'at': at.millisecondsSinceEpoch});
      final back = ProfilePhotoRef.fromJson(jsonDecode(jsonEncode(ref.toJson())));
      expect(back, ref);
      expect(back!.uploadedAt, at);
      expect(back.uploadedAt!.isUtc, isTrue);
    });

    test('a cleared reference keeps its `at` too', () {
      final at = DateTime.utc(2026, 11);
      final ref = ProfilePhotoRef.cleared(8, at: at);
      expect(ref.toJson(), {'r': 8, 'x': 1, 'at': at.millisecondsSinceEpoch});
      expect(ProfilePhotoRef.fromJson(ref.toJson())?.uploadedAt, at);
    });

    test('without an `at` there is no upload time and no `at` key', () {
      expect(made(5).toJson().containsKey('at'), isFalse);
      expect(ProfilePhotoRef.fromJson(made(5).toJson())?.uploadedAt, isNull);
    });

    test('an unusable `at` loses only the time, never the reference', () {
      for (final at in [0, -5, 1.5, '1700000000000', null, true]) {
        final read = ProfilePhotoRef.fromJson({...photo(), 'at': at});
        expect(read, isNotNull, reason: '$at');
        expect(read!.uploadedAt, isNull, reason: '$at');
        expect(read.mediaId, mediaId, reason: '$at');
      }
    });

    test('a hostile record is dropped whole, `at` or not', () {
      expect(ProfilePhotoRef.fromJson({...photo(r: 0), 'at': 5}), isNull);
      expect(ProfilePhotoRef.fromJson(null), isNull);
      expect(ProfilePhotoRef.fromJson('x'), isNull);
      expect(
        ProfilePhotoRef.fromJson({'r': 3, 'x': 1, 'm': mediaId, 'at': 5}),
        isNull,
      );
    });
  });

  group('a reference not spelled exactly is dropped whole', () {
    test('a non-map is null', () {
      for (final raw in [null, 'str', 5, true, <Object?>[], [1, 2]]) {
        expect(ProfilePhotoRef.fromWire(raw), isNull, reason: '$raw');
      }
    });

    test('the counter must be an int in 1..9007199254740991', () {
      for (final r in [
        0,
        -1,
        -9007199254740991,
        9007199254740992,
        1.0,
        1.5,
        2.0,
        '1',
        '',
        null,
        true,
        double.nan,
        double.infinity,
        [1],
      ]) {
        expect(ProfilePhotoRef.fromWire(photo(r: r)), isNull, reason: '$r');
        expect(
          ProfilePhotoRef.fromWire({'r': r, 'x': 1}),
          isNull,
          reason: 'cleared $r',
        );
      }
      expect(ProfilePhotoRef.fromWire({...photo()}..remove('r')), isNull);
      expect(ProfilePhotoRef.fromWire(const {'x': 1}), isNull);
    });

    test('`m` must be the canonical 32-byte box id', () {
      final last = mediaId[42];
      expect('AEIMQUYcgkosw048'.contains(last), isTrue);
      for (final m in [
        '',
        mediaId.substring(0, 42),
        '${mediaId}A',
        '$mediaId=',
        '${mediaId.substring(0, 41)}+$last',
        '${mediaId.substring(0, 41)}/$last',
        '${mediaId.substring(0, 41)} $last',
        '${mediaId.substring(0, 42)}B', // non-zero spare bits
        '${mediaId.substring(0, 42)}Z',
        base64.encode(idBytes), // the standard spelling, 44 chars
        base64.encode(Uint8List(16)), // a 16-byte id
        42,
        null,
        <String>[mediaId],
      ]) {
        expect(
          ProfilePhotoRef.fromWire(photo()..['m'] = m),
          isNull,
          reason: '$m',
        );
      }
    });

    test('`k` must be the canonical STANDARD base64 of 32 bytes', () {
      final zeros = base64.encode(Uint8List(32)); // 43 x 'A' + '='
      final plusSlash = base64.encode(List.filled(32, 0xfb));
      expect(plusSlash, contains('+'));
      expect(plusSlash, contains('/'));
      expect(
        ProfilePhotoRef.fromWire(photo(k: plusSlash)),
        isNotNull,
        reason: 'the standard alphabet is the spelling',
      );
      for (final k in [
        base64Url.encode(List.filled(32, 0xfb)), // url-safe alphabet
        key.substring(0, 43), // padding dropped
        key.substring(0, 42), // truncated
        base64.encode(List.filled(31, 7)),
        base64.encode(List.filled(33, 7)),
        base64.encode(List.filled(16, 7)),
        '$key\n',
        ' $key',
        '$key ',
        '${key.substring(0, 20)} ${key.substring(21)}',
        '${zeros.substring(0, 42)}B=', // non-zero spare bits
        '$key=',
        '',
        42,
        null,
      ]) {
        expect(
          ProfilePhotoRef.fromWire(photo()..['k'] = k),
          isNull,
          reason: '$k',
        );
      }
    });

    test('`i` must be the canonical standard base64 of 12 bytes', () {
      for (final i in [
        base64.encode(List.filled(11, 9)),
        base64.encode(List.filled(13, 9)),
        base64.encode(List.filled(16, 9)),
        base64.encode(List.filled(32, 9)),
        base64.encode(List.filled(11, 9)).replaceAll('=', ''),
        '$iv\n',
        '',
        12,
        null,
      ]) {
        expect(
          ProfilePhotoRef.fromWire(photo()..['i'] = i),
          isNull,
          reason: '$i',
        );
      }
    });

    test('a photo missing m, k or i is null', () {
      for (final dropped in ['m', 'k', 'i']) {
        expect(
          ProfilePhotoRef.fromWire(photo()..remove(dropped)),
          isNull,
          reason: dropped,
        );
      }
      expect(ProfilePhotoRef.fromWire(const {'r': 5}), isNull);
    });

    test('x is the cleared state only: x == 1 and none of m, k, i', () {
      for (final x in [0, 2, -1, 1.5, '1', true, null, <int>[1]]) {
        expect(
          ProfilePhotoRef.fromWire({'r': 5, 'x': x}),
          isNull,
          reason: 'x=$x',
        );
      }
      // A photo carrying an extra x is neither a photo nor a clear.
      expect(ProfilePhotoRef.fromWire({...photo(), 'x': 1}), isNull);
      expect(ProfilePhotoRef.fromWire({...photo(), 'x': 0}), isNull);
      // A clear carrying any part of a photo is dropped, not read as a clear.
      for (final extra in ['m', 'k', 'i']) {
        expect(
          ProfilePhotoRef.fromWire({'r': 5, 'x': 1, extra: photo()[extra]}),
          isNull,
          reason: extra,
        );
      }
      expect(ProfilePhotoRef.fromWire({'r': 5, 'x': 1}), isNotNull);
    });
  });

  group('supersedes: the highest counter wins, a tie keeps what is held', () {
    test('anything supersedes nothing', () {
      expect(made(1).supersedes(null), isTrue);
      expect(const ProfilePhotoRef.cleared(1).supersedes(null), isTrue);
    });

    test('only a strictly higher counter replaces', () {
      expect(made(6).supersedes(made(5)), isTrue);
      expect(made(5).supersedes(made(5)), isFalse);
      expect(made(4).supersedes(made(5)), isFalse);
    });

    test('a clear and a photo settle by counter alone, never by kind', () {
      const cleared5 = ProfilePhotoRef.cleared(5);
      expect(const ProfilePhotoRef.cleared(6).supersedes(made(5)), isTrue);
      expect(made(6).supersedes(cleared5), isTrue);
      expect(cleared5.supersedes(made(5)), isFalse);
      expect(made(5).supersedes(cleared5), isFalse);
      expect(
        const ProfilePhotoRef.cleared(4).supersedes(made(5)),
        isFalse,
        reason: 'a late older clear never removes a newer photo',
      );
      expect(made(4).supersedes(cleared5), isFalse);
    });

    test('the local upload time is not part of the order', () {
      expect(
        made(5, at: DateTime.utc(2030)).supersedes(made(5, at: DateTime.utc(2020))),
        isFalse,
      );
    });
  });

  test('copyWith moves the counter or the time and keeps the file', () {
    final at = DateTime.utc(2026, 11, 2);
    final moved = made(5).copyWith(rev: 9, uploadedAt: at);
    expect(moved.rev, 9);
    expect(moved.uploadedAt, at);
    expect(moved.mediaId, mediaId);
    expect(moved.key, key);
    expect(moved.iv, iv);
    expect(const ProfilePhotoRef.cleared(3).copyWith(rev: 4).isCleared, isTrue);
  });
}
