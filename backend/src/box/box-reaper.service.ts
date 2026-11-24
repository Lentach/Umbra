import { Injectable, Logger } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { BoxAlert } from './box-alert';
import { BoxCeilingMonitor } from './box-ceiling-monitor';
import { BoxDelivery } from './box-delivery.service';
import { BoxMediaStore } from './box-media.store';
import { takeRefusalCounts } from './box-throttler.guard';
import { BoxService } from './box.service';

const FAILED = Symbol('failed');

/** An errno code (`EACCES`) when the failure has one; never its message. */
function failureCode(error: unknown): string {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === 'string' && /^[A-Z0-9_]+$/.test(code) ? code : 'error';
}

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
  private sweeping = false;

  constructor(
    private readonly box: BoxService,
    private readonly store: BoxMediaStore,
    private readonly delivery: BoxDelivery,
    private readonly alert: BoxAlert,
  ) {}

  /**
   * Each step, and each file, fails on its own (BE-03): one undeletable file
   * or one failed query must not stop the steps after it, least of all the
   * alarm ping, and a sweep that could not finish its work pings `/fail`.
   * A sweep that starts while the previous one still runs does nothing.
   */
  @Cron(CronExpression.EVERY_10_MINUTES)
  async sweep(): Promise<void> {
    if (this.sweeping) {
      this.logger.warn('[box] sweep skipped (previous sweep still running)');
      return;
    }
    this.sweeping = true;
    try {
      await this.sweepOnce();
    } finally {
      this.sweeping = false;
    }
  }

  private async sweepOnce(): Promise<void> {
    let failed = false;
    const attempt = async <T>(
      step: string,
      run: () => Promise<T>,
    ): Promise<T | typeof FAILED> => {
      try {
        return await run();
      } catch (error) {
        failed = true;
        // The step and an errno code only: an fs message carries the path.
        this.logger.error(
          `[box] sweep step=${step} failed (${failureCode(error)})`,
        );
        return FAILED;
      }
    };

    await attempt('messages', () => this.box.deleteExpiredMessages());
    const expired = await attempt('media-list', () => this.box.expiredMedia());
    let mediaGone = 0;
    if (expired !== FAILED) {
      // File first, then row: a file that stayed keeps its row for a retry.
      const gone: Buffer[] = [];
      const codes = new Set<string>();
      for (const { id, path } of expired) {
        try {
          await this.store.remove(path);
          gone.push(id);
        } catch (error) {
          failed = true;
          codes.add(failureCode(error));
        }
      }
      if (gone.length < expired.length) {
        this.logger.error(
          `[box] sweep media undeletable=${expired.length - gone.length} (${[...codes].join(' ')})`,
        );
      }
      if (gone.length > 0) {
        const rows = await attempt('media-rows', () =>
          this.box.deleteMedia(gone),
        );
        if (rows !== FAILED) mediaGone = gone.length;
      }
    }
    const reaped = await attempt('queues', () =>
      this.box.reapQueues(new Date()),
    );
    const queuesGone = reaped === FAILED ? 0 : reaped.length;
    if (reaped !== FAILED) for (const rid of reaped) this.delivery.forget(rid);
    // Counts only: never an id, never an address.
    this.logger.debug(`[box] sweep media=${mediaGone} queues=${queuesGone}`);
    const totals = await attempt('totals', () => this.box.totals());
    let alarming = failed;
    if (totals !== FAILED) {
      if (totals === null) {
        // No row: every store is refused. Log the transition once, not per sweep.
        if (!this.totalsMissing) {
          this.logger.error(
            '[box] ceiling box_totals row missing (box refusing all stores)',
          );
        }
      }
      alarming =
        totals === null || this.ceiling.check(totals, this.logger) || failed;
      this.totalsMissing = totals === null;
    }
    await attempt('alarm', () => this.alert.report(alarming));
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
