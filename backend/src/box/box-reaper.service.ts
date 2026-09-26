import { Injectable, Logger } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { BoxDelivery } from './box-delivery.service';
import { BoxMediaStore } from './box-media.store';
import { takeRefusalCounts } from './box-throttler.guard';
import { BoxService } from './box.service';

/**
 * I3, the bounded residue: nothing the box stores outlives its window.
 *
 * Every 10 minutes: undelivered messages past 30 days, media past 14 days
 * (file first, then row — the repo's media-before-row rule), queues never
 * subscribed within 24 h of creation, and queues not subscribed for 90 days
 * (their messages and notifier go by FK cascade). The same pass logs how many
 * socket events were throttled and how many sends and uploads the quotas
 * refused since the last one (counts per event, never a client). At 00:00
 * UTC every queue's daily media budget restarts.
 */
@Injectable()
export class BoxReaper {
  private readonly logger = new Logger(BoxReaper.name);

  constructor(
    private readonly box: BoxService,
    private readonly store: BoxMediaStore,
    private readonly delivery: BoxDelivery,
  ) {}

  @Cron(CronExpression.EVERY_10_MINUTES)
  async sweep(): Promise<void> {
    await this.box.deleteExpiredMessages();
    const expired = await this.box.expiredMedia();
    for (const { path } of expired) await this.store.remove(path);
    if (expired.length > 0) {
      await this.box.deleteMedia(expired.map((m) => m.id));
    }
    const reaped = await this.box.reapQueues(new Date());
    for (const rid of reaped) this.delivery.forget(rid);
    // Counts only: never an id, never an address.
    this.logger.debug(
      `[box] sweep media=${expired.length} queues=${reaped.length}`,
    );
    const refused = takeRefusalCounts();
    if (refused.size > 0) {
      const counts = [...refused].map(([event, n]) => `${event}=${n}`);
      this.logger.log(`[box] refusals ${counts.join(' ')}`);
    }
  }

  @Cron('0 0 * * *', { timeZone: 'UTC' })
  async resetMediaBudgets(): Promise<void> {
    await this.box.resetMediaBudgets();
  }
}
