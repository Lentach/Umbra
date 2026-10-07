import { Inject, Injectable, Logger, OnModuleDestroy } from '@nestjs/common';
import { createHash, randomBytes } from 'crypto';
import {
  BOX_CHALLENGE_TTL_MS,
  BOX_CODE_BYTES,
  BOX_PUSH_DEBOUNCE_MS,
  BOX_PUSH_MAX_WAIT_MS,
} from './box.constants';
import {
  BOX_PUSH_TRANSPORT,
  BOX_WAKE_PUSH_TTL_S,
  type BoxPushTransport,
} from './box-push.transport';
import { BoxService } from './box.service';
import type { NotifierPlatform } from './box-wire';

/** A pushed code the box still accepts, and the push target it proves. */
export interface PendingChallenge {
  platform: NotifierPlatform;
  token: string;
  expiresAt: number;
  /** Nids already activated under this code: a repeat rewrites nothing. */
  activated: Set<string>;
}

/** Outstanding challenges kept at most; the oldest go first past this. */
const MAX_CHALLENGES = 10_000;

/** Announced wake-ups remembered at most; pruned by age, then cleared. */
const MAX_ANNOUNCED = 10_000;

/**
 * Push for the box (design §4.5).
 *
 * Registration is a push-channel challenge (SMP NTF pattern), one per TOKEN
 * (owner decision 34): step 1 pushes a random code to the token and stores
 * NOTHING durable; step 2 brings that code back with a batch of queues, each
 * entry signed by its own queue key, and only then are their `box_notifiers`
 * rows written. A stolen token therefore cannot be attached to someone
 * else's queue to bomb its device: the code reaches the token's holder only.
 *
 * Pending codes live in memory for ten minutes, keyed by SHA-256(code) — the
 * code is the credential, so the lookup never compares it byte by byte, and
 * several codes for one token stand side by side: a stranger challenging the
 * same token, or a reconnect between the steps, voids nothing. A restart
 * only makes the client run step 1 again.
 *
 * Wake-ups are coalesced per nid (2.5 s after the last send, 10 s at most
 * after the first) — the same tuning as the identity-side coalescer. An FCM
 * wake-up is `{type:'new_message'}` and nothing else: its `data` transits
 * Google readable. A Web Push one adds, inside the RFC 8291-encrypted
 * payload, `n` (the nid, base64url) and `c` (the queue's waiting non-quiet,
 * unexpired messages), so the push SW shows one card per chat with its
 * count (decision 77).
 */
@Injectable()
export class BoxNotifierService implements OnModuleDestroy {
  private readonly logger = new Logger(BoxNotifierService.name);
  private readonly challenges = new Map<string, PendingChallenge>();
  private readonly pending = new Map<
    string,
    { timer: NodeJS.Timeout; firstAt: number; nid: Buffer; toSocket: boolean }
  >();
  /**
   * Per nid, the newest waiting message (`NotifierTarget.newest`) the last
   * Web Push wake-up announced, and when it went out. In memory only: a
   * restart costs at most one repeated wake-up.
   */
  private readonly announced = new Map<
    string,
    { newest: number | null; at: number }
  >();

  constructor(
    private readonly box: BoxService,
    @Inject(BOX_PUSH_TRANSPORT) private readonly transport: BoxPushTransport,
  ) {}

  onModuleDestroy(): void {
    for (const { timer } of this.pending.values()) clearTimeout(timer);
    this.pending.clear();
  }

  /** Step 1: push a fresh code to the token. Unsigned: it proves nothing by itself. */
  async challenge(platform: NotifierPlatform, token: string): Promise<void> {
    const now = Date.now();
    // Map order is insertion order, oldest first: drop the expired, and the
    // oldest while still at the cap.
    for (const [key, entry] of this.challenges) {
      if (entry.expiresAt <= now || this.challenges.size >= MAX_CHALLENGES) {
        this.challenges.delete(key);
      }
    }
    const code = randomBytes(BOX_CODE_BYTES);
    this.challenges.set(createHash('sha256').update(code).digest('base64url'), {
      platform,
      token,
      expiresAt: now + BOX_CHALLENGE_TTL_MS,
      activated: new Set(),
    });
    const outcome = await this.transport.send(platform, token, {
      type: 'notifier_challenge',
      code: code.toString('base64url'),
    });
    if (outcome !== 'sent')
      this.logger.debug(`[box] challenge push ${outcome}`);
  }

  /** The live challenge `code` answers, or null (never pushed, or expired). */
  liveChallenge(code: Buffer): PendingChallenge | null {
    const entry = this.challenges.get(
      createHash('sha256').update(code).digest('base64url'),
    );
    return entry && entry.expiresAt > Date.now() ? entry : null;
  }

  /**
   * Step 2: writes the notifier of each of `nids` (signatures verified by the
   * caller) under `challenge`'s target. A nid already activated with this
   * code is not rewritten — every verb is idempotent.
   */
  async activate(challenge: PendingChallenge, nids: Buffer[]): Promise<void> {
    const fresh = nids.filter(
      (nid) => !challenge.activated.has(nid.toString('base64url')),
    );
    if (fresh.length === 0) return;
    await this.box.saveNotifiers(fresh, challenge.platform, challenge.token);
    for (const nid of fresh) challenge.activated.add(nid.toString('base64url'));
  }

  /**
   * A blob landed on a queue (or a socket that held some went away): wake
   * its device, coalesced. `toSocket`: the blob went to a socket that owns
   * the rid. It sticks only while EVERY schedule in the window was one; a
   * single other one makes the flush an ordinary wake-up.
   */
  schedule(nid: Buffer, toSocket = false): void {
    const key = nid.toString('base64url');
    const now = Date.now();
    const current = this.pending.get(key);
    const firstAt = current?.firstAt ?? now;
    clearTimeout(current?.timer);
    const delay = Math.min(
      BOX_PUSH_DEBOUNCE_MS,
      Math.max(0, firstAt + BOX_PUSH_MAX_WAIT_MS - now),
    );
    const allToSocket = (current?.toSocket ?? true) && toSocket;
    const timer = setTimeout(() => {
      this.pending.delete(key);
      void this.flush(nid, allToSocket);
    }, delay);
    timer.unref();
    this.pending.set(key, { timer, firstAt, nid, toSocket: allToSocket });
  }

  /**
   * `toSocket`: every blob of the window went to a live socket. A native
   * (FCM) device then gets nothing, as before. A Web Push device is woken
   * only if something that may wake still waits (`waiting` > 0), whether
   * the wake-up follows a live socket (a frozen page keeps its socket until
   * the ping timeout and never acks, while a live page has acked by now) or
   * a detach (a page that resumes reconnects at once and acks the blob its
   * old socket held: driving a frozen page, a `c: 0` push followed its
   * resume and the card alerted for nothing).
   */
  private async flush(nid: Buffer, toSocket: boolean): Promise<void> {
    try {
      const notifier = await this.box.notifierFor(nid);
      if (!notifier) return;
      const key = nid.toString('base64url');
      if (notifier.platform === 'webpush') {
        if (notifier.waiting === 0) return;
        // Everything that waits was announced by an earlier wake-up: a
        // frozen page is woken 2.5 s after the send, and its socket's ping
        // timeout would wake it AGAIN ~40 s later for the same message (two
        // alerts for one message, found driving an Android emulator).
        const prior = this.announced.get(key)?.newest;
        if (
          prior !== undefined &&
          prior !== null &&
          notifier.newest !== null &&
          notifier.newest <= prior
        ) {
          return;
        }
      } else if (toSocket) {
        return;
      }
      const outcome = await this.transport.send(
        notifier.platform,
        notifier.token,
        notifier.platform === 'webpush'
          ? { type: 'new_message', n: key, c: notifier.waiting }
          : { type: 'new_message' },
      );
      if (outcome === 'sent' && notifier.platform === 'webpush') {
        this.announce(key, notifier.newest);
      }
      if (outcome === 'gone') await this.box.dropNotifier(nid, notifier.token);
    } catch (error) {
      this.logger.warn(
        `[box] wake-up push failed: ${error instanceof Error ? error.name : 'unknown'}`,
      );
    }
  }

  /** Remembers what a wake-up announced; drops entries older than its TTL. */
  private announce(key: string, newest: number | null): void {
    const now = Date.now();
    if (this.announced.size >= MAX_ANNOUNCED) {
      for (const [other, { at }] of this.announced) {
        if (now - at > BOX_WAKE_PUSH_TTL_S * 1000) this.announced.delete(other);
      }
      if (this.announced.size >= MAX_ANNOUNCED) this.announced.clear();
    }
    this.announced.set(key, { newest, at: now });
  }
}
