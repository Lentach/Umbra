/// Native/non-web no-op: persistent storage is not a browser concern here.
Future<Map<String, bool>> requestPersistentStorage() async =>
    const {'supported': false, 'granted': false};
