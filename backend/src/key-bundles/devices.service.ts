import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, IsNull, Repository } from 'typeorm';
import { Device } from './device.entity';
import { DEFAULT_DEVICE_ID } from './key-bundles.service';

/**
 * The account's devices (Phase 1, multi-device spec §4).
 *
 * Phase 1 does not GRANT a second device — provisioning is Phase 2. What it
 * does is make the one device every account already has representable, and
 * keep the row alive as sessions connect, so revocation and the device list
 * have something real to act on rather than a table only a backfill ever
 * touched.
 */
@Injectable()
export class DevicesService {
  private readonly logger = new Logger(DevicesService.name);

  constructor(
    @InjectRepository(Device)
    private readonly deviceRepo: Repository<Device>,
  ) {}

  /**
   * Creates device 1's row on first sight. This is the ONLY creator of a
   * `devices` row for accounts that predate provisioning (§8), and
   * `isRevoked` depends on the row existing.
   *
   * Device 1 is the account's primary until provisioning ships (invariant I2:
   * only a Keystore-capable device may be primary, and today there is exactly
   * one device). Called on every connect, so it must be cheap and must never
   * break the connection: a failure here costs a missing row, not a session.
   *
   * The server keeps no "last online" clock (metadata privacy step 0): an
   * existing row is left exactly as it is — rewriting `isPrimary` would undo
   * a primary handover (§6.3) on the new primary's next connect, and
   * rewriting `platform` would erase what the row already knows.
   */
  async ensureRow(
    userId: number,
    deviceId: number = DEFAULT_DEVICE_ID,
    platform?: string,
  ): Promise<void> {
    if (deviceId !== DEFAULT_DEVICE_ID) {
      // Rows for ids >= 2 are created SOLELY by the provisioning commit
      // transaction (spec §12 Stage-0 amendment (b)): auto-inserting one
      // here would activate a deviceId the ceremony never committed and
      // reopen the never-activated-upload hole this ticket closes.
      return;
    }
    try {
      await this.deviceRepo
        .createQueryBuilder()
        .insert()
        .into(Device)
        .values({
          userId,
          deviceId,
          // First sight of device 1 IS the account's primary; a linked device
          // never claims that for itself (invariant I2).
          isPrimary: true,
          platform: platform ?? null,
        })
        // ON CONFLICT DO NOTHING on the (userId, deviceId) PK: two concurrent
        // first connects cannot race into a unique violation.
        .orIgnore()
        .execute();
    } catch (error) {
      this.logger.warn(
        `[devices] ensureRow failed deviceId=${deviceId}: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  /**
   * Whether this deviceId was activated by a provisioning commit (row
   * exists) and not revoked. Gate for per-device key-material uploads
   * (spec §5.1 / §12 amendment (b)): device 1 predates the devices table
   * and is exempt at the call sites, never here.
   */
  async isActive(userId: number, deviceId: number): Promise<boolean> {
    const row = await this.deviceRepo.findOne({ where: { userId, deviceId } });
    return row !== null && row.revokedAt === null;
  }

  /**
   * Whether this device was EXPLICITLY revoked (spec §12 amendment (xxii)).
   *
   * Deliberately the inverse polarity of {@link isActive}: a MISSING row
   * answers `false` here. `isActive` gates key-material UPLOADS and must fail
   * closed on absence, but this predicate gates SESSIONS, and every
   * pre-Phase-1 account has no `devices` row until its first connect writes
   * one (§8) — denying on absence would lock out the entire legacy install
   * base. Both predicates are correct for their own call sites; neither may
   * be swapped for the other.
   */
  async isRevoked(userId: number, deviceId: number): Promise<boolean> {
    const row = await this.deviceRepo.findOne({
      where: { userId, deviceId },
      select: { userId: true, deviceId: true, revokedAt: true },
    });
    return row !== null && row.revokedAt !== null;
  }

  /**
   * Stamps `revokedAt` on ONE device (spec §5.5), inside the caller's
   * transaction when given a manager.
   *
   * The `revokedAt IS NULL` predicate makes this idempotent and makes the
   * return value meaningful: a second revoke of the same device affects zero
   * rows and must NOT be reported as a fresh revocation, so the caller can
   * refuse a duplicate instead of re-running a teardown.
   */
  async revoke(
    userId: number,
    deviceId: number,
    manager?: EntityManager,
  ): Promise<boolean> {
    const repo = manager ? manager.getRepository(Device) : this.deviceRepo;
    const result = await repo
      .createQueryBuilder()
      .update(Device)
      .set({ revokedAt: () => 'now()' })
      .where('"userId" = :userId', { userId })
      .andWhere('"deviceId" = :deviceId', { deviceId })
      .andWhere('"revokedAt" IS NULL')
      .execute();
    return (result.affected ?? 0) > 0;
  }

  /**
   * Which device a PASSWORD login belongs to (spec §4 + §12 amendment
   * (xxii)).
   *
   * It must NOT be hardcoded to device 1. A §6.2 reset revokes the whole
   * pre-reset roster and moves the account onto a freshly allocated id
   * (amendment (xxviii)), so a login that kept claiming device 1 would mint a
   * token for a REVOKED device and both session gates would then correctly
   * refuse it — locking the owner out of their own account with the right
   * password.
   *
   * Order: the live primary, else the lowest live id (a roster mid-handover),
   * else device 1 — which is the honest answer for every pre-Phase-1 account,
   * whose row does not exist until its first connect writes one (§8).
   */
  async resolveLoginDeviceId(userId: number): Promise<number> {
    const live = await this.deviceRepo.find({
      where: { userId, revokedAt: IsNull() },
      order: { deviceId: 'ASC' },
    });
    if (live.length === 0) return DEFAULT_DEVICE_ID;
    return (live.find((row) => row.isPrimary) ?? live[0]).deviceId;
  }

  /**
   * Stamps `revokedAt` on every still-live device of the account EXCEPT
   * `keepDeviceId` — the §6.2 reset roster teardown (spec §12 amendments (f)
   * (ii) and (xxviii)). Returns the revoked device ids so the caller can tear
   * down each one's material inside its own `(userId, deviceId)` namespace.
   */
  async revokeAllExcept(
    userId: number,
    keepDeviceId: number,
    manager?: EntityManager,
  ): Promise<number[]> {
    const repo = manager ? manager.getRepository(Device) : this.deviceRepo;
    // RETURNING makes the set of affected devices authoritative rather than
    // re-read (a concurrent revoke between UPDATE and SELECT would otherwise
    // hide a device from the teardown).
    const result = await repo
      .createQueryBuilder()
      .update(Device)
      .set({ revokedAt: () => 'now()' })
      .where('"userId" = :userId', { userId })
      .andWhere('"deviceId" != :keepDeviceId', { keepDeviceId })
      .andWhere('"revokedAt" IS NULL')
      .returning('"deviceId"')
      .execute();
    const rows = (result.raw ?? []) as Array<{ deviceId: number }>;
    return rows.map((row) => row.deviceId);
  }

  /**
   * Allocates the next deviceId of an account (spec §12 Stage-0 amendment (a),
   * migration 0016).
   *
   * ONE atomic UPDATE ... RETURNING: concurrent allocations serialize on the
   * user row's lock, so two ceremonies can never be handed the same id. The
   * allocated id is the PRE-increment value — the column starts at 2 (every
   * existing account is single-device device 1), so the first allocation
   * returns 2 (decision record F4's off-by-one rider).
   *
   * The counter is NEVER decremented: an aborted provisioning ceremony leaves
   * a gap, and gaps are expected and safe — the invariant is
   * monotonic-never-reused, not dense (spec §12 Stage-0 amendment (a)).
   * Callers arrive in T3 (`openProvisioning` memoizes one allocation per
   * provisioningId) and in T6 (§6.2 reset never re-mints device 1).
   */
  async allocateDeviceId(userId: number): Promise<number> {
    // repo.query() returns [rows, rowCount] for UPDATE ... RETURNING
    // (backend/CLAUDE.md §4) — reading the bare result would be the rows
    // ARRAY, the trap that broke OTP claims once already.
    const [rows] = await this.deviceRepo.query<
      [Array<{ allocatedId: number }>, number]
    >(
      `UPDATE users
          SET "nextDeviceId" = "nextDeviceId" + 1
        WHERE id = $1
        RETURNING "nextDeviceId" - 1 AS "allocatedId"`,
      [userId],
    );
    if (rows.length === 0) {
      throw new Error('allocateDeviceId: user not found');
    }
    return rows[0].allocatedId;
  }

  /** Every device of an account, oldest first. Revoked rows included. */
  async listForUser(userId: number): Promise<Device[]> {
    return this.deviceRepo.find({
      where: { userId },
      order: { deviceId: 'ASC' },
    });
  }
}
