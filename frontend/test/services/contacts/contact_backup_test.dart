import 'dart:convert';

import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/services/contacts/contact_backup.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/passcode_fakes.dart';

ContactBackupCodec _codec([FakePasscodeKdf? kdf]) =>
    ContactBackupCodec(kdf: kdf ?? FakePasscodeKdf(), sealer: FakeContentSealer());

ContactRecord _record(int id) => ContactRecord(
  userId: id,
  username: 'peer$id',
  tag: '0001',
  state: ContactState.friend,
  devices: const [1, 2],
  outbound: const [
    ContactOutbound(peerDeviceId: 2, sid: 'SID', sealPub: 'PUB'),
  ],
  settings: const ContactSettings(disappearingTimer: 60, muted: true),
  queues: const [
    ContactQueue(
      rid: 'RID',
      sid: 'MYSID',
      authPriv: 'AUTHPRIV',
      sealPriv: 'SEALPRIV',
      sealPub: 'SEALPUB',
    ),
  ],
  legacy: const ContactLegacy(conversationId: 900, requestId: 11),
);

void main() {
  group('ContactBackupCodec', () {
    test('a sealed payload round-trips every field a peer is addressed by',
        () async {
      final codec = _codec();
      final (ck, _) = ContactBackupCodec.mintContentKey();
      final payload = ContactBackupPayload(
        userId: 7,
        self: UserModel(id: 7, username: 'me', tag: '0007'),
        contacts: [_record(42)],
      );

      final opened = await codec.openPayload(
        ck,
        await codec.sealPayload(ck, payload),
      );

      expect(opened.userId, 7);
      expect(opened.self?.username, 'me');
      final peer = opened.contacts.single;
      expect(peer.userId, 42);
      expect(peer.username, 'peer42');
      expect(peer.state, ContactState.friend);
      expect(peer.devices, [1, 2]);
      expect(peer.outbound.single.sid, 'SID');
      expect(peer.settings.disappearingTimer, 60);
      expect(peer.settings.muted, isTrue);
    });

    test('the blob carries NO queue private keys and no server-side ids',
        () async {
      final codec = _codec();
      final (ck, _) = ContactBackupCodec.mintContentKey();
      final payload = ContactBackupPayload(
        userId: 7,
        self: null,
        contacts: [_record(42)],
      );

      // Read the plaintext the codec produced, not the model: the promise is
      // about the BYTES the server is handed. Strip the fake sealer's 4-byte
      // key prefix, then the codec's own `uint32be(length)` pad frame.
      final blob = await codec.sealPayload(ck, payload);
      final framed = base64Decode(blob).sublist(4);
      final length = (framed[0] << 24) |
          (framed[1] << 16) |
          (framed[2] << 8) |
          framed[3];
      final plain = utf8.decode(framed.sublist(4, 4 + length));

      expect(plain, isNot(contains('AUTHPRIV')));
      expect(plain, isNot(contains('SEALPRIV')));
      expect(plain, isNot(contains('MYSID')));
      expect(plain, isNot(contains('conversationId')));
      expect(plain, isNot(contains('requestId')));
      // …while everything a restored device needs IS there.
      expect(plain, contains('peer42'));
      expect(plain, contains('SID'));

      final opened = await codec.openPayload(ck, blob);
      expect(opened.contacts.single.queues, isEmpty);
      expect(opened.contacts.single.legacy.conversationId, isNull);
    });

    test('the blob length is bucketed, so it is not a contact counter',
        () async {
      final codec = _codec();
      final (ck, _) = ContactBackupCodec.mintContentKey();
      Future<int> sealedLength(int peers) async => base64Decode(
        await codec.sealPayload(
          ck,
          ContactBackupPayload(
            userId: 7,
            self: null,
            contacts: [for (var i = 0; i < peers; i++) _record(100 + i)],
          ),
        ),
      ).length;

      // AES-GCM is length-preserving, so an unpadded blob's size divides
      // straight into a contact count for anyone holding a database dump.
      // One contact and ten must be indistinguishable by length.
      expect(await sealedLength(1), await sealedLength(10));
      // And every bucket is a whole number of blocks (+ the fake sealer's
      // 4-byte prefix), never the payload's natural size.
      expect((await sealedLength(1) - 4) % kContactBackupPadBlock, 0);
      // A graph big enough to need a second block gets one, not a refusal.
      expect(await sealedLength(200), greaterThan(await sealedLength(1)));
      expect((await sealedLength(200) - 4) % kContactBackupPadBlock, 0);
    });

    test('a wrap opens under its own secret and refuses every other', () async {
      final codec = _codec();
      final (ck, _) = ContactBackupCodec.mintContentKey();
      final salt = ContactBackupCodec.mintSalt();

      final wrap = await codec.wrap(
        kind: ContactWrapKind.password,
        wrapKey: await codec.deriveWrapKey(
          kind: ContactWrapKind.password,
          secret: 'right',
          salt: salt,
        ),
        ck: ck,
      );

      final right = await codec.unwrap(
        wrap,
        await codec.deriveWrapKey(
          kind: ContactWrapKind.password,
          secret: 'right',
          salt: salt,
        ),
      );
      final wrong = await codec.unwrap(
        wrap,
        await codec.deriveWrapKey(
          kind: ContactWrapKind.password,
          secret: 'wrong',
          salt: salt,
        ),
      );

      expect(right, ck);
      expect(wrong, isNull, reason: 'a wrong secret must not open the key');
    });

    test('a phrase wrap is insensitive to spacing and case, like the verifier',
        () async {
      final codec = _codec();
      final (ck, _) = ContactBackupCodec.mintContentKey();
      final salt = ContactBackupCodec.mintSalt();

      final wrap = await codec.wrap(
        kind: ContactWrapKind.phrase,
        wrapKey: await codec.deriveWrapKey(
          kind: ContactWrapKind.phrase,
          secret: 'abandon ability able',
          salt: salt,
        ),
        ck: ck,
      );

      expect(
        await codec.unwrap(
          wrap,
          await codec.deriveWrapKey(
            kind: ContactWrapKind.phrase,
            secret: '  Abandon   ABILITY  able ',
            salt: salt,
          ),
        ),
        ck,
      );
    });

    test('a blob from another feature is CORRUPT, never an empty contact list',
        () async {
      final codec = _codec();
      final (ck, _) = ContactBackupCodec.mintContentKey();
      final foreign = await codec.sealPayload(ck, _foreignDomainPayload());

      expect(
        () => codec.openPayload(ck, foreign),
        throwsA(isA<ContactBackupCorrupt>()),
      );
    });

    test('one unreadable contact entry is skipped, the rest still restore',
        () async {
      final codec = _codec();
      final (ck, _) = ContactBackupCodec.mintContentKey();
      // A row a NEWER build wrote (v: 2) beside one this build can read.
      final raw = {
        'v': kContactBackupVersion,
        'domain': kContactBackupDomain,
        'userId': 7,
        'contacts': [
          {'v': 2, 'userId': 41, 'username': 'future', 'tag': '0001',
            'state': 'friend'},
          _record(42).toBackupJson(),
        ],
      };
      final blob = await codec.sealPayload(ck, _RawPayload(raw));

      final opened = await codec.openPayload(ck, blob);
      expect(opened.contacts.map((c) => c.userId), [42]);
    });

    test('a minted ckId is the 22-char base64url the server accepts', () {
      for (var i = 0; i < 20; i++) {
        final (_, ckId) = ContactBackupCodec.mintContentKey();
        expect(ckId, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      }
    });

    test('a minted salt is 16 bytes, the length the codec insists on', () async {
      final salt = ContactBackupCodec.mintSalt();
      expect(base64Decode(salt).length, 16);
      expect(
        () => _codec().deriveWrapKey(
          kind: ContactWrapKind.password,
          secret: 'x',
          salt: base64Encode(List<int>.filled(8, 0)),
        ),
        throwsA(isA<ContactBackupCorrupt>()),
      );
    });

    test('a row whose wire shape is damaged is CORRUPT, never "no backup"', () {
      expect(
        () => ContactBackupRow.fromJson({'rev': 1, 'salt': 'x'}),
        throwsA(isA<ContactBackupCorrupt>()),
      );
    });
  });
}

ContactBackupPayload _foreignDomainPayload() => _RawPayload({
  'v': kContactBackupVersion,
  'domain': 'fp-history',
  'userId': 7,
  'contacts': const [],
});

/// Lets a test hand the codec a payload shape the public constructor cannot
/// build — the point being what the OPENER does with it.
class _RawPayload implements ContactBackupPayload {
  _RawPayload(this._raw);

  final Map<String, dynamic> _raw;

  @override
  Map<String, dynamic> toJson() => _raw;

  @override
  List<ContactRecord> get contacts => const [];

  @override
  UserModel? get self => null;

  @override
  int get userId => 0;
}
