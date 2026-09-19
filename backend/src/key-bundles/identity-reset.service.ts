import { Injectable, Logger } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { InjectRepository } from '@nestjs/typeorm';
import { DataSource, Repository } from 'typeorm';
import * as argon2 from 'argon2';
import { AccountAuthorization } from './account-authorization.entity';
import { IdentityResetRequest } from './identity-reset-request.entity';
import { RecoveryKey } from './recovery-key.entity';

/**
 * Phrase-sealed identity backup as written / served (amendment (lxxviii)
 * clause 1). Opaque to the server: `blob` is base64(iv12 || AES-256-GCM ct)
 * under PBKDF2-HMAC-SHA256(NFKD phrase, salt, iterations); `version` names
 * the blob format (1 is the only one defined).
 */
export interface IdentityBackupInput {
  blob: string;
  salt: string;
  iterations: number;
  version: number;
}

/** The same shape read back for `getIdentityBackup` — never partial. */
export type IdentityBackupRecord = IdentityBackupInput;

/**
 * Delay before a reset may replace the account identity. Owner-confirmed at
 * 72 h on 2026-08 (push is this app's only offline channel, so the window had
 * to survive a phone face-down overnight); lowered to 6 h by amendment
 * (lxxxii) clause 1 under the "seed is the account" posture — the push on
 * `identityResetPending` is now the only thing between a password thief and
 * the account for those 6 h, and the owner accepted that.
 */
export const RESET_DELAY_MS = 6 * 60 * 60 * 1000;

/**
 * Delay when a valid recovery key is presented. Shortens the wait; it never
 * removes the notifications or the ability to cancel (§6.2.1).
 */
export const RESET_DELAY_RECOVERY_MS = 60 * 60 * 1000;

/** Quiet period after a cancel, so a refused attempt cannot be retried in a loop. */
export const CANCEL_COOLDOWN_MS = 24 * 60 * 60 * 1000;

/**
 * How long a COMPLETED ceremony stays spendable.
 *
 * Without this bound a completed ceremony is a standing authorization: the
 * delay has already elapsed, so the replacement it permits is instant, and
 * `cancelReset` cannot touch it (that only acts on a pending row). An account
 * whose owner recovered their device and simply stopped would keep an
 * indefinite, un-cancellable instant-replacement grant — the exact "zero-delay
 * path" §6.2.1 rules out. Bounded, an unused grant lapses and a fresh ceremony
 * (with its full delay and notifications) is required again; starting one is
 * not blocked, since the cooldown applies only after a CANCEL.
 */
export const COMPLETED_GRANT_TTL_MS = 24 * 60 * 60 * 1000;

export const RECOVERY_MAX_FAILED_ATTEMPTS = 5;
export const RECOVERY_LOCKOUT_MS = 60 * 60 * 1000;

/**
 * How long a recovery phrase must have been enrolled before it may SHORTEN a
 * reset (spec §12 amendment (xlii)).
 *
 * The actor this defends against is a PASSWORD thief, and the point that
 * decides the design is that such a thief can already run the ordinary 6 h
 * credentials-only ceremony — that is the documented lost-device path. What
 * they must not also get is the SHORTCUT: enrol a phrase they chose, spend it
 * in the next message, and cut the owner's cancel window from 6 h to 1 h.
 * Password re-authentication would not stop them (they have the password), so
 * the age is the control that actually bites: any phrase minted after the
 * compromise is younger than this and buys nothing.
 *
 * Set to the full reset delay. A phrase old enough to shorten the window is
 * one that predates a same-session compromise by at least as long as the
 * window it removes. The genuine case — a careful user who enrolled a key in
 * advance, which is the entire point of the feature — is untouched.
 *
 * A phrase younger than this is NOT rejected and NOT spent: the ceremony still
 * starts, at the full delay. Refusing would break the lost-device path, and
 * spending would burn the user's key for nothing.
 */
//
// Its own literal, not an alias of RESET_DELAY_MS: the two are separate
// policies that happen to coincide today, and the spec pins the equality
// ("the reset delay is 6 hours and the age floor equals it") so a drift is a
// deliberate, tested decision rather than a silent side effect.
export const RECOVERY_MIN_AGE_MS = 6 * 60 * 60 * 1000;

/**
 * Argon2id parameters for the recovery-key verifier. Memory-hard on purpose:
 * a database dump must not turn into an offline guessing exercise. Values are
 * the current OWASP Password Storage profile (19 MiB, 2 iterations, 1 lane).
 * Raising these stays compatible (the PHC string self-describes, so existing
 * hashes keep verifying); dropping below OWASP guidance does not.
 */
export const RECOVERY_ARGON2_OPTIONS: argon2.HashOptions = {
  type: argon2.argon2id,
  memoryCost: 19456,
  timeCost: 2,
  parallelism: 1,
};

/**
 * A verifier of an arbitrary phrase under {@link RECOVERY_ARGON2_OPTIONS},
 * verified against when there is NOTHING real to verify — an unknown
 * identifier at `/auth/recover`, or a known account with no phrase enrolled —
 * so neither answers faster than a wrong phrase would ((lxxxii) clause 2:
 * the door is unauthenticated, and response time must not enumerate who
 * exists or who enrolled). Login's `TIMING_SAFE_DUMMY_HASH` is the bcrypt
 * precedent.
 */
export const TIMING_SAFE_DUMMY_VERIFIER =
  '$argon2id$v=19$m=19456,p=1,t=2$w2BrHORjqgyeXxt8gHZoKg$cJ92sbtx0cBRD/dsML6P5/sN5qKUBQNSM3Et6pDD5T0';

export type RequestResetStatus =
  | 'pending'
  | 'existing'
  | 'cooldown'
  | 'invalid_phrase'
  | 'locked'
  /**
   * (lxxiii) opt-in lock: the account has no `account_authorizations` row,
   * so the §6.1 refusal is not armed and a fresh install replaces the
   * identity on credentials alone. There is nothing for a ceremony to
   * authorize — and its completion teardown would revoke device 1 and move
   * the account onto an id no peer can synthesize while it stays un-enrolled.
   */
  | 'not_enrolled';

export interface RequestResetResult {
  status: RequestResetStatus;
  deadlineAt: Date | null;
  shortened: boolean;
  /**
   * The presented phrase was CORRECT but younger than {@link
   * RECOVERY_MIN_AGE_MS}, so it could not buy the shortcut (amendment (xlii))
   * and the ceremony runs the full delay.
   *
   * Reported rather than swallowed because the silent form is indistinguishable
   * from "no phrase given", which leaves an owner who typed their phrase
   * correctly staring at 6 h with no idea why. This discloses nothing new: a
   * WRONG phrase already answers `invalid_phrase`, so phrase correctness is
   * already observable — this only explains a delay the caller can see anyway.
   */
  phraseTooNew: boolean;
}

export interface IdentityResetStatusSummary {
  status: 'pending' | 'completed';
  deadlineAt: Date;
  /**
   * Whether a recovery key shortened this ceremony (§6.2.1). Carried so a
   * session that reconnects INTO a running ceremony can say the same thing the
   * live broadcast said, instead of describing a 1 h wait as the default 6 h one.
   */
  shortened: boolean;
}

/**
 * Internal: the partial unique index refused a second pending row because a
 * concurrent request won the race.
 *
 * Thrown so the transaction ROLLS BACK. The loser may have presented a valid
 * recovery phrase, and that phrase is single-use: committing here would spend
 * it on a ceremony it did not create, leaving the account on the winner's
 * un-shortened 6 h deadline with no phrase left to shorten a retry.
 */
class PendingResetConflict extends Error {
  constructor(readonly insertError: unknown) {
    super('a pending reset already exists for this account');
    this.name = 'PendingResetConflict';
  }
}

/**
 * The account-identity reset ceremony (Phase 0b, multi-device spec §6.2) and
 * its optional recovery key (§6.2.1).
 *
 * This service owns ceremony STATE only — notifications are fanned out by the
 * socket layer, which holds the room and push plumbing. All state lives in
 * Postgres because every timing decision must survive a container restart.
 */
@Injectable()
export class IdentityResetService {
  private readonly logger = new Logger(IdentityResetService.name);

  constructor(
    @InjectRepository(IdentityResetRequest)
    private readonly resetRepo: Repository<IdentityResetRequest>,
    @InjectRepository(RecoveryKey)
    private readonly recoveryRepo: Repository<RecoveryKey>,
    @InjectRepository(AccountAuthorization)
    private readonly authorizationRepo: Repository<AccountAuthorization>,
    private readonly dataSource: DataSource,
  ) {}

  /**
   * Starts a ceremony, or reports why it was not started.
   *
   * A phrase presentation and the resulting row commit together: a phrase can
   * never be spent without producing the ceremony it paid for, and a shortened
   * ceremony can never exist without the phrase having been spent.
   */
  async requestReset(
    userId: number,
    recoveryPhrase?: string,
  ): Promise<RequestResetResult> {
    const existing = await this.resetRepo.findOne({
      where: { userId, status: 'pending' },
    });
    if (existing) {
      return {
        status: 'existing',
        deadlineAt: existing.deadlineAt,
        shortened: existing.shortened,
        // An already-running ceremony short-circuits BEFORE the phrase is
        // examined, so there is no age verdict to report.
        phraseTooNew: false,
      };
    }

    // (lxxiii) opt-in lock: an un-enrolled account is never refused by §6.1,
    // so a ceremony cannot help it and its completion would actively harm it
    // (see `RequestResetStatus`). Refused BEFORE the phrase is examined —
    // this is a fact about the account, not an attempt against the phrase,
    // so it spends nothing and never counts toward the five-attempt lockout.
    // Ordered after the pending check on purpose: a row created before this
    // rule existed must keep answering `existing` so it stays cancellable.
    const enrolled =
      (await this.authorizationRepo.findOne({
        where: { userId },
        select: { userId: true },
      })) !== null;
    if (!enrolled) {
      this.logger.warn(
        `[identity-reset] request refused: account not enrolled`,
      );
      return {
        status: 'not_enrolled',
        deadlineAt: null,
        shortened: false,
        phraseTooNew: false,
      };
    }

    // 24h post-cancel cooldown (§6.2), with the 2026-08-19 carve-out: a
    // password change VOIDS a cooldown armed before it. The refusal copy tells
    // a user whose ceremony an intruder cancelled to change their password;
    // once they have (revoking every refresh token), the attacker-authored
    // cancel must not keep the owner locked out of a legitimate ceremony.
    // Deliberately narrow: a PENDING ceremony is never cancelled here (rows
    // carry no requester attribution — cancelling could discard the owner's
    // own in-flight 6 h wait), and a cancel AFTER the password change still
    // cools down as before.
    const recentCancel = await this.resetRepo
      .createQueryBuilder('r')
      .innerJoin('users', 'u', 'u.id = r."userId"')
      .where('r."userId" = :userId', { userId })
      .andWhere('r.status = :status', { status: 'cancelled' })
      .andWhere('r."cancelledAt" > :since', {
        since: new Date(Date.now() - CANCEL_COOLDOWN_MS),
      })
      .andWhere(
        '(u."passwordChangedAt" IS NULL OR r."cancelledAt" > u."passwordChangedAt")',
      )
      .orderBy('r."cancelledAt"', 'DESC')
      .getOne();
    if (recentCancel) {
      this.logger.warn(
        `[identity-reset] request refused by post-cancel cooldown`,
      );
      return {
        status: 'cooldown',
        deadlineAt: null,
        shortened: false,
        phraseTooNew: false,
      };
    }

    try {
      return await this.dataSource.transaction(async (manager) => {
        let shortened = false;
        let phraseTooNew = false;
        if (recoveryPhrase != null && recoveryPhrase.length > 0) {
          const outcome = await this.spendRecoveryPhrase(
            manager.getRepository(RecoveryKey),
            userId,
            recoveryPhrase,
          );
          // `too_new` is the ONLY non-accepted outcome that still starts a
          // ceremony (amendment (xlii)): the phrase was right but cannot buy
          // the shortcut, so the owner keeps the full 6 h to notice and
          // cancel. Refusing outright would break the lost-device path that
          // §6.2 exists to serve.
          if (outcome !== 'accepted' && outcome !== 'too_new') {
            return {
              status: outcome,
              deadlineAt: null,
              shortened: false,
              phraseTooNew: false,
            };
          }
          shortened = outcome === 'accepted';
          phraseTooNew = outcome === 'too_new';
        }

        const deadlineAt = new Date(
          Date.now() + (shortened ? RESET_DELAY_RECOVERY_MS : RESET_DELAY_MS),
        );
        try {
          await manager.getRepository(IdentityResetRequest).insert({
            userId,
            status: 'pending',
            deadlineAt,
            shortened,
          });
        } catch (error) {
          // Leave the transaction by throwing: the winner's row is not visible
          // to this one anyway, and rolling back is what un-spends a recovery
          // phrase this request paid but got no ceremony for.
          throw new PendingResetConflict(error);
        }
        this.logger.warn(
          `[identity-reset] ceremony started shortened=${shortened} phraseTooNew=${phraseTooNew} deadlineAt=${deadlineAt.toISOString()}`,
        );
        return {
          status: 'pending' as const,
          deadlineAt,
          shortened,
          phraseTooNew,
        };
      });
    } catch (error) {
      if (!(error instanceof PendingResetConflict)) throw error;
      // Read the winner AFTER the rollback, on a fresh transaction: report its
      // deadline rather than inventing one.
      const winner = await this.resetRepo.findOne({
        where: { userId, status: 'pending' },
      });
      if (winner) {
        return {
          status: 'existing',
          deadlineAt: winner.deadlineAt,
          shortened: winner.shortened,
          // The race winner's ceremony, not ours: this request's phrase (if
          // any) bought nothing, and the rollback un-spent it.
          phraseTooNew: false,
        };
      }
      // No winner: the insert failed for some other reason (or the race winner
      // was cancelled in between). Nothing was spent, so surface the fault.
      throw error.insertError;
    }
  }

  /**
   * Verifies and spends a recovery phrase, returning 'accepted' or the status
   * explaining the refusal. Failures are counted and trigger a lockout, so the
   * phrase cannot be guessed online.
   *
   * `too_new` is NOT a refusal of the reset (amendment (xlii)): the phrase is
   * genuine but younger than [RECOVERY_MIN_AGE_MS], so it may not buy the
   * shortened window. The caller starts the ceremony at the FULL delay. The
   * phrase is deliberately left UNSPENT — it is the user's, it was correct,
   * and burning it here would cost a legitimate owner their key for nothing.
   */
  private async spendRecoveryPhrase(
    recoveryRepo: Repository<RecoveryKey>,
    userId: number,
    phrase: string,
  ): Promise<'accepted' | 'invalid_phrase' | 'locked' | 'too_new'> {
    const row = await recoveryRepo.findOne({ where: { userId } });
    // No phrase enrolled, or already spent: same answer either way, so the
    // wording never distinguishes the two. It is not constant TIME — an
    // enrolled account pays a 19 MiB Argon2id verify and an un-enrolled one
    // returns at once — and it does not need to be: this path is reachable
    // only by a caller already authenticated AS the account, who can read the
    // enrolment state from their own settings screen anyway.
    if (!row || row.usedAt != null) return 'invalid_phrase';
    const verdict = await this.verifyAgainstRow(recoveryRepo, row, phrase);
    if (verdict !== 'accepted') return verdict;

    // The phrase is correct. It may still be too YOUNG to buy the shortcut
    // (amendment (xlii)) — checked only now, after verification, so a wrong
    // guess still costs a failed attempt and cannot be used to probe the
    // enrolment age. Left unspent on purpose; see the doc comment.
    const ageMs = Date.now() - row.createdAt.getTime();
    if (ageMs < RECOVERY_MIN_AGE_MS) {
      this.logger.warn(
        `[identity-reset] recovery phrase too new to shorten ageMs=${ageMs} requiredMs=${RECOVERY_MIN_AGE_MS}`,
      );
      return 'too_new';
    }

    // Single-use: spent in the same transaction that creates the ceremony.
    await recoveryRepo.update(
      { id: row.id },
      { usedAt: new Date(), failedAttempts: 0, lockedUntil: null },
    );
    return 'accepted';
  }

  /**
   * The phrase as a CREDENTIAL (amendment (lxxxii) clause 2): verified against
   * the stored verifier through the same failure counter and lockout the
   * §6.2 shortcut spends, never consumed, `usedAt` ignored — `usedAt` marks
   * the SHORTCUT as taken, and the (lxxviii) restore door ignores it for the
   * same reason. The age rule does not apply either: it defends the shortcut
   * against a phrase the thief minted, and minting one already requires the
   * identity. No phrase enrolled reads as a wrong phrase, deliberately — and
   * COSTS the same: this door is unauthenticated, so the answer must not be
   * faster for an account that never enrolled.
   */
  async verifyRecoveryPhrase(
    userId: number,
    phrase: string,
  ): Promise<'accepted' | 'invalid_phrase' | 'locked'> {
    const row = await this.recoveryRepo.findOne({ where: { userId } });
    if (!row) {
      await argon2
        .verify(TIMING_SAFE_DUMMY_VERIFIER, phrase)
        .catch(() => false);
      return 'invalid_phrase';
    }
    return this.verifyAgainstRow(this.recoveryRepo, row, phrase);
  }

  private async verifyAgainstRow(
    recoveryRepo: Repository<RecoveryKey>,
    row: RecoveryKey,
    phrase: string,
  ): Promise<'accepted' | 'invalid_phrase' | 'locked'> {
    if (row.lockedUntil != null && row.lockedUntil.getTime() > Date.now()) {
      return 'locked';
    }

    const valid = await argon2
      .verify(row.verifierHash, phrase)
      .catch((error: unknown) => {
        // A malformed stored hash must never authorize anything.
        this.logger.error(
          `[identity-reset] recovery verify failed: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
        return false;
      });
    if (valid) {
      // A correct presentation clears the budget, as the shortcut does on
      // spend — four fumbles before the right words must not leave the owner
      // one typo from an hour's lockout.
      if (row.failedAttempts > 0) {
        await recoveryRepo.update(
          { id: row.id },
          { failedAttempts: 0, lockedUntil: null },
        );
      }
      return 'accepted';
    }

    // Counted in SQL, not read-modify-write: two failures landing together
    // would otherwise both read the same count and both store count+1,
    // quietly buying extra attempts before the lockout.
    const updated = await recoveryRepo
      .createQueryBuilder()
      .update(RecoveryKey)
      .set({
        failedAttempts: () => '"failedAttempts" + 1',
        lockedUntil: () =>
          `CASE WHEN "failedAttempts" + 1 >= ${RECOVERY_MAX_FAILED_ATTEMPTS}` +
          ` THEN :lockedUntil ELSE "lockedUntil" END`,
      })
      .where('id = :id', {
        id: row.id,
        lockedUntil: new Date(Date.now() + RECOVERY_LOCKOUT_MS),
      })
      .returning(['failedAttempts'])
      .execute();
    const stored = (updated.raw as Array<{ failedAttempts?: number }>)[0]
      ?.failedAttempts;
    const failedAttempts = Number(stored ?? row.failedAttempts + 1);
    return failedAttempts >= RECOVERY_MAX_FAILED_ATTEMPTS
      ? 'locked'
      : 'invalid_phrase';
  }

  /**
   * Cancels the pending ceremony. Conditional on status='pending', which is
   * what serializes a cancel against the expiry commit: if the commit already
   * landed, this affects no rows and the completed reset stands.
   */
  async cancelReset(userId: number): Promise<boolean> {
    const result = await this.resetRepo
      .createQueryBuilder()
      .update(IdentityResetRequest)
      .set({ status: 'cancelled', cancelledAt: () => 'now()' })
      .where('"userId" = :userId', { userId })
      .andWhere('status = :status', { status: 'pending' })
      .execute();
    const cancelled = (result.affected ?? 0) > 0;
    if (cancelled) {
      this.logger.warn(`[identity-reset] ceremony cancelled`);
    }
    return cancelled;
  }

  /**
   * Spends a completed ceremony to authorize exactly one identity replacement.
   * Conditional on consumedAt IS NULL, so two concurrent uploads can never both
   * be authorized by the same ceremony.
   */
  async consumeCompletedReset(userId: number): Promise<boolean> {
    const result = await this.resetRepo
      .createQueryBuilder()
      .update(IdentityResetRequest)
      .set({ consumedAt: () => 'now()' })
      .where('"userId" = :userId', { userId })
      .andWhere('status = :status', { status: 'completed' })
      .andWhere('"consumedAt" IS NULL')
      .andWhere('"completedAt" > :graceSince', {
        graceSince: new Date(Date.now() - COMPLETED_GRANT_TTL_MS),
      })
      .execute();
    const consumed = (result.affected ?? 0) > 0;
    if (consumed) {
      this.logger.warn(
        `[identity-reset] completed ceremony consumed by identity upload`,
      );
    }
    return consumed;
  }

  /**
   * What a client needs to render its own state at connect time: a pending
   * ceremony with its deadline, or an unspent completed one.
   */
  async getStatusForUser(
    userId: number,
  ): Promise<IdentityResetStatusSummary | null> {
    const pending = await this.resetRepo.findOne({
      where: { userId, status: 'pending' },
    });
    if (pending) {
      return {
        status: 'pending',
        deadlineAt: pending.deadlineAt,
        shortened: pending.shortened,
      };
    }
    const completed = await this.resetRepo
      .createQueryBuilder('r')
      .where('r."userId" = :userId', { userId })
      .andWhere('r.status = :status', { status: 'completed' })
      .andWhere('r."consumedAt" IS NULL')
      .andWhere('r."completedAt" > :graceSince', {
        graceSince: new Date(Date.now() - COMPLETED_GRANT_TTL_MS),
      })
      .orderBy('r."completedAt"', 'DESC')
      .getOne();
    if (completed) {
      return {
        status: 'completed',
        deadlineAt: completed.deadlineAt,
        shortened: completed.shortened,
      };
    }
    return null;
  }

  /**
   * Enrolls or replaces the account's recovery phrase. Only the Argon2id
   * verifier is stored. Replacing clears the spent/lockout state, because the
   * new phrase is a new secret.
   *
   * Replacing ALSO restarts the age clock (amendment (xlii)). `createdAt` is a
   * `@CreateDateColumn`, so an UPDATE leaves it at the ORIGINAL enrolment —
   * which would hand a thief the whole shortcut back: replace the phrase on a
   * long-standing row and the new secret inherits an age it never had. The age
   * gate governs the SECRET, not the row, so a new secret starts at zero.
   * Returns whether this was a replacement, so the caller can word the
   * notification correctly.
   *
   * `backup` (amendment (lxxviii) clause 1) is the phrase-sealed identity
   * blob. Verifier and blob land in ONE statement — atomic by construction —
   * so a crash can never leave a blob sealed under a phrase whose verifier
   * was not stored (or vice versa). Absent means an older client: the phrase
   * is replaced and any stored blob is left untouched.
   */
  async setRecoveryKey(
    userId: number,
    phrase: string,
    backup?: IdentityBackupInput,
  ): Promise<boolean> {
    const verifierHash = await argon2.hash(phrase, RECOVERY_ARGON2_OPTIONS);
    const backupColumns = backup
      ? {
          backupBlob: backup.blob,
          backupSalt: backup.salt,
          backupIterations: backup.iterations,
          backupVersion: backup.version,
          backupUpdatedAt: new Date(),
        }
      : {};
    const existing = await this.recoveryRepo.findOne({ where: { userId } });
    if (existing) {
      await this.recoveryRepo.update(
        { id: existing.id },
        {
          verifierHash,
          usedAt: null,
          failedAttempts: 0,
          lockedUntil: null,
          createdAt: new Date(),
          ...backupColumns,
        },
      );
      return true;
    }
    await this.recoveryRepo.insert({ userId, verifierHash, ...backupColumns });
    return false;
  }

  /**
   * The stored identity backup, or null when the account never uploaded one
   * (amendment (lxxviii) clause 1). Served only to the authenticated owner —
   * harmless even then, because the blob is sealed under the phrase.
   */
  async getIdentityBackup(
    userId: number,
  ): Promise<IdentityBackupRecord | null> {
    const row = await this.recoveryRepo.findOne({ where: { userId } });
    if (
      !row ||
      row.backupBlob == null ||
      row.backupSalt == null ||
      row.backupIterations == null ||
      row.backupVersion == null
    ) {
      return null;
    }
    return {
      blob: row.backupBlob,
      salt: row.backupSalt,
      iterations: row.backupIterations,
      version: row.backupVersion,
    };
  }

  /** Whether a sealed identity backup exists — `ownKeyBundleStatus`'s flag. */
  async hasIdentityBackup(userId: number): Promise<boolean> {
    const row = await this.recoveryRepo.findOne({
      where: { userId },
      select: { id: true, backupBlob: true },
    });
    return row?.backupBlob != null;
  }

  /**
   * Whether ANY recovery phrase is enrolled — blob or not ((lxxxiii) clause
   * 4). A pre-(lxxviii) verifier-only row already resets the password at the
   * (lxxxii) door, so the Chats nudge must not ask its owner for "12 words".
   */
  async hasRecoveryPhrase(userId: number): Promise<boolean> {
    const row = await this.recoveryRepo.findOne({
      where: { userId },
      select: { id: true },
    });
    return row != null;
  }

  /**
   * Commits ceremonies whose delay has elapsed. Runs every minute so a restart
   * cannot skip a deadline.
   *
   * The status='pending' predicate in the UPDATE is the serialization point
   * against a concurrent cancel — no row is ever pulled back out of a terminal
   * state. Completion also invalidates any unspent recovery phrase in the same
   * transaction (§6.2.1: a completed reset spends it too).
   *
   * Completion deliberately fans out NO notification: the loud surface fires
   * when the new identity key is actually uploaded, through the existing
   * identity-replacement alarm.
   */
  @Cron(CronExpression.EVERY_MINUTE)
  async completeDueResets(): Promise<void> {
    try {
      await this.dataSource.transaction(async (manager) => {
        const result = await manager
          .getRepository(IdentityResetRequest)
          .createQueryBuilder()
          .update(IdentityResetRequest)
          .set({ status: 'completed', completedAt: () => 'now()' })
          .where('status = :status', { status: 'pending' })
          .andWhere('"deadlineAt" <= now()')
          .returning('"id", "userId"')
          .execute();
        const raw: unknown = result.raw;
        const rows: Array<{ userId: number }> = Array.isArray(raw)
          ? (raw as Array<{ userId: number }>)
          : [];
        if (rows.length === 0) return;
        const userIds = [...new Set(rows.map((row) => row.userId))];
        await manager
          .getRepository(RecoveryKey)
          .createQueryBuilder()
          .update(RecoveryKey)
          .set({ usedAt: () => 'now()' })
          .where('"userId" IN (:...userIds)', { userIds })
          .andWhere('"usedAt" IS NULL')
          .execute();
        this.logger.warn(
          `[identity-reset] delay elapsed, identity replacement authorized count=${userIds.length}`,
        );
      });
    } catch (error) {
      // A failed sweep must never kill the scheduler; the next minute retries.
      this.logger.error(
        `[identity-reset] expiry sweep failed: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }
}
