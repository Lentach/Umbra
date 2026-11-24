import { Socket } from 'socket.io';

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
