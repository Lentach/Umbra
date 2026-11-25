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
