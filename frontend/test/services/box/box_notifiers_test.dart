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

  /// The box's side: step 1 pushes a fresh code for the nid (unless
  /// [deliver] is off), step 2 is `active` only with that nid's live code.
  final issued = <String, String>{};
  var deliver = true;
  var codeFill = 0x90;

  /// Codes pushed BEFORE the real one on the next challenge (a late push
  /// from an earlier challenge).
  final strays = <Uint8List>[];

  /// Answers for step 1, by nid, used once each (then the default).
  final challengeAnswers = <String, Map<String, Object?>>{};

  List<EmittedFrame> registerFrames() => [
    for (final socket in sockets.sockets)
      for (final f in socket.emitted)
        if (f.event == 'registerNotifier') f,
  ];

  /// `(nid, step)` of every registerNotifier frame, in emit order.
  List<(String, int)> steps() => [
    for (final f in registerFrames())
      (f.frame['nid']! as String, f.frame.containsKey('token') ? 1 : 2),
  ];

  Future<void> friend(int peer, ContactQueue queue) => store.update(
    peer,
    (_) => ContactRecord(
      userId: peer,
      username: 'peer$peer',
      tag: '0001',
      state: ContactState.friend,
      queues: [queue],
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
    strays.clear();
    challengeAnswers.clear();
    deliver = true;
    codeFill = 0x90;
    push = _Push();
    sockets = FakeBoxSockets()
      ..respond = (_, f) {
        if (f.event != 'registerNotifier') return {'ok': true, 'refused': []};
        final nid = f.frame['nid']! as String;
        if (f.frame.containsKey('token')) {
          final canned = challengeAnswers.remove(nid);
          if (canned != null) return canned;
          final code = _bytes(16, codeFill++);
          issued[nid] = boxB64(code);
          final pending = [...strays, if (deliver) code];
          strays.clear();
          scheduleMicrotask(() => pending.forEach(push.codes.add));
          return {'ok': true, 'state': 'challenged'};
        }
        return issued[nid] == f.frame['code']
            ? {'ok': true, 'state': 'active'}
            : {'ok': false, 'code': 'auth_failed'};
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
    'activates a notifier on every contact queue, one challenge at a time, '
    'and never on the request queue or the self-queue (decisions 2, 32)',
    () async {
      final a = _queue(0x10);
      final b = _queue(0x20);
      await friend(42, a);
      await friend(43, b);
      expect(await store.claimRequestQueue(_queue(0x30)), isNotNull);
      expect(await store.claimSelfQueue(_queue(0x40)), isNotNull);

      notifiers = build()..run();
      await settle();

      // The code carries no nid: the next challenge waits for the activate.
      expect(steps(), [(a.nid, 1), (a.nid, 2), (b.nid, 1), (b.nid, 2)]);
      final target = BoxNotifiers.targetId(push.current!);
      expect(store.notifierActive(a.nid, target), isTrue);
      expect(store.notifierActive(b.nid, target), isTrue);
    },
  );

  test(
    'what was activated is not challenged again, across a reopen',
    () async {
      final a = _queue(0x10);
      await friend(42, a);
      notifiers = build()..run();
      await settle();
      expect(steps(), hasLength(2));

      notifiers.dispose();
      await store.open(1);
      notifiers = build()..run();
      await settle();
      expect(steps(), hasLength(2), reason: 'a push per launch would spend '
          'the 30 / 15 min budget and ring the phone');
    },
  );

  test('a new push target re-registers every queue under it', () async {
    final a = _queue(0x10);
    final b = _queue(0x20);
    await friend(42, a);
    await friend(43, b);
    notifiers = build()..run();
    await settle();
    final before = BoxNotifiers.targetId(push.current!);

    push.current = (platform: NotifierPlatform.fcm, token: 'fcm-token-2');
    push.changed.add(null);
    await settle();

    expect(steps().skip(4), [(a.nid, 1), (a.nid, 2), (b.nid, 1), (b.nid, 2)]);
    final after = BoxNotifiers.targetId(push.current!);
    expect(store.notifierActive(a.nid, after), isTrue);
    expect(store.notifierActive(a.nid, before), isFalse);
  });

  test('no push target (no permission, no token): nothing is asked', () async {
    await friend(42, _queue(0x10));
    push.current = null;
    notifiers = build()..run();
    await settle();
    expect(registerFrames(), isEmpty);
  });

  test(
    'a challenge whose code never arrives ends the pass and records nothing; '
    'that target rests (a web page re-runs on every return to the screen), '
    'then is asked again',
    () async {
      final a = _queue(0x10);
      final b = _queue(0x20);
      await friend(42, a);
      await friend(43, b);
      deliver = false;
      notifiers = build(
        codeWait: const Duration(milliseconds: 30),
        park: const Duration(milliseconds: 500),
      )..run();
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await settle();

      expect(steps(), [(a.nid, 1)], reason: 'push is not reaching this app: '
          'more challenges would only spend the budget');
      final target = BoxNotifiers.targetId(push.current!);
      expect(store.notifierActive(a.nid, target), isFalse);

      deliver = true;
      notifiers.run();
      await settle();
      expect(steps(), hasLength(1), reason: 'resting');

      await Future<void>.delayed(const Duration(milliseconds: 900));
      await settle();
      expect(steps().skip(1), [(a.nid, 1), (a.nid, 2), (b.nid, 1), (b.nid, 2)]);
    },
  );

  test(
    'a push target the box refuses (invalid_payload) ends the pass — every '
    'queue would get the same answer — and rests; a new target goes ahead',
    () async {
      final a = _queue(0x10);
      final b = _queue(0x20);
      await friend(42, a);
      await friend(43, b);
      challengeAnswers[a.nid] = {'ok': false, 'code': 'invalid_payload'};
      notifiers = build()..run();
      await settle();
      expect(steps(), [(a.nid, 1)]);

      notifiers.run();
      await settle();
      expect(steps(), hasLength(1), reason: 'resting');

      push.current = (platform: NotifierPlatform.fcm, token: 'fcm-token-2');
      push.changed.add(null);
      await settle();
      expect(steps().skip(1), [(a.nid, 1), (a.nid, 2), (b.nid, 1), (b.nid, 2)]);
    },
  );

  test(
    "a stray code from an earlier challenge is refused, and the challenge's "
    'own code still activates it',
    () async {
      final a = _queue(0x10);
      await friend(42, a);
      strays.add(_bytes(16, 0x01));
      notifiers = build()..run();
      await settle();

      expect(steps(), [(a.nid, 1), (a.nid, 2), (a.nid, 2)]);
      expect(
        store.notifierActive(a.nid, BoxNotifiers.targetId(push.current!)),
        isTrue,
      );
    },
  );

  test('rate_limited stops the pass and resumes it after retryAfter', () async {
    final a = _queue(0x10);
    final b = _queue(0x20);
    await friend(42, a);
    await friend(43, b);
    challengeAnswers[b.nid] = {
      'ok': false,
      'code': 'rate_limited',
      'retryAfterMs': 40,
    };
    notifiers = build()..run();
    await settle();
    expect(steps(), [(a.nid, 1), (a.nid, 2), (b.nid, 1)]);

    await Future<void>.delayed(const Duration(milliseconds: 400));
    await settle();
    expect(steps().skip(3), [(b.nid, 1), (b.nid, 2)]);
  });

  test(
    'a queue the box refuses to challenge is skipped; the others register',
    () async {
      final a = _queue(0x10);
      final b = _queue(0x20);
      await friend(42, a);
      await friend(43, b);
      challengeAnswers[a.nid] = {'ok': false, 'code': 'auth_failed'};
      notifiers = build()..run();
      await settle();
      expect(steps(), [(a.nid, 1), (b.nid, 1), (b.nid, 2)]);
    },
  );

  test('overlapping triggers run ONE pass', () async {
    final a = _queue(0x10);
    await friend(42, a);
    notifiers = build()
      ..run()
      ..run();
    push.changed.add(null);
    await settle();
    expect(steps(), [(a.nid, 1), (a.nid, 2)]);
  });

  test(
    'a target that changes mid-pass gets its own pass right after',
    () async {
      final a = _queue(0x10);
      final b = _queue(0x20);
      await friend(42, a);
      await friend(43, b);
      final answer = sockets.respond!;
      var rotated = false;
      sockets.respond = (socket, f) {
        final reply = answer(socket, f);
        if (!rotated && !f.frame.containsKey('token')) {
          rotated = true;
          push.current = (platform: NotifierPlatform.fcm, token: 'fcm-token-2');
          push.changed.add(null);
        }
        return reply;
      };
      notifiers = build()..run();
      await settle();

      final after = BoxNotifiers.targetId(push.current!);
      expect(store.notifierActive(a.nid, after), isTrue);
      expect(store.notifierActive(b.nid, after), isTrue);
    },
  );

  test('a store that is closed or a box that is down asks nothing', () async {
    await friend(42, _queue(0x10));
    store.close();
    notifiers = build()..run();
    await settle();
    expect(registerFrames(), isEmpty);

    await store.open(1);
    sockets.last.serverDrop();
    notifiers.run();
    await settle();
    expect(registerFrames(), isEmpty);
  });

  test('a store that closes mid-pass (a vault re-lock) ends the pass', () async {
    final a = _queue(0x10);
    final b = _queue(0x20);
    await friend(42, a);
    await friend(43, b);
    final answer = sockets.respond!;
    sockets.respond = (socket, f) {
      final reply = answer(socket, f);
      if (f.event == 'registerNotifier' && !f.frame.containsKey('token')) {
        store.close();
      }
      return reply;
    };
    notifiers = build()..run();
    await settle();
    expect(steps(), [(a.nid, 1), (a.nid, 2)]);
  });

  test(
    "a newer build's notifier row: nothing is asked, since nothing could be "
    'recorded and every run would challenge again',
    () async {
      await friend(42, _queue(0x10));
      await kv.setString(
        ContactStore.notifiersKey(1),
        '{"v":${ContactStore.notifiersVersion + 1}}',
      );
      await store.open(1);
      notifiers = build()..run();
      await settle();
      expect(registerFrames(), isEmpty);
    },
  );
}
