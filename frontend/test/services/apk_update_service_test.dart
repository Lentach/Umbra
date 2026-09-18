import 'dart:convert';

import 'package:fireplace/config/app_version_info.dart';
import 'package:fireplace/services/apk_update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Installed build. `buildNumber` is the Android versionCode.
void installed(String buildNumber) {
  AppVersionInfo.debugResetForTest();
  PackageInfo.setMockInitialValues(
    appName: 'fireplace',
    packageName: 'com.fireplace.app',
    version: '0.2.49',
    buildNumber: buildNumber,
    buildSignature: '',
  );
}

http.Client serving(Object? body, {int status = 200}) =>
    MockClient((_) async => http.Response(jsonEncode(body), status));

Map<String, Object?> payload(Object? android) => {
  'version': '0.2.50',
  'gitCommit': 'd37e2dcc',
  'buildTime': '',
  'android': android,
};

ApkUpdateService build(
  http.Client client, {
  int? dismissed,
  bool isAndroid = true,
  void Function(int)? onDismiss,
}) => ApkUpdateService(
  client: client,
  baseUrl: 'https://example.invalid',
  isAndroid: isAndroid,
  readDismissed: () async => dismissed,
  writeDismissed: (code) async => onDismiss?.call(code),
);

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  setUp(() => installed('20049'));

  test('offers a build whose versionCode is higher than the installed one', () async {
    final service = build(
      serving(
        payload({
          'versionCode': 20050,
          'versionName': '0.2.50',
          'url': 'https://example.invalid/umbra-0.2.50.apk',
        }),
      ),
    );

    expect(
      await service.check(),
      (
        versionCode: 20050,
        versionName: '0.2.50',
        url: 'https://example.invalid/umbra-0.2.50.apk',
      ),
    );
  });

  test('stays silent when the published build is the installed one', () async {
    final service = build(
      serving(
        payload({
          'versionCode': 20049,
          'versionName': '0.2.49',
          'url': 'https://example.invalid/a.apk',
        }),
      ),
    );

    expect(await service.check(), isNull);
  });

  // The web tier deploys on its own: 0.2.50 shipped a web-only boot loader.
  // Reading the channel off the served semver would nag every APK user.
  test('ignores the web tier version beside the channel', () async {
    final service = build(serving(payload(null)));

    expect(await service.check(), isNull);
  });

  test('stays silent once the user dismissed that exact build', () async {
    final service = build(
      serving(
        payload({
          'versionCode': 20050,
          'versionName': '0.2.50',
          'url': 'https://example.invalid/a.apk',
        }),
      ),
      dismissed: 20050,
    );

    expect(await service.check(), isNull);
  });

  test('offers again when a build newer than the dismissed one appears', () async {
    final service = build(
      serving(
        payload({
          'versionCode': 20051,
          'versionName': '0.2.51',
          'url': 'https://example.invalid/a.apk',
        }),
      ),
      dismissed: 20050,
    );

    expect((await service.check())?.versionCode, 20051);
  });

  test('never offers off Android', () async {
    final service = build(
      serving(
        payload({
          'versionCode': 20050,
          'versionName': '0.2.50',
          'url': 'https://example.invalid/a.apk',
        }),
      ),
      isAndroid: false,
    );

    expect(await service.check(), isNull);
  });

  test('swallows a network failure rather than surfacing it', () async {
    final service = build(
      MockClient((_) async => throw http.ClientException('offline')),
    );

    expect(await service.check(), isNull);
  });

  test('rejects a channel missing its download url', () async {
    final service = build(
      serving(payload({'versionCode': 20050, 'versionName': '0.2.50'})),
    );

    expect(await service.check(), isNull);
  });

  test('rejects a non-200 answer', () async {
    final service = build(
      serving(
        payload({
          'versionCode': 20050,
          'versionName': '0.2.50',
          'url': 'https://example.invalid/a.apk',
        }),
        status: 503,
      ),
    );

    expect(await service.check(), isNull);
  });

  // The banner is the ONLY surface offering the download, so a dismissal that
  // outlived the process would strand the user on "Later" until a newer build
  // shipped. A relaunch must ask again.
  test('a dismissal does not survive a cold start', () async {
    final service = ApkUpdateService(
      client: serving(
        payload({
          'versionCode': 20050,
          'versionName': '0.2.50',
          'url': 'https://example.invalid/a.apk',
        }),
      ),
      baseUrl: 'https://example.invalid',
      isAndroid: true,
      readInstalledCode: () async => 20049,
    );
    addTearDown(ApkUpdateService.debugResetDismissal);

    await service.dismiss(20050);
    expect(await service.check(), isNull, reason: 'silent within the run');

    ApkUpdateService.debugResetDismissal(); // what a relaunch does
    expect((await service.check())?.versionCode, 20050);
  });

  test('dismiss records the build the user turned down', () async {
    int? recorded;
    final service = build(
      serving(payload(null)),
      onDismiss: (code) => recorded = code,
    );

    await service.dismiss(20050);

    expect(recorded, 20050);
  });
}
