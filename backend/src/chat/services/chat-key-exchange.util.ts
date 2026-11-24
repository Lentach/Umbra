import { Socket } from 'socket.io';

const PRE_KEY_FETCH_MIN_INTERVAL_MS = 750;
const PRE_KEY_FETCH_MAP_TTL_MS = 10 * 60 * 1000;
const PRE_KEY_FETCH_MAP_MAX_ENTRIES = 10000;
export const SESSION_REBUILD_REQUEST_TTL_MS = 24 * 60 * 60 * 1000;
const SESSION_REBUILD_MAP_MAX_RECIPIENTS = 10000;

/** Nonce issued to one authenticated socket session. */
export interface RegistrationLockNonce {
  nonce: string;
  expiresAt: number;
}

/** The per-socket bag the gateway populates once a session is authenticated. */
interface AuthenticatedSocketData {
  /**
   * `deviceId` comes from the JWT (Phase 1, spec §4). Absent on a token issued
   * before the claim existed — device 1 by definition (§8).
   */
  user?: { id: number; deviceId?: number };
  registrationLockNonce?: RegistrationLockNonce;
}

/**
 * socket.io declares `Socket.data` as `any`, so every read off it is untyped.
 * One documented narrowing keeps that assertion in a single place instead of
 * repeating it at each access site.
 */
export function socketData(client: Socket): AuthenticatedSocketData {
  return client.data as AuthenticatedSocketData;
}

/** Message of an unknown thrown value, without trusting it to be an Error. */
export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * Paces bundle fetches per (requester, target USER, target DEVICE).
 *
 * The device dimension is load-bearing since Phase 1 made bundles and OTP
 * pools per-device: establishing sessions to a two-device peer needs two
 * fetches back to back, and a per-user key would REFUSE the second one
 * outright — making lawful multi-device fan-out impossible (spec §5.2).
 */
export function isPreKeyFetchRateLimited(
  lastPreKeyFetchByPair: Map<string, number>,
  requesterId: number,
  recipientId: number,
  recipientDeviceId: number,
): boolean {
  const now = Date.now();
  cleanupPreKeyFetchTracker(lastPreKeyFetchByPair, now);
  const key = `${requesterId}:${recipientId}:${recipientDeviceId}`; // log-guard: key
  const lastSeen = lastPreKeyFetchByPair.get(key);
  if (
    lastSeen !== undefined &&
    now - lastSeen < PRE_KEY_FETCH_MIN_INTERVAL_MS
  ) {
    return true;
  }
  lastPreKeyFetchByPair.set(key, now);
  return false;
}

function cleanupPreKeyFetchTracker(
  lastPreKeyFetchByPair: Map<string, number>,
  now: number,
): void {
  for (const [key, ts] of lastPreKeyFetchByPair.entries()) {
    if (now - ts > PRE_KEY_FETCH_MAP_TTL_MS) {
      lastPreKeyFetchByPair.delete(key);
    }
  }
  if (lastPreKeyFetchByPair.size <= PRE_KEY_FETCH_MAP_MAX_ENTRIES) {
    return;
  }

  const ordered = [...lastPreKeyFetchByPair.entries()].sort(
    (a, b) => a[1] - b[1],
  );
  const toDelete = lastPreKeyFetchByPair.size - PRE_KEY_FETCH_MAP_MAX_ENTRIES;
  for (let i = 0; i < toDelete; i++) {
    lastPreKeyFetchByPair.delete(ordered[i][0]);
  }
}

export function rememberSessionRebuildRequest(
  pendingSessionRebuildsByRecipient: Map<number, Map<number, number>>,
  recipientId: number,
  requesterId: number,
): void {
  cleanupPendingSessionRebuilds(pendingSessionRebuildsByRecipient, Date.now());
  let pending = pendingSessionRebuildsByRecipient.get(recipientId);
  if (!pending) {
    pending = new Map<number, number>();
    pendingSessionRebuildsByRecipient.set(recipientId, pending);
  }
  pending.set(requesterId, Date.now());
}

export function clearPendingSessionRebuildRequest(
  pendingSessionRebuildsByRecipient: Map<number, Map<number, number>>,
  recipientId: number,
  requesterId: number,
): void {
  const pending = pendingSessionRebuildsByRecipient.get(recipientId);
  if (!pending) return;
  pending.delete(requesterId);
  if (pending.size === 0) {
    pendingSessionRebuildsByRecipient.delete(recipientId);
  }
}

function cleanupPendingSessionRebuilds(
  pendingSessionRebuildsByRecipient: Map<number, Map<number, number>>,
  now: number,
): void {
  for (const [recipientId, pending] of pendingSessionRebuildsByRecipient) {
    for (const [requesterId, requestedAt] of pending) {
      if (now - requestedAt > SESSION_REBUILD_REQUEST_TTL_MS) {
        pending.delete(requesterId);
      }
    }
    if (pending.size === 0) {
      pendingSessionRebuildsByRecipient.delete(recipientId);
    }
  }
  // Bound memory the same way the prekey-fetch tracker is bounded: a client
  // can mint pending entries for arbitrary recipientIds (DTO only checks
  // positive), so evict the least-recently-requested recipients past the cap.
  if (
    pendingSessionRebuildsByRecipient.size <= SESSION_REBUILD_MAP_MAX_RECIPIENTS
  ) {
    return;
  }
  const newest = (pending: Map<number, number>): number =>
    Math.max(...pending.values());
  const ordered = [...pendingSessionRebuildsByRecipient.entries()].sort(
    (a, b) => newest(a[1]) - newest(b[1]),
  );
  const toDelete =
    pendingSessionRebuildsByRecipient.size - SESSION_REBUILD_MAP_MAX_RECIPIENTS;
  for (let i = 0; i < toDelete; i++) {
    pendingSessionRebuildsByRecipient.delete(ordered[i][0]);
  }
}
