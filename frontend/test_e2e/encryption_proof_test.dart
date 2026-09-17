// PROOF HARNESS — "show me the server cannot read my messages."
//
// This file is not a unit test dressed up as evidence. It drives the REAL
// client stack (ApiService REST auth -> Socket.IO -> real libsignal) against a
// REAL backend and a REAL Postgres, sends messages containing a unique
// plaintext NEEDLE, and then goes looking for that needle in every text-typed
// column of every table in the database. It prints everything it finds so a
// human can read the transcript and check the claim themselves.
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
//   1. one text message, fully disclosed: plaintext, ciphertext, and the exact
//      DB row the server ended up holding;
//   2. the needle appears in ZERO columns of the WHOLE database (the sweep
//      reports how many columns it scanned, so it cannot pass vacuously);
//   3. the recipient's private identity key appears in ZERO columns either —
//      the server holds public halves only, so it could not decrypt even if
//      it wanted to;
//   4. census: EVERY message row in the database is a ciphertext row;
//   5. an image: the bytes the server stores and re-serves are AES-GCM
//      ciphertext, and its key/IV live only inside the Signal-encrypted
//      envelope, never in a column.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/e2e_test_client.dart';

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
  final cipher = pc.GCMBlockCipher(pc.AESEngine())
    ..init(true, pc.AEADParameters(pc.KeyParameter(key), 128, iv, Uint8List(0)));
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

  late E2eClient alice;
  late E2eClient bob;
  late int conversationId;

  /// Runs a dynamic sweep over EVERY text-typed column of EVERY table in the
  /// `public` schema looking for [literal].
  ///
  /// Returns `(hits, columnsScanned)`. The scanned count is returned on
  /// purpose: a sweep that silently scanned nothing would "find no plaintext"
  /// and prove absolutely nothing, so the tests assert on it.
  Future<(List<List<String>>, int)> sweepDatabaseFor(String literal) async {
    // LIKE's only metacharacters are `%` and `_`. Standard base64
    // (A-Za-z0-9+/=), hex, and the hyphenated needle contain neither, and no
    // quote — so the FULL string is safe to sweep, which is a strictly
    // stronger claim than sweeping a fragment of it.
    if (!RegExp(r'^[A-Za-z0-9+/=-]+$').hasMatch(literal)) {
      throw ArgumentError('needle must be LIKE- and quote-safe: $literal');
    }
    final rows = await e2eSql('''
CREATE TEMP TABLE _proof_hits(tbl text, col text, hits bigint);
DO \$do\$
DECLARE
  r record;
  n bigint;
  scanned int := 0;
BEGIN
  FOR r IN
    SELECT table_name AS tname, column_name AS cname
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND data_type IN ('text', 'character varying', 'character',
                         'json', 'jsonb', 'uuid')
     ORDER BY table_name, column_name
  LOOP
    scanned := scanned + 1;
    EXECUTE format(
      'SELECT count(*) FROM public.%I WHERE %I::text LIKE %L',
      r.tname, r.cname, '%$literal%'
    ) INTO n;
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

  /// The longest run of `[A-Za-z0-9]` inside [s].
  ///
  /// Only needed for the username control: harness usernames contain `_`,
  /// which IS a LIKE metacharacter (any single character). Key material is
  /// base64 and gets swept in full — see [sweepDatabaseFor].
  String longestAlnumRun(String s) {
    final runs = RegExp(r'[A-Za-z0-9]+').allMatches(s).map((m) => m[0]!);
    return runs.reduce((a, b) => b.length > a.length ? b : a);
  }

  /// Uploads [bytes] through the real authenticated media endpoint and
  /// returns the URL the server hands back.
  Future<String> uploadMedia(E2eClient client, Uint8List bytes) async {
    final boundary = '----umbraproof$runTag';
    final head = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="mediaType"\r\n\r\n'
      'image\r\n'
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; '
      'filename="proof.jpg"\r\n'
      'Content-Type: image/jpeg\r\n\r\n',
    );
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final http = HttpClient();
    try {
      final req = await http.postUrl(Uri.parse('$baseUrl/media/upload'));
      req.headers.set('Authorization', 'Bearer ${client.accessToken}');
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      req.add(head);
      req.add(bytes);
      req.add(tail);
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200 && res.statusCode != 201) {
        throw StateError('media upload failed ${res.statusCode}: $body');
      }
      return (jsonDecode(body) as Map<String, dynamic>)['mediaUrl'] as String;
    } finally {
      http.close(force: true);
    }
  }

  /// GETs a URL with NO credentials — the position of an outsider who has the
  /// media link. Returns the HTTP status, never throws on a refusal.
  Future<int> probeAnonymous(String url) async {
    final http = HttpClient();
    try {
      final req = await http.getUrl(Uri.parse(url));
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    } finally {
      http.close(force: true);
    }
  }

  /// GETs a URL as a signed-in participant — the best case for anyone trying
  /// to read the file, short of owning the server.
  Future<Uint8List> fetchAsUser(String url, E2eClient client) async {
    final http = HttpClient();
    try {
      final req = await http.getUrl(Uri.parse(url));
      req.headers.set('Authorization', 'Bearer ${client.accessToken}');
      final res = await req.close();
      if (res.statusCode != 200) {
        throw StateError('fetch failed ${res.statusCode} for $url');
      }
      final chunks = <int>[];
      await for (final chunk in res) {
        chunks.addAll(chunk);
      }
      return Uint8List.fromList(chunks);
    } finally {
      http.close(force: true);
    }
  }

  setUpAll(() async {
    await requireBackendUp(baseUrl);

    // ignore: invalid_use_of_visible_for_testing_member
    FlutterSecureStorage.setMockInitialValues({});
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});

    alice = E2eClient('alice', baseUrl);
    bob = E2eClient('bob', baseUrl);

    await alice.registerFresh();
    await bob.registerFresh();
    await alice.connectSocket();
    await bob.connectSocket();
    await alice.initializeAndUploadKeys();
    await bob.initializeAndUploadKeys();

    // Friendship, so a conversation exists.
    alice.socketService.sendFriendRequest(bob.userId);
    final request =
        await bob.events.next(
              'newFriendRequest',
              where: (p) =>
                  p is Map &&
                  p['sender'] is Map &&
                  (p['sender'] as Map)['id'] == alice.userId,
              reason: 'bob receives the invite',
            )
            as Map;
    bob.socketService.acceptFriendRequest(request['id'] as int);
    final accepted =
        await alice.events.next('friendRequestAccepted', reason: 'accept')
            as Map;
    conversationId = accepted['conversationId'] as int;

    // X3DH: alice fetches bob's PUBLIC bundle and builds a Signal session.
    final bundle = await alice.fetchBundleFor(bob.userId);
    await alice.encryption.buildSession(
      bob.userId,
      bundle,
      expectedIdentityBase64: null,
    );

    rule('SETUP');
    say('backend under test      : $baseUrl');
    say('alice userId            : ${alice.userId} (${alice.username})');
    say('bob   userId            : ${bob.userId} (${bob.username})');
    say('conversationId          : $conversationId');
    say('bob PUBLIC bundle the server served alice:');
    say('  identityPublicKey     : ${preview(bundle['identityPublicKey'] as String)}');
    say('  signedPreKeyPublic    : ${preview(bundle['signedPreKeyPublic'] as String)}');
    say('  oneTimePreKeyId       : ${bundle['oneTimePreKeyId']}');
    say('Note: every field above is a PUBLIC key half. That is all the server');
    say('has ever been given.');
  });

  tearDownAll(() {
    alice.dispose();
    bob.dispose();
  });

  group('E2E proof', () {
    late int messageId;
    late String wireCiphertext;

    test('1. one message, fully disclosed: plaintext vs. what the server got', () async {
      rule('1. ONE MESSAGE, FULLY DISCLOSED');

      // The exact plaintext JSON the app hands to libsignal.
      final envelopeJson = jsonEncode(E2eEnvelope.build(needle));
      say('Alice types            : $needle');
      say('App builds envelope    : $envelopeJson');

      wireCiphertext = await alice.encryption.encrypt(bob.userId, envelopeJson);
      say('libsignal produces     : ${preview(wireCiphertext, head: 96)}');

      final sent = await alice.sendEncrypted(
        bob.userId,
        wireCiphertext,
        tempId: 'proof-1-$runTag',
      );
      messageId = sent['id'] as int;
      say('server acks message id : $messageId');

      // --- what the database actually holds -----------------------------
      final rows = await e2eSql('''
SELECT "id", "content", coalesce("encryptedContent", '<NULL>'),
       "messageType", coalesce("mediaUrl", '<NULL>'),
       "sender_id", "conversation_id", "createdAt"
  FROM public.messages WHERE "id" = $messageId;
''');
      expect(rows, hasLength(1), reason: 'the row must exist');
      final row = rows.single;
      rule('WHAT THE SERVER STORED FOR MESSAGE $messageId');
      say('messages.id            : ${row[0]}');
      say('messages.content       : ${row[1]}');
      say('messages.encryptedContent: ${preview(row[2], head: 96)}');
      say('messages.messageType   : ${row[3]}');
      say('messages.mediaUrl      : ${row[4]}');
      say('messages.sender_id     : ${row[5]}   <- metadata, NOT hidden');
      say('messages.conversation_id: ${row[6]}  <- metadata, NOT hidden');
      say('messages.createdAt     : ${row[7]}   <- metadata, NOT hidden');

      expect(
        row[1],
        '[encrypted]',
        reason: 'the readable column holds a literal placeholder, never text',
      );
      expect(
        row[2],
        wireCiphertext,
        reason: 'what the server stored is byte-identical to the ciphertext '
            'libsignal produced on the client',
      );
      expect(
        row[2],
        matches(RegExp(r'^\d+:[A-Za-z0-9+/]+=*$')),
        reason: 'Signal wire format "{type}:{base64}"',
      );

      // The ciphertext is not a reversible encoding of the plaintext.
      final rawBytes = base64Decode(
        wireCiphertext.substring(wireCiphertext.indexOf(':') + 1),
      );
      final asLatin1 = String.fromCharCodes(rawBytes);
      expect(
        asLatin1.contains(needle),
        isFalse,
        reason: 'decoding the base64 must not reveal the plaintext',
      );
      say('');
      say('base64-decoded ciphertext is ${rawBytes.length} bytes of noise;');
      say('it does NOT contain the sentence Alice typed.');

      // --- and the recipient can still read it ---------------------------
      final received = await bob.awaitNewMessage('proof-1-$runTag');
      final decrypted = await bob.decryptText(
        alice.userId,
        received['encryptedContent'] as String,
      );
      expect(decrypted, needle);
      say('');
      say('Bob decrypts it back to: $decrypted');
      say('So this is encryption, not deletion: the ONLY parties who can read');
      say('it are the two devices holding the Signal session.');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('2. the plaintext is in ZERO columns of the entire database', () async {
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
        say('as ${entry.key.padRight(13)} -> '
            '${hits.isEmpty ? 'NOT FOUND' : 'FOUND'} '
            '(${entry.value.length} chars, $n columns scanned)');
        for (final h in hits) {
          say('    HIT -> ${h[0]}.${h[1]} x${h[2]}');
        }
        expect(
          hits,
          isEmpty,
          reason: 'the sentence Alice typed must not exist anywhere in the '
              'database, in any encoding (${entry.key})',
        );
      }

      expect(
        scanned,
        greaterThan(50),
        reason: 'the sweep must actually have scanned the schema; a sweep of '
            'nothing would find nothing and prove nothing',
      );

      // Control: the sweep is capable of finding things. Without this the
      // "no hits" result above could just mean the query is broken.
      final controlNeedle = longestAlnumRun(alice.username);
      final (controlHits, _) = await sweepDatabaseFor(controlNeedle);
      say('');
      say('CONTROL — sweeping for a run of alice\'s USERNAME '
          '("$controlNeedle" out of "${alice.username}"):');
      for (final h in controlHits) {
        say('HIT -> ${h[0]}.${h[1]} x${h[2]}');
      }
      expect(
        controlHits,
        isNotEmpty,
        reason: 'the sweep finds a string that IS in the database, so the '
            'empty result for the message plaintext is a real negative',
      );
      say('The sweep works. The message plaintext is simply not there.');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('3. the private keys are not on the server either', () async {
      rule('3. WHERE THE KEYS LIVE');

      final bobPair = await bob.encryption.identityKeyPairForLinking();
      final bobPrivate = base64Encode(bobPair.getPrivateKey().serialize());
      final bobPublic = base64Encode(bobPair.getPublicKey().serialize());

      final stored = await e2eSql('''
SELECT "userId", "deviceId", "identityPublicKey"
  FROM public.key_bundles WHERE "userId" = ${bob.userId};
''');
      expect(stored, isNotEmpty);
      say('key_bundles row for bob: userId=${stored.first[0]} '
          'deviceId=${stored.first[1]}');
      say('  stored identityPublicKey: ${preview(stored.first[2])}');
      say('  bob\'s real PUBLIC key   : ${preview(bobPublic)}');
      expect(
        stored.first[2],
        bobPublic,
        reason: 'the server holds exactly the PUBLIC half',
      );

      // The WHOLE key, not a fragment: base64 contains no LIKE metacharacter
      // (`%`, `_`) and no quote, so the entire string is a safe pattern.
      say('');
      say('bob\'s PRIVATE identity key : ${preview(bobPrivate)}');
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
        reason: 'the public half IS on the server, so the sweep can see key '
            'material when it is there',
      );
      say('Not present. The server was never given it, so there is no key on');
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
      say('columns whose NAME suggests private material: '
          '${suspicious.isEmpty ? 'none' : suspicious.map((r) => r[0]).join(', ')}');
      expect(suspicious, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('4. census: every message row in the database is ciphertext', () async {
      rule('4. CENSUS OVER EVERY MESSAGE IN THIS DATABASE');

      final census = await e2eSql('''
SELECT count(*),
       count(*) FILTER (WHERE "content" = '[encrypted]'),
       count(*) FILTER (WHERE "content" <> '[encrypted]'),
       count(*) FILTER (WHERE "encryptedContent" IS NOT NULL
                          AND "encryptedContent" !~ '^[0-9]+:[A-Za-z0-9+/]+=*\$')
  FROM public.messages;
''');
      final total = int.parse(census.single[0]);
      final encrypted = int.parse(census.single[1]);
      final readable = int.parse(census.single[2]);
      final malformed = int.parse(census.single[3]);

      say('messages total                        : $total');
      say('  content = "[encrypted]"             : $encrypted');
      say('  content = anything else (READABLE!) : $readable');
      say('  encryptedContent not Signal-shaped  : $malformed');

      final envelopes = await e2eSql('''
SELECT count(*),
       count(*) FILTER (WHERE "ciphertext" ~ '^[0-9]+:[A-Za-z0-9+/]+=*\$')
  FROM public.message_envelopes;
''');
      say('message_envelopes total               : ${envelopes.single[0]}');
      say('  Signal-shaped ciphertext            : ${envelopes.single[1]}');

      expect(total, greaterThan(0), reason: 'the census must see real rows');
      expect(
        readable,
        0,
        reason: 'not one message row in this database holds readable text',
      );
      expect(malformed, 0);
      expect(envelopes.single[0], envelopes.single[1]);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('5. a picture: the server stores and serves ciphertext bytes', () async {
      rule('5. MEDIA');

      // Stand in for a photo: bytes a human would recognise instantly.
      final plainBytes = Uint8List.fromList(
        utf8.encode('$mediaNeedle ${'.' * 400}'),
      );
      final encrypted = encryptLikeTheApp(plainBytes);
      say('original bytes          : ${plainBytes.length} B, '
          'starting "$mediaNeedle"');
      say('AES-256-GCM ciphertext  : ${encrypted.ciphertext.length} B');
      say('media key (client-side) : ${preview(encrypted.keyBase64)}');

      final mediaUrl = await uploadMedia(alice, encrypted.ciphertext);
      say('server stored it at     : $mediaUrl');

      // First: an outsider holding the link.
      final anonStatus = await probeAnonymous(mediaUrl);
      say('GET with no credentials : HTTP $anonStatus');
      expect(
        anonStatus,
        isNot(200),
        reason: 'the media endpoint must not serve strangers',
      );

      // What the server hands back when asked for that file.
      final served = await fetchAsUser(mediaUrl, alice);
      say('server serves back      : ${served.length} B');
      expect(
        served,
        orderedEquals(encrypted.ciphertext),
        reason: 'the server serves exactly the ciphertext it was handed — it '
            'never had anything else',
      );
      expect(
        String.fromCharCodes(served).contains(mediaNeedle),
        isFalse,
        reason: 'what comes off the server is not the picture',
      );
      say('Those bytes do NOT contain the content: the server stored an');
      say('opaque blob and gave the same opaque blob back.');

      // The key rides INSIDE the Signal-encrypted envelope, so it never
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

      // Send it the way the app does: the ciphertext plus the metadata the
      // server legitimately needs (type, media URL). Those two DO become
      // columns — that is exactly the metadata boundary being disclosed here.
      final tempId = 'proof-media-$runTag';
      alice.socketService.sendMessage(
        bob.userId,
        '[encrypted]',
        tempId: tempId,
        encryptedContent: ct,
        messageType: 'IMAGE',
        mediaUrl: mediaUrl,
      );
      final sent =
          await alice.events.next(
                'messageSent',
                where: (p) => p is Map && p['tempId'] == tempId,
                reason: 'image send ack',
              )
              as Map;
      final mediaMessageId = sent['id'] as int;
      say('');
      say('image message id        : $mediaMessageId');

      final stored = await e2eSql('''
SELECT "content", coalesce("mediaUrl", '<NULL>'), "messageType"
  FROM public.messages WHERE "id" = $mediaMessageId;
''');
      say('messages.content        : ${stored.single[0]}      <- no content');
      say('messages.mediaUrl       : ${stored.single[1]}');
      say('messages.messageType    : ${stored.single[2]}   <- METADATA the '
          'server does see');

      // The media key must not be anywhere in the database — full string.
      final (keyHits, scanned) = await sweepDatabaseFor(encrypted.keyBase64);
      say('swept $scanned columns for the media key, in full');
      for (final h in keyHits) {
        say('HIT -> ${h[0]}.${h[1]} x${h[2]}');
      }
      expect(scanned, greaterThan(50));
      expect(keyHits, isEmpty, reason: 'the media key is not a column');
      say('The key that opens that file is in no column of the database. It');
      say('exists only inside the Signal ciphertext of the message.');

      // And the recipient can open the picture.
      final receivedMessage = await bob.awaitNewMessage('proof-media-$runTag');
      final receivedJson = await bob.encryption.decrypt(
        alice.userId,
        receivedMessage['encryptedContent'] as String,
      );
      final env = E2eEnvelope.parse(receivedJson);
      final reopened = decryptLikeTheApp(served, env.mediaKey!, env.mediaIv!);
      expect(reopened, orderedEquals(plainBytes));
      say('');
      say('Bob pulls the same ciphertext, takes key+IV out of the DECRYPTED');
      say('envelope, and recovers the original bytes exactly.');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
