import 'package:web/web.dart' as web;

/// Frees the browser blob behind a finished recording. record_web's
/// `stop()` hands out an object URL that holds the audio in page memory
/// until it is revoked (or the page reloads).
void revokeRecordingBlobUrl(String url) => web.URL.revokeObjectURL(url);
