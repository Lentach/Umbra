import { Inject, Injectable } from '@nestjs/common';
import { randomBytes } from 'crypto';
import { DataSource } from 'typeorm';
import {
  BOX_IDLE_REAP_DAYS,
  BOX_MEDIA_DAILY_BUDGET_BYTES,
  BOX_MEDIA_LADDER,
  BOX_MSG_TTL_MS,
  BOX_NID_BYTES,
  BOX_NORMAL_QUEUE_CAP,
  BOX_REQUEST_QUEUE_CAP,
  BOX_RID_BYTES,
  BOX_SID_BYTES,
  BOX_MSG_ID_BYTES,
  BOX_UNCLAIMED_TTL_MS,
} from './box.constants';
import type { NotifierPlatform, QueueKind } from './box-wire';

export interface QueueAddress {
  rid: Buffer;
  sid: Buffer;
  nid: Buffer;
}

export type EnqueueResult =
  | { result: 'stored'; rid: Buffer; nid: Buffer }
  | { result: 'full' }
  /** The global message ceiling is reached (decision 30); nothing was stored. */
  | { result: 'over_ceiling' }
  /** Unknown or deleted sid: the caller answers `ok` anyway (no block oracle). */
  | { result: 'dropped' };

export type MediaCharge =
  'charged' | 'over_budget' | 'over_ceiling' | 'unknown_sid';

/** An upload about to be streamed to `path`, on one ladder rung. */
export interface NewMedia {
  id: Buffer;
  path: string;
  bucket: string;
  bytes: number;
  expiresAt: Date;
}

const RUNG_BUCKETS = BOX_MEDIA_LADDER.map((r) => r.bucket);
const RUNG_BYTES = BOX_MEDIA_LADDER.map((r) => r.bytes);

/**
 * The global ceiling's two numbers (decision 30). Injected, not imported, so
 * the integration suite can lower them instead of writing 2 GiB; the module
 * provides `BOX_GLOBAL_MSG_CEILING` / `BOX_GLOBAL_MEDIA_CEILING_BYTES`.
 */
export interface BoxCeiling {
  msgs: number;
  mediaBytes: number;
}
export const BOX_CEILING = Symbol('BOX_CEILING');

/** The UTC calendar day of `at`, as Postgres `date` text. */
function utcDay(at: Date): string {
  return at.toISOString().slice(0, 10);
}

/**
 * Every read and write of the box tables. Raw SQL on purpose: each counter
 * change (`msgCount`, `mediaBytesToday`, the global totals) happens in the
 * SAME statement or transaction as the row change it counts, so a crash or a
 * race can never leave a count that lets a queue — or the box — exceed its
 * cap.
 *
 * THE GLOBAL CEILING (decision 30, E12) is one row, `box_totals` (migration
 * 0024): `msgCount` = every `box_msgs` row, `mediaBytes` = every `box_media`
 * row at its rung size. `enqueue` and `chargeMedia` check and bump it with
 * ONE conditional UPDATE on its primary key; counting the tables instead
 * would scan up to 60 000 rows on every send. Each path that removes a
 * message or a medium gives it back in the same statement: ack, the TTL
 * sweep, `deleteQueue` and the reaper (a queue's `msgCount` is exactly the
 * rows its FK cascade removes), `deleteMedia`. A request-queue eviction
 * replaces a message, so the total does not move. The price: every send and
 * upload serialises on that row for the rest of its three-statement
 * transaction — accepted at the box's per-IP send rate.
 *
 * `repo.query()` on Postgres answers DELETE/UPDATE with `[rows, rowCount]`
 * and SELECT/INSERT with `rows` (backend/CLAUDE.md §4) — a `WITH` statement
 * by its OUTER verb; every call below destructures accordingly.
 *
 * LOCK ORDER, everywhere: `box_queues` rows first — several at once only in
 * rid order — then `box_msgs` rows, then the one `box_totals` row LAST:
 * after taking it a transaction only writes rows it already holds or inserts
 * new ones, so it never waits while holding it. `enqueue` must hold the
 * queue while it evicts a message, so any writer that deletes a message and
 * then touches the queue's counter (ack, the expiry sweep) takes the queue
 * lock FIRST; the opposite order deadlocks an ack against a flood on a full
 * request queue (40P01, reproduced by the integration suite). The FK
 * cascades (queue → msgs) already follow this order, and a message row is
 * only ever written under its queue's lock.
 */
@Injectable()
export class BoxService {
  constructor(
    private readonly db: DataSource,
    @Inject(BOX_CEILING) private readonly ceiling: BoxCeiling,
  ) {}

  /**
   * Idempotent per `authPub`: a client whose answer was lost retries with the
   * same key and gets the SAME queue back rather than an orphan. Only the key
   * holder can sign for it, so returning the existing address leaks nothing.
   * `null` when that key already owns a queue of the other kind.
   */
  async createQueue(
    kind: QueueKind,
    authPub: Buffer,
  ): Promise<QueueAddress | null> {
    const inserted: { rid: Buffer; sid: Buffer; nid: Buffer }[] =
      await this.db.query(
        `INSERT INTO public.box_queues
           (rid, sid, nid, "recipientAuthPub", kind, "claimBy")
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT ("recipientAuthPub") DO NOTHING
         RETURNING rid, sid, nid`,
        [
          randomBytes(BOX_RID_BYTES),
          randomBytes(BOX_SID_BYTES),
          randomBytes(BOX_NID_BYTES),
          authPub,
          kind,
          new Date(Date.now() + BOX_UNCLAIMED_TTL_MS),
        ],
      );
    if (inserted.length === 1) return inserted[0];
    const existing: (QueueAddress & { kind: QueueKind })[] =
      await this.db.query(
        `SELECT rid, sid, nid, kind FROM public.box_queues
        WHERE "recipientAuthPub" = $1`,
        [authPub],
      );
    const queue = existing[0];
    if (!queue || queue.kind !== kind) return null;
    return { rid: queue.rid, sid: queue.sid, nid: queue.nid };
  }

  /**
   * Stores one blob. A normal queue refuses when full; a request queue drops
   * its oldest instead (first contact must never be blocked by a spammer who
   * holds the public request sid) — which replaces a message, so it is taken
   * even at the global ceiling. Any other blob past the ceiling is refused,
   * and so is one for an unknown sid: at the ceiling a dead sid must read
   * like a live one (no block oracle). The queue row is locked for the
   * duration, so the count checks and the insert cannot interleave with
   * another send.
   */
  async enqueue(sid: Buffer, blob: Buffer): Promise<EnqueueResult> {
    return this.db.transaction(async (tx) => {
      const rows: {
        rid: Buffer;
        nid: Buffer;
        kind: QueueKind;
        msgCount: number;
      }[] = await tx.query(
        `SELECT rid, nid, kind, "msgCount" FROM public.box_queues
          WHERE sid = $1 FOR UPDATE`,
        [sid],
      );
      const queue = rows[0];
      if (!queue) {
        // Read only. A missing totals row fails closed, as in the UPDATE below.
        const room: { fits: boolean }[] = await tx.query(
          `SELECT "msgCount" < $1 AS fits FROM public.box_totals WHERE id = 1`,
          [this.ceiling.msgs],
        );
        return room[0]?.fits === true
          ? ({ result: 'dropped' } as const)
          : ({ result: 'over_ceiling' } as const);
      }
      if (queue.kind === 'normal' && queue.msgCount >= BOX_NORMAL_QUEUE_CAP) {
        return { result: 'full' } as const;
      }
      let evicted = 0;
      if (queue.kind === 'request' && queue.msgCount >= BOX_REQUEST_QUEUE_CAP) {
        [, evicted] = await tx.query(
          `DELETE FROM public.box_msgs WHERE id = (
             SELECT id FROM public.box_msgs WHERE rid = $1
              ORDER BY "createdAt", id LIMIT 1)`,
          [queue.rid],
        );
      }
      if (evicted === 0) {
        const [, grown]: [unknown, number] = await tx.query(
          `UPDATE public.box_totals SET "msgCount" = "msgCount" + 1
            WHERE id = 1 AND "msgCount" < $1`,
          [this.ceiling.msgs],
        );
        if (grown === 0) return { result: 'over_ceiling' } as const;
        await tx.query(
          `UPDATE public.box_queues SET "msgCount" = "msgCount" + 1
            WHERE rid = $1`,
          [queue.rid],
        );
      }
      const now = Date.now();
      await tx.query(
        `INSERT INTO public.box_msgs (id, rid, blob, "createdAt", "expiresAt")
         VALUES ($1, $2, $3, $4, $5)`,
        [
          randomBytes(BOX_MSG_ID_BYTES),
          queue.rid,
          blob,
          new Date(now),
          new Date(now + BOX_MSG_TTL_MS),
        ],
      );
      return { result: 'stored', rid: queue.rid, nid: queue.nid } as const;
    });
  }

  /** The auth key of each rid that exists, keyed by its base64url form. */
  async authKeysByRid(rids: Buffer[]): Promise<Map<string, Buffer>> {
    const rows: { rid: Buffer; recipientAuthPub: Buffer }[] =
      await this.db.query(
        `SELECT rid, "recipientAuthPub" FROM public.box_queues
          WHERE rid = ANY($1::bytea[])`,
        [rids],
      );
    return new Map(
      rows.map((r) => [r.rid.toString('base64url'), r.recipientAuthPub]),
    );
  }

  /** The auth key of each nid whose queue exists, keyed by its base64url form. */
  async authKeysByNid(nids: Buffer[]): Promise<Map<string, Buffer>> {
    const rows: { nid: Buffer; recipientAuthPub: Buffer }[] =
      await this.db.query(
        `SELECT nid, "recipientAuthPub" FROM public.box_queues
          WHERE nid = ANY($1::bytea[])`,
        [nids],
      );
    return new Map(
      rows.map((r) => [r.nid.toString('base64url'), r.recipientAuthPub]),
    );
  }

  /**
   * The nid of each queue in `rids` still holding a message delivery would
   * hand out (not expired): a socket that owned them went away, and what it
   * was handed may be unread. Read-only, so the lock order (queue rows
   * before msg rows) is not involved.
   */
  async waitingNids(rids: Buffer[]): Promise<Buffer[]> {
    const rows: { nid: Buffer }[] = await this.db.query(
      `SELECT q.nid FROM public.box_queues q
        WHERE q.rid = ANY($1::bytea[])
          AND EXISTS (SELECT 1 FROM public.box_msgs m
                       WHERE m.rid = q.rid AND m."expiresAt" > now())`,
      [rids],
    );
    return rows.map((r) => r.nid);
  }

  /**
   * A subscribe claims the queue (clears `claimBy`) and stamps the UTC day.
   * The WHERE skips rows already in that state: a reconnect loop must not
   * rewrite every row of a device on every connect.
   */
  async markSubscribed(rids: Buffer[]): Promise<void> {
    await this.db.query(
      `UPDATE public.box_queues
          SET "touchedDay" = $2::date, "claimBy" = NULL
        WHERE rid IN (
          SELECT rid FROM public.box_queues
           WHERE rid = ANY($1::bytea[])
             AND ("touchedDay" IS DISTINCT FROM $2::date OR "claimBy" IS NOT NULL)
           ORDER BY rid FOR UPDATE)`,
      [rids, utcDay(new Date())],
    );
  }

  /** Idempotent: acking a message that is already gone changes nothing. */
  async ack(rid: Buffer, id: Buffer): Promise<void> {
    await this.db.transaction(async (tx) => {
      await tx.query(
        `SELECT 1 FROM public.box_queues WHERE rid = $1 FOR UPDATE`,
        [rid],
      );
      await tx.query(
        `WITH gone AS (
           DELETE FROM public.box_msgs WHERE rid = $1 AND id = $2 RETURNING rid),
         queue AS (
           UPDATE public.box_queues
              SET "msgCount" = "msgCount" - (SELECT count(*) FROM gone)
            WHERE rid = $1 AND EXISTS (SELECT 1 FROM gone))
         UPDATE public.box_totals
            SET "msgCount" = "msgCount" - (SELECT count(*) FROM gone)
          WHERE id = 1 AND EXISTS (SELECT 1 FROM gone)`,
        [rid, id],
      );
    });
  }

  /**
   * Messages and the notifier go with it (FK cascades); the global total
   * gives back the queue's `msgCount`, which is exactly what the cascade
   * removes.
   */
  async deleteQueue(rid: Buffer): Promise<void> {
    await this.db.query(
      `WITH gone AS (
         DELETE FROM public.box_queues WHERE rid = $1 RETURNING "msgCount")
       UPDATE public.box_totals
          SET "msgCount" = "msgCount" - (SELECT sum("msgCount") FROM gone)
        WHERE id = 1 AND EXISTS (SELECT 1 FROM gone)`,
      [rid],
    );
  }

  /**
   * Up to `perRid` oldest undelivered ids of each rid, skipping the ids
   * already in flight on the asking socket. Ids only: blobs are fetched for
   * the few that win the round-robin, never for a whole backlog.
   */
  async pendingHeads(
    rids: Buffer[],
    inFlight: Buffer[],
    perRid: number,
  ): Promise<{ rid: Buffer; id: Buffer }[]> {
    return this.db.query(
      `SELECT rid, id FROM (
         SELECT m.rid, m.id, row_number() OVER (
                  PARTITION BY m.rid ORDER BY m."createdAt", m.id) AS rn
           FROM public.box_msgs m
          WHERE m.rid = ANY($1::bytea[])
            AND NOT (m.id = ANY($2::bytea[]))
            AND m."expiresAt" > now()) t
        WHERE rn <= $3
        ORDER BY rid, rn`,
      [rids, inFlight, perRid],
    );
  }

  /** The blobs of these ids that still exist, keyed by id in base64url. */
  async blobs(ids: Buffer[]): Promise<Map<string, Buffer>> {
    const rows: { id: Buffer; blob: Buffer }[] = await this.db.query(
      `SELECT id, blob FROM public.box_msgs
        WHERE id = ANY($1::bytea[]) AND "expiresAt" > now()`,
      [ids],
    );
    return new Map(rows.map((r) => [r.id.toString('base64url'), r.blob]));
  }

  /**
   * Points each of `nids` at the token. Selected from `box_queues`, so a
   * queue deleted since its signature was checked is skipped, not an FK
   * error.
   */
  async saveNotifiers(
    nids: Buffer[],
    platform: NotifierPlatform,
    token: string,
  ): Promise<void> {
    await this.db.query(
      `INSERT INTO public.box_notifiers (nid, token, platform, "verifiedAt")
       SELECT q.nid, $2, $3, now() FROM public.box_queues q
        WHERE q.nid = ANY($1::bytea[])
       ON CONFLICT (nid) DO UPDATE
         SET token = EXCLUDED.token, platform = EXCLUDED.platform,
             "verifiedAt" = EXCLUDED."verifiedAt"`,
      [nids, token, platform],
    );
  }

  async notifierFor(
    nid: Buffer,
  ): Promise<{ platform: NotifierPlatform; token: string } | null> {
    const rows: { platform: NotifierPlatform; token: string }[] =
      await this.db.query(
        `SELECT platform, token FROM public.box_notifiers WHERE nid = $1`,
        [nid],
      );
    return rows[0] ?? null;
  }

  /** The push service said the token is gone; keep a row re-registered since. */
  async dropNotifier(nid: Buffer, token: string): Promise<void> {
    await this.db.query(
      `DELETE FROM public.box_notifiers WHERE nid = $1 AND token = $2`,
      [nid, token],
    );
  }

  /**
   * Charges an upload to the daily budget of the NORMAL queue behind `sid`
   * AND to the global media total, and records it — one transaction, so the
   * total always counts exactly the `box_media` rows (a crash between a
   * charge and the row cannot strand bytes). The row names no queue ("budget
   * without link"). The queue row is locked, so parallel uploads cannot
   * overdraw either budget. At the ceiling an unknown sid (or none) is
   * refused like a live one: the answer must not test a sid.
   */
  async chargeMedia(sid: Buffer | null, media: NewMedia): Promise<MediaCharge> {
    return this.db.transaction(async (tx) => {
      const rows: { kind: QueueKind; mediaBytesToday: number }[] = sid
        ? await tx.query(
            `SELECT kind, "mediaBytesToday" FROM public.box_queues
              WHERE sid = $1 FOR UPDATE`,
            [sid],
          )
        : [];
      const queue = rows[0];
      if (!queue) {
        const room: { fits: boolean }[] = await tx.query(
          `SELECT "mediaBytes" + $1 <= $2 AS fits
             FROM public.box_totals WHERE id = 1`,
          [media.bytes, this.ceiling.mediaBytes],
        );
        return room[0]?.fits === true ? 'unknown_sid' : 'over_ceiling';
      }
      if (
        queue.kind !== 'normal' ||
        queue.mediaBytesToday + media.bytes > BOX_MEDIA_DAILY_BUDGET_BYTES
      ) {
        return 'over_budget';
      }
      const [, grown]: [unknown, number] = await tx.query(
        `UPDATE public.box_totals SET "mediaBytes" = "mediaBytes" + $1
          WHERE id = 1 AND "mediaBytes" + $1 <= $2`,
        [media.bytes, this.ceiling.mediaBytes],
      );
      if (grown === 0) return 'over_ceiling';
      await tx.query(
        `UPDATE public.box_queues
            SET "mediaBytesToday" = "mediaBytesToday" + $2
          WHERE sid = $1`,
        [sid, media.bytes],
      );
      await tx.query(
        `INSERT INTO public.box_media (id, path, "sizeBucket", "expiresAt")
         VALUES ($1, $2, $3, $4)`,
        [media.id, media.path, media.bucket, media.expiresAt],
      );
      return 'charged';
    });
  }

  /** The rows go, and the global total gives back their rung sizes. */
  async deleteMedia(ids: Buffer[]): Promise<void> {
    await this.db.query(
      `WITH gone AS (
         DELETE FROM public.box_media WHERE id = ANY($1::bytea[])
         RETURNING "sizeBucket")
       UPDATE public.box_totals
          SET "mediaBytes" = "mediaBytes" - (
            SELECT COALESCE(sum(l.bytes), 0) FROM gone
              JOIN unnest($2::text[], $3::bigint[]) AS l(bucket, bytes)
                ON l.bucket = gone."sizeBucket")
        WHERE id = 1 AND EXISTS (SELECT 1 FROM gone)`,
      [ids, RUNG_BUCKETS, RUNG_BYTES],
    );
  }

  /** The stored path of a live media id, or null. */
  async mediaPath(id: Buffer): Promise<string | null> {
    const rows: { path: string }[] = await this.db.query(
      `SELECT path FROM public.box_media WHERE id = $1 AND "expiresAt" > now()`,
      [id],
    );
    return rows[0]?.path ?? null;
  }

  async expiredMedia(): Promise<{ id: Buffer; path: string }[]> {
    return this.db.query(
      `SELECT id, path FROM public.box_media WHERE "expiresAt" <= now()`,
    );
  }

  /**
   * I3: expired messages go, and their queues' counts and the global total
   * follow in the same statement. The queues are locked first (rid order)
   * and only THEIR messages are deleted, against one fixed cutoff, so a
   * message expiring mid-sweep on an unlocked queue cannot reintroduce the
   * msg-then-queue order.
   */
  async deleteExpiredMessages(): Promise<void> {
    const cutoff = new Date();
    await this.db.transaction(async (tx) => {
      const locked: { rid: Buffer }[] = await tx.query(
        `SELECT rid FROM public.box_queues
          WHERE rid IN (
            SELECT rid FROM public.box_msgs WHERE "expiresAt" <= $1)
          ORDER BY rid FOR UPDATE`,
        [cutoff],
      );
      if (locked.length === 0) return;
      await tx.query(
        `WITH gone AS (
           DELETE FROM public.box_msgs
            WHERE "expiresAt" <= $1 AND rid = ANY($2::bytea[])
            RETURNING rid),
         queues AS (
           UPDATE public.box_queues q
              SET "msgCount" = q."msgCount" - g.n
             FROM (SELECT rid, count(*)::int AS n FROM gone GROUP BY rid) g
            WHERE q.rid = g.rid)
         UPDATE public.box_totals
            SET "msgCount" = "msgCount" - (SELECT count(*) FROM gone)
          WHERE id = 1 AND EXISTS (SELECT 1 FROM gone)`,
        [cutoff, locked.map((r) => r.rid)],
      );
    });
  }

  /**
   * I3: a queue never subscribed within 24 h of creation, and a queue not
   * subscribed for 90 whole days, are deleted with their messages and
   * notifier; the global total gives back their `msgCount`s in the same
   * statement. Returns the rids so live delivery state can forget them.
   */
  async reapQueues(now: Date): Promise<Buffer[]> {
    const cutoff = new Date(now.getTime());
    cutoff.setUTCDate(cutoff.getUTCDate() - BOX_IDLE_REAP_DAYS);
    // A SELECT outside, so `query()` answers the rows alone.
    const rows: { rid: Buffer }[] = await this.db.query(
      `WITH gone AS (
         DELETE FROM public.box_queues
          WHERE rid IN (
            SELECT rid FROM public.box_queues
             WHERE ("claimBy" IS NOT NULL AND "claimBy" <= $1)
                OR ("touchedDay" IS NOT NULL AND "touchedDay" < $2::date)
             ORDER BY rid FOR UPDATE)
          RETURNING rid, "msgCount"),
       total AS (
         UPDATE public.box_totals
            SET "msgCount" = "msgCount" - (SELECT sum("msgCount") FROM gone)
          WHERE id = 1 AND EXISTS (SELECT 1 FROM gone))
       SELECT rid FROM gone`,
      [now, utcDay(cutoff)],
    );
    return rows.map((r) => r.rid);
  }

  /** The daily media budget restarts at 00:00 UTC. */
  async resetMediaBudgets(): Promise<void> {
    await this.db.query(
      `UPDATE public.box_queues SET "mediaBytesToday" = 0
        WHERE rid IN (
          SELECT rid FROM public.box_queues WHERE "mediaBytesToday" <> 0
           ORDER BY rid FOR UPDATE)`,
    );
  }
}
