import { Injectable, Logger, UnauthorizedException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';
import { createHash, randomBytes } from 'crypto';
import { RefreshToken } from './refresh-token.entity';

const REFRESH_TOKEN_BYTE_LENGTH = 48;
/** Opaque refresh tokens remain valid for this long (sliding on each refresh). */
export const REFRESH_TOKEN_TTL_DAYS = 365;

@Injectable()
export class RefreshTokensService {
  private readonly logger = new Logger(RefreshTokensService.name);

  constructor(
    @InjectRepository(RefreshToken)
    private readonly refreshRepo: Repository<RefreshToken>,
  ) {}

  static hashToken(plain: string): string {
    return createHash('sha256').update(plain, 'utf8').digest('hex');
  }

  private expiresAtFromNow(): Date {
    const expiresAt = new Date();
    expiresAt.setUTCDate(expiresAt.getUTCDate() + REFRESH_TOKEN_TTL_DAYS);
    return expiresAt;
  }

  /**
   * Persists a new refresh session and returns the plaintext token
   * (client-only).
   *
   * [deviceId] is the per-device anchor a revoke will use (Phase 1, spec §4):
   * delete that device's rows and kick its sockets, leaving every other device
   * signed in. NULL keeps a pre-Phase-1 session honest instead of guessing.
   */
  async createToken(
    userId: number,
    deviceId: number | null = null,
    deviceName: string | null = null,
    manager?: EntityManager,
  ): Promise<string> {
    const repo = manager
      ? manager.getRepository(RefreshToken)
      : this.refreshRepo;
    const plain = randomBytes(REFRESH_TOKEN_BYTE_LENGTH).toString('base64url');
    const tokenHash = RefreshTokensService.hashToken(plain);
    const expiresAt = this.expiresAtFromNow();
    await repo.save(
      repo.create({
        userId,
        tokenHash,
        expiresAt,
        deviceId,
        deviceName,
      }),
    );
    return plain;
  }

  /**
   * Validates a plaintext refresh token, extends its expiry, and reports whose
   * session it is — account AND device (Phase 1, spec §4), so the reissued
   * access token keeps naming the same device instead of silently becoming
   * device 1.
   *
   * This deliberately keeps the opaque refresh token stable. Hard single-use
   * rotation turns a lost `/auth/refresh` response into a self-inflicted logout:
   * the server has already deleted the row, while the client can only retry the
   * old token. Sliding the existing row preserves sticky sessions without
   * weakening explicit revoke/password-change invalidation.
   *
   * A REVOKED device's row is kept, not deleted (decision 130, E130a): it is
   * the only thing a device woken after its access JWT expired can ask "was I
   * revoked?" with. It is refused HERE, before the slide, with its own answer
   * (`Device revoked`) instead of the `Invalid refresh token` that logout, a
   * password change and expiry give — a client reads nothing but the explicit
   * answer as "revoked". [isRevoked] is the caller's, because the `devices`
   * table is not this module's.
   */
  async consumeAndSlide(
    plain: string,
    isRevoked: (userId: number, deviceId: number | null) => Promise<boolean>,
  ): Promise<{ userId: number; deviceId: number | null }> {
    const tokenHash = RefreshTokensService.hashToken(plain);
    const row = await this.refreshRepo.findOne({ where: { tokenHash } });
    if (!row) {
      this.logger.warn(
        '[auth-session-end] reason=refresh_invalid source=refresh_endpoint hasUser=false',
      );
      throw new UnauthorizedException('Invalid refresh token');
    }
    if (new Date(row.expiresAt).getTime() <= Date.now()) {
      this.logger.warn(
        `[auth-session-end] reason=refresh_expired source=refresh_endpoint`,
      );
      await this.refreshRepo.remove(row);
      throw new UnauthorizedException('Refresh token expired');
    }
    if (await isRevoked(row.userId, row.deviceId)) {
      this.logger.warn(
        '[auth-session-end] reason=device_revoked source=refresh_endpoint',
      );
      throw new UnauthorizedException('Device revoked');
    }

    row.expiresAt = this.expiresAtFromNow();
    await this.refreshRepo.save(row);
    return { userId: row.userId, deviceId: row.deviceId };
  }

  async revokeByPlain(plain: string): Promise<void> {
    const tokenHash = RefreshTokensService.hashToken(plain);
    const row = await this.refreshRepo.findOne({ where: { tokenHash } });
    if (row) {
      await this.refreshRepo.remove(row);
    }
  }

  /**
   * Drops the sessions of an account — EXCEPT those of a device the account's
   * list already shows revoked (`devices."revokedAt"`): those rows are the
   * proof of that revocation `consumeAndSlide` answers from, and they cannot
   * mint anything (refused there). `manager` makes it part of the caller's
   * transaction — the §6.2 roster teardown needs the session wipe and the
   * roster mutation to commit or roll back together (amendment (xxviii)), and
   * its own revocations are visible to this statement. A session with no
   * `device_id` (pre-Phase-1) belongs to no revoked device and is dropped.
   */
  async revokeAllForUser(
    userId: number,
    manager?: EntityManager,
  ): Promise<void> {
    const repo = manager
      ? manager.getRepository(RefreshToken)
      : this.refreshRepo;
    await repo.query(
      `DELETE FROM public.refresh_tokens
        WHERE user_id = $1
          AND (device_id IS NULL OR device_id NOT IN (
            SELECT "deviceId" FROM public.devices
             WHERE "userId" = $1 AND "revokedAt" IS NOT NULL))`,
      [userId],
    );
  }
}
