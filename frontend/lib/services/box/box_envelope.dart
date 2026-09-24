import 'dart:convert';

import '../../utils/e2e_envelope.dart';
import 'box_frame.dart';

/// Room a box envelope leaves for Signal around it: a real PreKey message
/// measured 148 B over its plaintext (header, MAC, CBC padding); doubled.
const int kBoxSignalReserveBytes = 256;

/// The most envelope bytes one box frame carries.
const int kBoxEnvelopeMaxBytes =
    BoxFrame.maxSignalBytes - kBoxSignalReserveBytes;

/// The E2E envelope a box send seals (metadata-privacy PR3.1 slice (c)),
/// with the link preview it actually carries.
///
/// The composer bounds the user's TEXT to one frame
/// (`AppConstants.maxEnvelopeBytes`); a link preview is not the user's text
/// and has no bound (a native og:title comes from up to 100 KB of HTML), so
/// when the whole envelope would not fit one frame the preview is dropped —
/// the text is never truncated, and a message the composer accepted is
/// never refused for its preview.
({String json, Map<String, String?>? linkPreview}) boxEnvelope(
  String content, {
  required Map<String, dynamic> senderListInfo,
  required String msgId,
  required DateTime sentAt,
  Map<String, String?>? linkPreview,
}) {
  String build(Map<String, String?>? preview) => jsonEncode(
    E2eEnvelope.build(
      content,
      linkPreview: preview,
      senderListInfo: senderListInfo,
      msgId: msgId,
      sentAt: sentAt,
    ),
  );
  final json = build(linkPreview);
  if (linkPreview == null || utf8.encode(json).length <= kBoxEnvelopeMaxBytes) {
    return (json: json, linkPreview: linkPreview);
  }
  return (json: build(null), linkPreview: null);
}
