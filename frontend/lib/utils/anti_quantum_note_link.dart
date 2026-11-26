import 'dart:convert';
import 'dart:typed_data';

import '../config/app_config.dart';

/// Detection + parsing for Anti-Quantum Note links:
/// `<baseUrl>/note/<32-hex>#<b64url key>[&c=<convId>][&e=<expiry epoch ms>]`
///
/// The whole trimmed message must be exactly ONE own-origin note URL — the
/// banner replaces the bubble body, so a URL embedded in prose stays a plain
/// link. Host is pinned to [AppConfig.baseUrl]: a foreign host must never
/// wear the trusted note banner.
///
/// `c`/`e` live in the FRAGMENT on purpose: fragments are never transmitted
/// in HTTP requests, so the server learns neither the conversation id nor
/// anything it does not already know. `c` powers the reveal page's
/// "Open Umbra" deep link (`/?notify_conv=<c>`); `e` powers the in-chat
/// self-destruct countdown without any server round trip.
final RegExp _noteUrlTail =
    RegExp(r'^[0-9a-f]{32}#[A-Za-z0-9_-]+=*(&[ce]=\d+)*$');

bool isAntiQuantumNoteUrl(String content, {String? baseUrl}) {
  final trimmed = content.trim();
  final prefix = '${baseUrl ?? AppConfig.baseUrl}/note/';
  if (!trimmed.startsWith(prefix)) return false;
  return _noteUrlTail.hasMatch(trimmed.substring(prefix.length));
}

/// The canonical production origin. A dev/preview build (BASE_URL pointing at
/// localhost or a LAN IP) can still receive a link minted by the production
/// app; that link is OURS and must reveal in-app rather than bounce through
/// an external tab.
const String kFireplaceProductionOrigin = 'https://fireplace.ignorelist.com';

/// Own-origin = this build's [AppConfig.baseUrl] OR the production origin.
/// Anything else is a foreign link and keeps the external-launch fallback.
bool isOwnOriginNoteUrl(String content, {String? baseUrl}) =>
    isAntiQuantumNoteUrl(content, baseUrl: baseUrl) ||
    isAntiQuantumNoteUrl(content, baseUrl: kFireplaceProductionOrigin);

/// Decode the AES-256 key from a note URL's fragment. The key is the first
/// `&`-segment of the fragment, base64url-encoded (Dart's decoder also accepts
/// the standard alphabet, mirroring the reveal page's `-`/`_` translation).
///
/// Returns null unless it decodes to EXACTLY 32 bytes — the same pre-flight
/// check the server landing page runs BEFORE its destructive reveal POST, so
/// a mangled or truncated fragment can never burn the note.
Uint8List? decodeAntiQuantumNoteKey(String url) {
  final hashIndex = url.indexOf('#');
  if (hashIndex < 0 || hashIndex + 1 >= url.length) return null;
  final fragment = url.substring(hashIndex + 1).split('&').first;
  if (fragment.isEmpty) return null;
  try {
    final bytes = base64Url.decode(base64Url.normalize(fragment));
    return bytes.length == 32 ? bytes : null;
  } on FormatException {
    return null;
  }
}

class AntiQuantumNoteLink {
  final String url;

  /// 32-hex server token (the `/note/<token>` path segment) — the id the
  /// status endpoint takes. Never contains the key: that stays in the
  /// fragment.
  final String token;

  /// Server-side note death moment, from the `e` fragment param.
  /// Null for links sent before the countdown feature existed.
  final DateTime? expiresAt;

  const AntiQuantumNoteLink({
    required this.url,
    required this.token,
    this.expiresAt,
  });

  /// The origin the note lives on — where reveal/status calls must go. For a
  /// production link opened in a dev build this is the production origin, not
  /// this build's BASE_URL.
  String get origin => url.substring(0, url.indexOf('/note/'));
}

/// The largest epoch-ms a [DateTime] can hold.
const int _maxEpochMs = 8640000000000000;

/// Parse a note link previously accepted by [isAntiQuantumNoteUrl];
/// returns null when [content] is not a note link.
AntiQuantumNoteLink? parseAntiQuantumNoteLink(String content,
    {String? baseUrl}) {
  if (!isAntiQuantumNoteUrl(content, baseUrl: baseUrl)) return null;
  final url = content.trim();
  DateTime? expiresAt;
  final fragment = url.substring(url.indexOf('#') + 1);
  for (final part in fragment.split('&').skip(1)) {
    if (part.startsWith('e=')) {
      final ms = int.tryParse(part.substring(2));
      // DateTime throws beyond +-8.64e15 ms; a peer controls these digits, so
      // an out-of-range value reads as "no expiry" (as E2eEnvelope does).
      if (ms != null && ms <= _maxEpochMs) {
        expiresAt = DateTime.fromMillisecondsSinceEpoch(ms);
      }
    }
  }
  final hashIndex = url.indexOf('#');
  final token = url.substring(hashIndex - 32, hashIndex);
  return AntiQuantumNoteLink(url: url, token: token, expiresAt: expiresAt);
}

/// Parse a note link against this build's [AppConfig.baseUrl] first, then the
/// production origin. Returns null for foreign-origin URLs.
AntiQuantumNoteLink? parseOwnOriginNoteLink(String content, {String? baseUrl}) =>
    parseAntiQuantumNoteLink(content, baseUrl: baseUrl) ??
    parseAntiQuantumNoteLink(content, baseUrl: kFireplaceProductionOrigin);
