import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/utils/e2e_envelope.dart';

void main() {
  group('E2eEnvelope', () {
    test('build includes mediaKey and mediaIv when provided', () {
      final map = E2eEnvelope.build(
        'hello',
        mediaKey: 'key123',
        mediaIv: 'iv456',
      );
      expect(map['mediaKey'], 'key123');
      expect(map['mediaIv'], 'iv456');
    });

    test('build omits mediaKey/mediaIv when null', () {
      final map = E2eEnvelope.build('hello');
      expect(map.containsKey('mediaKey'), isFalse);
      expect(map.containsKey('mediaIv'), isFalse);
    });

    test('parse returns mediaKey and mediaIv from JSON', () {
      final json = jsonEncode({
        'content': 'hi',
        'mediaKey': 'k',
        'mediaIv': 'iv',
      });
      final result = E2eEnvelope.parse(json);
      expect(result.mediaKey, 'k');
      expect(result.mediaIv, 'iv');
    });

    test('parse returns null mediaKey for legacy envelope', () {
      final json = jsonEncode({
        'content': 'legacy',
        'mediaUrl': 'https://res.cloudinary.com/demo/image/upload/x.jpg',
      });
      final result = E2eEnvelope.parse(json);
      expect(result.mediaKey, isNull);
      expect(result.mediaIv, isNull);
    });

    test(
      'media dimensions and ThumbHash survive a build -> parse round trip',
      () {
        final built = E2eEnvelope.build(
          '',
          messageType: 'IMAGE',
          mediaUrl: 'http://localhost:3000/media/msgs/image.bin',
          mediaKey: 'key',
          mediaIv: 'iv',
          mediaWidth: 3024,
          mediaHeight: 4032,
          mediaThumbHash: 'thumbhash-base64',
        );

        final result = E2eEnvelope.parse(jsonEncode(built));

        expect(result.mediaWidth, 3024);
        expect(result.mediaHeight, 4032);
        expect(result.mediaThumbHash, 'thumbhash-base64');
      },
    );

    test(
      'parse drops media geometry and ThumbHash when dimensions are unsafe',
      () {
        final cases = <({String name, Map<String, Object?> fields})>[
          (name: 'missing', fields: {}),
          (
            name: 'half-present',
            fields: {'mediaWidth': 640, 'mediaThumbHash': 'hash'},
          ),
          (
            name: 'wrong-type',
            fields: {
              'mediaWidth': '640',
              'mediaHeight': 480,
              'mediaThumbHash': 'hash',
            },
          ),
          (
            name: 'out-of-range',
            fields: {
              'mediaWidth': 32769,
              'mediaHeight': 480,
              'mediaThumbHash': 'hash',
            },
          ),
          (
            name: 'invalid',
            fields: {
              'mediaWidth': 0,
              'mediaHeight': -1,
              'mediaThumbHash': 'hash',
            },
          ),
        ];

        for (final c in cases) {
          final result = E2eEnvelope.parse(
            jsonEncode({'content': '', 'messageType': 'IMAGE', ...c.fields}),
          );

          expect(result.mediaWidth, isNull, reason: c.name);
          expect(result.mediaHeight, isNull, reason: c.name);
          expect(result.mediaThumbHash, isNull, reason: c.name);
        }
      },
    );

    test('parse drops invalid ThumbHash while keeping valid dimensions', () {
      final emptyHash = E2eEnvelope.parse(
        jsonEncode({
          'content': '',
          'messageType': 'IMAGE',
          'mediaWidth': 640,
          'mediaHeight': 480,
          'mediaThumbHash': '',
        }),
      );
      expect(emptyHash.mediaWidth, 640);
      expect(emptyHash.mediaHeight, 480);
      expect(emptyHash.mediaThumbHash, isNull);

      final wrongTypeHash = E2eEnvelope.parse(
        jsonEncode({
          'content': '',
          'messageType': 'IMAGE',
          'mediaWidth': 640,
          'mediaHeight': 480,
          'mediaThumbHash': 42,
        }),
      );
      expect(wrongTypeHash.mediaWidth, 640);
      expect(wrongTypeHash.mediaHeight, 480);
      expect(wrongTypeHash.mediaThumbHash, isNull);
    });

    test('build omits messageType for TEXT and includes it otherwise', () {
      final text = E2eEnvelope.build('hi');
      expect(
        text.containsKey('messageType'),
        isFalse,
        reason: 'TEXT is the wire default and must be elided',
      );

      final voice = E2eEnvelope.build('', messageType: 'VOICE');
      expect(voice['messageType'], 'VOICE');
    });

    test('parse defaults messageType to TEXT when absent', () {
      final result = E2eEnvelope.parse(jsonEncode({'content': 'hi'}));
      expect(result.messageType, 'TEXT');
    });

    test('parse rounds a fractional num mediaDuration', () {
      final result = E2eEnvelope.parse(
        jsonEncode({
          'content': '',
          'messageType': 'VOICE',
          'mediaDuration': 7.6,
        }),
      );
      expect(result.mediaDuration, 8);
    });

    test('linkPreview fields survive a build -> parse round trip', () {
      final built = E2eEnvelope.build(
        'check this out https://example.com',
        linkPreview: {
          'url': 'https://example.com',
          'title': 'Example',
          'imageUrl': 'https://example.com/og.png',
        },
      );
      final result = E2eEnvelope.parse(jsonEncode(built));
      expect(result.linkPreviewUrl, 'https://example.com');
      expect(result.linkPreviewTitle, 'Example');
      expect(result.linkPreviewImageUrl, 'https://example.com/og.png');
    });

    test('parse leaves linkPreview fields null when envelope has none', () {
      final result = E2eEnvelope.parse(jsonEncode({'content': 'hi'}));
      expect(result.linkPreviewUrl, isNull);
      expect(result.linkPreviewTitle, isNull);
      expect(result.linkPreviewImageUrl, isNull);
    });

    group('msgId (metadata-privacy PR2.1 wire id)', () {
      test('survives a build -> parse round trip', () {
        final built = E2eEnvelope.build(
          'hi',
          msgId: 'temp_1758700000000_7-m3x9k2a1',
        );
        final result = E2eEnvelope.parse(jsonEncode(built));
        expect(result.msgId, 'temp_1758700000000_7-m3x9k2a1');
      });

      test('is absent from an envelope built without one', () {
        expect(E2eEnvelope.build('hi'), isNot(contains('msgId')));
        expect(E2eEnvelope.parse(jsonEncode({'content': 'hi'})).msgId, isNull);
      });

      // The value comes from a PEER and lands on this device's disk as a
      // record stamp; anything outside the sender's own minting shape (the
      // server's sendToken bound, 8..64 of [A-Za-z0-9_-]) is refused.
      test('parses to null when the peer sent a malformed one', () {
        final malformed = <Object?>[
          42,
          'short',
          'x' * 65,
          'has space in it',
          'semi;colon-token',
          <String, Object?>{'nested': true},
        ];
        for (final value in malformed) {
          final result = E2eEnvelope.parse(
            jsonEncode({'content': 'hi', 'msgId': value}),
          );
          expect(result.msgId, isNull, reason: 'msgId $value');
          expect(result.content, 'hi', reason: 'the message still arrives');
        }
      });

      test('accepts both ends of the length bound', () {
        for (final value in ['a' * 8, 'Z' * 64]) {
          final result = E2eEnvelope.parse(
            jsonEncode({'content': 'hi', 'msgId': value}),
          );
          expect(result.msgId, value);
        }
      });
    });

    group('t / ts (metadata-privacy PR3.1 box envelope, decision 13)', () {
      test('an envelope without t is a chat message — every old-path one', () {
        expect(E2eEnvelope.parse(jsonEncode({'content': 'hi'})).type, 'msg');
        expect(E2eEnvelope.build('hi'), isNot(contains('t')));
      });

      test('t and ts survive a build -> parse round trip', () {
        final sentAt = DateTime.utc(2026, 9, 24, 12, 30, 5, 123);
        final built = E2eEnvelope.build('hi', type: 'goodbye', sentAt: sentAt);
        expect(built['t'], 'goodbye');
        expect(built['ts'], sentAt.millisecondsSinceEpoch);
        final parsed = E2eEnvelope.parse(jsonEncode(built));
        expect(parsed.type, 'goodbye');
        expect(parsed.sentAt, sentAt);
        expect(parsed.sentAt!.isUtc, isTrue);
      });

      test('a t that is not a string matches no type, never a message', () {
        for (final value in <Object>[1, true, <String>[], <String, Object>{}]) {
          final parsed = E2eEnvelope.parse(
            jsonEncode({'content': 'hi', 't': value}),
          );
          expect(parsed.type, isNot('msg'), reason: '$value');
        }
      });

      test('a ts that is not a positive whole ms is absent, never a date', () {
        for (final value in <Object>[0, -1, 1.5, '1758700000000', 1 << 53]) {
          final parsed = E2eEnvelope.parse(
            jsonEncode({'content': 'hi', 'ts': value}),
          );
          expect(parsed.sentAt, isNull, reason: '$value');
        }
        expect(E2eEnvelope.parse(jsonEncode({'content': 'hi'})).sentAt, isNull);
      });
    });

    group('queue_handoff / queue_handoff_ack (sibling self-queues)', () {
      // Canonical unpadded base64url of 32 bytes: 42 free chars, then one of
      // the 16 whose low two bits are zero.
      final sid = '${'A' * 42}E';
      final sealPub = '${'b' * 42}w';

      test('a handoff round-trips its address under its own type', () {
        final json = jsonEncode(
          E2eEnvelope.buildQueueHandoff(sid: sid, sealPub: sealPub),
        );
        expect(E2eEnvelope.parse(json).type, E2eEnvelope.typeQueueHandoff);
        expect(E2eEnvelope.parseQueueHandoff(json), (sid: sid, sealPub: sealPub));
      });

      test('an ack round-trips the sid it acknowledges', () {
        final json = jsonEncode(E2eEnvelope.buildQueueHandoffAck(sid: sid));
        expect(E2eEnvelope.parse(json).type, E2eEnvelope.typeQueueHandoffAck);
        expect(E2eEnvelope.parseQueueHandoffAck(json), sid);
      });

      test('neither is ever read as a chat message', () {
        for (final built in [
          E2eEnvelope.buildQueueHandoff(sid: sid, sealPub: sealPub),
          E2eEnvelope.buildQueueHandoffAck(sid: sid),
        ]) {
          expect(
            E2eEnvelope.parse(jsonEncode(built)).type,
            isNot(E2eEnvelope.typeMessage),
          );
        }
      });

      test('an address that is not a canonical 32-byte id is null — never '
          'stored, never sent to', () {
        for (final bad in [
          'short',
          '${'A' * 42}B', // spare bits set: not the canonical spelling
          '${'A' * 43}=',
          'A' * 44,
          42,
          null,
        ]) {
          expect(
            E2eEnvelope.parseQueueHandoff(
              jsonEncode({'t': 'queue_handoff', 'sid': bad, 'sealPub': sealPub}),
            ),
            isNull,
          );
          expect(
            E2eEnvelope.parseQueueHandoff(
              jsonEncode({'t': 'queue_handoff', 'sid': sid, 'sealPub': bad}),
            ),
            isNull,
          );
          expect(
            E2eEnvelope.parseQueueHandoffAck(
              jsonEncode({'t': 'queue_handoff_ack', 'sid': bad}),
            ),
            isNull,
          );
        }
      });

      test('the other type, or no JSON object at all, is null', () {
        final handoff = jsonEncode(
          E2eEnvelope.buildQueueHandoff(sid: sid, sealPub: sealPub),
        );
        final ack = jsonEncode(E2eEnvelope.buildQueueHandoffAck(sid: sid));
        expect(E2eEnvelope.parseQueueHandoff(ack), isNull);
        expect(E2eEnvelope.parseQueueHandoffAck(handoff), isNull);
        expect(E2eEnvelope.parseQueueHandoff('[1]'), isNull);
        expect(E2eEnvelope.parseQueueHandoffAck('not json'), isNull);
      });
    });

    group('first contact p / timer (slice (f), decision 55, E15k)', () {
      final sid = '${'A' * 42}E';
      final sealPub = '${'b' * 42}w';

      /// A request as an OLDER build wrote it: this build never writes the
      /// legacy `a`, so it is put in by hand.
      String requestWith(String? avatar) {
        final built = E2eEnvelope.buildFriendRequest(
          sid: sid,
          sealPub: sealPub,
          profile: (
            username: 'ann',
            tag: '1412',
            avatarUrl: null,
            avatar: null,
          ),
        );
        if (avatar != null) (built['p'] as Map<String, dynamic>)['a'] = avatar;
        return jsonEncode(built);
      }

      test('a photo is kept as the path of a file on our avatar route, '
          'whatever host it names', () {
        for (final (sent, kept) in [
          ('https://fireplace.example/media/avatars/a1b2.jpg', '/media/avatars/a1b2.jpg'),
          ('http://127.0.0.1:3000/media/avatars/x_y-z.png', '/media/avatars/x_y-z.png'),
          ('https://evil.example/media/avatars/a.jpg?t=1', '/media/avatars/a.jpg'),
          ('/media/avatars/a.jpg', '/media/avatars/a.jpg'),
        ]) {
          expect(
            E2eEnvelope.parseFriendRequest(requestWith(sent))?.profile,
            (username: 'ann', tag: '1412', avatarUrl: kept, avatar: null),
            reason: sent,
          );
        }
      });

      test('a photo anywhere else is dropped, the name kept', () {
        for (final sent in [
          'https://evil.example/track.png',
          '/media/msgs/a.bin',
          '/media/avatars/../msgs/a.bin',
          '/avatars/a.jpg',
        ]) {
          expect(
            E2eEnvelope.parseFriendRequest(requestWith(sent))?.profile,
            (username: 'ann', tag: '1412', avatarUrl: null, avatar: null),
            reason: sent,
          );
        }
      });

      test('a timer round-trips its setting and time; off is null; a ttl '
          'outside the sheet is refused', () {
        final at = DateTime.utc(2026, 9, 27, 12);
        expect(
          E2eEnvelope.parseTimer(
            jsonEncode(E2eEnvelope.buildTimer(ttl: 3600, sentAt: at)),
          ),
          (ttl: 3600, sentAt: at),
        );
        expect(
          E2eEnvelope.parseTimer(
            jsonEncode(E2eEnvelope.buildTimer(ttl: null, sentAt: at)),
          ),
          (ttl: null, sentAt: at),
        );
        expect(
          E2eEnvelope.parseTimer(
            jsonEncode({'t': 'timer', 'ttl': 1, 'ts': at.millisecondsSinceEpoch}),
          ),
          isNull,
        );
        expect(
          E2eEnvelope.parseTimer(jsonEncode({'t': 'timer', 'ts': 5})),
          isNull,
          reason: 'no ttl key at all is not "off"',
        );
      });
    });

    group('profile photo reference (decision 138)', () {
      final sid = '${'A' * 42}E';
      final sealPub = '${'b' * 42}w';
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

      Map<String, dynamic> wire(int rev) => {
        'm': mediaId,
        'k': key,
        'i': iv,
        'r': rev,
      };

      /// An envelope with `p` as the test spells it, hand-made so a hostile
      /// or legacy shape this build never writes can be fed in.
      String requestWithP(Map<String, dynamic> p) => jsonEncode({
        't': 'friend_request',
        'sid': sid,
        'sealPub': sealPub,
        'p': p,
      });

      group('the quiet profile envelope', () {
        test('a photo round-trips with the time its file was made', () {
          final at = DateTime.utc(2026, 11, 8, 9, 30);
          final built = E2eEnvelope.buildProfile(photo(7, at: at));
          expect(built, {
            't': 'profile',
            'av': wire(7),
            'ts': at.millisecondsSinceEpoch,
          });

          final parsed = E2eEnvelope.parseProfile(jsonEncode(built));
          expect(parsed, isNotNull);
          expect(parsed!.avatar.toWire(), wire(7));
          expect(parsed.avatar.hasPhoto, isTrue);
          expect(parsed.madeAt, at);
          expect(parsed.madeAt!.isUtc, isTrue);
        });

        test('the cleared state round-trips', () {
          final built = E2eEnvelope.buildProfile(const ProfilePhotoRef.cleared(8));
          expect(built, {
            't': 'profile',
            'av': {'r': 8, 'x': 1},
          });
          final parsed = E2eEnvelope.parseProfile(jsonEncode(built));
          expect(parsed!.avatar.isCleared, isTrue);
          expect(parsed.avatar.rev, 8);
          expect(parsed.madeAt, isNull);
        });

        test('no time is written when none is known, and none is read', () {
          final built = E2eEnvelope.buildProfile(photo(7));
          expect(built.containsKey('ts'), isFalse);
          expect(E2eEnvelope.parseProfile(jsonEncode(built))!.madeAt, isNull);
        });

        test('the device-local upload time is `ts`, never an `at` key', () {
          final sent = jsonEncode(
            E2eEnvelope.buildProfile(
              photo(7, at: DateTime.utc(2026, 11, 8)),
            ),
          );
          expect(sent, isNot(contains('"at"')));
          expect(
            (jsonDecode(sent) as Map<String, dynamic>)['av'],
            wire(7),
            reason: 'only the wire shape of the reference travels',
          );
        });

        test('it is a type of its own, never read as a chat message', () {
          final parsed = E2eEnvelope.parse(
            jsonEncode(E2eEnvelope.buildProfile(photo(7))),
          );
          expect(parsed.type, E2eEnvelope.typeProfile);
          expect(parsed.type, isNot(E2eEnvelope.typeMessage));
        });

        test('a `ts` that is no sound time keeps the photo, drops only the '
            'time', () {
          for (final ts in [
            0,
            -1,
            8640000000000001,
            1.5,
            '1790000000000',
            null,
            true,
          ]) {
            final parsed = E2eEnvelope.parseProfile(
              jsonEncode({'t': 'profile', 'av': wire(7), 'ts': ts}),
            );
            expect(parsed, isNotNull, reason: '$ts');
            expect(parsed!.avatar.rev, 7, reason: '$ts');
            expect(parsed.madeAt, isNull, reason: '$ts');
          }
        });

        test('any other type is null, whatever it carries', () {
          for (final type in ['timer', 'message', 'friend_request', '', null]) {
            expect(
              E2eEnvelope.parseProfile(
                jsonEncode({if (type != null) 't': type, 'av': wire(7)}),
              ),
              isNull,
              reason: '$type',
            );
          }
          expect(
            E2eEnvelope.parseProfile(jsonEncode({'content': 'hi', 'av': wire(7)})),
            isNull,
          );
        });

        test('a reference not spelled exactly is null — the frame carries '
            'no photo, never half of one', () {
          for (final av in <Object?>[
            null,
            'x',
            5,
            <Object?>[],
            <String, dynamic>{},
            {...wire(7), 'r': 0},
            {...wire(7), 'r': 1.0},
            {...wire(7), 'r': '7'},
            {...wire(7), 'm': 'short'},
            {...wire(7), 'm': '${mediaId.substring(0, 42)}B'},
            {...wire(7), 'k': base64Url.encode(List.filled(32, 0xfb))},
            {...wire(7), 'i': base64.encode(List.filled(16, 9))},
            {...wire(7), 'x': 1},
            {'r': 7, 'x': 2},
            {'r': 7, 'x': 1, 'm': mediaId},
          ]) {
            expect(
              E2eEnvelope.parseProfile(
                jsonEncode({'t': 'profile', 'av': av, 'ts': 1790000000000}),
              ),
              isNull,
              reason: '$av',
            );
          }
          expect(E2eEnvelope.parseProfile(jsonEncode({'t': 'profile'})), isNull);
        });

        test('bytes that are no JSON object are null', () {
          for (final raw in ['not json', '[]', '5', '"profile"', 'null', '']) {
            expect(E2eEnvelope.parseProfile(raw), isNull, reason: raw);
          }
        });
      });

      group('the profile `p` of a first contact', () {
        test('a request carries the reference as `av` and reads it back', () {
          final built = E2eEnvelope.buildFriendRequest(
            sid: sid,
            sealPub: sealPub,
            profile: (
              username: 'ann',
              tag: '1412',
              avatarUrl: null,
              avatar: photo(7, at: DateTime.utc(2026, 11, 8)),
            ),
          );
          expect(built['p'], {'u': 'ann', 'g': '1412', 'av': wire(7)});

          final profile = E2eEnvelope.parseFriendRequest(
            jsonEncode(built),
          )?.profile;
          expect(profile?.username, 'ann');
          expect(profile?.tag, '1412');
          expect(profile?.avatarUrl, isNull);
          expect(profile?.avatar?.toWire(), wire(7));
          expect(profile?.avatar?.uploadedAt, isNull);
        });

        test('an accept carries it in its handoff too', () {
          final built = E2eEnvelope.buildQueueHandoff(
            sid: sid,
            sealPub: sealPub,
            profile: (
              username: 'bob',
              tag: '0002',
              avatarUrl: null,
              avatar: const ProfilePhotoRef.cleared(9),
            ),
          );
          expect(built['p'], {
            'u': 'bob',
            'g': '0002',
            'av': {'r': 9, 'x': 1},
          });
          final profile = E2eEnvelope.profileOf(jsonEncode(built));
          expect(profile?.avatar?.isCleared, isTrue);
          expect(profile?.avatar?.rev, 9);
          expect(profile?.username, 'bob');
        });

        test('the legacy `a` is never written, whatever the profile holds', () {
          final built = E2eEnvelope.buildFriendRequest(
            sid: sid,
            sealPub: sealPub,
            profile: (
              username: 'ann',
              tag: '1412',
              avatarUrl: '/media/avatars/a1b2.jpg',
              avatar: photo(7),
            ),
          );
          final p = built['p'] as Map<String, dynamic>;
          expect(p.containsKey('a'), isFalse);
          expect(p['av'], wire(7));
          expect(jsonEncode(built), isNot(contains('avatars')));

          final onlyLegacy = E2eEnvelope.buildQueueHandoff(
            sid: sid,
            sealPub: sealPub,
            profile: (
              username: 'ann',
              tag: '1412',
              avatarUrl: '/media/avatars/a1b2.jpg',
              avatar: null,
            ),
          );
          expect(onlyLegacy['p'], {'u': 'ann', 'g': '1412'});
        });

        test('no photo at all writes no photo key', () {
          final built = E2eEnvelope.buildFriendRequest(
            sid: sid,
            sealPub: sealPub,
            profile: (
              username: 'ann',
              tag: '1412',
              avatarUrl: null,
              avatar: null,
            ),
          );
          expect(built['p'], {'u': 'ann', 'g': '1412'});
        });

        test('an older build\'s `a` is still read, into the legacy path', () {
          final profile = E2eEnvelope.parseFriendRequest(
            requestWithP({
              'u': 'ann',
              'g': '1412',
              'a': 'https://fireplace.example/media/avatars/a1b2.jpg',
            }),
          )?.profile;
          expect(profile?.avatarUrl, '/media/avatars/a1b2.jpg');
          expect(profile?.avatar, isNull);
        });

        test('both may arrive: each is read on its own', () {
          final profile = E2eEnvelope.profileOf(
            requestWithP({
              'u': 'ann',
              'g': '1412',
              'a': '/media/avatars/a1b2.jpg',
              'av': wire(7),
            }),
          );
          expect(profile?.avatarUrl, '/media/avatars/a1b2.jpg');
          expect(profile?.avatar?.toWire(), wire(7));
        });

        test('a malformed `av` is no photo, the name and tag are kept', () {
          for (final av in <Object?>[
            'x',
            7,
            <Object?>[],
            {...wire(7), 'r': -3},
            {...wire(7), 'k': 'short'},
            {...wire(7), 'm': 5},
            {...wire(7), 'x': 1},
            {'r': 7, 'x': 1, 'k': key},
          ]) {
            final profile = E2eEnvelope.parseFriendRequest(
              requestWithP({'u': 'ann', 'g': '1412', 'av': av}),
            )?.profile;
            expect(profile, isNotNull, reason: '$av');
            expect(profile!.username, 'ann', reason: '$av');
            expect(profile.tag, '1412', reason: '$av');
            expect(profile.avatar, isNull, reason: '$av');
          }
        });

        test('a malformed `av` does not cost the legacy path beside it', () {
          final profile = E2eEnvelope.profileOf(
            requestWithP({
              'u': 'ann',
              'g': '1412',
              'a': '/media/avatars/a1b2.jpg',
              'av': {...wire(7), 'r': 0},
            }),
          );
          expect(profile?.avatar, isNull);
          expect(profile?.avatarUrl, '/media/avatars/a1b2.jpg');
        });

        test('a cleared `av` is a photo removed, read as such', () {
          final profile = E2eEnvelope.profileOf(
            requestWithP({
              'u': 'ann',
              'g': '1412',
              'av': {'r': 7, 'x': 1},
            }),
          );
          expect(profile?.avatar?.isCleared, isTrue);
          expect(profile?.avatar?.rev, 7);
          expect(profile?.avatarUrl, isNull);
        });
      });
    });

    group('ttl / re / boxMedia (item 3, E17a/E18a/E18b)', () {
      final boxMedia = '${'A' * 42}E';
      const quote = (
        wireId: 'temp_1758700000000_2-m3x9k2a1',
        senderId: 2,
        type: 'IMAGE',
        snippet: 'look at this',
      );

      test('all three survive a build -> parse round trip', () {
        final built = E2eEnvelope.build(
          'hi',
          ttl: 60,
          replyQuote: quote,
          boxMedia: boxMedia,
        );
        expect(built['ttl'], 60);
        expect(built['re'], {
          'w': quote.wireId,
          's': 2,
          'k': 'IMAGE',
          'x': 'look at this',
        });
        expect(built['boxMedia'], boxMedia);
        final parsed = E2eEnvelope.parse(jsonEncode(built));
        expect(parsed.ttl, 60);
        expect(parsed.replyQuote, quote);
        expect(parsed.boxMedia, boxMedia);
      });

      test('none is written when not given, and none parses from an old '
          'envelope', () {
        final built = E2eEnvelope.build('hi');
        expect(built.keys, isNot(anyOf(contains('ttl'), contains('re'))));
        expect(built, isNot(contains('boxMedia')));
        final parsed = E2eEnvelope.parse(jsonEncode({'content': 'hi'}));
        expect(parsed.ttl, isNull);
        expect(parsed.replyQuote, isNull);
        expect(parsed.boxMedia, isNull);
      });

      test('a ttl outside the timer sheet range (5 s..30 d) is no timer, '
          'never a message dropped', () {
        for (final value in <Object>[0, 4, 2592001, -60, 60.5, '60', true]) {
          final parsed = E2eEnvelope.parse(
            jsonEncode({'content': 'hi', 'ttl': value}),
          );
          expect(parsed.ttl, isNull, reason: '$value');
          expect(parsed.content, 'hi', reason: '$value');
        }
        for (final value in [5, 2592000]) {
          expect(
            E2eEnvelope.parse(jsonEncode({'content': 'hi', 'ttl': value})).ttl,
            value,
          );
        }
        expect(E2eEnvelope.build('hi', ttl: 4), isNot(contains('ttl')));
      });

      test('an invalid re is dropped whole — never the message; a bad wire '
          'id is dropped alone', () {
        final valid = {'w': quote.wireId, 's': 2, 'k': 'TEXT', 'x': 'hey'};
        for (final bad in <Object?>[
          'not an object',
          [1],
          {...valid, 's': 0},
          {...valid, 's': 0x80000000},
          {...valid, 's': '2'},
          {...valid}..remove('s'),
          {...valid, 'k': 7},
          {...valid}..remove('k'),
          {...valid, 'x': 9},
          {...valid}..remove('x'),
          {...valid, 'x': 'a' * 257},
          {...valid, 'x': '界' * 86},
        ]) {
          final parsed = E2eEnvelope.parse(
            jsonEncode({'content': 'hi', 're': bad}),
          );
          expect(parsed.replyQuote, isNull, reason: '$bad');
          expect(parsed.content, 'hi', reason: '$bad');
        }
        for (final w in <Object?>['short', 'x' * 65, 'has space', 42]) {
          final parsed = E2eEnvelope.parse(
            jsonEncode({'content': 'hi', 're': {...valid, 'w': w}}),
          );
          expect(
            parsed.replyQuote,
            (wireId: null, senderId: 2, type: 'TEXT', snippet: 'hey'),
            reason: '$w',
          );
        }
        expect(
          E2eEnvelope.parse(
            jsonEncode({'content': 'hi', 're': {...valid, 'x': '界' * 85}}),
          ).replyQuote?.snippet,
          '界' * 85,
          reason: '255 bytes is within the bound',
        );
      });

      test('build cuts the snippet to 256 UTF-8 bytes at a character '
          'boundary, so what it writes always parses', () {
        for (final (text, kept) in [
          ('a' * 300, 'a' * 256),
          ('界' * 100, '界' * 85),
          ('${'a' * 254}😀z', 'a' * 254),
          ('${'a' * 252}😀z', '${'a' * 252}😀'),
        ]) {
          final built = E2eEnvelope.build(
            'hi',
            replyQuote: (wireId: null, senderId: 2, type: 'TEXT', snippet: text),
          );
          final re = built['re'] as Map<String, dynamic>;
          expect(re['x'], kept);
          expect(re, isNot(contains('w')), reason: 'no wire id, no w');
          expect(
            E2eEnvelope.parse(jsonEncode(built)).replyQuote?.snippet,
            kept,
          );
        }
      });

      test('a boxMedia not spelled as a canonical 32-byte id is absent', () {
        for (final bad in <Object?>[
          'short',
          '${'A' * 42}B',
          '${'A' * 43}=',
          'A' * 44,
          42,
        ]) {
          final parsed = E2eEnvelope.parse(
            jsonEncode({'content': 'hi', 'boxMedia': bad}),
          );
          expect(parsed.boxMedia, isNull, reason: '$bad');
          expect(parsed.content, 'hi');
        }
        expect(
          E2eEnvelope.build('hi', boxMedia: 'short'),
          isNot(contains('boxMedia')),
        );
      });
    });
  });
}
