import {
  BOX_AUTH_PUB_BYTES,
  BOX_BLOB_BYTES,
  BOX_CODE_BYTES,
  BOX_MSG_ID_BYTES,
  BOX_NID_BYTES,
  BOX_RID_BYTES,
  BOX_SID_BYTES,
  BOX_SIG_BYTES,
  BOX_SUBSCRIBE_MAX,
  BOX_TOKEN_MAX_CHARS,
} from './box.constants';

/**
 * The box's wire vocabulary (G3 surface A, `docs/contracts/wire.md`).
 *
 * Every client event carries ONE object and a socket.io ack; the ack is the
 * answer: `{ok:true, …}` or `{ok:false, code, retryAfterMs?}`, never an
 * `exception`/`error` event.
 *
 * The parser is deliberately stricter than `validateDto` (which lives in
 * `chat/`, where I1 forbids the box to reach, and which keeps unknown keys):
 * an unknown or missing key, another `v`, or an id that is not the ONE
 * canonical base64url spelling of exactly its length is `invalid_payload`.
 * Canonical matters: Node decodes base64url leniently, so without the
 * re-encode check one rid would have several spellings, and every map keyed
 * by the string form would disagree with the database keyed by the bytes.
 */

export type BoxCode =
  | 'invalid_payload'
  | 'auth_failed'
  | 'queue_full'
  | 'quota_exceeded'
  | 'rate_limited'
  | 'internal';

export interface BoxRefusal {
  ok: false;
  code: BoxCode;
  retryAfterMs?: number;
}
export type BoxAnswer<T extends object = object> =
  ({ ok: true } & T) | BoxRefusal;

export type QueueKind = 'normal' | 'request';
export type NotifierPlatform = 'fcm' | 'webpush';

export interface CreateQueueCmd {
  kind: QueueKind;
  authPub: Buffer;
  sig: Buffer;
}
export interface SendCmd {
  sid: Buffer;
  blob: Buffer;
}
export interface SubscribeCmd {
  subs: { rid: Buffer; sig: Buffer }[];
}
export interface AckCmd {
  rid: Buffer;
  id: Buffer;
  sig: Buffer;
}
export interface DeleteQueueCmd {
  rid: Buffer;
  sig: Buffer;
}
export type RegisterNotifierCmd =
  | {
      step: 1;
      nid: Buffer;
      platform: NotifierPlatform;
      token: string;
      sig: Buffer;
    }
  | { step: 2; nid: Buffer; code: Buffer; sig: Buffer };

/** `data` as a record when it is a plain object with EXACTLY these keys; else null. */
function exactKeys(
  data: unknown,
  keys: readonly string[],
): Record<string, unknown> | null {
  if (typeof data !== 'object' || data === null || Array.isArray(data)) {
    return null;
  }
  const record = data as Record<string, unknown>;
  if (Object.keys(record).length !== keys.length) return null;
  return keys.every((k) => Object.prototype.hasOwnProperty.call(record, k))
    ? record
    : null;
}

/** A command frame: exactly `v` plus these keys, with `v: 1`. */
function command(
  data: unknown,
  keys: readonly string[],
): Record<string, unknown> | null {
  const record = exactKeys(data, ['v', ...keys]);
  return record?.v === 1 ? record : null;
}

/**
 * The bytes of `value` when it is the canonical unpadded base64url spelling
 * of exactly `bytes` bytes; otherwise null.
 */
export function decodeFixedB64(value: unknown, bytes: number): Buffer | null {
  if (typeof value !== 'string') return null;
  if (value.length !== Math.ceil((bytes * 4) / 3)) return null;
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const decoded = Buffer.from(value, 'base64url');
  if (decoded.length !== bytes) return null;
  return decoded.toString('base64url') === value ? decoded : null;
}

export function parseCreateQueue(data: unknown): CreateQueueCmd | null {
  const o = command(data, ['kind', 'authPub', 'sig']);
  if (!o || (o.kind !== 'normal' && o.kind !== 'request')) return null;
  const authPub = decodeFixedB64(o.authPub, BOX_AUTH_PUB_BYTES);
  const sig = decodeFixedB64(o.sig, BOX_SIG_BYTES);
  return authPub && sig ? { kind: o.kind, authPub, sig } : null;
}

export function parseSend(data: unknown): SendCmd | null {
  const o = command(data, ['sid', 'blob']);
  if (!o) return null;
  const sid = decodeFixedB64(o.sid, BOX_SID_BYTES);
  const blob = decodeFixedB64(o.blob, BOX_BLOB_BYTES);
  return sid && blob ? { sid, blob } : null;
}

export function parseSubscribe(data: unknown): SubscribeCmd | null {
  const o = command(data, ['subs']);
  if (!o || !Array.isArray(o.subs)) return null;
  const entries: unknown[] = o.subs;
  if (entries.length < 1 || entries.length > BOX_SUBSCRIBE_MAX) return null;
  const subs: SubscribeCmd['subs'] = [];
  for (const entry of entries) {
    const e = exactKeys(entry, ['rid', 'sig']);
    const rid = e && decodeFixedB64(e.rid, BOX_RID_BYTES);
    const sig = e && decodeFixedB64(e.sig, BOX_SIG_BYTES);
    if (!rid || !sig) return null;
    subs.push({ rid, sig });
  }
  return { subs };
}

export function parseAck(data: unknown): AckCmd | null {
  const o = command(data, ['rid', 'id', 'sig']);
  if (!o) return null;
  const rid = decodeFixedB64(o.rid, BOX_RID_BYTES);
  const id = decodeFixedB64(o.id, BOX_MSG_ID_BYTES);
  const sig = decodeFixedB64(o.sig, BOX_SIG_BYTES);
  return rid && id && sig ? { rid, id, sig } : null;
}

export function parseDeleteQueue(data: unknown): DeleteQueueCmd | null {
  const o = command(data, ['rid', 'sig']);
  if (!o) return null;
  const rid = decodeFixedB64(o.rid, BOX_RID_BYTES);
  const sig = decodeFixedB64(o.sig, BOX_SIG_BYTES);
  return rid && sig ? { rid, sig } : null;
}

export function parseRegisterNotifier(
  data: unknown,
): RegisterNotifierCmd | null {
  const step1 = command(data, ['nid', 'platform', 'token', 'sig']);
  if (step1) {
    const nid = decodeFixedB64(step1.nid, BOX_NID_BYTES);
    const sig = decodeFixedB64(step1.sig, BOX_SIG_BYTES);
    const { platform, token } = step1;
    if (!nid || !sig || typeof token !== 'string') return null;
    if (platform === 'fcm' && FCM_TOKEN.test(token)) {
      return { step: 1, nid, platform, token, sig };
    }
    if (platform === 'webpush' && parseWebPushSubscription(token)) {
      return { step: 1, nid, platform, token, sig };
    }
    return null;
  }
  const step2 = command(data, ['nid', 'code', 'sig']);
  if (!step2) return null;
  const nid = decodeFixedB64(step2.nid, BOX_NID_BYTES);
  const code = decodeFixedB64(step2.code, BOX_CODE_BYTES);
  const sig = decodeFixedB64(step2.sig, BOX_SIG_BYTES);
  return nid && code && sig ? { step: 2, nid, code, sig } : null;
}

const FCM_TOKEN = new RegExp(`^[A-Za-z0-9_:-]{1,${BOX_TOKEN_MAX_CHARS}}$`);

/**
 * Push services a Web Push endpoint may point at. `registerNotifier` is
 * UNAUTHENTICATED and the box later POSTs to the endpoint, so an open
 * endpoint would be a server-side request forgery primitive into the VPS's
 * own network (metadata service, loopback, the DB port). Exact hosts, plus
 * the WNS family, which is one host per region.
 */
const WEB_PUSH_HOSTS: Record<string, true> = {
  'fcm.googleapis.com': true,
  'updates.push.services.mozilla.com': true,
  'web.push.apple.com': true,
};
const WEB_PUSH_HOST_SUFFIXES = ['.notify.windows.com'];

export interface WebPushSubscriptionShape {
  endpoint: string;
  keys: { p256dh: string; auth: string };
}

/**
 * The subscription a `webpush` token carries, when it is exactly the
 * `PushSubscription.toJSON()` shape (`expirationTime` tolerated) with an
 * https endpoint on a known push service and keys of the right sizes.
 */
export function parseWebPushSubscription(
  token: string,
): WebPushSubscriptionShape | null {
  if (token.length > BOX_TOKEN_MAX_CHARS) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(token);
  } catch {
    return null;
  }
  if (typeof parsed !== 'object' || parsed === null) return null;
  // A non-null object from JSON.parse: its own keys are the whole payload.
  const subscription = parsed as Record<string, unknown>;
  const { endpoint, keys, ...rest } = subscription;
  if (Object.keys(rest).some((k) => k !== 'expirationTime')) return null;
  if (typeof endpoint !== 'string') return null;
  let url: URL;
  try {
    url = new URL(endpoint);
  } catch {
    return null;
  }
  const host = url.hostname;
  const knownHost =
    WEB_PUSH_HOSTS[host] === true ||
    WEB_PUSH_HOST_SUFFIXES.some((suffix) => host.endsWith(suffix));
  if (url.protocol !== 'https:' || url.port !== '' || !knownHost) return null;
  const keyPair = exactKeys(keys, ['p256dh', 'auth']);
  const p256dh = keyPair?.p256dh;
  const auth = keyPair?.auth;
  if (typeof p256dh !== 'string' || typeof auth !== 'string') return null;
  if (
    decodeLooseB64(p256dh)?.length !== 65 ||
    decodeLooseB64(auth)?.length !== 16
  ) {
    return null;
  }
  return { endpoint, keys: { p256dh, auth } };
}

/** Browsers disagree on padding for subscription keys; accept both. */
function decodeLooseB64(value: string): Buffer | null {
  if (!/^[A-Za-z0-9_-]+=*$/.test(value)) return null;
  return Buffer.from(value.replace(/=+$/, ''), 'base64url');
}
