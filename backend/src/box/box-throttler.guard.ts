import { ExecutionContext, Injectable, Logger } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import {
  InjectThrottlerOptions,
  InjectThrottlerStorage,
  normalizeIp,
  ThrottlerGuard,
  type ThrottlerLimitDetail,
  type ThrottlerModuleOptions,
  type ThrottlerStorage,
} from '@nestjs/throttler';
import { MESSAGE_METADATA } from '@nestjs/websockets/constants';
import type { Socket } from 'socket.io';
import { proxiedClientIp } from '../common/client-ip';
import { BoxDelivery } from './box-delivery.service';
import { parseAck, type BoxRefusal } from './box-wire';

/**
 * Who a box caller is, for throttling: its client IP as nginx reported it
 * (`X-Real-IP`, `common/client-ip.ts`), with an IPv6 address widened to its
 * /64 — a client holding a /64 would otherwise rotate source addresses and
 * never share a counter (findings §2026-09-22 night, input #2). Masking here
 * leaves the login/register buckets, which key on the full address, alone.
 */
export function boxTrackerFor(
  headers: Record<string, string | string[] | undefined> | undefined,
  fallbackAddress: string | undefined,
): string {
  return normalizeIp(
    proxiedClientIp(headers) ?? fallbackAddress ?? 'unknown',
    64,
  );
}

/**
 * Refusals since the last `takeRefusalCounts()`: throttles per event
 * (`send`, `subscribe`, …) and quota refusals as `<event>:<cause>` (E11) —
 * `send:ceiling`, `mediaUpload:ceiling` (the global ceiling, decision 30)
 * and `mediaUpload:budget` (a queue's daily budget, or a request queue). The
 * one abuse signal for the unauthenticated namespace (nginx keeps no access
 * log, `infra/nginx/fireplace.conf`): a COUNTER, never a tracker, so the
 * prod log says "send was refused 900 times" and never from where.
 */
const refusals = new Map<string, number>();

export function countRefusal(key: string): void {
  refusals.set(key, (refusals.get(key) ?? 0) + 1);
}

/** The counts since the previous call, which starts a new window. */
export function takeRefusalCounts(): Map<string, number> {
  const window = new Map(refusals);
  refusals.clear();
  return window;
}

/**
 * Rate limits for `/box` (I1 forbids reusing `chat/`'s `WsThrottlerGuard`).
 *
 * Every box event is answered on its socket.io ACK, so a throttled event is
 * answered there too — `{ok:false, code:'rate_limited', retryAfterMs}` — and
 * then refused, so the handler never runs. Nest's WS args are
 * `[client, data, ack?]`, hence `getArgs()[2]`.
 *
 * An event WITHOUT an ack has no reply channel at all: every answer, the
 * refusals included, would be silence. That is a broken client, and it is
 * disconnected (`io server disconnect`) before it spends a bucket.
 *
 * An `ack` naming a message the box pushed to THIS socket and not yet acked
 * skips the limit, once per push (`BoxDelivery.claimAck`): the victim of a
 * junk flood on its public request sid acks every frame, and a per-address
 * bucket spent on those would hold every queue on its socket behind a full
 * window. Any other ack — a stale id, a forgery, a repeat — is counted.
 */
@Injectable()
export class BoxThrottlerGuard extends ThrottlerGuard {
  private readonly boxLogger = new Logger(BoxThrottlerGuard.name);

  constructor(
    @InjectThrottlerOptions() options: ThrottlerModuleOptions,
    @InjectThrottlerStorage() storageService: ThrottlerStorage,
    reflector: Reflector,
    private readonly delivery: BoxDelivery,
  ) {
    super(options, storageService, reflector);
  }

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const ack: unknown = context.getArgs()[2];
    if (typeof ack !== 'function') {
      context.switchToWs().getClient<Socket>().disconnect(true);
      return false;
    }
    return super.canActivate(context);
  }

  protected shouldSkip(context: ExecutionContext): Promise<boolean> {
    if (eventOf(context) !== 'ack') return Promise.resolve(false);
    const ws = context.switchToWs();
    const cmd = parseAck(ws.getData());
    return Promise.resolve(
      cmd !== null && this.delivery.claimAck(ws.getClient<Socket>().id, cmd.id),
    );
  }

  protected getRequestResponse(context: ExecutionContext) {
    const client = context.switchToWs().getClient<Socket>();
    // ThrottlerGuard sets rate-limit headers on `res`; a socket has none.
    const res = {
      header() {
        return res;
      },
    };
    return {
      req: client as unknown as Record<string, unknown>,
      res: res as unknown as Record<string, unknown>,
    };
  }

  protected getTracker(req: Record<string, unknown>): Promise<string> {
    // `req` is the socket handed over by getRequestResponse above.
    const socket = req as unknown as Socket;
    return Promise.resolve(
      boxTrackerFor(socket.handshake?.headers, socket.handshake?.address),
    );
  }

  protected async throwThrottlingException(
    context: ExecutionContext,
    detail: ThrottlerLimitDetail,
  ): Promise<void> {
    // canActivate let only ack-carrying events through.
    const ack = context.getArgs()[2] as (answer: BoxRefusal) => void;
    const refusal: BoxRefusal = {
      ok: false,
      code: 'rate_limited',
      retryAfterMs: Math.max(0, detail.timeToBlockExpire * 1000),
    };
    ack(refusal);
    const name = eventOf(context) ?? 'unknown';
    countRefusal(name);
    // Per refusal at debug only: a flood must not amplify itself through prod
    // logs. `BoxReaper` logs the counts every sweep.
    this.boxLogger.debug(`[box-throttle] refused event=${name}`);
    return super.throwThrottlingException(context, detail);
  }
}

function eventOf(context: ExecutionContext): string | undefined {
  return Reflect.getMetadata(MESSAGE_METADATA, context.getHandler()) as
    string | undefined;
}
