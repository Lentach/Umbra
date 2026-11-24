import 'dart:js_interop';

@JS('document.title')
external set _docTitleJS(JSString v);

@JS('fetch')
external JSPromise<JSAny?> _fetch(JSString url);

/// Publishes to `document.title` AND fires a beacon request whose path
/// carries the payload — it lands in the static server's access log, which
/// works even when the page cannot be polled (headful runs).
void publishResult(String v) {
  _docTitleJS = v.toJS;
  try {
    _fetch(
      Uri(path: '/bench_result', queryParameters: {'d': v}).toString().toJS,
    );
  } catch (_) {}
}
