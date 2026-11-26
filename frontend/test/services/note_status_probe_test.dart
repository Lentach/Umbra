import 'package:fireplace/config/app_config.dart';
import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/message/anti_quantum_note_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A3-MSG-B-04 (owner decision 2026-11-26): the note card's status poll asks
/// WITHOUT login. A request that carries the account's JWT lets a request log
/// link the account that created a note to every account that polls it.
void main() {
  const noteToken = '0123456789abcdef0123456789abcdef'; // gitleaks:allow

  late List<http.Request> seen;
  late ApiService api;

  setUp(() {
    seen = [];
    api = ApiService(
      baseUrl: 'http://t',
      httpClient: MockClient((request) async {
        seen.add(request);
        return http.Response('{"alive":true}', 200);
      }),
    );
  });

  /// Nothing that names the caller: no bearer token, no cookie.
  void expectAnonymous(http.Request request) {
    final names = request.headers.keys.map((k) => k.toLowerCase()).toSet();
    expect(names, isNot(contains('authorization')));
    expect(names, isNot(contains('cookie')));
  }

  test('ApiService.isNoteAlive is a bare GET of the status path', () async {
    final alive = await api.isNoteAlive(noteToken);

    expect(alive, isTrue);
    expect(seen, hasLength(1));
    expect(seen.single.method, 'GET');
    expect(seen.single.url.path, '/note/$noteToken/status');
    expectAnonymous(seen.single);
  });

  // The card's OWN default wiring, not a probe the test builds: no
  // `aliveProbe` is injected, the card makes its probe and its HTTP client
  // itself. A card that built an authenticated probe again would send a
  // login here (or none at all) and fail.
  testWidgets('a card with no injected probe polls the status path without '
      'any login', (tester) async {
    final asked = <http.Request>[];
    final expiry = DateTime.now()
        .add(const Duration(hours: 2))
        .millisecondsSinceEpoch;

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: RpgTheme.themeDataLight,
            home: Scaffold(
              body: AntiQuantumNoteCard(
                noteUrl:
                    '${AppConfig.baseUrl}/note/$noteToken#abcABC012_-&e=$expiry',
                isMine: false,
                textColor: Colors.black,
                isDark: false,
                maxWidth: 280,
              ),
            ),
          ),
        );
        await tester.pump();
        // The card arms a periodic timer; unmount so none is pending.
        await tester.pumpWidget(const SizedBox());
      },
      () => MockClient((request) async {
        asked.add(request);
        return http.Response('{"alive":true}', 200);
      }),
    );

    expect(asked, hasLength(1));
    expect(asked.single.method, 'GET');
    expect(asked.single.url.path, '/note/$noteToken/status');
    expectAnonymous(asked.single);
  });

  test('a note that is gone reads as not alive', () async {
    final gone = ApiService(
      baseUrl: 'http://t',
      httpClient: MockClient(
        (_) async => http.Response('{"alive":false}', 200),
      ),
    );

    expect(await gone.isNoteAlive(noteToken), isFalse);
  });

  test('an HTTP failure throws, so the card fails open', () async {
    final down = ApiService(
      baseUrl: 'http://t',
      httpClient: MockClient((_) async => http.Response('', 429)),
    );

    await expectLater(down.isNoteAlive(noteToken), throwsException);
  });
}
