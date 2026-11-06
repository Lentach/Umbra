/// Non-web: there is no push service worker to leave the session for (the
/// native background isolate reads the token store itself).
Future<void> writeWakeSession({
  required String refresh,
  required String api,
}) async {}

/// Non-web: nothing was written.
Future<void> clearWakeSession() async {}
