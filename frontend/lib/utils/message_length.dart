import 'dart:convert';

import '../constants/app_constants.dart';
import 'e2e_envelope.dart';

/// True when [text] fits the sendable size budget.
///
/// Measures the ACTUAL encrypted input — the UTF-8 byte size of the JSON-encoded
/// E2E envelope — not the raw string, because JSON escaping (quotes, backslashes,
/// control chars) and multi-byte emoji/ZWJ sequences all change the encrypted
/// size. [AppConstants.maxEnvelopeBytes] is sized to one box frame, well
/// under the old path's 65536-char base64 ciphertext cap.
bool isMessageWithinByteLimit(String text) =>
    utf8.encode(jsonEncode(E2eEnvelope.build(text))).length <=
    AppConstants.maxEnvelopeBytes;
