import { Injectable, Logger } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { BoxAlert } from './box-alert';
import { BoxCeilingMonitor } from './box-ceiling-monitor';
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
 * refused since the last one (counts per event, never a client), and checks
 * `box_totals` against the OPEN band and the whole ceiling (WARN from 50 %,
 * ERROR from 80 %, #204), then pings the operator's alarm with the one-bit
 * result (`BoxAlert`, plan D2 O1). At 00:00 UTC every queue's daily media
 * budget restarts.
 */
@Injectable()
export class BoxReaper {
  private readonly logger = new Logger(BoxReaper.name);
  private readonly ceiling = new BoxCeilingMonitor();
  private totalsMissing = false;

  constructor(
    private readonly box: BoxService,
    private readonly store: BoxMediaStore,
    private readonly delivery: BoxDelivery,
    private readonly alert: BoxAlert,
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
    const totals = await this.box.totals();
    if (totals === null) {
      // No row: every store is refused. Log the transition once, not per sweep.
      if (!this.totalsMissing) {
        this.logger.error(
          '[box] ceiling box_totals row missing (box refusing all stores)',
        );
      }
    }
    const alarming = totals === null || this.ceiling.check(totals, this.logger);
    this.totalsMissing = totals === null;
    await this.alert.report(alarming);
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
