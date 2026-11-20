import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'link_preview_thumb.dart';

/// Client-side link preview fetcher.
/// Used for E2E encrypted messages where the server cannot read content.
class LinkPreviewService {
  static final _urlRegex =
      RegExp(r'https?://[^\s<>"{}|\\^`\[\]]+', caseSensitive: false);

  /// Whether [host] names this device, its network, or another address no
  /// public site lives at: loopback, private, link-local, CGNAT, unspecified,
  /// multicast and reserved IPv4; IPv6 loopback, unspecified, IPv4-mapped or
  /// -compatible, ULA, link-local and multicast; and any numeric IPv4 form
  /// other than a plain dotted quad (`2130706433`, `0x7f.1`, `0177.0.0.1`),
  /// which resolvers read as an address the dotted check never sees.
  /// A DNS name is judged by its text only: one that RESOLVES to a private
  /// address is not caught here.
  @visibleForTesting
  static bool isPrivateHost(String host) {
    var h = host.toLowerCase();
    if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
    final zone = h.indexOf('%');
    if (zone != -1) h = h.substring(0, zone);
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    if (h.isEmpty) return true;
    if (h == 'localhost' || h.endsWith('.localhost')) return true;
    if (h.contains(':')) return _isPrivateIpv6(h);
    final labels = h.split('.');
    final numeric = RegExp(r'^(0x[0-9a-f]*|\d+)$');
    if (!labels.every(numeric.hasMatch)) return false;
    final octets = <int>[];
    for (final label in labels) {
      // A hex or zero-led (octal) part, or a short form: not a plain quad.
      if (label.startsWith('0x') ||
          (label.length > 1 && label.startsWith('0'))) {
        return true;
      }
      octets.add(int.parse(label));
    }
    if (octets.length != 4 || octets.any((o) => o > 255)) return true;
    return _isPrivateIpv4(octets);
  }

  static bool _isPrivateIpv4(List<int> o) {
    final a = o[0];
    final b = o[1];
    return a == 0 || // this network
        a == 10 ||
        a == 127 ||
        (a == 100 && b >= 64 && b <= 127) || // CGNAT
        (a == 169 && b == 254) || // link-local
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 192 && b == 0 && o[2] == 0) || // IETF protocol assignments
        (a == 198 && (b == 18 || b == 19)) || // benchmarking
        a >= 224; // multicast, reserved, broadcast
  }

  static bool _isPrivateIpv6(String h) {
    // `::` first (unspecified, loopback, IPv4-compatible/-mapped) or a
    // zero first hextet (the same, written out): reserved space.
    if (h.startsWith(':')) return true;
    final first = int.tryParse(h.split(':').first, radix: 16);
    if (first == null) return true;
    return first == 0 ||
        (first >= 0xfc00 && first <= 0xfdff) || // ULA
        (first >= 0xfe80 && first <= 0xfeff) || // link-local, old site-local
        first >= 0xff00; // multicast
  }

  /// SSRF protection: only HTTPS, no private IPs.
  /// [pageUrl] used to resolve relative imageUrl (e.g. /image.png).
  static bool isSafeImageUrl(String? imageUrl, [String? pageUrl]) {
    if (imageUrl == null || imageUrl.isEmpty) return false;
    try {
      final Uri? resolved = pageUrl != null
          ? Uri.parse(pageUrl).resolve(imageUrl.trim())
          : Uri.tryParse(imageUrl.trim());
      if (resolved == null) return false;
      if (resolved.scheme != 'https') return false;
      final host = resolved.host;
      if (host.isEmpty) return false;
      return !isPrivateHost(host);
    } catch (_) {
      return false;
    }
  }

  /// First URL in [text], or null. Same regex the preview paths use.
  static String? extractFirstUrl(String text) =>
      _urlRegex.firstMatch(text)?.group(0);

  /// URL without its `#fragment`. Fragments can carry secrets (Anti-Quantum
  /// Note decryption keys, magic-link tokens) and are never needed to fetch
  /// a preview — HTTP never transmits them. NEVER send a fragment to the
  /// link-preview proxy.
  static String stripFragment(String url) {
    final hashIndex = url.indexOf('#');
    return hashIndex == -1 ? url : url.substring(0, hashIndex);
  }

  /// Extract first URL from text, fetch OG metadata, return preview or null.
  static Future<Map<String, String?>?> fetchPreview(String text) async {
    final match = _urlRegex.firstMatch(text);
    if (match == null) return null;
    final url = match.group(0)!;

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;

    // SSRF protection: skip private/local URLs
    if (isPrivateHost(uri.host)) return null;

    try {
      final response = await http
          .get(uri, headers: {
            'User-Agent': 'Mozilla/5.0 (compatible; Umbra/1.0)',
          })
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) return null;

      final contentType = response.headers['content-type'] ?? '';
      if (!contentType.contains('text/html')) return null;

      // Only parse first 100KB
      final html =
          response.body.substring(0, min(response.body.length, 100000));

      final title = _extractOgTag(html, 'og:title') ?? _extractTitle(html);
      final rawImageUrl = _extractOgTag(html, 'og:image');
      final img = rawImageUrl == null
          ? null
          : await fetchThumbnail(rawImageUrl, url);

      if (title == null && img == null) return null;

      // Never `imageUrl` (C1): the receiver fetches nothing from the page's
      // host; it renders only the thumbnail made here.
      return {'url': url, 'title': title, 'img': img};
    } catch (e) {
      debugPrint('[LinkPreviewService] Failed to fetch preview for $url: $e');
      return null;
    }
  }

  /// The largest og:image this build downloads.
  static const int kMaxImageDownloadBytes = 2 * 1024 * 1024;

  /// The whole og:image leg — every hop, the body and the scaling — gets this
  /// long, so a slow host never holds the send for more than the page's 5 s
  /// plus this.
  static const Duration kImageBudget = Duration(seconds: 3);

  /// [rawImageUrl] (resolved against [pageUrl]) fetched from this device and
  /// scaled into a base64 JPEG thumbnail, or null on ANY failure — a preview
  /// without an image, never a failed send. HTTPS and [isSafeImageUrl] only
  /// (every redirect hop too), `image/*` only, streamed and abandoned past
  /// [kMaxImageDownloadBytes], and ONE overall deadline of [budget]: on
  /// expiry the download stops and the client is closed.
  static Future<String?> fetchThumbnail(
    String rawImageUrl,
    String pageUrl, {
    http.Client? client,
    Duration budget = kImageBudget,
  }) async {
    if (!isSafeImageUrl(rawImageUrl, pageUrl)) return null;
    final c = client ?? http.Client();
    var expired = false;
    try {
      return await _downloadThumbnail(
        rawImageUrl,
        pageUrl,
        c,
        () => expired,
      ).timeout(
        budget,
        onTimeout: () {
          expired = true;
          debugPrint('[LinkPreviewService] Thumbnail deadline passed');
          return null;
        },
      );
    } on Object catch (e) {
      debugPrint('[LinkPreviewService] Thumbnail failed: $e');
      return null;
    } finally {
      // A caller's client is the caller's; ours is closed so a stalled
      // socket is torn down at the deadline.
      if (client == null) c.close();
    }
  }

  static Future<String?> _downloadThumbnail(
    String rawImageUrl,
    String pageUrl,
    http.Client c,
    bool Function() expired,
  ) async {
    var uri = Uri.parse(pageUrl).resolve(rawImageUrl.trim());
    // Redirects by hand: every hop must still pass the HTTPS / non-private
    // check, as the backend's web path does.
    http.StreamedResponse response;
    var hops = 0;
    while (true) {
      response = await c.send(
        http.Request('GET', uri)
          ..followRedirects = false
          ..headers['User-Agent'] = 'Mozilla/5.0 (compatible; Umbra/1.0)',
      );
      final location = response.headers['location'];
      if (response.statusCode < 300 ||
          response.statusCode >= 400 ||
          location == null) {
        break;
      }
      if (++hops > 3 || !isSafeImageUrl(location, uri.toString())) {
        return null;
      }
      uri = uri.resolve(location);
    }
    if (response.statusCode != 200) return null;
    final type = (response.headers['content-type'] ?? '').toLowerCase();
    if (!type.trimLeft().startsWith('image/')) return null;
    if ((response.contentLength ?? 0) > kMaxImageDownloadBytes) return null;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (expired()) return null;
      bytes.add(chunk);
      if (bytes.length > kMaxImageDownloadBytes) return null;
    }
    if (expired()) return null;
    return LinkPreviewThumb.scale(bytes.takeBytes());
  }

  static String? _extractOgTag(String html, String property) {
    // Match <meta property="og:title" content="...">
    final regex = RegExp(
      '<meta[^>]*property=["\']$property["\'][^>]*content=["\'](.*?)["\']',
      caseSensitive: false,
    );
    final match = regex.firstMatch(html);
    if (match != null) return _decodeHtmlEntities(match.group(1)!);

    // Also try content before property (some sites reverse attribute order)
    final regex2 = RegExp(
      '<meta[^>]*content=["\'](.*?)["\'][^>]*property=["\']$property["\']',
      caseSensitive: false,
    );
    final match2 = regex2.firstMatch(html);
    if (match2 != null) return _decodeHtmlEntities(match2.group(1)!);

    return null;
  }

  static String? _extractTitle(String html) {
    final regex = RegExp(
      '<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    );
    final match = regex.firstMatch(html);
    if (match != null) {
      final title = _decodeHtmlEntities(match.group(1)!.trim());
      return title.isEmpty ? null : title;
    }
    return null;
  }

  static String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAll('&apos;', "'");
  }
}
