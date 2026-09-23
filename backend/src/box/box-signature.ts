import { createHash, createPublicKey, verify } from 'crypto';
import type { NotifierPlatform, QueueKind } from './box-wire';

/**
 * What a recipient command signs (G3 surface A §1, `docs/contracts/wire.md`):
 *
 *   M = "umbra.box.v1" 0x00 ‖ verb 0x00 ‖ u8(len sockId) ‖ utf8(sockId) ‖ F
 *
 * `sockId` is the socket.io id of the connection the command arrives on, so a
 * captured signature is dead once that connection closes, with no clock and no
 * nonce store; within one connection a replay is harmless because every verb
 * is idempotent. The verb and the per-verb fields `F` keep a signature for one
 * command from standing in for another.
 */
export type BoxSignedVerb =
  'createQueue' | 'subscribe' | 'ack' | 'deleteQueue' | 'registerNotifier';

const DOMAIN = Buffer.from('umbra.box.v1\0', 'ascii');

export function boxSignedMessage(
  verb: BoxSignedVerb,
  sockId: string,
  fields: Buffer,
): Buffer {
  const sock = Buffer.from(sockId, 'utf8');
  if (sock.length > 255) {
    throw new RangeError('socket id longer than a u8 length prefix');
  }
  return Buffer.concat([
    DOMAIN,
    Buffer.from(`${verb}\0`, 'ascii'),
    Buffer.from([sock.length]),
    sock,
    fields,
  ]);
}

/** F for `createQueue`: the kind byte, then the key being proven. */
export function createQueueFields(kind: QueueKind, authPub: Buffer): Buffer {
  return Buffer.concat([
    Buffer.from([kind === 'normal' ? 0x01 : 0x02]),
    authPub,
  ]);
}

/** F for `ack`: rid ‖ message id. */
export function ackFields(rid: Buffer, id: Buffer): Buffer {
  return Buffer.concat([rid, id]);
}

/**
 * F for `registerNotifier` step 1: nid ‖ 0x01 ‖ SHA-256(platform 0x00 token).
 * The separator keeps ("fcm", "x…") and ("fc", "mx…") from hashing alike.
 */
export function notifierChallengeFields(
  nid: Buffer,
  platform: NotifierPlatform,
  token: string,
): Buffer {
  const digest = createHash('sha256')
    .update(Buffer.from(`${platform}\0${token}`, 'utf8'))
    .digest();
  return Buffer.concat([nid, Buffer.from([0x01]), digest]);
}

/** F for `registerNotifier` step 2: nid ‖ 0x02 ‖ the code the push delivered. */
export function notifierActivateFields(nid: Buffer, code: Buffer): Buffer {
  return Buffer.concat([nid, Buffer.from([0x02]), code]);
}

/**
 * Pure Ed25519 (RFC 8032) over `message` under the raw 32-byte `authPub`.
 * A key that is not a valid point answers false: to the caller it is the same
 * `auth_failed` as a wrong signature.
 */
export function verifyBoxSignature(
  authPub: Buffer,
  message: Buffer,
  sig: Buffer,
): boolean {
  try {
    const key = createPublicKey({
      key: { kty: 'OKP', crv: 'Ed25519', x: authPub.toString('base64url') },
      format: 'jwk',
    });
    return verify(null, message, key, sig);
  } catch {
    return false;
  }
}
