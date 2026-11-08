import 'dart:typed_data';

import '../api_service.dart';

/// The bytes of this account's own LEGACY server photo, for decision 138's
/// one-time migration (release A only; release B deletes this file with the
/// server's avatar route).
///
/// Asks the server for the profile (`GET /users/me` `profilePictureUrl`) —
/// never the auth session's cached copy, which is rebuilt from token claims
/// when the profile fetch failed at boot and would read as "no photo". Null
/// means settled: the account has no server photo, or the server no longer
/// holds the file. Anything that fails (no answer, a 5xx) THROWS: nothing was
/// decided, and the caller asks again later.
Future<Uint8List?> fetchLegacyOwnPhoto(ApiService api, String token) async {
  final me = await api.fetchMe(token);
  final path = me['profilePictureUrl'];
  if (path is! String || path.trim().isEmpty) return null;
  final url = path.startsWith('http://') || path.startsWith('https://')
      ? path
      : '${api.baseUrl}$path';
  return api.fetchLegacyAvatarBytes(url);
}
