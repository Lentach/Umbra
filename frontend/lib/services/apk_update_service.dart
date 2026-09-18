import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../config/app_version_info.dart';

/// A published APK, as advertised by `GET /version`.
///
/// `versionCode` is the Android packaging integer the installer compares;
/// `versionName` is display only.
typedef ApkRelease = ({int versionCode, String versionName, String url});

/// Key under which the last user-dismissed `versionCode` is remembered.
const String _dismissedKey = 'apk_update_dismissed_version_code';

/// Offers a newer sideloaded APK, and only when there genuinely is one.
///
/// Sideloaded installs have no store watching them: a friend runs whatever
/// they last tapped until someone tells them otherwise. This is that telling.
///
/// The channel is READ FROM `/version`'s `android` block, never from the
/// `version` field beside it. The web tier deploys independently — `0.2.50`
/// shipped a web-only boot loader with no native change — so comparing
/// against the served semver would nag every APK user for releases that have
/// no APK behind them.
///
/// Silence is the default everywhere it is not certain: on web, on iOS, when
/// the server publishes no channel, when the network fails, when the payload
/// is the wrong shape, and when the user has already dismissed this exact
/// build. The prompt exists to inform, and a wrong prompt costs more trust
/// than a missing one.
class ApkUpdateService {
  ApkUpdateService({
    http.Client? client,
    String? baseUrl,
    Future<int?> Function()? readDismissed,
    Future<void> Function(int versionCode)? writeDismissed,
    Future<int?> Function()? readInstalledCode,
    bool? isAndroid,
  }) : _client = client ?? http.Client(),
       _baseUrl = baseUrl ?? AppConfig.baseUrl,
       _readDismissed = readDismissed ?? _readDismissedFromPrefs,
       _writeDismissed = writeDismissed ?? _writeDismissedToPrefs,
       _readInstalledCode = readInstalledCode ?? _installedFromPackage,
       _isAndroid = isAndroid ?? (!kIsWeb && Platform.isAndroid);

  final http.Client _client;
  final String _baseUrl;
  final Future<int?> Function() _readDismissed;
  final Future<void> Function(int versionCode) _writeDismissed;
  final Future<int?> Function() _readInstalledCode;
  final bool _isAndroid;

  /// The release worth offering, or `null` when the user should see nothing.
  ///
  /// Never throws: every failure path is "no offer".
  Future<ApkRelease?> check() async {
    if (!_isAndroid) return null;

    final ApkRelease? published;
    try {
      published = await _fetchChannel();
    } on Exception catch (_) {
      // Offline, DNS failure, TLS failure, malformed body. An update prompt is
      // not worth surfacing a network error the user cannot act on.
      return null;
    }
    if (published == null) return null;

    final installed = await _readInstalledCode();
    // An unparsable build number means this APK cannot be compared against
    // anything; offering an "update" then is a guess.
    if (installed == null || published.versionCode <= installed) return null;

    final dismissed = await _readDismissed();
    if (dismissed != null && dismissed >= published.versionCode) return null;

    return published;
  }

  /// Silences the offer for [versionCode]. A LATER build still prompts, so
  /// dismissing once does not opt out of every future release.
  Future<void> dismiss(int versionCode) => _writeDismissed(versionCode);

  Future<ApkRelease?> _fetchChannel() async {
    final response = await _client
        .get(Uri.parse('$_baseUrl/version'))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;

    final decoded = jsonDecode(response.body);
    // One shape check for the whole record: a half-filled channel is not an
    // offer, because a prompt without a URL cannot be acted on.
    if (decoded
        case {
          'android': {
            'versionCode': final int versionCode,
            'versionName': final String versionName,
            'url': final String url,
          },
        }
        when versionCode > 0 && url.isNotEmpty) {
      return (versionCode: versionCode, versionName: versionName, url: url);
    }
    return null;
  }

  /// The installed Android versionCode. `buildNumber` is that integer on
  /// Android; anywhere else it is not a versionCode at all, which is why an
  /// unparsable value must read as "cannot compare" rather than "0".
  static Future<int?> _installedFromPackage() async =>
      int.tryParse((await AppVersionInfo.load()).buildNumber);

  static Future<int?> _readDismissedFromPrefs() async =>
      SharedPreferencesAsync().getInt(_dismissedKey);

  static Future<void> _writeDismissedToPrefs(int versionCode) =>
      SharedPreferencesAsync().setInt(_dismissedKey, versionCode);
}
