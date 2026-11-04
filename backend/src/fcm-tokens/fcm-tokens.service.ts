import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { FcmToken } from './fcm-token.entity';

@Injectable()
export class FcmTokensService {
  private readonly logger = new Logger(FcmTokensService.name);

  constructor(
    @InjectRepository(FcmToken)
    private readonly fcmTokenRepo: Repository<FcmToken>,
  ) {}

  async upsert(
    userId: number,
    token: string,
    platform: string,
    deviceId: number | null = null,
  ): Promise<void> {
    await this.fcmTokenRepo.upsert({ userId, token, platform, deviceId }, [
      'token',
    ]);
  }

  /**
   * Drops the FCM tokens of ONE revoked device (spec §5.5), plus every row of
   * the account whose `deviceId` is NULL — the same ambiguity ruling as web
   * push (spec §12 amendment (xxiv)): an unattributable row may belong to the
   * device being cut off, and a surviving device re-registers on next start.
   */
  async removeForDevice(userId: number, deviceId: number): Promise<void> {
    await this.fcmTokenRepo
      .createQueryBuilder()
      .delete()
      .from(FcmToken)
      .where('"userId" = :userId', { userId })
      .andWhere('("deviceId" = :deviceId OR "deviceId" IS NULL)', { deviceId })
      .execute();
  }

  /**
   * The FCM tokens registered by exactly this device (never a NULL row:
   * those cannot be attributed, and another live device may own them).
   */
  async tokensForDevice(userId: number, deviceId: number): Promise<string[]> {
    const rows = await this.fcmTokenRepo.find({
      where: { userId, deviceId },
      select: { token: true },
    });
    return rows.map((row) => row.token);
  }

  async removeByTokenForUser(userId: number, token: string): Promise<void> {
    await this.fcmTokenRepo.delete({ userId, token });
  }

  async removeByUserId(userId: number): Promise<void> {
    await this.fcmTokenRepo.delete({ userId });
  }

  async findTokensByUserId(
    userId: number,
    platforms?: string[],
  ): Promise<string[]> {
    const rows = await this.fcmTokenRepo.find({ where: { userId } });
    if (!platforms?.length) {
      return rows.map((r) => r.token);
    }
    const allowed = new Set(platforms);
    return rows.filter((r) => allowed.has(r.platform)).map((r) => r.token);
  }

  async removeByTokens(tokens: string[]): Promise<void> {
    if (!tokens.length) return;
    await this.fcmTokenRepo
      .createQueryBuilder()
      .delete()
      .from(FcmToken)
      .where('token IN (:...tokens)', { tokens })
      .execute();
  }
}
