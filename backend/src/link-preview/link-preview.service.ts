import { Injectable, Logger } from '@nestjs/common';
import { lookup as dnsLookup } from 'node:dns';
import type { LookupFunction } from 'node:net';
import { isIP } from 'node:net';
import { Agent, fetch as undiciFetch } from 'undici';

// ---------------------------------------------------------------------------
// SSRF defence: every outbound hostname is validated at two layers.
//  1. URL-literal layer: WHATWG URL normalizes exotic IPv4 spellings
//     (decimal `2130706433`, hex `0x7f000001`, octal `0177.0.0.1`) into dotted
//     quads, so `isPrivateIp` on the parsed hostname catches them all.
//  2. DNS layer (resolve-and-pin): the undici Agent below runs a custom
//     `lookup` at CONNECT time — the very addresses the socket will dial are
//     validated, and a hostname whose DNS answer includes ANY private address
//     is refused. Because validation and connection use the same resolution,
//     DNS-rebinding (public answer during a pre-check, private answer during
//     connect) cannot bypass it.
// ---------------------------------------------------------------------------

function ipv4ToBytes(ip: string): number[] | null {
  const parts = ip.split('.');
  if (parts.length !== 4) return null;
  const bytes: number[] = [];
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const n = Number(part);
    if (n > 255) return null;
    bytes.push(n);
  }
  return bytes;
}

function ipv6ToBytes(ip: string): number[] | null {
  const zoneIdx = ip.indexOf('%');
  if (zoneIdx !== -1) ip = ip.slice(0, zoneIdx);
  const halves = ip.split('::');
  if (halves.length > 2) return null;

  const parseGroups = (s: string): number[] | null => {
    if (s === '') return [];
    const groups: number[] = [];
    for (const g of s.split(':')) {
      if (g.includes('.')) {
        // Embedded IPv4 tail, e.g. ::ffff:127.0.0.1
        const v4 = ipv4ToBytes(g);
        if (!v4) return null;
        groups.push((v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]);
      } else {
        if (!/^[0-9a-f]{1,4}$/i.test(g)) return null;
        groups.push(parseInt(g, 16));
      }
    }
    return groups;
  };

  const left = parseGroups(halves[0]);
  const right = halves.length === 2 ? parseGroups(halves[1]) : [];
  if (!left || !right) return null;
  const fill = 8 - left.length - right.length;
  if (halves.length === 2 ? fill < 1 : fill !== 0) return null;
  const groups =
    halves.length === 2
      ? [...left, ...new Array<number>(fill).fill(0), ...right]
      : left;
  if (groups.length !== 8) return null;
  const bytes: number[] = [];
  for (const g of groups) bytes.push(g >> 8, g & 0xff);
  return bytes;
}

function isPrivateV4Bytes(b: number[]): boolean {
  if (b[0] === 0) return true; // 0.0.0.0/8 "this network"
  if (b[0] === 10) return true; // 10/8 RFC 1918
  if (b[0] === 100 && (b[1] & 0xc0) === 64) return true; // 100.64/10 CGNAT
  if (b[0] === 127) return true; // loopback
  if (b[0] === 169 && b[1] === 254) return true; // link-local / cloud metadata
  if (b[0] === 172 && (b[1] & 0xf0) === 16) return true; // 172.16/12 RFC 1918
  if (b[0] === 192 && b[1] === 0 && b[2] === 0) return true; // 192.0.0/24 IETF
  if (b[0] === 192 && b[1] === 168) return true; // 192.168/16 RFC 1918
  if (b[0] === 198 && (b[1] & 0xfe) === 18) return true; // 198.18/15 benchmark
  if (b[0] >= 224) return true; // multicast + reserved + broadcast
  return false;
}

/** True when `ip` is a syntactically valid IP that must never be fetched. */
export function isPrivateIp(ip: string): boolean {
  const family = isIP(ip);
  if (family === 4) {
    const b = ipv4ToBytes(ip);
    return b ? isPrivateV4Bytes(b) : true;
  }
  if (family === 6) {
    const b = ipv6ToBytes(ip);
    if (!b) return true;
    // IPv4-mapped ::ffff:0:0/96 — validate the embedded IPv4
    if (b.slice(0, 10).every((x) => x === 0) && b[10] === 0xff && b[11] === 0xff) {
      return isPrivateV4Bytes(b.slice(12));
    }
    // NAT64 well-known prefix 64:ff9b::/96 — validate the embedded IPv4
    if (
      b[0] === 0x00 &&
      b[1] === 0x64 &&
      b[2] === 0xff &&
      b[3] === 0x9b &&
      b.slice(4, 12).every((x) => x === 0)
    ) {
      return isPrivateV4Bytes(b.slice(12));
    }
    // :: (unspecified) and ::1 (loopback)
    if (b.slice(0, 15).every((x) => x === 0) && b[15] <= 1) return true;
    if ((b[0] & 0xfe) === 0xfc) return true; // fc00::/7 ULA
    if (b[0] === 0xfe && (b[1] & 0xc0) === 0x80) return true; // fe80::/10 link-local
    return false;
  }
  return false; // not an IP literal — DNS layer decides
}

/** True when the (already URL-normalized) hostname must never be fetched. */
function isBlockedHostname(hostname: string): boolean {
  // Node's URL parser wraps IPv6 addresses in brackets (e.g. '[::1]')
  const host = hostname.startsWith('[') ? hostname.slice(1, -1) : hostname;
  if (isIP(host)) return isPrivateIp(host);
  const lower = host.toLowerCase();
  return lower === 'localhost' || lower.endsWith('.localhost');
}

/** True only for safe HTTPS URLs pointing to public hosts */
function isSafeImageUrl(url: string): boolean {
  try {
    const { protocol, hostname } = new URL(url);
    return protocol === 'https:' && !isBlockedHostname(hostname);
  } catch {
    return false;
  }
}

/** True only for http(s) URLs whose host is public — gates every fetch hop. */
function isFetchableUrl(url: string): boolean {
  try {
    const { protocol, hostname } = new URL(url);
    return (
      (protocol === 'http:' || protocol === 'https:') &&
      !isBlockedHostname(hostname)
    );
  } catch {
    return false;
  }
}

/**
 * DNS lookup used by the outbound Agent at connect time. Resolves ALL
 * addresses and refuses the connection when any answer is private — the
 * socket then dials only addresses this function returned (resolve-and-pin).
 * Exported for tests.
 */
export function ssrfSafeLookup(
  hostname: string,
  options: { all?: boolean } & Record<string, unknown>,
  callback: (
    err: NodeJS.ErrnoException | null,
    address?: string | { address: string; family: number }[],
    family?: number,
  ) => void,
): void {
  dnsLookup(hostname, { ...options, all: true }, (err, addresses) => {
    if (err) return callback(err);
    const list = Array.isArray(addresses) ? addresses : [];
    if (list.length === 0) {
      const e: NodeJS.ErrnoException = new Error(
        `No address records for ${hostname}`,
      );
      e.code = 'ENOTFOUND';
      return callback(e);
    }
    if (list.some((a) => isPrivateIp(a.address))) {
      const e: NodeJS.ErrnoException = new Error(
        `Refusing to connect: ${hostname} resolves to a private address`,
      );
      e.code = 'ECONNREFUSED';
      return callback(e);
    }
    if (options?.all) return callback(null, list);
    callback(null, list[0].address, list[0].family);
  });
}

// net's LookupFunction type demands a mandatory address arg in the callback;
// our implementation follows the (options.all ? addresses[] : address, family)
// contract the socket actually invokes — the shape is unexpressible verbatim.
const pinnedLookup = ssrfSafeLookup as unknown as LookupFunction;

const ssrfSafeAgent = new Agent({ connect: { lookup: pinnedLookup } });

/** fetch that can only connect to publicly-routable addresses. Exported so a
 *  test can drive it end-to-end and prove undici actually honors the pinned
 *  DNS lookup (a fail-open would otherwise pass a lookup-only unit test). */
export const ssrfSafeFetch: typeof fetch = ((input: string, init: object) =>
  undiciFetch(input, {
    ...init,
    dispatcher: ssrfSafeAgent,
  })) as unknown as typeof fetch;

const MAX_REDIRECTS = 5;

function parseOgMeta(html: string, pageUrl: string): {
  title: string | null;
  imageUrl: string | null;
} {
  const title =
    html.match(/<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']/i)?.[1] ??
    html.match(/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:title["']/i)?.[1] ??
    html.match(/<title[^>]*>([^<]+)<\/title>/i)?.[1] ??
    null;

  const rawImageUrl =
    html.match(/<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i)?.[1] ??
    html.match(/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/i)?.[1] ??
    null;

  const imageUrl = rawImageUrl
    ? (() => {
        try {
          const resolved = rawImageUrl.startsWith('http')
            ? rawImageUrl
            : new URL(rawImageUrl.trim(), pageUrl).href;
          return isSafeImageUrl(resolved) ? resolved : null;
        } catch {
          return null;
        }
      })()
    : null;

  return {
    title: title ? title.trim().substring(0, 200) : null,
    imageUrl,
  };
}

@Injectable()
export class LinkPreviewService {
  private readonly logger = new Logger(LinkPreviewService.name);

  /**
   * Outbound fetch. Public only as a test-injection seam; production always
   * keeps the default, which routes through the pinned-DNS SSRF agent.
   */
  fetchImpl: typeof fetch = ssrfSafeFetch;

  async fetchPreview(
    text: string,
  ): Promise<{ url: string; title: string | null; imageUrl: string | null } | null> {
    const startUrl =
      text.match(/https?:\/\/[^\s<>"{}|\\^`[\]]+/i)?.[0] ?? null;
    if (!startUrl) return null;

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);
    try {
      // Follow redirects manually so every hop is SSRF-validated. fetch's own
      // `redirect: 'follow'` would silently chase a 3xx into a private/metadata
      // host without re-checking it — the classic open-redirect SSRF bypass.
      // Hostname literals are checked here; hostnames that RESOLVE to private
      // addresses are refused by ssrfSafeLookup at connect time (DNS pinned).
      let currentUrl = startUrl;
      for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
        if (!isFetchableUrl(currentUrl)) return null;

        const response = await this.fetchImpl(currentUrl, {
          signal: controller.signal,
          redirect: 'manual',
          headers: { 'User-Agent': 'Mozilla/5.0 (compatible; ChatBot/1.0)' },
        });

        if (response.status >= 300 && response.status < 400) {
          const location = response.headers.get('location');
          if (!location) return null;
          try {
            currentUrl = new URL(location, currentUrl).href;
          } catch {
            return null;
          }
          continue; // re-validated at the top of the loop before the next fetch
        }

        if (!response.ok) return null;

        const contentType = response.headers.get('content-type') ?? '';
        if (!contentType.includes('text/html')) return null;

        // Read until </head> found (covers sites like YouTube with large inline JS)
        // or until 800KB safety limit to avoid unbounded downloads.
        const reader = response.body?.getReader();
        if (!reader) return null;
        let html = '';
        let totalBytes = 0;
        const decoder = new TextDecoder();
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          totalBytes += value.byteLength;
          html += decoder.decode(value);
          if (html.includes('</head>')) break;
          if (totalBytes > 800_000) break;
        }
        reader.cancel();

        const { title, imageUrl } = parseOgMeta(html, currentUrl);
        if (!title && !imageUrl) return null;

        // Preview is for the link as written in the message (startUrl).
        return { url: startUrl, title, imageUrl };
      }
      return null; // too many redirects
    } catch (err) {
      this.logger.debug(`Link preview fetch failed for ${startUrl}: ${err.message}`);
      return null;
    } finally {
      clearTimeout(timeout);
    }
  }
}
