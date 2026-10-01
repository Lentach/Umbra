/// Non-web: there is no push service worker to read the table.
Future<void> writeBoxPushNids(Map<String, int> table) async {}

/// Non-web: nothing was written.
Future<void> clearBoxPushNids() async {}
