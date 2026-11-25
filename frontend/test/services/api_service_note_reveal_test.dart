import 'package:fireplace/services/api_exception.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _token = 'not-a-real-note-token';

ApiService _api(int status, [String body = '{}']) => ApiService(
      baseUrl: 'http://localhost:3999',
      httpClient: MockClient((_) async => http.Response(body, status)),
    );

void main() {
  group('revealSecretNote keeps the HTTP status of a failed answer', () {
    for (final status in [429, 500, 502, 503]) {
      test('$status throws an ApiException carrying $status', () async {
        await expectLater(
          _api(status).revealSecretNote(_token),
          throwsA(
            isA<ApiException>().having(
              (e) => e.statusCode,
              'statusCode',
              status,
            ),
          ),
        );
      });
    }

    test('404 is still "gone" (null), not an error', () async {
      expect(await _api(404).revealSecretNote(_token), isNull);
    });

    test('200 returns the ciphertext', () async {
      expect(
        await _api(200, '{"ciphertext":"aXY=:Y3Q="}').revealSecretNote(_token),
        'aXY=:Y3Q=',
      );
    });
  });
}
