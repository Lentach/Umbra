import { UseFilters, UseGuards } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import {
  ConnectedSocket,
  MessageBody,
  OnGatewayDisconnect,
  SubscribeMessage,
  WebSocketGateway,
} from '@nestjs/websockets';
import type { Socket } from 'socket.io';
import { buildCorsOrigin } from '../common/socket-cors';
import { BoxAckFilter } from './box-ack.filter';
import { BoxDelivery } from './box-delivery.service';
import { BoxNotifierService } from './box-notifier.service';
import {
  ackFields,
  boxSignedMessage,
  createQueueFields,
  notifierActivateFields,
  notifierChallengeFields,
  verifyBoxSignature,
} from './box-signature';
import { BoxThrottlerGuard } from './box-throttler.guard';
import {
  parseAck,
  parseCreateQueue,
  parseDeleteQueue,
  parseRegisterNotifier,
  parseSend,
  parseSubscribe,
  type BoxAnswer,
  type BoxRefusal,
} from './box-wire';
import { BOX_LIMITS, BOX_THROTTLE_TTL_MS } from './box.constants';
import { BoxService } from './box.service';

const INVALID: BoxRefusal = { ok: false, code: 'invalid_payload' };
/** Unknown rid/nid, bad signature, wrong or stale code: ONE answer, no existence oracle. */
const AUTH_FAILED: BoxRefusal = { ok: false, code: 'auth_failed' };

/**
 * The box (metadata-privacy PR1.1, G3 surface A "Plain RPC"): a message path
 * with no account on it. The namespace has NO handshake auth and this file
 * imports nothing from `auth/`, `users/` or `chat/` (I1,
 * `scripts/verify-box-imports.mjs`).
 *
 * Six events, each answered by its handler's return value on the socket.io
 * ack (`{ok:true, …}` / `{ok:false, code, retryAfterMs?}`); one server push,
 * `msg`, from `BoxDelivery`. Recipient commands are Ed25519-signed over bytes
 * that include THIS connection's id (`box-signature.ts`), so they cannot be
 * replayed on another connection, and every verb is idempotent within one.
 * `send` is unsigned: the sid is the bearer credential, and an unknown sid is
 * answered `{ok:true}` exactly like a stored one (no block oracle).
 *
 * Contract: `docs/contracts/wire.md` "Box".
 */
@UseFilters(BoxAckFilter)
@UseGuards(BoxThrottlerGuard)
@WebSocketGateway({ namespace: '/box', cors: { origin: buildCorsOrigin() } })
export class BoxGateway implements OnGatewayDisconnect {
  constructor(
    private readonly box: BoxService,
    private readonly delivery: BoxDelivery,
    private readonly notifier: BoxNotifierService,
  ) {}

  handleDisconnect(client: Socket): void {
    this.delivery.detachSocket(client.id);
  }

  @Throttle({
    default: { limit: BOX_LIMITS.createQueue, ttl: BOX_THROTTLE_TTL_MS },
  })
  @SubscribeMessage('createQueue')
  async createQueue(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ): Promise<BoxAnswer<{ rid: string; sid: string; nid: string }>> {
    const cmd = parseCreateQueue(data);
    if (!cmd) return INVALID;
    // Proof of possession: the creator signs with the key it registers.
    const message = boxSignedMessage(
      'createQueue',
      client.id,
      createQueueFields(cmd.kind, cmd.authPub),
    );
    if (!verifyBoxSignature(cmd.authPub, message, cmd.sig)) return AUTH_FAILED;
    const address = await this.box.createQueue(cmd.kind, cmd.authPub);
    if (!address) return INVALID;
    return {
      ok: true,
      rid: address.rid.toString('base64url'),
      sid: address.sid.toString('base64url'),
      nid: address.nid.toString('base64url'),
    };
  }

  @Throttle({ default: { limit: BOX_LIMITS.send, ttl: BOX_THROTTLE_TTL_MS } })
  @SubscribeMessage('send')
  async send(@MessageBody() data: unknown): Promise<BoxAnswer> {
    const cmd = parseSend(data);
    if (!cmd) return INVALID;
    const stored = await this.box.enqueue(cmd.sid, cmd.blob);
    if (stored.result === 'full') return { ok: false, code: 'queue_full' };
    if (stored.result === 'stored' && !this.delivery.onEnqueued(stored.rid)) {
      this.notifier.schedule(stored.nid);
    }
    return { ok: true };
  }

  @Throttle({
    default: { limit: BOX_LIMITS.subscribe, ttl: BOX_THROTTLE_TTL_MS },
  })
  @SubscribeMessage('subscribe')
  async subscribe(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ): Promise<BoxAnswer<{ refused: { rid: string; code: 'auth_failed' }[] }>> {
    const cmd = parseSubscribe(data);
    if (!cmd) return INVALID;
    const keys = await this.box.authKeysByRid(cmd.subs.map((s) => s.rid));
    const accepted: Buffer[] = [];
    const refused: { rid: string; code: 'auth_failed' }[] = [];
    for (const { rid, sig } of cmd.subs) {
      const key = keys.get(rid.toString('base64url'));
      const message = boxSignedMessage('subscribe', client.id, rid);
      if (key && verifyBoxSignature(key, message, sig)) accepted.push(rid);
      else
        refused.push({ rid: rid.toString('base64url'), code: 'auth_failed' });
    }
    if (accepted.length > 0) {
      await this.box.markSubscribed(accepted);
      this.delivery.attach(client, accepted);
    }
    return { ok: true, refused };
  }

  @Throttle({ default: { limit: BOX_LIMITS.ack, ttl: BOX_THROTTLE_TTL_MS } })
  @SubscribeMessage('ack')
  async ack(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ): Promise<BoxAnswer> {
    const cmd = parseAck(data);
    if (!cmd) return INVALID;
    const message = boxSignedMessage(
      'ack',
      client.id,
      ackFields(cmd.rid, cmd.id),
    );
    if (!(await this.ownerSigned(cmd.rid, message, cmd.sig))) {
      return AUTH_FAILED;
    }
    await this.box.ack(cmd.rid, cmd.id);
    this.delivery.onAcked(client.id, cmd.id);
    return { ok: true };
  }

  /**
   * An unknown rid is `auth_failed`, never `ok`: answering `ok` for a
   * missing queue while refusing a bad signature on a live one would tell
   * anyone which rids exist. A client that retries a delete whose answer it
   * lost therefore reads `auth_failed` as "already gone".
   */
  @Throttle({
    default: { limit: BOX_LIMITS.deleteQueue, ttl: BOX_THROTTLE_TTL_MS },
  })
  @SubscribeMessage('deleteQueue')
  async deleteQueue(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ): Promise<BoxAnswer> {
    const cmd = parseDeleteQueue(data);
    if (!cmd) return INVALID;
    const message = boxSignedMessage('deleteQueue', client.id, cmd.rid);
    if (!(await this.ownerSigned(cmd.rid, message, cmd.sig))) {
      return AUTH_FAILED;
    }
    await this.box.deleteQueue(cmd.rid);
    this.delivery.forget(cmd.rid);
    return { ok: true };
  }

  @Throttle({
    default: { limit: BOX_LIMITS.registerNotifier, ttl: BOX_THROTTLE_TTL_MS },
  })
  @SubscribeMessage('registerNotifier')
  async registerNotifier(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ): Promise<BoxAnswer<{ state: 'challenged' | 'active' }>> {
    const cmd = parseRegisterNotifier(data);
    if (!cmd) return INVALID;
    const key = await this.box.authKeyByNid(cmd.nid);
    const fields =
      cmd.step === 1
        ? notifierChallengeFields(cmd.nid, cmd.platform, cmd.token)
        : notifierActivateFields(cmd.nid, cmd.code);
    const message = boxSignedMessage('registerNotifier', client.id, fields);
    if (!key || !verifyBoxSignature(key, message, cmd.sig)) return AUTH_FAILED;
    if (cmd.step === 1) {
      await this.notifier.challenge(cmd.nid, cmd.platform, cmd.token);
      return { ok: true, state: 'challenged' };
    }
    return (await this.notifier.activate(cmd.nid, cmd.code))
      ? { ok: true, state: 'active' }
      : AUTH_FAILED;
  }

  /** True when `rid` exists and `sig` is its owner's over `message`. */
  private async ownerSigned(
    rid: Buffer,
    message: Buffer,
    sig: Buffer,
  ): Promise<boolean> {
    const key = (await this.box.authKeysByRid([rid])).get(
      rid.toString('base64url'),
    );
    return key !== undefined && verifyBoxSignature(key, message, sig);
  }
}
