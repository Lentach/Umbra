import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { DataSource } from 'typeorm';

/**
 * Decision 150: the two identity-ceremony tables keep nothing for ever.
 *
 * - `identity_change_audit`: the NEWEST row per account stays (it warns a
 *   device that comes back after a long time offline); every older row goes
 *   once it is over 30 days old.
 * - `identity_reset_requests`: completed and cancelled rows go once the
 *   moment they ended is over 30 days old. A pending row is never touched
 *   (the statuses are listed, not "everything else"). A completed grant is
 *   spendable for 24 h only (`COMPLETED_GRANT_TTL_MS`), so a row this old
 *   authorizes nothing.
 */
const RETENTION_DAYS = 30;

@Injectable()
export class IdentityRetentionService {
  private readonly logger = new Logger(IdentityRetentionService.name);

  constructor(private readonly dataSource: DataSource) {}

  /** Daily, UTC, off the minute-grid the other sweeps share. Logs counts only. */
  @Cron('17 3 * * *', { timeZone: 'UTC' })
  async sweep(): Promise<void> {
    const auditRows = await this.prune(
      'audit',
      `DELETE FROM public.identity_change_audit a
       WHERE a."createdAt" < now() - make_interval(days => $1)
         AND EXISTS (
           SELECT 1 FROM public.identity_change_audit newer
           WHERE newer."userId" = a."userId"
             AND (newer."createdAt" > a."createdAt"
                  OR (newer."createdAt" = a."createdAt" AND newer.id > a.id))
         )`,
    );
    const resetRows = await this.prune(
      'reset',
      `DELETE FROM public.identity_reset_requests
       WHERE (status = 'completed'
              AND "completedAt" < now() - make_interval(days => $1))
          OR (status = 'cancelled'
              AND "cancelledAt" < now() - make_interval(days => $1))`,
    );
    if (auditRows + resetRows > 0) {
      this.logger.log(
        `[identity-retention] swept auditRows=${auditRows} resetRows=${resetRows}`,
      );
    }
  }

  /** Rows deleted; a failure costs this table one day, never the scheduler. */
  private async prune(table: string, sql: string): Promise<number> {
    try {
      // repo.query() answers a DELETE as [rows, rowCount].
      const [, count] = await this.dataSource.query<[unknown, number]>(sql, [
        RETENTION_DAYS,
      ]);
      return count;
    } catch (error) {
      this.logger.error(
        `[identity-retention] ${table} prune failed: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
      return 0;
    }
  }
}
