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
   */
  async consumeAndSlide(
    plain: string,
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
   * Drops EVERY session of an account. `manager` makes it part of the caller's
   * transaction — the §6.2 roster teardown needs the session wipe and the
   * roster mutation to commit or roll back together (amendment (xxviii)).
   */
  async revokeAllForUser(
    userId: number,
    manager?: EntityManager,
  ): Promise<void> {
    const repo = manager
      ? manager.getRepository(RefreshToken)
      : this.refreshRepo;
    await repo.delete({ userId });
  }

  /**
   * Deletes ONE device's refresh sessions (spec §5.5 revocation), inside the
   * caller's transaction when given a manager.
   *
   * Scoped by `(userId, device_id)`, so every other device stays signed in —
   * the whole point of the Phase 1 column. Rows with a NULL `device_id`
   * (pre-Phase-1 sessions) are deliberately NOT matched: they cannot be
   * attributed to a device, and deleting them would sign out the primary that
   * is performing the revocation.
   */
  async revokeForDevice(
    userId: number,
    deviceId: number,
    manager?: EntityManager,
  ): Promise<number> {
    const repo = manager
      ? manager.getRepository(RefreshToken)
      : this.refreshRepo;
    const result = await repo.delete({ userId, deviceId });
    return result.affected ?? 0;
  }
}
