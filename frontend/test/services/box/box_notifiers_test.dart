import 'dart:async';
import 'dart:typed_data';

import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_notifiers.dart';
import 'package:fireplace/services/box/box_signer.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/box/queue_seal.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/box_fakes.dart';

Uint8List _bytes(int length, int fill) =>
    Uint8List(length)..fillRange(0, length, fill);

ContactQueue _queue(int fill) {
  final auth = const Ed25519BoxSigner().mint();
  final seal = QueueSeal.mintKeyPair();
  return ContactQueue(
    rid: boxB64(_bytes(32, fill)),
    sid: boxB64(_bytes(32, fill + 1)),
    nid: boxB64(_bytes(16, fill + 2)),
    authPriv: boxB64(auth.bytes),
    sealPriv: boxB64(seal.privateKey),
    sealPub: boxB64(seal.publicKey),
  );
}

/// The platform push layer as the registrar sees it.
class _Push implements BoxPushSource {
  BoxPushTarget? current = (
    platform: NotifierPlatform.fcm,
    token: 'fcm-token-1',
  );
  final StreamController<Uint8List> codes = StreamController.broadcast();
  final StreamController<void> changed = StreamController.broadcast();

  @override
  Future<BoxPushTarget?> target() async => current;

  @override
  Stream<void> get targetChanged => changed.stream;

  @override
  Stream<Uint8List> get challengeCodes => codes.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentKv kv;
  late ContactStore store;
  late FakeBoxSockets sockets;
  late BoxClient box;
  late _Push push;
  late BoxNotifiers notifiers;

  /// The box's side: a challenge pushes a fresh code (unless [deliver] is
  /// off); an activation is refused whole unless its code was pushed, and
  /// then refuses only the entries in [gone].
  final issued = <String>{};
  final gone = <String>{};
  var deliver = true;
  var codeFill = 0x90;

  /// Codes pushed BEFORE the real one on the next challenge (a late push
  /// from an earlier challenge).
  final strays = <Uint8List>[];

  /// Answers for the next challenges, used once each (then the default).
  final challengeAnswers = <Map<String, Object?>>[];

  /// Every registerNotifier frame in emit order: `'challenge'`, or the nids
  /// one activation frame carried.
  List<Object> frames() => [
    for (final socket in sockets.sockets)
      for (final f in socket.emitted)
        if (f.event == 'registerNotifier')
          f.frame.containsKey('token')
              ? 'challenge'
              : [
                  for (final q in f.frame['queues']! as List)
                    (q as Map)['nid']! as String,
                ],
  ];

  Future<void> contact(
    int peer,
    List<ContactQueue> queues, {
    ContactState state = ContactState.friend,
  }) => store.update(
    peer,
    (_) => ContactRecord(
      userId: peer,
      username: 'peer$peer',
      tag: '0001',
      state: state,
      queues: queues,
    ),
  );

  BoxNotifiers build({
    Duration codeWait = const Duration(seconds: 5),
    Duration park = const Duration(minutes: 15),
  }) => BoxNotifiers(
    box: box,
    store: store,
    push: push,
    codeWait: codeWait,
    park: park,
  )..start();

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
  }

  String target() => BoxNotifiers.targetId(push.current!);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = await PrefsContentKv.open();
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(1);
    issued.clear();
    gone.clear();
    strays.clear();
    challengeAnswers.clear();
    deliver = true;
    codeFill = 0x90;
    push = _Push();
    sockets = FakeBoxSockets()
      ..respond = (_, f) {
        if (f.event != 'registerNotifier') return {'ok': true, 'refused': []};
        if (f.frame.containsKey('token')) {
          if (challengeAnswers.isNotEmpty) return challengeAnswers.removeAt(0);
          final code = _bytes(16, codeFill++);
          issued.add(boxB64(code));
          final pending = [...strays, if (deliver) code];
          strays.clear();
          scheduleMicrotask(() => pending.forEach(push.codes.add));
          return {'ok': true, 'state': 'challenged'};
        }
        if (!issued.contains(f.frame['code'])) {
          return {'ok': false, 'code': 'auth_failed'};
        }
        return {
          'ok': true,
          'refused': [
            for (final q in f.frame['queues']! as List)
              if (gone.contains((q as Map)['nid']))
                {'nid': q['nid'], 'code': 'auth_failed'},
          ],
        };
      };
    box = BoxClient(baseUrl: 'http://box.test', socketFactory: sockets.call)
      ..connect();
    sockets.last.serverConnect('S1');
    await pumpEventQueue();
  });

  tearDown(() {
    notifiers.dispose();
    box.dispose();
  });

  test(
    'ONE challenge proves the target, then ONE frame activates every contact '
    'queue; never the request queue or a self-queue, current or retiring '
    '(decisions 2, 32, 34)',
    () async {
      final a = _queue(0x10);
      final b = _queue(0x20);
      await contact(42, [a]);
      await contact(43, [b]);
      expect(await store.claimRequestQueue(_queue(0x30)), isNotNull);
      final self = _queue(0x40);
      expect(await store.claimSelfQueue(self), isNotNull);
      final rotated = await store.rotateSelfQueue(
        _queue(0x50),
        replaces: self.rid,
        live: const {},
        now: DateTime.utc(2026, 9, 25),
      );
      expect(rotated, isNotNull, reason: 'a retiring self-queue exists');

      notifiers = build()..run();
      await settle();

      expect(frames(), [
        'challenge',
        [a.nid, b.nid],
      ]);
      expect(store.notifierActive(a.nid, target()), isTrue);
      expect(store.notifierActive(b.nid, target()), isTrue);
    },
  );

  test(
    'a blocked or former contact gets no notifier: a blocked peer holding the '
    'sid could ring an offline device (decision 35)',
    () async {
      final friend = _queue(0x10);
      await contact(42, [friend]);
      await contact(43, [_queue(0x20)], state: ContactState.blocked);
      await contact(44, [_queue(0x30)], state: ContactState.former);

      notifiers = build()..run();
      await settle();

      expect(frames(), [
        'challenge',
        [friend.nid],
      ]);
    },
  );

  test('only blocked or former contacts: no challenge at all', () async {
    await contact(43, [_queue(0x20)], state: ContactState.blocked);
    notifiers = build()..run();
    await settle();
    expect(frames(), isEmpty);
  });

  test(
    'what was activated is not challenged again, across a reopen',
    () async {
      await contact(42, [_queue(0x10)]);
      notifiers = build()..run();
      await settle();
      expect(frames(), hasLength(2));

      notifiers.dispose();
      await store.open(1);
      notifiers = build()..run();
      await settle();
      expect(
        frames(),
        hasLength(2),
        reason:
            'a push per launch would spend '
            'the 30 / 15 min budget and ring the phone',
      );
    },
  );

  test('a new push target re-registers every queue under it', () async {
    final a = _queue(0x10);
    final b = _queue(0x20);
    await contact(42, [a]);
    await contact(43, [b]);
    notifiers = build()..run();
    await settle();
    final before = target();

    push.current = (platform: NotifierPlatform.fcm, token: 'fcm-token-2');
    push.changed.add(null);
    await settle();

    expect(frames().skip(2), [
      'challenge',
      [a.nid, b.nid],
    ]);
    expect(store.notifierActive(a.nid, target()), isTrue);
    expect(store.notifierActive(a.nid, before), isFalse);
  });

  test(
    'more queues than one frame carries: one code activates them all, in '
    'frames of $kBoxNotifierBatchMax',
    () async {
      final queues = [
        for (var i = 0; i <= kBoxNotifierBatchMax; i++) _queue(i % 200),
      ];
      // Distinct nids: the fill pattern repeats, so number them apart.
      final numbered = [
        for (var i = 0; i < queues.length; i++)
          ContactQueue(
            rid: queues[i].rid,
            sid: queues[i].sid,
            nid: boxB64(Uint8List(16)..buffer.asByteData().setUint32(0, i)),
            authPriv: queues[i].authPriv,
            sealPriv: queues[i].sealPriv,
            sealPub: queues[i].sealPub,
          ),
      ];
      await contact(42, numbered);
      notifiers = build()..run();
      await settle();

      final sent = frames();
      expect(sent.first, 'challenge');
      expect(
        [for (final f in sent.skip(1)) (f as List).length],
        [
          kBoxNotifierBatchMax,
          1,
        ],
      );
      expect(
        numbered.every((q) => store.notifierActive(q.nid, target())),
        isTrue,
      );
    },
  );

  test('no push target (no permission, no token): nothing is asked', () async {
    await contact(42, [_queue(0x10)]);
    push.current = null;
    notifiers = build()..run();
    await settle();
    expect(frames(), isEmpty);
  });

  test(
    'a challenge whose code never arrives ends the pass and records nothing; '
    'that target rests (a web page re-runs on every return to the screen), '
    'then is asked again',
    () async {
      final a = _queue(0x10);
      final b = _queue(0x20);
      await contact(42, [a]);
      await contact(43, [b]);
      deliver = false;
      notifiers = build(
        codeWait: const Duration(milliseconds: 30),
        park: const Duration(milliseconds: 1500),
      )..run();
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await settle();

      expect(frames(), ['challenge'], reason: 'push is not reaching this app');
      expect(store.notifierActive(a.nid, target()), isFalse);

      deliver = true;
      notifiers.run();
      await settle();
      expect(frames(), hasLength(1), reason: 'resting');

      await Future<void>.delayed(const Duration(milliseconds: 2500));
      await settle();
      expect(frames().skip(1), [
        'challenge',
        [a.nid, b.nid],
      ]);
    },
  );

  test(
    'a push target the box refuses (invalid_payload) ends the pass and '
    'rests; a new target goes ahead',
    () async {
      final a = _queue(0x10);
      await contact(42, [a]);
      challengeAnswers.add({'ok': false, 'code': 'invalid_payload'});
      notifiers = build()..run();
      await settle();
      expect(frames(), ['challenge']);

      notifiers.run();
      await settle();
      expect(frames(), hasLength(1), reason: 'resting');

      push.current = (platform: NotifierPlatform.fcm, token: 'fcm-token-2');
      push.changed.add(null);
      await settle();
      expect(frames().skip(1), [
        'challenge',
        [a.nid],
      ]);
    },
  );

  test(
    'a stray code from an earlier challenge is refused whole, and the '
    "challenge's own code still activates the batch",
    () async {
      final a = _queue(0x10);
      await contact(42, [a]);
      strays.add(_bytes(16, 0x01));
      notifiers = build()..run();
      await settle();

      expect(frames(), [
        'challenge',
        [a.nid],
        [a.nid],
      ]);
      expect(store.notifierActive(a.nid, target()), isTrue);
    },
  );

  test('rate_limited stops the pass and resumes it after retryAfter', () async {
    final a = _queue(0x10);
    await contact(42, [a]);
    challengeAnswers.add({
      'ok': false,
      'code': 'rate_limited',
      'retryAfterMs': 600,
    });
    notifiers = build()..run();
    await settle();
    expect(frames(), ['challenge']);

    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await settle();
    expect(frames().skip(1), [
      'challenge',
      [a.nid],
    ]);
  });

  test(
    'a queue the box refuses in the batch is not recorded, the others are; '
    'a later pass does not push another challenge for it',
    () async {
      final a = _queue(0x10);
      final b = _queue(0x20);
      await contact(42, [a]);
      await contact(43, [b]);
      gone.add(b.nid);
      notifiers = build()..run();
      await settle();
      expect(store.notifierActive(a.nid, target()), isTrue);
      expect(store.notifierActive(b.nid, target()), isFalse);

      notifiers.run();
      await settle();
      expect(
        frames(),
        hasLength(2),
        reason:
            'the box already said the '
            'queue is gone; another pass would only ring the device',
      );
    },
  );

  test('overlapping triggers run ONE pass', () async {
    final a = _queue(0x10);
    await contact(42, [a]);
    notifiers = build()
      ..run()
      ..run();
    push.changed.add(null);
    await settle();
    expect(frames(), [
      'challenge',
      [a.nid],
    ]);
  });

  test(
    'a target that changes mid-pass gets its own pass right after',
    () async {
      final a = _queue(0x10);
      final b = _queue(0x20);
      await contact(42, [a]);
      await contact(43, [b]);
      final answer = sockets.respond!;
      var rotated = false;
      sockets.respond = (socket, f) {
        final reply = answer(socket, f);
        if (!rotated && f.frame.containsKey('queues')) {
          rotated = true;
          push.current = (platform: NotifierPlatform.fcm, token: 'fcm-token-2');
          push.changed.add(null);
        }
        return reply;
      };
      notifiers = build()..run();
      await settle();

      expect(store.notifierActive(a.nid, target()), isTrue);
      expect(store.notifierActive(b.nid, target()), isTrue);
    },
  );

  test('a store that is closed or a box that is down asks nothing', () async {
    await contact(42, [_queue(0x10)]);
    store.close();
    notifiers = build()..run();
    await settle();
    expect(frames(), isEmpty);

    await store.open(1);
    sockets.last.serverDrop();
    notifiers.run();
    await settle();
    expect(frames(), isEmpty);
  });

  test(
    'a store that closes mid-pass (a vault re-lock) ends the pass',
    () async {
      await contact(42, [_queue(0x10)]);
      final answer = sockets.respond!;
      sockets.respond = (socket, f) {
        final reply = answer(socket, f);
        if (f.event == 'registerNotifier' && f.frame.containsKey('token')) {
          store.close();
        }
        return reply;
      };
      notifiers = build()..run();
      await settle();
      expect(frames(), ['challenge']);
    },
  );

  test(
    "a newer build's notifier row: nothing is asked, since nothing could be "
    'recorded and every run would challenge again',
    () async {
      await contact(42, [_queue(0x10)]);
      await kv.setString(
        ContactStore.notifiersKey(1),
        '{"v":${ContactStore.notifiersVersion + 1}}',
      );
      await store.open(1);
      notifiers = build()..run();
      await settle();
      expect(frames(), isEmpty);
    },
  );
}
