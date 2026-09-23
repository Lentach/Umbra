/**
 * The box's fixed numbers (metadata-privacy PR1.1, design §3 I3/I5 + §4.1,
 * G3 surface A). Every one is part of the wire contract or an invariant, so
 * a change here is a contract change: `docs/contracts/wire.md` says the same.
 */

/** I5: every message blob is exactly this many bytes (outer layer, sealed + padded). */
export const BOX_BLOB_BYTES = 16384;

/** Decoded byte lengths of the base64url ids on the wire. */
export const BOX_RID_BYTES = 32;
export const BOX_SID_BYTES = 32;
export const BOX_NID_BYTES = 16;
export const BOX_MSG_ID_BYTES = 16;
export const BOX_MEDIA_ID_BYTES = 32;
export const BOX_AUTH_PUB_BYTES = 32;
export const BOX_SIG_BYTES = 64;
export const BOX_CODE_BYTES = 16;

/** A normal queue refuses a send once it holds this many (`queue_full`; the sender retries). */
export const BOX_NORMAL_QUEUE_CAP = 128;
/** A request queue (first contact only) keeps this many and drops the oldest. */
export const BOX_REQUEST_QUEUE_CAP = 50;

/** Unacknowledged `msg` frames in flight per socket (the credit window). */
export const BOX_DELIVERY_WINDOW = 16;
/** Rids per `subscribe` frame. */
export const BOX_SUBSCRIBE_MAX = 256;
/** A notifier token (FCM token or a Web Push subscription JSON). */
export const BOX_TOKEN_MAX_CHARS = 4096;

const DAY_MS = 24 * 60 * 60 * 1000;
/** I3: an undelivered message lives this long. */
export const BOX_MSG_TTL_MS = 30 * DAY_MS;
/** I3: an uploaded media blob lives this long. */
export const BOX_MEDIA_TTL_MS = 14 * DAY_MS;
/** I3: a queue nobody ever subscribed to is deleted after this long. */
export const BOX_UNCLAIMED_TTL_MS = DAY_MS;
/** I3: a queue not subscribed for this many whole days is reaped with its messages. */
export const BOX_IDLE_REAP_DAYS = 90;
/** A push-challenge code is accepted for this long after it was sent. */
export const BOX_CHALLENGE_TTL_MS = 10 * 60 * 1000;

/**
 * I5 media ladder: an upload's body is exactly one of these sizes. The 32 MiB
 * rung waits for nginx `client_max_body_size` (21m today), so it is not here.
 */
export const BOX_MEDIA_LADDER: ReadonlyArray<{
  bytes: number;
  bucket: string;
}> = [
  { bytes: 4 * 1024, bucket: '4k' },
  { bytes: 16 * 1024, bucket: '16k' },
  { bytes: 64 * 1024, bucket: '64k' },
  { bytes: 256 * 1024, bucket: '256k' },
  { bytes: 1024 * 1024, bucket: '1m' },
  { bytes: 4 * 1024 * 1024, bucket: '4m' },
  { bytes: 16 * 1024 * 1024, bucket: '16m' },
];

/**
 * Media bytes one NORMAL queue may receive per UTC day, charged at the RUNG
 * size (a 4.1 MiB file costs 16 MiB). The budget bounds disk use by whoever
 * holds a sid (a revoked peer keeps it until rotation, design §4.2): 64
 * top-rung files a day, ≤ 14 GiB per queue over the 14-day TTL. Owner's
 * number (2026-09-23; 256 MiB was 16 videos a day). `mediaBytesToday` is an
 * `integer`: budget + the top rung must stay below 2^31, so anything from
 * 2 GiB up needs that column widened first.
 * Request queues take no media — first contact never carries a file, and a
 * request sid is served to anyone who can search.
 */
export const BOX_MEDIA_DAILY_BUDGET_BYTES = 1024 * 1024 * 1024;

/**
 * Push coalescing per notifier, the existing tuning (design §4.5): wait this
 * long after the last send, but never longer than the max since the first.
 */
export const BOX_PUSH_DEBOUNCE_MS = 2500;
export const BOX_PUSH_MAX_WAIT_MS = 10000;

/** Per-/64 (IPv6) or per-address (IPv4) limits, per 15 minutes (G3 surface A §2). */
export const BOX_THROTTLE_TTL_MS = 15 * 60 * 1000;
export const BOX_LIMITS = {
  createQueue: 120,
  send: 1500,
  subscribe: 60,
  ack: 3000,
  deleteQueue: 300,
  registerNotifier: 30,
  mediaUpload: 300,
  mediaDownload: 3000,
} as const;
