// PROOF HARNESS — "show me the server cannot read my messages."
//
// This file is not a unit test dressed up as evidence. It drives the REAL
// client stack (ApiService REST auth -> Socket.IO -> real libsignal -> the
// real box client) against a REAL backend and a REAL Postgres, sends messages
// containing a unique plaintext NEEDLE, and then goes looking for that needle
// in every text-typed and bytea column of every table in the database. It
// prints everything it finds so a human can read the transcript and check the
// claim themselves.
//
// Since Phase 4 step 5 the server has no message path of its own: a message
// is a Signal ciphertext, sealed to the recipient's queue key and dropped on
// the box (`/box`), which stores one opaque 16 KiB blob and nothing about who
// sent it. That blob is what the server can possibly hold, so that is what is
// sent and swept here. (The old `messages` / `message_envelopes` tables are
// gone; test 4 checks that too.)
//
// Run it against an ISOLATED stack, never production and never someone else's
// dev stack:
//
//   docker compose -p fpproof -f docker-compose.yml -f docker-compose.proof.yml up -d
//   cd frontend
//   E2E_BASE_URL=http://localhost:3100 E2E_DB_CONTAINER=fpproof-db-1 \
//     flutter test test_e2e/encryption_proof_test.dart
//
// What each test establishes:
//   1. one text message, fully disclosed: plaintext, Signal ciphertext, the
//      sealed blob, and the exact DB row the box ended up holding;
//   2. the needle appears in ZERO columns of the WHOLE database (the sweep
//      reports how many columns it scanned, so it cannot pass vacuously);
//   3. the recipient's private identity key appears in ZERO columns either —
//      the server holds public halves only, so it could not decrypt even if
//      it wanted to;
//   4. census: EVERY blob the box holds is one fixed-size sealed blob, and the
//      tables that used to hold readable message rows no longer exist;
//   5. an image: the bytes the box stores and re-serves are AES-GCM
//      ciphertext, and its key/IV live only inside the Signal-encrypted
//      message, never in a column.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_signer.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/box/queue_seal.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/box_fakes.dart' show PointyGcmSealer;
import 'support/e2e_test_client.dart';

/// Opt-in, and it MUST stay that way: this file registers two accounts and
/// `/auth/register` is 10 per HOUR per IP with an in-memory counter shared by
/// every account in `test_e2e/`. The shared `e2e-wire` run already spends that
/// bucket to the edge, so these two registrations are what tipped
/// `full_stack_e2e_test.dart` into `ThrottlerException(429)` on
/// `f86a43de` — the failure lands on whichever suite runs last, which is why it
/// looked like a defect in a file this change never touched. It runs on the
/// `e2e-isolated-probes` stack instead, whose fresh backend means a fresh
/// counter. Never raise the production cap to fit a test (`.github/workflows/ci.yml`).
const bool _enabled = bool.fromEnvironment('ENCRYPTION_PROOF');

/// The rung the box's media ladder starts at (`BOX_MEDIA_LADDER`, I5): an
/// upload is exactly one rung, so the proof's "picture" is sized to it.
const int _mediaRungBytes = 4 * 1024;

/// AES-GCM's 128-bit tag, appended to the ciphertext.
const int _gcmTagBytes = 16;

/// AES-256-GCM with the app's parameters (32-byte key, 12-byte IV) — the same
/// shape `MediaCryptoService` produces.
///
/// The app itself reaches AES-GCM through `package:webcrypto`, whose BoringSSL
/// backend CANNOT load under `flutter test` on this machine (it needs MSVC:
/// `dart run webcrypto:setup` fails with "CMAKE_C_COMPILER not set"). The
/// claim this test makes is about the SERVER — that what it receives, stores
/// and serves is an opaque blob whose key it never sees — and that claim does
/// not depend on which AES-GCM implementation produced the blob. The app's own
/// media path is evidenced separately against production media files.
({Uint8List ciphertext, String keyBase64, String ivBase64}) encryptLikeTheApp(
  Uint8List bytes,
) {
  final rnd = pc.SecureRandom('Fortuna')
    ..seed(
      pc.KeyParameter(
        Uint8List.fromList(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)),
        ),
      ),
    );
  final key = rnd.nextBytes(32);
  final iv = rnd.nextBytes(12);
  final cipher = pc.GCMBlockCipher(
    pc.AESEngine(),
  )..init(true, pc.AEADParameters(pc.KeyParameter(key), 128, iv, Uint8List(0)));
  return (
    ciphertext: cipher.process(bytes),
    keyBase64: base64Encode(key),
    ivBase64: base64Encode(iv),
  );
}

Uint8List decryptLikeTheApp(Uint8List ciphertext, String keyB64, String ivB64) {
  final cipher = pc.GCMBlockCipher(pc.AESEngine())
    ..init(
      false,
      pc.AEADParameters(
        pc.KeyParameter(Uint8List.fromList(base64Decode(keyB64))),
        128,
        Uint8List.fromList(base64Decode(ivB64)),
        Uint8List(0),
      ),
    );
  return cipher.process(ciphertext);
}

/// Everything printed by the proof is prefixed so the evidence is greppable
/// out of the surrounding test noise.
// Why ignored: the printed transcript IS this suite's deliverable —
// docs/proof/e2e-encryption-proof.md quotes it verbatim — so `print` here is
// the product, not debug litter.
// ignore: avoid_print
void say(String line) => print('[PROOF] $line');

void rule(String title) {
  say('');
  say('=' * 72);
  say(title);
  say('=' * 72);
}

/// Shortens a blob for display while still showing it is what it claims.
String preview(String s, {int head = 64}) =>
    s.length <= head ? s : '${s.substring(0, head)}… (${s.length} chars)';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Whether [haystack] holds [needle] as a contiguous run of bytes.
bool _containsBytes(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  enableRealNetwork();

  final baseUrl = e2eBaseUrl();
  final runTag = DateTime.now().millisecondsSinceEpoch.toString();

  // The needle. Deliberately restricted to [A-Za-z0-9-] so it is safe to
  // interpolate into a SQL LIKE pattern, and deliberately a sentence a human
  // would recognise instantly if it ever showed up in a database dump.
  final needle = 'UMBRA-PROOF-$runTag-MEET-ME-AT-THE-DOCKS-AT-MIDNIGHT';
  final mediaNeedle = 'UMBRA-PROOF-$runTag-THIS-IS-INSIDE-THE-PICTURE';

  const signer = Ed25519BoxSigner();
  final seal = QueueSeal(cipher: PointyGcmSealer());

  late E2eClient alice;
  late E2eClient bob;
  late BoxClient aliceBox;
  late BoxClient bobBox;
  late BoxQueueAuth bobQueue;
  late QueueAddress bobAddress;
  late QueueSealKeyPair bobSealKeys;
  final bobGot = <BoxDelivery>[];

  Future<void> boxReady(BoxClient box) async {
    if (box.state == BoxState.ready) return;
    final ready = box.states.firstWhere((s) => s == BoxState.ready);
    box.connect();
    await ready.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException('box not ready: ${box.state}'),
    );
  }

  Future<void> until(bool Function() condition, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('waited 15 s for $what');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// [signalCiphertext] as the app sends it: framed, sealed to bob's queue key
  /// and dropped on his queue by alice's box connection. Returns the blob that
  /// left alice's device — byte for byte what the box was handed.
  Future<Uint8List> sendToBob(String signalCiphertext) async {
    final frame = BoxFrame.fromSignalCiphertext(
      signalCiphertext,
      senderDeviceId: 1,
    )!;
    final blob = await seal.seal(bobSealKeys.publicKey, frame.encode());
    expect(blob, isNotNull, reason: 'sealing must succeed');
    expect(blob, hasLength(kBoxBlobBytes));
    expect(
      await aliceBox.send(bobAddress.sid, blob!),
      isA<BoxOk<void>>(),
      reason: 'the box takes the blob',
    );
    return blob;
  }

  /// Opens delivery [index] on bob's side: unseal, unframe, return the frame.
  Future<BoxFrame> bobOpens(int index) async {
    await until(() => bobGot.length > index, 'bob delivery #$index');
    final body = await seal.open(
      bobSealKeys.privateKey,
      bobSealKeys.publicKey,
      bobGot[index].blob,
    );
    expect(body, isNotNull, reason: 'bob can open what was sealed to him');
    return BoxFrame.decode(body!)!;
  }

  /// Runs a dynamic sweep over EVERY text-typed column (when [likeLiteral] is
  /// given) and EVERY bytea column (when [byteaHex] is given) of EVERY table
  /// in the `public` schema.
  ///
  /// Returns `(hits, columnsScanned)`. The scanned count is returned on
  /// purpose: a sweep that silently scanned nothing would "find no plaintext"
  /// and prove absolutely nothing, so the tests assert on it.
  Future<(List<List<String>>, int)> sweep({
    String? likeLiteral,
    String? byteaHex,
  }) async {
    // LIKE's only metacharacters are `%` and `_`. Standard base64
    // (A-Za-z0-9+/=), hex, and the hyphenated needle contain neither, and no
    // quote — so the FULL string is safe to sweep, which is a strictly
    // stronger claim than sweeping a fragment of it.
    if (likeLiteral != null &&
        !RegExp(r'^[A-Za-z0-9+/=-]+$').hasMatch(likeLiteral)) {
      throw ArgumentError('needle must be LIKE- and quote-safe: $likeLiteral');
    }
    final types = [
      if (likeLiteral != null)
        "'text', 'character varying', 'character', 'json', 'jsonb', 'uuid'",
      if (byteaHex != null) "'bytea'",
    ].join(', ');
    final textArm = likeLiteral == null
        ? ''
        : '''
    IF r.dtype <> 'bytea' THEN
      EXECUTE format(
        'SELECT count(*) FROM public.%I WHERE %I::text LIKE %L',
        r.tname, r.cname, '%$likeLiteral%'
      ) INTO n;
    END IF;''';
    final byteaArm = byteaHex == null
        ? ''
        : '''
    IF r.dtype = 'bytea' THEN
      EXECUTE format(
        'SELECT count(*) FROM public.%I WHERE position(decode(%L, ''hex'') IN %I) > 0',
        r.tname, '$byteaHex', r.cname
      ) INTO n;
    END IF;''';
    final rows = await e2eSql('''
CREATE TEMP TABLE _proof_hits(tbl text, col text, hits bigint);
DO \$do\$
DECLARE
  r record;
  n bigint;
  scanned int := 0;
BEGIN
  FOR r IN
    SELECT table_name AS tname, column_name AS cname, data_type AS dtype
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND data_type IN ($types)
     ORDER BY table_name, column_name
  LOOP
    scanned := scanned + 1;
    n := 0;
$textArm
$byteaArm
    IF n > 0 THEN
      INSERT INTO _proof_hits VALUES (r.tname, r.cname, n);
    END IF;
  END LOOP;
  INSERT INTO _proof_hits VALUES ('__columns_scanned__', '-', scanned);
END
\$do\$;
SELECT tbl, col, hits FROM _proof_hits ORDER BY tbl, col;
''');
    // psql echoes a command tag ("CREATE TABLE", "DO") on its own line for
    // every non-SELECT statement, even under -At. Those are 1-field rows;
    // only the 3-field rows are results.
    var scanned = 0;
    final hits = <List<String>>[];
    for (final row in rows) {
      if (row.length != 3) continue;
      if (row[0] == '__columns_scanned__') {
        scanned = int.parse(row[2]);
      } else {
        hits.add(row);
      }
    }
    return (hits, scanned);
  }

  /// [literal] in every text column AND, as its UTF-8 bytes, in every bytea
  /// column.
  Future<(List<List<String>>, int)> sweepDatabaseFor(String literal) => sweep(
    likeLiteral: literal,
    byteaHex: _hex(utf8.encode(literal)),
  );

  /// The longest run of `[A-Za-z0-9]` inside [s].
  ///
  /// Only needed for the username control: harness usernames contain `_`,
  /// which IS a LIKE metacharacter (any single character). Key material is
  /// base64 and gets swept in full — see [sweep].
  String longestAlnumRun(String s) {
    final runs = RegExp('[A-Za-z0-9]+').allMatches(s).map((m) => m[0]!);
    return runs.reduce((a, b) => b.length > a.length ? b : a);
  }

  /// POSTs [bytes] (exactly one ladder rung) to `/box/media` against bob's
  /// queue sid and returns the media id the box hands back.
  Future<String> uploadMedia(Uint8List bytes) async {
    final http = HttpClient();
    try {
      final req = await http.postUrl(Uri.parse('$baseUrl/box/media'));
      req.headers
        ..set('Box-Sid', boxB64(bobAddress.sid))
        ..set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
      req
        ..contentLength = bytes.length
        ..add(bytes);
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 201) {
        throw StateError('media upload failed ${res.statusCode}: $body');
      }
      return (jsonDecode(body) as Map<String, dynamic>)['id'] as String;
    } finally {
      http.close(force: true);
    }
  }

  /// GETs a media capability URL with NO credentials: the id IS the
  /// credential, so this is exactly what anyone holding the link — or the
  /// server — can read.
  Future<Uint8List> fetchMedia(String url) async {
    final http = HttpClient();
    try {
      final req = await http.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw StateError('fetch failed ${res.statusCode} for $url');
      }
      final chunks = <int>[];
      await res.forEach(chunks.addAll);
      return Uint8List.fromList(chunks);
    } finally {
      http.close(force: true);
    }
  }

  group(
    'E2E proof',
    () {
      late Uint8List textBlob;
      late String wireCiphertext;
      // Guards the teardown below. `setUpAll` fails BEFORE the clients exist
      // whenever the backend is not up yet — the common local case — and an
      // unguarded `tearDownAll` then reports a second, misleading
      // `LateInitializationError` on top of the real cause. `addTearDown` is
      // NOT the fix here: package:test runs `setUpAll` as its own synthetic
      // test, so a callback registered inside it fires the moment `setUpAll`
      // completes — disposing both clients before test 1 ever runs.
      var clientsBuilt = false;
      var boxBuilt = false;
      setUpAll(() async {
        await requireBackendUp(baseUrl);

        // Why ignored: seeding the real plugin's mock store is the only way to run
        // the app's own storage stack here, and the setter is @visibleForTesting in
        // a package we do not own.
        // ignore: invalid_use_of_visible_for_testing_member
        FlutterSecureStorage.setMockInitialValues({});
        // Same reason as above, for the SharedPreferences backend.
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({});

        alice = E2eClient('alice', baseUrl);
        bob = E2eClient('bob', baseUrl);
        clientsBuilt = true;

        await alice.registerFresh();
        await bob.registerFresh();
        await alice.connectSocket();
        await bob.connectSocket();
        await alice.initializeAndUploadKeys();
        await bob.initializeAndUploadKeys();

        // X3DH: alice fetches bob's PUBLIC bundle and builds a Signal session.
        final bundle = await alice.fetchBundleFor(bob.userId);
        await alice.encryption.buildSession(
          bob.userId,
          bundle,
          expectedIdentityBase64: null,
        );

        // Bob's box queue: the one address a message to him is dropped on.
        aliceBox = BoxClient(
          baseUrl: baseUrl,
          // The harness's other box file does the same: the proof is about
          // the server, not the box client's own socket plumbing.
          socketFactory: IoBoxSocket.new,
        );
        bobBox = BoxClient(baseUrl: baseUrl, socketFactory: IoBoxSocket.new);
        boxBuilt = true;
        await boxReady(aliceBox);
        await boxReady(bobBox);
        final key = signer.mint();
        final created = await bobBox.createQueue(QueueKind.normal, key);
        expect(created, isA<BoxOk<QueueAddress>>());
        bobAddress = (created as BoxOk<QueueAddress>).value;
        bobQueue = BoxQueueAuth(rid: bobAddress.rid, key: key);
        bobSealKeys = QueueSeal.mintKeyPair();
        bobBox.deliveries.listen(bobGot.add);
        final subscribed = await bobBox.subscribe([bobQueue]);
        expect(subscribed, isA<BoxOk<List<BoxRefusal>>>());

        rule('SETUP');
        say('backend under test      : $baseUrl');
        say('alice userId            : ${alice.userId} (${alice.username})');
        say('bob   userId            : ${bob.userId} (${bob.username})');
        say('bob box queue sid       : ${preview(boxB64(bobAddress.sid))}');
        say('bob PUBLIC bundle the server served alice:');
        say(
          '  identityPublicKey     : ${preview(bundle['identityPublicKey'] as String)}',
        );
        say(
          '  signedPreKeyPublic    : ${preview(bundle['signedPreKeyPublic'] as String)}',
        );
        say('  oneTimePreKeyId       : ${bundle['oneTimePreKeyId']}');
        say(
          'Note: every field above is a PUBLIC key half. That is all the server',
        );
        say('has ever been given.');
      });

      tearDownAll(() async {
        if (boxBuilt) {
          // Deleting the queue takes its undelivered blobs with it: nothing of
          // this run's messages is left on a shared dev database.
          await bobBox.deleteQueue(bobQueue);
          aliceBox.dispose();
          bobBox.dispose();
        }
        if (!clientsBuilt) return;
        alice.dispose();
        bob.dispose();
      });

      test(
        '1. one message, fully disclosed: plaintext vs. what the server got',
        () async {
          rule('1. ONE MESSAGE, FULLY DISCLOSED');

          // The exact plaintext JSON the app hands to libsignal.
          final envelopeJson = jsonEncode(E2eEnvelope.build(needle));
          say('Alice types            : $needle');
          say('App builds envelope    : $envelopeJson');

          wireCiphertext = await alice.encryption.encrypt(
            bob.userId,
            envelopeJson,
          );
          say('libsignal produces     : ${preview(wireCiphertext, head: 96)}');
          expect(
            wireCiphertext,
            matches(RegExp(r'^\d+:[A-Za-z0-9+/]+=*$')),
            reason: 'Signal wire format "{type}:{base64}"',
          );

          textBlob = await sendToBob(wireCiphertext);
          say(
            "sealed to bob's queue key: ${textBlob.length} B, "
            '${preview(_hex(textBlob), head: 96)}',
          );

          // --- what the database actually holds -----------------------------
          final ridHex = _hex(bobAddress.rid);
          final rows = await e2eSql('''
SELECT encode("id", 'hex'), octet_length("blob"), encode("blob", 'hex'),
       "createdAt", "expiresAt"
  FROM public.box_msgs WHERE "rid" = decode('$ridHex', 'hex');
''');
          expect(rows, hasLength(1), reason: 'the row must exist');
          final row = rows.single;
          rule('WHAT THE SERVER STORED FOR THIS MESSAGE');
          say('box_msgs.id            : ${row[0]}');
          say('box_msgs.blob          : ${preview(row[2], head: 96)}');
          say('  octet_length         : ${row[1]}');
          say('box_msgs.createdAt     : ${row[3]}   <- metadata, NOT hidden');
          say('box_msgs.expiresAt     : ${row[4]}   <- metadata, NOT hidden');

          expect(
            row[2],
            _hex(textBlob),
            reason: 'what the box stored is byte-identical to the sealed blob '
                "that left alice's device",
          );
          expect(row[1], '$kBoxBlobBytes', reason: 'one fixed size (I5)');

          // The row names nobody: no sender column exists at all.
          final columns = await e2eSql('''
SELECT column_name FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'box_msgs'
 ORDER BY ordinal_position;
''');
          final names = [for (final c in columns) c.single];
          say('box_msgs columns       : ${names.join(', ')}');
          expect(
            names.where(
              (n) => RegExp('sender|user|from|account').hasMatch(n),
            ),
            isEmpty,
            reason: 'the box row cannot name a sender or an account (I2)',
          );

          // Neither the plaintext nor even the Signal ciphertext is visible:
          // the blob is sealed to a key only bob's device holds.
          final frame = BoxFrame.fromSignalCiphertext(
            wireCiphertext,
            senderDeviceId: 1,
          )!;
          expect(
            String.fromCharCodes(textBlob).contains(needle),
            isFalse,
            reason: 'the blob must not reveal the plaintext',
          );
          expect(
            _containsBytes(textBlob, frame.signal.sublist(0, 16)),
            isFalse,
            reason: 'the Signal ciphertext is itself inside the seal',
          );
          say('');
          say('the stored blob is ${textBlob.length} bytes of noise;');
          say('it does NOT contain the sentence Alice typed, nor the Signal');
          say('ciphertext that carries it.');

          // --- and the recipient can still read it ---------------------------
          final opened = await bobOpens(0);
          final decrypted = await bob.decryptText(
            alice.userId,
            opened.signalCiphertext,
          );
          expect(decrypted, needle);
          say('');
          say('Bob unseals and decrypts it back to: $decrypted');
          say(
            'So this is encryption, not deletion: the ONLY parties who can read',
          );
          say('it are the two devices holding the queue key and the session.');
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test(
        '2. the plaintext is in ZERO columns of the entire database',
        () async {
          rule('2. FULL-DATABASE SWEEP FOR THE PLAINTEXT');
          say('needle: $needle');

          // Three encodings, because a literal-only sweep would miss plaintext
          // sitting verbatim inside a base64 or hex blob — e.g. an envelope that
          // was stored unencrypted but base64'd on the way in.
          final encodings = <String, String>{
            'literal UTF-8': needle,
            'base64': base64Encode(utf8.encode(needle)),
            'hex': utf8
                .encode(needle)
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join(),
          };

          var scanned = 0;
          for (final entry in encodings.entries) {
            final (hits, n) = await sweepDatabaseFor(entry.value);
            scanned = n;
            say(
              'as ${entry.key.padRight(13)} -> '
              '${hits.isEmpty ? 'NOT FOUND' : 'FOUND'} '
              '(${entry.value.length} chars, $n columns scanned)',
            );
            for (final h in hits) {
              say('    HIT -> ${h[0]}.${h[1]} x${h[2]}');
            }
            expect(
              hits,
              isEmpty,
              reason:
                  'the sentence Alice typed must not exist anywhere in the '
                  'database, in any encoding (${entry.key})',
            );
          }

          expect(
            scanned,
            greaterThan(50),
            reason:
                'the sweep must actually have scanned the schema; a sweep of '
                'nothing would find nothing and prove nothing',
          );

          // Control: the sweep is capable of finding things. Without this the
          // "no hits" result above could just mean the query is broken.
          final controlNeedle = longestAlnumRun(alice.username);
          final (controlHits, _) = await sweepDatabaseFor(controlNeedle);
          say('');
          say(
            "CONTROL — sweeping for a run of alice's USERNAME "
            '("$controlNeedle" out of "${alice.username}"):',
          );
          for (final h in controlHits) {
            say('HIT -> ${h[0]}.${h[1]} x${h[2]}');
          }
          expect(
            controlHits,
            isNotEmpty,
            reason:
                'the sweep finds a string that IS in the database, so the '
                'empty result for the message plaintext is a real negative',
          );

          // Control for the bytea half: the sealed blob alice sent starts
          // `0x01 ‖ ephemeral public key`; those 32 bytes ARE in a bytea
          // column, so a bytea sweep for them must hit `box_msgs.blob`.
          final (byteaHits, byteaScanned) = await sweep(
            byteaHex: _hex(textBlob.sublist(1, 33)),
          );
          say('');
          say(
            'CONTROL — sweeping bytea columns ($byteaScanned) for the '
            'ephemeral key inside the stored blob:',
          );
          for (final h in byteaHits) {
            say('HIT -> ${h[0]}.${h[1]} x${h[2]}');
          }
          expect(
            byteaHits.map((h) => '${h[0]}.${h[1]}'),
            contains('box_msgs.blob'),
            reason: 'the bytea sweep sees a value that IS in a bytea column',
          );
          say('The sweep works. The message plaintext is simply not there.');
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      test(
        '3. the private keys are not on the server either',
        () async {
          rule('3. WHERE THE KEYS LIVE');

          final bobPair = await bob.encryption.identityKeyPairForLinking();
          final bobPrivate = base64Encode(bobPair.getPrivateKey().serialize());
          final bobPublic = base64Encode(bobPair.getPublicKey().serialize());

          final stored = await e2eSql('''
SELECT "userId", "deviceId", "identityPublicKey"
  FROM public.key_bundles WHERE "userId" = ${bob.userId};
''');
          expect(stored, isNotEmpty);
          say(
            'key_bundles row for bob: userId=${stored.first[0]} '
            'deviceId=${stored.first[1]}',
          );
          say('  stored identityPublicKey: ${preview(stored.first[2])}');
          say("  bob's real PUBLIC key   : ${preview(bobPublic)}");
          expect(
            stored.first[2],
            bobPublic,
            reason: 'the server holds exactly the PUBLIC half',
          );

          // The WHOLE key, not a fragment: base64 contains no LIKE metacharacter
          // (`%`, `_`) and no quote, so the entire string is a safe pattern.
          say('');
          say("bob's PRIVATE identity key : ${preview(bobPrivate)}");
          say('searching every column of the database for it, in full…');
          final (hits, scanned) = await sweepDatabaseFor(bobPrivate);
          say('columns scanned: $scanned');
          for (final h in hits) {
            say('HIT -> ${h[0]}.${h[1]} x${h[2]}');
          }
          expect(scanned, greaterThan(50));
          expect(
            hits,
            isEmpty,
            reason: 'the private identity key must exist nowhere on the server',
          );

          // Control: the PUBLIC half of the same key IS findable, which proves
          // the sweep would have found the private half had it been stored.
          final (publicHits, _) = await sweepDatabaseFor(bobPublic);
          say('');
          say('CONTROL — the same full-string sweep for the PUBLIC half:');
          for (final h in publicHits) {
            say('HIT -> ${h[0]}.${h[1]} x${h[2]}');
          }
          expect(
            publicHits,
            isNotEmpty,
            reason:
                'the public half IS on the server, so the sweep can see key '
                'material when it is there',
          );
          say(
            'Not present. The server was never given it, so there is no key on',
          );
          say('the server with which the stored ciphertext could be opened.');

          // No column anywhere is even NAMED like private key material.
          final suspicious = await e2eSql('''
SELECT table_name || '.' || column_name
  FROM information_schema.columns
 WHERE table_schema = 'public'
   AND (lower(column_name) LIKE '%private%'
     OR lower(column_name) LIKE '%secret%'
     OR lower(column_name) LIKE '%privkey%')
 ORDER BY 1;
''');
          say('');
          say(
            'columns whose NAME suggests private material: '
            '${suspicious.isEmpty ? 'none' : suspicious.map((r) => r[0]).join(', ')}',
          );
          expect(suspicious, isEmpty);
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      test(
        '4. census: every blob the box holds is sealed, and no readable '
        'message table exists',
        () async {
          rule('4. CENSUS OVER EVERY MESSAGE IN THIS DATABASE');

          final census = await e2eSql('''
SELECT count(*),
       count(*) FILTER (WHERE octet_length("blob") = $kBoxBlobBytes)
  FROM public.box_msgs;
''');
          final total = int.parse(census.single[0]);
          final fixedSize = int.parse(census.single[1]);
          say('box_msgs rows total                   : $total');
          say('  blob is exactly $kBoxBlobBytes bytes         : $fixedSize');
          expect(
            total,
            greaterThan(0),
            reason: 'the census must see real rows',
          );
          expect(
            fixedSize,
            total,
            reason: 'every stored blob is one fixed-size sealed blob (I5)',
          );

          // The tables that held a readable row per message are gone
          // (migration 0027): the server keeps no message, envelope,
          // conversation or friend row of its own to be census-ed.
          final gone = await e2eSql('''
SELECT table_name FROM information_schema.tables
 WHERE table_schema = 'public'
   AND table_name IN ('messages', 'message_envelopes', 'conversations',
                      'friend_requests', 'blocked_users', 'reaction_keys')
 ORDER BY 1;
''');
          say(
            'old message-path tables still present : '
            '${gone.isEmpty ? 'none' : gone.map((r) => r.single).join(', ')}',
          );
          expect(gone, isEmpty);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test(
        '5. a picture: the box stores and serves ciphertext bytes',
        () async {
          rule('5. MEDIA');

          // Stand in for a photo: bytes a human would recognise instantly,
          // sized so the AES-GCM ciphertext is EXACTLY one ladder rung (the
          // box refuses any other size from the headers).
          final plainBytes = Uint8List.fromList(
            utf8.encode(mediaNeedle).followedBy(
              List<int>.filled(
                _mediaRungBytes - _gcmTagBytes - mediaNeedle.length,
                0x2e,
              ),
            ).toList(),
          );
          final encrypted = encryptLikeTheApp(plainBytes);
          expect(encrypted.ciphertext, hasLength(_mediaRungBytes));
          say(
            'original bytes          : ${plainBytes.length} B, '
            'starting "$mediaNeedle"',
          );
          say('AES-256-GCM ciphertext  : ${encrypted.ciphertext.length} B');
          say('media key (client-side) : ${preview(encrypted.keyBase64)}');

          final mediaId = await uploadMedia(encrypted.ciphertext);
          final mediaUrl = '$baseUrl/box/media/$mediaId';
          say('box stored it at        : $mediaUrl');

          final row = await e2eSql('''
SELECT "sizeBucket" FROM public.box_media
 WHERE "id" = decode('${_hex(boxB64Decode(mediaId, 32)!)}', 'hex');
''');
          expect(row, hasLength(1), reason: 'the media row must exist');
          say('box_media.sizeBucket    : ${row.single.single}   <- metadata');

          // What the box hands back when asked for that file. The id is the
          // credential: there is no account on this path at all.
          final served = await fetchMedia(mediaUrl);
          say('box serves back         : ${served.length} B');
          expect(
            served,
            orderedEquals(encrypted.ciphertext),
            reason:
                'the box serves exactly the ciphertext it was handed — it '
                'never had anything else',
          );
          expect(
            String.fromCharCodes(served).contains(mediaNeedle),
            isFalse,
            reason: 'what comes off the server is not the picture',
          );
          say('Those bytes do NOT contain the content: the box stored an');
          say('opaque blob and gave the same opaque blob back.');

          // The key rides INSIDE the Signal-encrypted message, so it never
          // becomes a column.
          final envelopeJson = jsonEncode(
            E2eEnvelope.build(
              '',
              messageType: 'IMAGE',
              mediaUrl: mediaUrl,
              mediaKey: encrypted.keyBase64,
              mediaIv: encrypted.ivBase64,
            ),
          );
          final ct = await alice.encryption.encrypt(bob.userId, envelopeJson);
          await sendToBob(ct);

          // The media key must not be anywhere in the database — full string.
          final (keyHits, scanned) = await sweepDatabaseFor(
            encrypted.keyBase64,
          );
          say('swept $scanned columns for the media key, in full');
          for (final h in keyHits) {
            say('HIT -> ${h[0]}.${h[1]} x${h[2]}');
          }
          expect(scanned, greaterThan(50));
          expect(keyHits, isEmpty, reason: 'the media key is not a column');
          say(
            'The key that opens that file is in no column of the database. It',
          );
          say('exists only inside the Signal ciphertext of the message.');

          // And the recipient can open the picture.
          final opened = await bobOpens(1);
          final receivedJson = await bob.encryption.decrypt(
            alice.userId,
            opened.signalCiphertext,
          );
          final env = E2eEnvelope.parse(receivedJson);
          final reopened = decryptLikeTheApp(
            served,
            env.mediaKey!,
            env.mediaIv!,
          );
          expect(reopened, orderedEquals(plainBytes));
          say('');
          say(
            'Bob pulls the same ciphertext, takes key+IV out of the DECRYPTED',
          );
          say('envelope, and recovers the original bytes exactly.');
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    },
    // The gate lives on the GROUP and the lifecycle hooks live INSIDE it, both
    // deliberately. A test-level `skip:` still runs `setUpAll`, so the default
    // run would pay this file's entire register-bucket cost only to skip every
    // test — and `tearDownAll` would then throw disposing an uninitialized
    // `alice`. `enrolled_identity_lock_test.dart:60-66` records the same lesson.
    skip: _enabled
        ? false
        : 'set --dart-define=ENCRYPTION_PROOF=true (needs a fresh register bucket)',
  );
}
