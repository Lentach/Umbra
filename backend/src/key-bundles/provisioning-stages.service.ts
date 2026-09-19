import { Injectable, Logger, OnModuleDestroy } from '@nestjs/common';
import { randomUUID } from 'crypto';

/** Lifetime of a provisioning stage (spec §5.1: 10-minute TTL). */
export const PROVISIONING_STAGE_TTL_MS = 10 * 60 * 1000;

/** How often expired stages are swept out between accesses. */
const SWEEP_INTERVAL_MS = 60 * 1000;

/**
 * One in-flight §5.1 provisioning ceremony.
 *
 * `deviceId` is allocated exactly ONCE, at `openProvisioning`, and memoized
 * here (spec §12 Stage-0 amendment (a)) — a duplicated or retried
 * `provisionDevice` re-uses it, never re-allocates. `ephPubP` pins the FIRST
 * ephemeral the primary presented (amendment (c)); `ephPubN` deliberately has
 * no field anywhere — it is QR-only and must never transit the server.
 */
export interface ProvisioningStage {
  readonly provisioningId: string;
  readonly userId: number;
  /** The exact socket that opened the ceremony; the hello relay targets it. */
  readonly openerSocketId: string;
  /** Which role the opener plays (amendment (lxxvii): default 'new'). */
  readonly openerRole: 'new' | 'primary';
  /**
   * Socket of the enrolled primary: the opener when `openerRole` is
   * 'primary', otherwise recorded at `provisioningHello`. Only this socket
   * may stage the blob (`provisionDevice`).
   */
  primarySocketId: string | null;
  /**
   * Socket of the joining device: the opener when `openerRole` is 'new',
   * otherwise recorded at `provisioningHello`. Blob fetch and completion
   * bind to it.
   */
  newDeviceSocketId: string | null;
  /** Memoized allocation from `users.nextDeviceId` (amendment (a)). */
  readonly deviceId: number;
  /** First `provisioningHello` ephemeral, base64 of 33 bytes. */
  ephPubP: string | null;
  /** Staged IK-bearing blob (opaque base64) — encrypted client-side. */
  blob: string | null;
  stagedListCanonical: string | null;
  stagedListSignature: string | null;
  /** Platform label of the staged list's new entry (amendment (i)). */
  platform: string | null;
  /** Epoch ms. */
  readonly expiresAt: number;
  /**
   * Flipped by the one-shot {@link ProvisioningStagesService.consume} CAS.
   * A consumed stage survives until TTL so a duplicate complete can be
   * answered `already_completed` instead of `unknown_stage`.
   */
  consumed: boolean;
}

/**
 * In-memory §5.1 provisioning stages, keyed by provisioningId.
 *
 * Deliberately NOT a table (spec §12 amendment (iv)): the stage is bound to
 * the opener's socket session, which cannot outlive the process — a backend
 * restart drops every pending stage, indistinguishable from TTL expiry and
 * handled by I1 abort hygiene on the client. Nothing durable leaks; counter
 * gaps from aborted ceremonies are safe per amendment (a).
 *
 * Multiple concurrent stages per account are ALLOWED — falsification 20
 * (concurrent double-link) depends on two stages racing the same version
 * slot and the loser re-signing.
 */
@Injectable()
export class ProvisioningStagesService implements OnModuleDestroy {
  private readonly logger = new Logger(ProvisioningStagesService.name);
  private readonly stages = new Map<string, ProvisioningStage>();
  private readonly sweepTimer: NodeJS.Timeout;

  constructor() {
    this.sweepTimer = setInterval(() => this.sweep(), SWEEP_INTERVAL_MS);
    // The sweep is hygiene between lazy expiries — it must never keep the
    // process (or a jest run) alive on its own.
    this.sweepTimer.unref?.();
  }

  onModuleDestroy(): void {
    clearInterval(this.sweepTimer);
  }

  open(
    userId: number,
    openerSocketId: string,
    deviceId: number,
    openerRole: 'new' | 'primary' = 'new',
  ): ProvisioningStage {
    const stage: ProvisioningStage = {
      provisioningId: randomUUID(),
      userId,
      openerSocketId,
      openerRole,
      primarySocketId: openerRole === 'primary' ? openerSocketId : null,
      newDeviceSocketId: openerRole === 'new' ? openerSocketId : null,
      deviceId,
      ephPubP: null,
      blob: null,
      stagedListCanonical: null,
      stagedListSignature: null,
      platform: null,
      expiresAt: Date.now() + PROVISIONING_STAGE_TTL_MS,
      consumed: false,
    };
    this.stages.set(stage.provisioningId, stage);
    this.logger.log(`[provisioning] stage opened deviceId=${deviceId}`);
    return stage;
  }

  /**
   * The stage, or null when it never existed or has expired. Lazy expiry:
   * an expired stage is dropped on access, so "expired" and "unknown" are
   * deliberately indistinguishable to callers.
   */
  get(provisioningId: string): ProvisioningStage | null {
    const stage = this.stages.get(provisioningId);
    if (!stage) return null;
    if (stage.expiresAt <= Date.now()) {
      this.stages.delete(provisioningId);
      return null;
    }
    return stage;
  }

  /**
   * One-shot compare-and-set (spec §12 amendment (a)). SYNCHRONOUS on
   * purpose: the Node event loop makes check+flip atomic, so of two
   * concurrent `provisioningComplete` calls exactly one wins.
   */
  consume(provisioningId: string): boolean {
    const stage = this.get(provisioningId);
    if (!stage || stage.consumed) return false;
    stage.consumed = true;
    return true;
  }

  /**
   * Returns a consumed stage to the unconsumed pool after a FAILED commit
   * transaction (e.g. `stale_version` — falsification 20: the primary
   * re-signs v+2 against the SAME stage). The stage stays live until TTL.
   */
  restore(provisioningId: string): void {
    const stage = this.get(provisioningId);
    if (stage) stage.consumed = false;
  }

  /**
   * Retires a stage whose commit SUCCEEDED: `consumed` stays true so a
   * duplicate complete answers `already_completed`, and the blob is dropped
   * so it can never be re-fetched after commit (amendment (a)).
   */
  retire(provisioningId: string): void {
    const stage = this.get(provisioningId);
    if (!stage) return;
    stage.consumed = true;
    stage.blob = null;
    stage.stagedListCanonical = null;
    stage.stagedListSignature = null;
  }

  /** Drops a stage entirely (cancel — spec §5.1 discard rule). */
  discard(provisioningId: string): void {
    this.stages.delete(provisioningId);
  }

  /**
   * Drops EVERY stage of one account and returns how many (spec §5.1
   * "revoke preempts linking" + §12 amendment (xxv)).
   *
   * Account-wide, not scoped to the revoked deviceId: every live stage carries
   * a list mutation signed against the PRE-revocation list, so revocation's
   * version+1 makes all of them stale by construction. Discarding turns a
   * guaranteed `stale_version` at commit into an immediate, honest
   * `unknown_stage`, and a security action never waits on a stuck link.
   */
  discardForUser(userId: number): number {
    let discarded = 0;
    for (const [id, stage] of this.stages) {
      if (stage.userId !== userId) continue;
      this.stages.delete(id);
      discarded += 1;
    }
    if (discarded > 0) {
      this.logger.log(
        `[provisioning] ${discarded} stage(s) preempted by revocation`,
      );
    }
    return discarded;
  }

  /** Periodic hygiene between lazy expiries. */
  sweep(): void {
    const now = Date.now();
    for (const [id, stage] of this.stages) {
      if (stage.expiresAt <= now) this.stages.delete(id);
    }
  }
}
