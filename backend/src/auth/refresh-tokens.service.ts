import { Injectable, Logger, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';
import { createHash, createHmac, randomBytes, randomUUID } from 'crypto';
import { RefreshToken } from './refresh-token.entity';
import { resolveJwtSecret } from './jwt-secret';

const REFRESH_TOKEN_BYTE_LENGTH = 48;
/**
 * A session lives this long after its last refresh (sliding, per session; the
 * token itself rotates on every refresh that asks for it, plan B4).
 */
export const REFRESH_TOKEN_TTL_DAYS = 365;

/** Domain separation: the rotation key is derived from `JWT_SECRET`. */
const ROTATION_KEY_LABEL = 'fireplace refresh-token rotation v1';

/** The family prefix of `<familyId>.<secret>`: the session row's uuid. */
const FAMILY_ID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** What a redeemed refresh token answers. */
export interface RedeemedSession {
  userId: number;
  deviceId: number | null;
  /** The token the client must keep from now on (the same one unless rotated). */
  refreshToken: string;
}

@Injectable()
export class RefreshTokensService {
  private readonly logger = new Logger(RefreshTokensService.name);
  private readonly rotationKey: Buffer;

  constructor(
    @InjectRepository(RefreshToken)
    private readonly refreshRepo: Repository<RefreshToken>,
    configService: ConfigService,
  ) {
    this.rotationKey = createHmac('sha256', resolveJwtSecret(configService))
      .update(ROTATION_KEY_LABEL, 'utf8')
      .digest();
  }

  static hashToken(plain: string): string {
    return createHash('sha256').update(plain, 'utf8').digest('hex');
  }

  /**
   * The session (family) id a token names, or null for a token issued before
   * plan B4 (no prefix) or one that does not parse.
   */
  static familyOf(plain: string): string | null {
    const dot = plain.indexOf('.');
    if (dot <= 0) return null;
    const familyId = plain.slice(0, dot);
    return FAMILY_ID.test(familyId) ? familyId : null;
  }

  /**
   * The token that replaces [plain] in session [familyId]. Deterministic, so
   * a retry of the same old token — a lost response, two requests racing —
   * gets the SAME successor back, never a second one that would orphan the
   * first. Keyed by the server secret, so holding a token does not let anyone
   * compute the tokens after it.
   */
  private successorOf(familyId: string, plain: string): string {
    const secret = createHmac('sha384', this.rotationKey)
      .update(plain, 'utf8')
      .digest('base64url');
    return `${familyId}.${secret}`;
  }

  private expiresAtFromNow(): Date {
    const expiresAt = new Date();
    expiresAt.setUTCDate(expiresAt.getUTCDate() + REFRESH_TOKEN_TTL_DAYS);
    return expiresAt;
  }

  /**
   * Persists a new refresh session and returns the plaintext token
   * (client-only): `<sessionId>.<secret>`, the session's family id first.
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
    const id = randomUUID();
    const plain = `${id}.${randomBytes(REFRESH_TOKEN_BYTE_LENGTH).toString('base64url')}`;
    await repo.save(
      repo.create({
        id,
        userId,
        tokenHash: RefreshTokensService.hashToken(plain),
        prevTokenHash: null,
        expiresAt: this.expiresAtFromNow(),
        deviceId,
        deviceName,
      }),
    );
    return plain;
  }

  /**
   * Validates a plaintext refresh token and reports whose session it is —
   * account AND device (Phase 1, spec §4), so the reissued access token keeps
   * naming the same device instead of silently becoming device 1 — and which
   * token the client keeps from now on (plan B4).
   *
   * [rotate] (the client asked, `POST /auth/refresh {rotate: true}`): the
   * session's current token is replaced by its successor, which is returned,
   * and the expiry slides. A rotating client that presents the token just
   * replaced lost the response that carried its successor — the successor was
   * never used, or the session would have moved on — so it gets that same
   * successor back: a lost response never becomes a logout. Without
   * [rotate] (web, builds before 0.2.88, a native client whose store refused
   * its last token) the current token stays and only the expiry slides.
   *
   * Reuse ends the session: an older token of the family (it names the
   * session), or the replaced token from a client that does not rotate — it
   * cannot hold one unless someone else rotated its session. Either way two
   * parties hold the session; the row is deleted and both meet `Invalid
   * refresh token` at their next refresh.
   *
   * A REVOKED device's row is kept, not deleted (decision 130, E130a): it is
   * the only thing a device woken after its access JWT expired can ask "was I
   * revoked?" with. It is refused HERE, before any rotation, slide or reuse
   * check, with its own answer (`Device revoked`) instead of the `Invalid
   * refresh token` that logout, a password change, reuse and expiry give — a
   * client reads nothing but the explicit answer as "revoked". [isRevoked] is
   * the caller's, because the `devices` table is not this module's.
   */
  async redeem(
    plain: string,
    isRevoked: (userId: number, deviceId: number | null) => Promise<boolean>,
    { rotate }: { rotate: boolean },
  ): Promise<RedeemedSession> {
    const presented = RefreshTokensService.hashToken(plain);
    let row = await this.findByCurrentOrReplaced(presented);
    if (!row) {
      const familyId = RefreshTokensService.familyOf(plain);
      const family = familyId
        ? await this.refreshRepo.findOne({ where: { id: familyId } })
        : null;
      if (!family) {
        this.logger.warn(
          '[auth-session-end] reason=refresh_invalid source=refresh_endpoint hasUser=false',
        );
        throw new UnauthorizedException('Invalid refresh token');
      }
      // A token of a live session that has moved on two or more steps.
      await this.refuseDeadOrRevoked(family, isRevoked);
      return this.endReusedSession(family);
    }
    await this.refuseDeadOrRevoked(row, isRevoked);

    if (row.tokenHash === presented) {
      if (!rotate) {
        // Targeted, never `save(row)`: a whole-row write could undo a
        // rotation that landed since the read.
        await this.refreshRepo.update(
          { id: row.id, tokenHash: presented },
          { expiresAt: this.expiresAtFromNow() },
        );
        return this.answer(row, plain);
      }
      const next = this.successorOf(row.id, plain);
      const rotated = await this.refreshRepo.update(
        { id: row.id, tokenHash: presented },
        {
          tokenHash: RefreshTokensService.hashToken(next),
          prevTokenHash: presented,
          expiresAt: this.expiresAtFromNow(),
        },
      );
      if (rotated.affected === 1) return this.answer(row, next);
      // Another request with this same token rotated first: this one is its
      // retry, unless the session ended or moved on again meanwhile.
      row = await this.refreshRepo.findOne({ where: { id: row.id } });
      if (!row) {
        throw new UnauthorizedException('Invalid refresh token');
      }
      if (row.prevTokenHash !== presented) return this.endReusedSession(row);
    }

    // [plain] is the token the current one replaced: its successor is
    // answered again, and the expiry slides as on any refresh. The successor
    // is derived anew, so after a JWT_SECRET change the current token (which
    // never reached whoever presents its predecessor) is re-keyed; the one
    // holder that costs a sign-in is a native install whose store refused the
    // successor (runtime-reference "JWT_SECRET").
    if (!rotate) return this.endReusedSession(row);
    const next = this.successorOf(row.id, plain);
    const answered = await this.refreshRepo.update(
      { id: row.id, prevTokenHash: presented },
      {
        tokenHash: RefreshTokensService.hashToken(next),
        expiresAt: this.expiresAtFromNow(),
      },
    );
    if (answered.affected === 1) return this.answer(row, next);
    // The session ended or moved on since the read: [plain] is now older
    // than the replaced token.
    const current = await this.refreshRepo.findOne({ where: { id: row.id } });
    if (!current) {
      throw new UnauthorizedException('Invalid refresh token');
    }
    return this.endReusedSession(current);
  }

  private findByCurrentOrReplaced(
    tokenHash: string,
  ): Promise<RefreshToken | null> {
    return this.refreshRepo.findOne({
      where: [{ tokenHash }, { prevTokenHash: tokenHash }],
    });
  }

  private answer(row: RefreshToken, refreshToken: string): RedeemedSession {
    return { userId: row.userId, deviceId: row.deviceId, refreshToken };
  }

  private async refuseDeadOrRevoked(
    row: RefreshToken,
    isRevoked: (userId: number, deviceId: number | null) => Promise<boolean>,
  ): Promise<void> {
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
  }

  private async endReusedSession(row: RefreshToken): Promise<never> {
    await this.refreshRepo.delete({ id: row.id });
    this.logger.warn(
      '[auth-session-end] reason=refresh_reuse source=refresh_endpoint',
    );
    throw new UnauthorizedException('Invalid refresh token');
  }

  /** Logout: ends the session the client's current (or just replaced) token names. */
  async revokeByPlain(plain: string): Promise<void> {
    const row = await this.findByCurrentOrReplaced(
      RefreshTokensService.hashToken(plain),
    );
    if (row) {
      await this.refreshRepo.remove(row);
    }
  }

  /**
   * Drops the sessions of an account — EXCEPT those of a device the account's
   * list already shows revoked (`devices."revokedAt"`): those rows are the
   * proof of that revocation `redeem` answers from, and they cannot
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
