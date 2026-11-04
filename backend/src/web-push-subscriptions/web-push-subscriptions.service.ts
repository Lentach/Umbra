import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { WebPushSubscription } from './web-push-subscription.entity';

interface WebPushSubscriptionUpsertInput {
  userId: number;
  /**
   * Which device registered this endpoint (spec §12 amendment (xxiv)). NULL
   * only for rows written before the claim reached the HTTP surface.
   */
  deviceId?: number | null;
  endpoint: string;
  p256dh: string;
  auth: string;
  userAgent?: string | null;
  expirationTime?: number | null;
}

@Injectable()
export class WebPushSubscriptionsService {
  constructor(
    @InjectRepository(WebPushSubscription)
    private readonly subscriptionRepo: Repository<WebPushSubscription>,
  ) {}

  async upsert(input: WebPushSubscriptionUpsertInput): Promise<void> {
    await this.subscriptionRepo.upsert(
      {
        userId: input.userId,
        deviceId: input.deviceId ?? null,
        endpoint: input.endpoint,
        p256dh: input.p256dh,
        auth: input.auth,
        userAgent: input.userAgent ?? null,
        expirationTime:
          input.expirationTime == null ? null : String(input.expirationTime),
      },
      ['endpoint'],
    );
  }

  /**
   * Drops the push endpoints of ONE revoked device (spec §5.5), plus every
   * row of the account whose `deviceId` is NULL.
   *
   * Amendment (xxiv): a NULL row was registered before the HTTP surface
   * carried a device id, so it cannot be attributed — and one of them may be
   * the device being cut off. Ambiguity resolves toward cutting it off: a
   * surviving device re-registers its endpoint on its next start, costing at
   * most one missed push window, whereas keeping the row would keep pushing
   * to the device the user just revoked.
   */
  async removeForDevice(userId: number, deviceId: number): Promise<void> {
    await this.subscriptionRepo
      .createQueryBuilder()
      .delete()
      .from(WebPushSubscription)
      .where('"userId" = :userId', { userId })
      .andWhere('("deviceId" = :deviceId OR "deviceId" IS NULL)', { deviceId })
      .execute();
  }

  /**
   * The endpoints registered by exactly this device (never a NULL row:
   * those cannot be attributed, and another live device may own them).
   */
  async endpointsForDevice(
    userId: number,
    deviceId: number,
  ): Promise<string[]> {
    const rows = await this.subscriptionRepo.find({
      where: { userId, deviceId },
      select: { endpoint: true },
    });
    return rows.map((row) => row.endpoint);
  }

  async removeByEndpointForUser(
    userId: number,
    endpoint: string,
  ): Promise<void> {
    await this.subscriptionRepo.delete({ userId, endpoint });
  }

  async removeByUserId(userId: number): Promise<void> {
    await this.subscriptionRepo.delete({ userId });
  }

  async removeByEndpoints(endpoints: string[]): Promise<void> {
    if (!endpoints.length) return;
    await this.subscriptionRepo
      .createQueryBuilder()
      .delete()
      .from(WebPushSubscription)
      .where('endpoint IN (:...endpoints)', { endpoints })
      .execute();
  }

  async findByUserId(userId: number): Promise<WebPushSubscription[]> {
    return this.subscriptionRepo.find({ where: { userId } });
  }
}
