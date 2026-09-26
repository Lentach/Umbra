import { Logger, UseFilters, UseGuards } from '@nestjs/common';
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
  verifyBoxSignature,
} from './box-signature';
import { BoxThrottlerGuard, countRefusal } from './box-throttler.guard';
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
  private readonly logger = new Logger(BoxGateway.name);

  constructor(
    private readonly box: BoxService,
    private readonly delivery: BoxDelivery,
    private readonly notifier: BoxNotifierService,
  ) {}

  /**
   * A queue the socket owned that still holds messages wakes its device:
   * those went to this socket instead of to a push, and it may never have
   * read them. Like `send`'s push, it fires even if the device resubscribes
   * within the coalescing wait.
   */
  async handleDisconnect(client: Socket): Promise<void> {
    const owned = this.delivery.detachSocket(client.id);
    if (owned.length === 0) return;
    try {
      for (const nid of await this.box.waitingNids(owned)) {
        this.notifier.schedule(nid);
      }
    } catch (error) {
      this.logger.warn(
        `[box] wake-up on disconnect failed: ${error instanceof Error ? error.name : 'unknown'}`,
      );
    }
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
    if (stored.result === 'over_ceiling') {
      countRefusal('send:ceiling');
      return { ok: false, code: 'quota_exceeded' };
    }
    if (stored.result === 'stored' && !this.delivery.onEnqueued(stored.rid)) {
      this.notifier.schedule(stored.nid);
    }
    return { ok: true };
  }

  /**
   * Each entry stands alone, refusals listed in frame order: `auth_failed`
   * (unknown rid or wrong signature, one answer) or `limit` (past the
   * socket's rid cap, E10). A `limit` entry is checked before the claim, so
   * it claims nothing — unless a concurrent frame on this socket filled the
   * cap in between; `attach` refuses it then, after its own owner's
   * signature already claimed the queue (harmless).
   */
  @Throttle({
    default: { limit: BOX_LIMITS.subscribe, ttl: BOX_THROTTLE_TTL_MS },
  })
  @SubscribeMessage('subscribe')
  async subscribe(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ): Promise<
    BoxAnswer<{ refused: { rid: string; code: 'auth_failed' | 'limit' }[] }>
  > {
    const cmd = parseSubscribe(data);
    if (!cmd) return INVALID;
    const keys = await this.box.authKeysByRid(cmd.subs.map((s) => s.rid));
    const signed = cmd.subs.map(({ rid, sig }) => {
      const key = keys.get(rid.toString('base64url'));
      const message = boxSignedMessage('subscribe', client.id, rid);
      return key !== undefined && verifyBoxSignature(key, message, sig);
    });
    const { fits, over } = this.delivery.fit(
      client.id,
      cmd.subs.filter((_, i) => signed[i]).map((s) => s.rid),
    );
    if (fits.length > 0) {
      await this.box.markSubscribed(fits);
      over.push(...this.delivery.attach(client, fits));
    }
    const overRids = new Set(over.map((rid) => rid.toString('base64url')));
    const refused: { rid: string; code: 'auth_failed' | 'limit' }[] = [];
    cmd.subs.forEach(({ rid }, i) => {
      const b64 = rid.toString('base64url');
      if (!signed[i]) refused.push({ rid: b64, code: 'auth_failed' });
      else if (overRids.has(b64)) refused.push({ rid: b64, code: 'limit' });
    });
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

  /**
   * Step 1 `{platform, token}` pushes a code to the token; step 2 `{code,
   * queues}` activates each queue whose entry its own key signed over
   * `nid ‖ 0x02 ‖ code` (owner decision 34). A dead code refuses the whole
   * frame; a bad entry is refused alone, one answer for an unknown nid and a
   * wrong signature, as in `subscribe`.
   */
  @Throttle({
    default: { limit: BOX_LIMITS.registerNotifier, ttl: BOX_THROTTLE_TTL_MS },
  })
  @SubscribeMessage('registerNotifier')
  async registerNotifier(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ): Promise<
    BoxAnswer<
      | { state: 'challenged' }
      | { refused: { nid: string; code: 'auth_failed' }[] }
    >
  > {
    const cmd = parseRegisterNotifier(data);
    if (!cmd) return INVALID;
    if (cmd.step === 1) {
      await this.notifier.challenge(cmd.platform, cmd.token);
      return { ok: true, state: 'challenged' };
    }
    const challenge = this.notifier.liveChallenge(cmd.code);
    if (!challenge) return AUTH_FAILED;
    const keys = await this.box.authKeysByNid(cmd.queues.map((q) => q.nid));
    const accepted: Buffer[] = [];
    const refused: { nid: string; code: 'auth_failed' }[] = [];
    for (const { nid, sig } of cmd.queues) {
      const key = keys.get(nid.toString('base64url'));
      const message = boxSignedMessage(
        'registerNotifier',
        client.id,
        notifierActivateFields(nid, cmd.code),
      );
      if (key && verifyBoxSignature(key, message, sig)) accepted.push(nid);
      else
        refused.push({ nid: nid.toString('base64url'), code: 'auth_failed' });
    }
    await this.notifier.activate(challenge, accepted);
    return { ok: true, refused };
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
