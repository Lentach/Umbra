import 'dart:async';
import 'dart:convert';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phase 4 step 4 review, finding F2 (E114m). A friend's device list is looked
/// up BY HANDLE (decision 114, E114a) and that lookup spends one one-time
/// pre-key of every live device of the friend, so it was once per process. A
/// refetch found it spent — and the three paths that DROP the list first (a
/// rebuild request, a newer-list claim, acknowledging a new key) left the
/// friend with no list at all until a restart, where by id they had worked;
/// the verify dialog's served-key fetch was spent the same way by the very
/// lookup that raised the warning.
///
/// The fix: an EVENT buys one more lookup, floored (a peer-driven event, one a
/// minute) and capped (per process); inside the floor, or past the cap, the
/// held list stands.
///
/// Second review (E114o, E114p): every lookup sets the floor, the first of the
/// process and the carried one included; and a lookup nobody answered (a
/// timeout) is asked again by the next fetch, a bounded number of times,
/// instead of leaving a friend whose list an event had dropped with none.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ownUserId = 7;
  const peerId = 42;

  late DateTime now;
  late EncryptionProvider provider;
  late List<String> emitted;
  late DeviceAuthorityEngine engine;
  late Map<String, dynamic> enrollment;
  late String identityKey;

  /// What the handle lookup serves next: the friend's account identity and its
  /// list record.
  late String servedKey;
  late Map<String, dynamic> served;
  var lookups = 0;

  /// The next lookups get no answer (a timeout, a dropped socket).
  var lookupFails = false;

  /// What the real lookup's answer provokes, if anything.
  void Function()? onAnswer;

  Map<String, dynamic> listOf(
    DeviceAuthorityEngine by,
    Map<String, dynamic> enrolled,
    int version,
    List<int> devices,
  ) {
    final signed = by.signList(
      DeviceList(
        userId: peerId,
        version: version,
        devices: [
          for (final d in devices)
            DeviceListEntry(deviceId: d, platform: 'web', addedAtMs: d * 1000),
        ],
      ),
    );
    return {
      'dakPub': enrolled['dakPub'],
      'enrollmentSig': enrolled['enrollmentSig'],
      'enrollmentCreatedAt': enrolled['createdAt'],
      'listVersion': version,
      'listSignature': signed['listSignature'],
      'listCanonical': signed['listCanonical'],
    };
  }

  /// `MessagingProvider.lookupBoxPeerList` as far as the E2E layer sees it:
  /// the served identity and list go to `adoptServedAccount`, a refusal is
  /// left to the caller, and the answer's record comes back.
  Future<Map<String, dynamic>?> lookup(int peer) async {
    lookups++;
    if (lookupFails) throw StateError('box peer $peer: no search answer');
    try {
      await provider.adoptServedAccount(
        peer,
        identityKey: servedKey,
        authorization: served,
      );
    } on DeviceListVerificationException {
      // The caller judges the list under the anchor it holds.
    }
    onAnswer?.call();
    return served;
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    now = DateTime.utc(2026, 10, 22, 12);
    emitted = [];
    lookups = 0;
    onAnswer = null;
    lookupFails = false;
    await E2ePersistentDiag.clear();
    final p = EncryptionProvider(clock: () => now);
    provider = p;
    p
      ..listsByHandle = ((peer) => peer == peerId)
      ..lookupBoxPeerList = lookup
      ..setEmitCallback((event, data) {
        emitted.add(event);
        if (event == 'checkOwnKeyBundle') {
          p.onOwnKeyBundleStatus({'exists': false});
        }
      })
      // The box refresh: a dropped list is looked up again by whoever reads it.
      ..onDeviceListInvalidated = (user) => unawaited(
        p
            .getVerifiedDeviceList(user)
            .then<void>((_) {}, onError: (Object _) {}),
      );
    await p.initializeE2E(ownUserId);

    engine = DeviceAuthorityEngine();
    final identity = generateIdentityKeyPair();
    enrollment = engine.mintEnrollment(
      userId: peerId,
      identity: identity,
      createdAtMs: 1234567890,
    );
    identityKey = base64Encode(identity.getPublicKey().serialize());
    await p.encryptionService.debugSavePeerIdentity(peerId, identityKey);
    servedKey = identityKey;
    served = listOf(engine, enrollment, 1, [1]);
  });

  /// The first lookup of the process, which E114a already allowed.
  Future<void> firstSight() async {
    await provider.getVerifiedDeviceList(peerId);
    expect(lookups, 1);
  }

  void rebuildRequest() =>
      provider.onSessionRebuildNeeded({'fromUserId': peerId});

  group("a friend's list refetched on an event (E114m)", () {
    // Mutation: `_takeLookup` keeps the once-per-process guard (a second
    // lookup of the friend throws `lookup spent`, unseen).
    test('a rebuild request looks the friend up again and the new list is '
        'held, with no id on the wire', () async {
      await firstSight();
      now = now.add(kBoxRelookupFloor); // past the floor the lookup set
      served = listOf(engine, enrollment, 2, [1, 2]);

      rebuildRequest();
      await pumpEventQueue();

      expect(lookups, 2);
      expect(provider.cachedDeviceList(peerId)?.liveDeviceIds, [1, 2]);
      expect(emitted, isNot(contains('getDeviceList')));
    });

    // Mutation: drop the floor/cap check from `_owedRelookup`, or let an
    // invalidation during a lookup mint a new token.
    test('repeated invalidations inside the floor — one of them caused by the '
        "lookup's own answer — cost exactly ONE extra lookup, and the friend "
        'is never left without a list', () async {
      await firstSight();
      now = now.add(kBoxRelookupFloor); // past the floor the lookup set
      served = listOf(engine, enrollment, 2, [1, 2]);
      onAnswer = () => provider.invalidateDeviceList(peerId);

      rebuildRequest();
      await pumpEventQueue();
      expect(lookups, 2);

      for (var i = 0; i < 6; i++) {
        now = now.add(const Duration(seconds: 5));
        rebuildRequest();
        provider.invalidateDeviceList(peerId);
        expect(
          provider.cachedDeviceList(peerId),
          isNotNull,
          reason: 'a dropped list would leave the friend with none until a '
              'restart; inside the floor the held one stands',
        );
        await pumpEventQueue();
      }

      expect(lookups, 2);
      expect(provider.cachedDeviceList(peerId)?.version, 2);

      // Past the floor the next event buys the next lookup, once, although
      // every answer provokes another invalidation.
      now = now.add(kBoxRelookupFloor);
      rebuildRequest();
      await pumpEventQueue();
      expect(lookups, 3);
      expect(provider.cachedDeviceList(peerId), isNotNull);
    });

    // Mutation: drop `kBoxRelookupCap` from `_relookupAvailable`.
    test('past the cap no event looks the friend up again, whatever the '
        'time', () async {
      await firstSight();

      for (var i = 0; i < kBoxRelookupCap + 3; i++) {
        now = now.add(kBoxRelookupFloor);
        rebuildRequest();
        await pumpEventQueue();
      }

      expect(lookups, 1 + kBoxRelookupCap);
      expect(provider.cachedDeviceList(peerId), isNotNull);
    });

    // Mutation: the in-flight join leaves the token (`_relookupOwed.remove`
    // dropped from `_fetchDeviceListAnswer`). A person's act is the event that
    // can reach it: a peer-driven one finds the floor the lookup just set.
    test("a person's act during the first-sight lookup is answered by it and "
        'leaves no lookup owed', () async {
      onAnswer = () => provider.invalidateDeviceList(peerId, byPerson: true);
      await provider.getVerifiedDeviceList(peerId);
      onAnswer = null;
      await pumpEventQueue();
      expect(lookups, 1);
      expect(provider.cachedDeviceList(peerId), isNotNull);

      await expectLater(
        provider.getVerifiedDeviceList(peerId, forceRefresh: true),
        throwsStateError,
      );
      expect(lookups, 1);
    });

    // Mutation: `_takeLookup` sets no floor for the first lookup of the
    // process (the one the box refresh makes at connect): a rebuild request
    // seconds later buys a second lookup at once.
    test('every lookup sets the floor, the first of the process too: a rebuild '
        'request seconds after it keeps the held list and buys nothing',
        () async {
      await firstSight();
      served = listOf(engine, enrollment, 2, [1, 2]);

      rebuildRequest();
      await pumpEventQueue();

      expect(lookups, 1);
      expect(provider.cachedDeviceList(peerId)?.version, 1);

      now = now.add(kBoxRelookupFloor);
      rebuildRequest();
      await pumpEventQueue();

      expect(lookups, 2);
      expect(provider.cachedDeviceList(peerId)?.version, 2);
    });

    // Mutation: `_takeLookup` has no retry: the lookup an event bought got no
    // answer, its token went with it, and the list the event had dropped never
    // came back (`lookup spent` at every refresh, until a restart).
    test("a rebuild request's lookup nobody answers is asked again by the next "
        'refresh, and the friend has its list back with no restart', () async {
      await firstSight();
      now = now.add(kBoxRelookupFloor);
      served = listOf(engine, enrollment, 2, [1, 2]);

      lookupFails = true;
      rebuildRequest();
      await pumpEventQueue();
      expect(lookups, 2, reason: 'the lookup went out and nobody answered');
      expect(provider.cachedDeviceList(peerId), isNull);

      lookupFails = false;
      final list = await provider.getVerifiedDeviceList(peerId);

      expect(list.liveDeviceIds, [1, 2]);
      expect(lookups, 3);
      // The retry was answered: nothing is owed any more.
      await expectLater(
        provider.getVerifiedDeviceList(peerId, forceRefresh: true),
        throwsStateError,
      );
      expect(lookups, 3);
    });

    // Mutation: the retry has no bound (a friend nobody answers is asked at
    // every refresh), or the next lookup an event buys does not start the
    // count over.
    test('a first lookup nobody answers is asked again by the next refresh, '
        'three times at most; the next event then starts over', () async {
      lookupFails = true;
      for (var i = 0; i < kBoxLookupRetries + 3; i++) {
        await expectLater(
          provider.getVerifiedDeviceList(peerId),
          throwsStateError,
        );
      }
      expect(lookups, 1 + kBoxLookupRetries);
      expect(provider.cachedDeviceList(peerId), isNull);

      final unanswered = E2ePersistentDiag.entries
          .where((e) => e.contains('BOX_LIST_LOOKUP_UNANSWERED'))
          .toList();
      expect(unanswered, hasLength(1 + kBoxLookupRetries));
      expect(unanswered.first, allOf(contains('n: 1'), contains('retry: true')));
      expect(
        unanswered.last,
        allOf(contains('n: ${1 + kBoxLookupRetries}'), contains('retry: false')),
      );

      // The friend is reachable again, but the next lookup an event buys is
      // not answered either: it starts the count over, so it is retried too.
      now = now.add(kBoxRelookupFloor);
      rebuildRequest();
      await pumpEventQueue();
      expect(lookups, 2 + kBoxLookupRetries);
      expect(provider.cachedDeviceList(peerId), isNull);

      lookupFails = false;
      final list = await provider.getVerifiedDeviceList(peerId);

      expect(list.liveDeviceIds, [1]);
      expect(lookups, 3 + kBoxLookupRetries);
    });

    // Mutation: the unanswered count ignores which account asked: a lookup of
    // the account that signed out, failing late, is counted for the next one.
    test('a lookup that fails after its account went away says nothing about '
        'the next one', () async {
      final gate = Completer<Map<String, dynamic>?>();
      provider.lookupBoxPeerList = (peer) {
        lookups++;
        return gate.future;
      };
      final pending = expectLater(
        provider.getVerifiedDeviceList(peerId),
        throwsStateError,
      );
      provider.clearAll();

      gate.completeError(StateError('box peer $peerId: no search answer'));
      await pending;

      expect(
        E2ePersistentDiag.entries.where(
          (e) => e.contains('BOX_LIST_LOOKUP_UNANSWERED'),
        ),
        isEmpty,
      );
    });
  });

  group('a friend that reset its keys (amendment (xlvii) clause 3)', () {
    late DeviceAuthorityEngine afterEngine;
    late IdentityKeyPair afterIdentity;
    late Map<String, dynamic> afterEnrollment;
    late String afterKey;

    setUp(() {
      afterEngine = DeviceAuthorityEngine();
      afterIdentity = generateIdentityKeyPair();
      afterEnrollment = afterEngine.mintEnrollment(
        userId: peerId,
        identity: afterIdentity,
        createdAtMs: 99,
      );
      afterKey = base64Encode(afterIdentity.getPublicKey().serialize());
    });

    /// The friend reset: its new account is what the server serves now, and the
    /// rebuild request it sent reaches us.
    Future<void> friendResets() async {
      await firstSight();
      served = listOf(afterEngine, afterEnrollment, 2, [5]);
      servedKey = afterKey;
      now = now.add(const Duration(minutes: 10));
      rebuildRequest();
      await pumpEventQueue();
      expect(lookups, 2, reason: "the event's own lookup");
      expect(
        provider.peersWithChangedIdentity,
        contains(peerId),
        reason: 'the served list cannot verify under the anchor held',
      );
    }

    // Mutation: `_fetchServedAccountIdentity` takes the by-id path for a
    // friend (its lookup is spent: nothing to acknowledge until a restart).
    test('the dialog shows the key the lookup that raised the warning served: '
        'no second lookup, no id on the wire', () async {
      await friendResets();
      now = now.add(const Duration(seconds: 10));

      final shown = await provider.loadPeerIdentityVerification(
        peerId,
        timeout: const Duration(seconds: 1),
      );

      expect(shown.hasOffer, isTrue);
      expect(shown.offeredWasServed, isTrue);
      expect(shown.offeredIdentityBase64, afterKey);
      expect(lookups, 2);
      expect(emitted, isNot(contains('getDeviceList')));
      expect(emitted, isNot(contains('fetchPreKeyBundle')));
    });

    // Mutation: `_servedIdentityByHandle` never asks (memo only).
    test('a warning no lookup of this process raised is answered by the one '
        'lookup the dialog may make', () async {
      await provider.encryptionService.recordPeerIdentityChangedFromServer(
        peerId,
      );
      served = listOf(afterEngine, afterEnrollment, 2, [5]);
      servedKey = afterKey;

      final shown = await provider.loadPeerIdentityVerification(
        peerId,
        timeout: const Duration(seconds: 1),
      );

      expect(shown.offeredIdentityBase64, afterKey);
      expect(lookups, 1);
      expect(emitted, isNot(contains('fetchPreKeyBundle')));
    });

    // Mutation: `_servedIdentityByHandle` ignores the memo's age (a stale
    // identity is shown, nothing asked), or asks on every open.
    test('a memo older than the floor is asked again, once; opening the '
        'dialog again costs nothing (the served key is the candidate now)',
        () async {
      await friendResets();
      now = now.add(const Duration(minutes: 5));

      final shown = await provider.loadPeerIdentityVerification(
        peerId,
        timeout: const Duration(seconds: 1),
      );
      expect(lookups, 3);
      expect(shown.offeredIdentityBase64, afterKey);

      for (var i = 0; i < 3; i++) {
        await provider.loadPeerIdentityVerification(
          peerId,
          timeout: const Duration(seconds: 1),
        );
      }
      expect(lookups, 3);
    });

    // Mutation: `acknowledgePeerIdentity` drops the list with no lookup owed
    // (the old once-per-process guard answers `lookup spent`).
    test('after the human acknowledges, the friend is looked up again and its '
        'new list verifies under the new anchor', () async {
      await friendResets();
      now = now.add(const Duration(seconds: 20));
      final shown = await provider.loadPeerIdentityVerification(
        peerId,
        timeout: const Duration(seconds: 1),
      );
      expect(shown.offeredIdentityBase64, afterKey);

      final advanced = await provider.acknowledgePeerIdentity(
        peerId,
        adoptIdentityBase64: shown.offeredIdentityBase64,
      );
      await pumpEventQueue();

      expect(advanced, isTrue);
      expect(lookups, 3);
      expect(provider.cachedDeviceList(peerId)?.liveDeviceIds, [5]);
      expect(emitted, isNot(contains('getDeviceList')));
    });

    // Mutation: `_takeLookup` has no retry: the person's token went with the
    // lookup nobody answered, the acknowledgement had dropped the list, and
    // every refresh got `lookup spent` — no list until a restart (second
    // review).
    test('a lookup nobody answers after the human acknowledged is asked again '
        'by the next refresh: the friend gets its list back, no restart',
        () async {
      await friendResets();
      now = now.add(const Duration(seconds: 20));
      final shown = await provider.loadPeerIdentityVerification(
        peerId,
        timeout: const Duration(seconds: 1),
      );

      lookupFails = true;
      final advanced = await provider.acknowledgePeerIdentity(
        peerId,
        adoptIdentityBase64: shown.offeredIdentityBase64,
      );
      await pumpEventQueue();

      expect(advanced, isTrue);
      expect(lookups, 3, reason: "the acknowledgement's lookup went out");
      expect(provider.cachedDeviceList(peerId), isNull);

      lookupFails = false;
      final list = await provider.getVerifiedDeviceList(peerId);

      expect(list.liveDeviceIds, [5]);
      expect(lookups, 4);
    });

    // Mutation: `_relookupAvailable` applies the cap to a person's act (drive
    // defect, 10-22: six events spent the cap, the acknowledgement dropped the
    // list and its refetch was refused — no list until a restart).
    test('after the events spent the cap, a person who acknowledges the new '
        "key still gets the friend's list back", () async {
      await firstSight();
      for (var i = 0; i < kBoxRelookupCap; i++) {
        now = now.add(kBoxRelookupFloor);
        rebuildRequest();
        await pumpEventQueue();
      }
      expect(lookups, 1 + kBoxRelookupCap);

      // The friend resets; no event may look it up now, but the server's own
      // alarm raises the warning and the person opens the dialog.
      served = listOf(afterEngine, afterEnrollment, 2, [5]);
      servedKey = afterKey;
      await provider.encryptionService.recordPeerIdentityChangedFromServer(
        peerId,
      );
      now = now.add(const Duration(minutes: 10));
      final shown = await provider.loadPeerIdentityVerification(
        peerId,
        timeout: const Duration(seconds: 1),
      );
      expect(shown.offeredIdentityBase64, afterKey);
      expect(lookups, 2 + kBoxRelookupCap, reason: 'a person is no event');

      final advanced = await provider.acknowledgePeerIdentity(
        peerId,
        adoptIdentityBase64: shown.offeredIdentityBase64,
      );
      await pumpEventQueue();

      expect(advanced, isTrue);
      expect(lookups, 3 + kBoxRelookupCap);
      expect(provider.cachedDeviceList(peerId)?.liveDeviceIds, [5]);
    });
  });
}
