import { Inject, Injectable, Logger, OnModuleDestroy } from '@nestjs/common';
import { randomBytes, timingSafeEqual } from 'crypto';
import {
  BOX_CHALLENGE_TTL_MS,
  BOX_CODE_BYTES,
  BOX_PUSH_DEBOUNCE_MS,
  BOX_PUSH_MAX_WAIT_MS,
} from './box.constants';
import {
  BOX_PUSH_TRANSPORT,
  type BoxPushTransport,
} from './box-push.transport';
import { BoxService } from './box.service';
import type { NotifierPlatform } from './box-wire';

interface Challenge {
  code: Buffer;
  platform: NotifierPlatform;
  token: string;
  expiresAt: number;
  activated: boolean;
}

/** Outstanding challenges kept at most; the oldest go first past this. */
const MAX_CHALLENGES = 10_000;

/**
 * Push for the box (design §4.5).
 *
 * Registration is a push-channel challenge (SMP NTF pattern): step 1 pushes
 * a random code to the token and stores NOTHING durable; step 2 must bring
 * that code back signed by the queue's auth key, and only then is the
 * `box_notifiers` row written. A stolen token therefore cannot be attached to
 * someone else's queue to bomb its device. Pending challenges live in memory
 * for ten minutes: a restart only makes the client run step 1 again.
 *
 * Wake-ups carry `{type:'new_message'}` and nothing else, coalesced per nid
 * (2.5 s after the last send, 10 s at most after the first) — the same tuning
 * as the identity-side coalescer.
 */
@Injectable()
export class BoxNotifierService implements OnModuleDestroy {
  private readonly logger = new Logger(BoxNotifierService.name);
  private readonly challenges = new Map<string, Challenge>();
  private readonly pending = new Map<
    string,
    { timer: NodeJS.Timeout; firstAt: number; nid: Buffer }
  >();

  constructor(
    private readonly box: BoxService,
    @Inject(BOX_PUSH_TRANSPORT) private readonly transport: BoxPushTransport,
  ) {}

  onModuleDestroy(): void {
    for (const { timer } of this.pending.values()) clearTimeout(timer);
    this.pending.clear();
  }

  /** Step 1: push a fresh code to the token. The caller already verified the signature. */
  async challenge(
    nid: Buffer,
    platform: NotifierPlatform,
    token: string,
  ): Promise<void> {
    const now = Date.now();
    // Map order is insertion order, oldest first: drop the expired, and the
    // oldest while still at the cap.
    for (const [key, entry] of this.challenges) {
      if (entry.expiresAt <= now || this.challenges.size >= MAX_CHALLENGES) {
        this.challenges.delete(key);
      }
    }
    const code = randomBytes(BOX_CODE_BYTES);
    const key = nid.toString('base64url');
    // Re-inserted, not updated: Map order is the eviction order above.
    this.challenges.delete(key);
    this.challenges.set(key, {
      code,
      platform,
      token,
      expiresAt: now + BOX_CHALLENGE_TTL_MS,
      activated: false,
    });
    const outcome = await this.transport.send(platform, token, {
      type: 'notifier_challenge',
      code: code.toString('base64url'),
    });
    if (outcome !== 'sent')
      this.logger.debug(`[box] challenge push ${outcome}`);
  }

  /**
   * Step 2: the code came back (signature verified by the caller). True when
   * it matches a live challenge for this nid. A repeat of an accepted code
   * answers true again without rewriting — every verb is idempotent.
   */
  async activate(nid: Buffer, code: Buffer): Promise<boolean> {
    const entry = this.challenges.get(nid.toString('base64url'));
    if (!entry || entry.expiresAt <= Date.now()) return false;
    if (!timingSafeEqual(entry.code, code)) return false;
    if (!entry.activated) {
      await this.box.saveNotifier(nid, entry.platform, entry.token);
      entry.activated = true;
    }
    return true;
  }

  /** A blob landed on a queue nobody is subscribed to: wake its device, coalesced. */
  schedule(nid: Buffer): void {
    const key = nid.toString('base64url');
    const now = Date.now();
    const current = this.pending.get(key);
    const firstAt = current?.firstAt ?? now;
    clearTimeout(current?.timer);
    const delay = Math.min(
      BOX_PUSH_DEBOUNCE_MS,
      Math.max(0, firstAt + BOX_PUSH_MAX_WAIT_MS - now),
    );
    const timer = setTimeout(() => {
      this.pending.delete(key);
      void this.flush(nid);
    }, delay);
    timer.unref();
    this.pending.set(key, { timer, firstAt, nid });
  }

  private async flush(nid: Buffer): Promise<void> {
    try {
      const notifier = await this.box.notifierFor(nid);
      if (!notifier) return;
      const outcome = await this.transport.send(
        notifier.platform,
        notifier.token,
        { type: 'new_message' },
      );
      if (outcome === 'gone') await this.box.dropNotifier(nid, notifier.token);
    } catch (error) {
      this.logger.warn(
        `[box] wake-up push failed: ${error instanceof Error ? error.name : 'unknown'}`,
      );
    }
  }
}
