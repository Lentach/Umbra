import 'dart:convert';

import '../../utils/e2e_envelope.dart';
import 'box_frame.dart';

/// Room a box envelope leaves for Signal around it: a real PreKey message
/// measured 148 B over its plaintext (header, MAC, CBC padding); doubled.
const int kBoxSignalReserveBytes = 256;

/// The most envelope bytes one box frame carries.
const int kBoxEnvelopeMaxBytes =
    BoxFrame.maxSignalBytes - kBoxSignalReserveBytes;

/// The E2E envelopes a box send seals (metadata-privacy PR3.1 slice (c)):
/// `json` for the peer's devices, `copyJson` — the same message naming the
/// peer [sentTo] — for the sender's own other devices (sibling queues part
/// B, E5), and the link preview both actually carry. Both carry the
/// message's type, its own timer [ttl] and a reply's [replyQuote] (item 3,
/// E18a/E18b).
///
/// The composer bounds the user's TEXT to one frame
/// (`AppConstants.maxEnvelopeBytes`), and the quote's snippet and the timer
/// are bounded too (E18c); a link preview is not the user's text and has no
/// bound (a native og:title comes from up to 100 KB of HTML), so when the
/// copy — the longer of the two — would not fit one frame the preview is
/// dropped from BOTH: the text, quote and timer are never dropped, a message
/// the composer accepted is never refused for its preview, and every device
/// shows the same message.
({String json, String copyJson, Map<String, String?>? linkPreview}) boxEnvelope(
  String content, {
  required Map<String, dynamic> senderListInfo,
  required String msgId,
  required DateTime sentAt,
  required int sentTo,
  Map<String, String?>? linkPreview,
  String messageType = 'TEXT',
  int? ttl,
  E2eReplyQuote? replyQuote,
}) {
  String build(Map<String, String?>? preview, {int? to}) => jsonEncode(
    E2eEnvelope.build(
      content,
      messageType: messageType,
      linkPreview: preview,
      senderListInfo: senderListInfo,
      msgId: msgId,
      sentAt: sentAt,
      sentTo: to,
      ttl: ttl,
      replyQuote: replyQuote,
    ),
  );
  final fits =
      linkPreview == null ||
      utf8.encode(build(linkPreview, to: sentTo)).length <=
          kBoxEnvelopeMaxBytes;
  final preview = fits ? linkPreview : null;
  return (
    json: build(preview),
    copyJson: build(preview, to: sentTo),
    linkPreview: preview,
  );
}
