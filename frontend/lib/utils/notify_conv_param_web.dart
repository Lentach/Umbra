import 'package:web/web.dart' as web;

/// Read `?notify_conv=<id>` from the current URL.
/// Returns the conversation ID as an int, or null if absent/invalid.
/// Called once at app start before [runApp].
int? consumeNotifyConvParam() {
  final raw = Uri.base.queryParameters['notify_conv'];
  if (raw == null) return null;
  return int.tryParse(raw);
}

/// [uri] without its `notify_conv` parameter, as the address-bar string.
///
/// `Uri.replace(queryParameters: null)` KEEPS the old query, so when nothing
/// is left the URI is rebuilt without one instead.
String notifyConvStrippedUrl(Uri uri) {
  final params = Map<String, String>.from(uri.queryParameters)
    ..remove('notify_conv');
  if (params.isNotEmpty) return uri.replace(queryParameters: params).toString();
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
    host: uri.host.isEmpty ? null : uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    fragment: uri.fragment.isEmpty ? null : uri.fragment,
  ).toString();
}

/// Strip `?notify_conv=<id>` from the address bar so a manual page refresh
/// does not re-trigger the deep-link navigation.
void stripNotifyConvParam() {
  if (!Uri.base.queryParameters.containsKey('notify_conv')) return;
  web.window.history.replaceState(null, '', notifyConvStrippedUrl(Uri.base));
}
