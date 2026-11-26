import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/config/app_config.dart';
import 'package:fireplace/utils/anti_quantum_note_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const baseUrl = 'https://fireplace.example.com';
  const hex = '0123456789abcdef0123456789abcdef'; // 32 lowercase hex chars
  const url = '$baseUrl/note/$hex#abcABC012_-';

  group('isAntiQuantumNoteUrl', () {
    test('accepts an exact own-origin note URL', () {
      expect(isAntiQuantumNoteUrl(url, baseUrl: baseUrl), isTrue);
    });

    test('accepts a fragment key with = padding', () {
      expect(
        isAntiQuantumNoteUrl('$baseUrl/note/$hex#abc=', baseUrl: baseUrl),
        isTrue,
      );
      expect(
        isAntiQuantumNoteUrl('$baseUrl/note/$hex#abc==', baseUrl: baseUrl),
        isTrue,
      );
    });

    test('accepts a URL with surrounding whitespace (trimmed)', () {
      expect(
        isAntiQuantumNoteUrl('  \n\t$url  \n', baseUrl: baseUrl),
        isTrue,
      );
    });

    test('rejects a URL embedded in prose', () {
      expect(
        isAntiQuantumNoteUrl('check this $url out', baseUrl: baseUrl),
        isFalse,
      );
    });

    test('rejects a foreign host', () {
      expect(
        isAntiQuantumNoteUrl(
          'https://evil.example.org/note/$hex#abc',
          baseUrl: baseUrl,
        ),
        isFalse,
      );
    });

    test('rejects a note URL missing the key fragment', () {
      expect(
        isAntiQuantumNoteUrl('$baseUrl/note/$hex', baseUrl: baseUrl),
        isFalse,
      );
      expect(
        isAntiQuantumNoteUrl('$baseUrl/note/$hex#', baseUrl: baseUrl),
        isFalse,
      );
    });

    test('rejects a token of the wrong length (31 or 33 hex chars)', () {
      const hex31 = '0123456789abcdef0123456789abcde'; // 31 chars
      const hex33 = '0123456789abcdef0123456789abcdef0'; // 33 chars
      expect(
        isAntiQuantumNoteUrl('$baseUrl/note/$hex31#abc', baseUrl: baseUrl),
        isFalse,
      );
      expect(
        isAntiQuantumNoteUrl('$baseUrl/note/$hex33#abc', baseUrl: baseUrl),
        isFalse,
      );
    });

    test('rejects an uppercase-hex token', () {
      const upper = '0123456789ABCDEF0123456789ABCDEF';
      expect(
        isAntiQuantumNoteUrl('$baseUrl/note/$upper#abc', baseUrl: baseUrl),
        isFalse,
      );
    });

    test('rejects trailing characters after the fragment', () {
      expect(
        isAntiQuantumNoteUrl('$url trailing', baseUrl: baseUrl),
        isFalse,
      );
      expect(
        isAntiQuantumNoteUrl('$url/more', baseUrl: baseUrl),
        isFalse,
      );
    });

    test('accepts a fragment with a c= conversation param', () {
      expect(
        isAntiQuantumNoteUrl('$baseUrl/note/$hex#abcABC012_-&c=12',
            baseUrl: baseUrl),
        isTrue,
      );
    });

    test('accepts a fragment with an e= expiry param', () {
      expect(
        isAntiQuantumNoteUrl('$baseUrl/note/$hex#abcABC012_-&e=1720000000000',
            baseUrl: baseUrl),
        isTrue,
      );
    });

    test('accepts a fragment with both c= and e= params', () {
      expect(
        isAntiQuantumNoteUrl(
            '$baseUrl/note/$hex#abcABC012_-&c=12&e=1720000000000',
            baseUrl: baseUrl),
        isTrue,
      );
    });

    test('rejects an unknown fragment param', () {
      expect(
        isAntiQuantumNoteUrl('$baseUrl/note/$hex#abc&x=1', baseUrl: baseUrl),
        isFalse,
      );
    });

    test('rejects a non-numeric c= value', () {
      expect(
        isAntiQuantumNoteUrl('$baseUrl/note/$hex#abc&c=abc', baseUrl: baseUrl),
        isFalse,
      );
    });

    test('rejects a bare trailing ampersand', () {
      expect(
        isAntiQuantumNoteUrl('$baseUrl/note/$hex#abc&', baseUrl: baseUrl),
        isFalse,
      );
    });
  });

  group('parseAntiQuantumNoteLink', () {
    test('returns null for non-note content', () {
      expect(parseAntiQuantumNoteLink('just some text', baseUrl: baseUrl),
          isNull);
      expect(
        parseAntiQuantumNoteLink('https://evil.example.org/note/$hex#abc',
            baseUrl: baseUrl),
        isNull,
      );
    });

    test('parses a note link with no expiry into a null expiresAt', () {
      final link = parseAntiQuantumNoteLink(url, baseUrl: baseUrl);
      expect(link, isNotNull);
      expect(link!.url, url);
      expect(link.token, hex);
      expect(link.expiresAt, isNull);
    });

    test('extracts the 32-hex server token regardless of fragment params', () {
      const ms = 1720000000000;
      final noteUrl = '$baseUrl/note/$hex#abcABC012_-&c=42&e=$ms';
      final link = parseAntiQuantumNoteLink(noteUrl, baseUrl: baseUrl);
      expect(link, isNotNull);
      expect(link!.token, hex);
    });

    test('parses the e= param into expiresAt (epoch ms)', () {
      const ms = 1720000000000;
      final noteUrl = '$baseUrl/note/$hex#abcABC012_-&e=$ms';
      final link = parseAntiQuantumNoteLink(noteUrl, baseUrl: baseUrl);
      expect(link, isNotNull);
      expect(link!.url, noteUrl);
      expect(link.expiresAt, DateTime.fromMillisecondsSinceEpoch(ms));
    });

    // A3-UTL-02: a friend's link can carry any digits after e=; a value outside
    // DateTime's range must read as "no expiry", not throw into the bubble.
    test('an e= beyond the DateTime range is ignored, not thrown', () {
      for (final huge in ['9000000000000000', '99999999999999999999']) {
        final noteUrl = '$baseUrl/note/$hex#abcABC012_-&e=$huge';
        final link = parseAntiQuantumNoteLink(noteUrl, baseUrl: baseUrl);
        expect(link, isNotNull, reason: huge);
        expect(link!.expiresAt, isNull, reason: huge);
        expect(link.token, hex);
      }
    });

    test('ignores c= and only reads e= for expiresAt', () {
      const ms = 1720000000000;
      final noteUrl = '$baseUrl/note/$hex#abcABC012_-&c=42&e=$ms';
      final link = parseAntiQuantumNoteLink(noteUrl, baseUrl: baseUrl);
      expect(link, isNotNull);
      expect(link!.expiresAt, DateTime.fromMillisecondsSinceEpoch(ms));
    });

    test('trims surrounding whitespace before parsing', () {
      const ms = 1720000000000;
      final noteUrl = '$baseUrl/note/$hex#abcABC012_-&e=$ms';
      final link = parseAntiQuantumNoteLink('  $noteUrl \n', baseUrl: baseUrl);
      expect(link, isNotNull);
      expect(link!.url, noteUrl);
      expect(link.expiresAt, DateTime.fromMillisecondsSinceEpoch(ms));
    });
  });

  group('own-origin detection', () {
    // In the test VM AppConfig.baseUrl resolves from Uri.base (no BASE_URL
    // dart-define), so build-origin URLs must be constructed from it.
    final buildUrl = '${AppConfig.baseUrl}/note/$hex#abcABC012_-';
    const prodUrl = '$kFireplaceProductionOrigin/note/$hex#abcABC012_-';

    test('accepts a note URL on this build\'s BASE_URL', () {
      expect(isOwnOriginNoteUrl(buildUrl), isTrue);
      expect(parseOwnOriginNoteLink(buildUrl), isNotNull);
    });

    test('accepts a production-origin URL even when the build origin differs',
        () {
      expect(isOwnOriginNoteUrl(prodUrl), isTrue);
      final link = parseOwnOriginNoteLink(prodUrl);
      expect(link, isNotNull);
      expect(link!.origin, kFireplaceProductionOrigin);
      expect(link.token, hex);
    });

    test('rejects a foreign origin: it must never wear the trusted banner',
        () {
      const foreign = 'https://evil.example.org/note/$hex#abcABC012_-';
      expect(isOwnOriginNoteUrl(foreign), isFalse);
      expect(parseOwnOriginNoteLink(foreign), isNull);
    });

    test('rejects a lookalike host sharing the production prefix', () {
      const lookalike =
          '$kFireplaceProductionOrigin.evil.org/note/$hex#abcABC012_-';
      expect(isOwnOriginNoteUrl(lookalike), isFalse);
    });

    test('origin getter points reveal calls at the note\'s own host', () {
      final link = parseOwnOriginNoteLink(buildUrl);
      expect(link, isNotNull);
      expect(link!.origin, AppConfig.baseUrl);
    });
  });

  group('decodeAntiQuantumNoteKey', () {
    final keyBytes = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));

    test('round-trips a base64url 32-byte key', () {
      final url = '$baseUrl/note/$hex#${base64Url.encode(keyBytes)}';
      expect(decodeAntiQuantumNoteKey(url), keyBytes);
    });

    test('reads only the first &-segment: c=/e= params never corrupt the key',
        () {
      final url =
          '$baseUrl/note/$hex#${base64Url.encode(keyBytes)}&c=42&e=1720000000000';
      expect(decodeAntiQuantumNoteKey(url), keyBytes);
    });

    test('accepts an unpadded base64url fragment (normalize before decode)',
        () {
      final unpadded = base64Url.encode(keyBytes).replaceAll('=', '');
      final url = '$baseUrl/note/$hex#$unpadded';
      expect(decodeAntiQuantumNoteKey(url), keyBytes);
    });

    test('rejects a key that is not exactly 32 bytes — pre-flight burn guard',
        () {
      for (final len in [8, 31, 33]) {
        final url =
            '$baseUrl/note/$hex#${base64Url.encode(List.filled(len, 1))}';
        expect(decodeAntiQuantumNoteKey(url), isNull, reason: 'len $len');
      }
    });

    test('rejects a missing or empty fragment', () {
      expect(decodeAntiQuantumNoteKey('$baseUrl/note/$hex'), isNull);
      expect(decodeAntiQuantumNoteKey('$baseUrl/note/$hex#'), isNull);
      expect(decodeAntiQuantumNoteKey('$baseUrl/note/$hex#&e=1'), isNull);
    });

    test('rejects an undecodable fragment instead of throwing', () {
      expect(decodeAntiQuantumNoteKey('$baseUrl/note/$hex#!!not-base64!!'),
          isNull);
    });
  });
}
