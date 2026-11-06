import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fireplace/services/api_service.dart';

void main() {
  group('rewriteLoopbackMediaUrl', () {
    const lanBase = 'http://192.168.1.50:3000';

    test('rewrites localhost host to baseUrl host/scheme/port', () {
      expect(
        rewriteLoopbackMediaUrl(
          'http://localhost:3000/media/msgs/abc.bin',
          lanBase,
        ),
        'http://192.168.1.50:3000/media/msgs/abc.bin',
      );
    });

    test('rewrites 127.0.0.1 host too', () {
      expect(
        rewriteLoopbackMediaUrl(
          'http://127.0.0.1:3000/media/msgs/abc.bin',
          lanBase,
        ),
        'http://192.168.1.50:3000/media/msgs/abc.bin',
      );
    });

    test('rewrites to https same-origin production base', () {
      expect(
        rewriteLoopbackMediaUrl(
          'http://localhost:3000/media/msgs/voice.bin',
          'https://fireplace.example.com',
        ),
        'https://fireplace.example.com/media/msgs/voice.bin',
      );
    });

    test('leaves a non-loopback (production) host unchanged', () {
      const prod = 'https://fireplace.example.com/media/msgs/abc.bin';
      expect(rewriteLoopbackMediaUrl(prod, lanBase), prod);
    });

    test('preserves the path and query when rewriting', () {
      expect(
        rewriteLoopbackMediaUrl(
          'http://localhost:3000/media/avatars/u.jpg?v=2',
          lanBase,
        ),
        'http://192.168.1.50:3000/media/avatars/u.jpg?v=2',
      );
    });

    test('returns original url when baseUrl is malformed/empty', () {
      const url = 'http://localhost:3000/media/msgs/abc.bin';
      expect(rewriteLoopbackMediaUrl(url, ''), url);
    });
  });

  group('ApiService.fetchMediaBytes applies the loopback rewrite', () {
    test('fetches the rewritten LAN host without credentials', () async {
      late Uri requested;
      String? authHeader;
      final mock = MockClient((request) async {
        requested = request.url;
        authHeader = request.headers['Authorization'];
        return http.Response.bytes([1, 2, 3], 200);
      });

      final api = ApiService(
        baseUrl: 'http://192.168.1.50:3000',
        httpClient: mock,
      );

      final bytes = await api.fetchMediaBytes(
        'http://localhost:3000/media/avatars/u.jpg',
      );

      expect(requested.host, '192.168.1.50');
      expect(requested.port, 3000);
      expect(requested.path, '/media/avatars/u.jpg');
      expect(authHeader, isNull);
      expect(bytes, [1, 2, 3]);
    });
  });

  // Regression for H-04: the media `mediaUrl` comes from the
  // (sender-controlled, never server-validated) E2E envelope, so a malicious
  // peer must not be able to point the client at an attacker host.
  group('ApiService.fetchMediaBytes only talks to trusted hosts', () {
    const prodBase = 'https://fireplace.example.com';

    test('refuses to fetch an untrusted host and makes no request', () async {
      var requestMade = false;
      final mock = MockClient((request) async {
        requestMade = true;
        return http.Response.bytes([1, 2, 3], 200);
      });
      final api = ApiService(baseUrl: prodBase, httpClient: mock);

      await expectLater(
        api.fetchMediaBytes('https://attacker.example/media/steal.bin'),
        throwsA(isA<Exception>()),
      );
      expect(requestMade, isFalse);
    });

    test('fetches legacy Cloudinary media without credentials', () async {
      String? authHeader;
      Uri? requested;
      final mock = MockClient((request) async {
        requested = request.url;
        authHeader = request.headers['Authorization'];
        return http.Response.bytes([9], 200);
      });
      final api = ApiService(baseUrl: prodBase, httpClient: mock);

      final bytes = await api.fetchMediaBytes(
        'https://res.cloudinary.com/demo/image/upload/v1/x.jpg',
      );

      expect(requested?.host, 'res.cloudinary.com');
      expect(authHeader, isNull);
      expect(bytes, [9]);
    });

    test('fetches a same-origin avatar without credentials', () async {
      String? authHeader;
      Uri? requested;
      final mock = MockClient((request) async {
        requested = request.url;
        authHeader = request.headers['Authorization'];
        return http.Response.bytes([7], 200);
      });
      final api = ApiService(baseUrl: prodBase, httpClient: mock);

      final bytes = await api.fetchMediaBytes('$prodBase/media/avatars/u.jpg');

      expect(requested?.host, 'fireplace.example.com');
      expect(authHeader, isNull);
      expect(bytes, [7]);
    });
  });
}
