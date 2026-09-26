import 'dart:typed_data';

import 'box_wire.dart';

/// How a box attachment is named inside the app (item 3 / media wiring,
/// E17a): `box:<the box's 43-char base64url id>` in `MessageModel.mediaUrl`
/// and the plaintext record. Never on the wire — the envelope carries the id
/// alone as `boxMedia` — and never a URL anything fetches over HTTP: the
/// bytes come from `BoxMediaFetcher`, the key from the record.
const String kBoxMediaUrlPrefix = 'box:';

/// The in-app name of media [id] (the box's own spelling, `boxB64`).
String boxMediaUrl(String id) => '$kBoxMediaUrlPrefix$id';

/// Whether [url] names a box attachment: such a row is uploaded (it has an
/// id), and it is only ever sent over the box (decision 25).
bool isBoxMediaUrl(String? url) =>
    url != null && url.startsWith(kBoxMediaUrlPrefix);

/// The 32-byte id [url] names; null unless it is a box attachment spelled
/// canonically.
Uint8List? boxMediaIdOf(String? url) {
  if (!isBoxMediaUrl(url)) return null;
  return boxB64Decode(
    url!.substring(kBoxMediaUrlPrefix.length),
    kBoxMediaIdBytes,
  );
}
