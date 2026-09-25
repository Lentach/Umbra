import { Injectable } from '@nestjs/common';
import { randomBytes } from 'crypto';
import { DataSource } from 'typeorm';
import {
  BOX_IDLE_REAP_DAYS,
  BOX_MEDIA_DAILY_BUDGET_BYTES,
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
  /** Unknown or deleted sid: the caller answers `ok` anyway (no block oracle). */
  | { result: 'dropped' };

export type MediaCharge = 'charged' | 'over_budget' | 'unknown_sid';

/** The UTC calendar day of `at`, as Postgres `date` text. */
function utcDay(at: Date): string {
  return at.toISOString().slice(0, 10);
}

/**
 * Every read and write of the box tables. Raw SQL on purpose: each counter
 * change (`msgCount`, `mediaBytesToday`) happens in the SAME statement or
 * transaction as the row change it counts, so a crash or a race can never
 * leave a count that lets a queue exceed its cap.
 *
 * `repo.query()` on Postgres answers DELETE/UPDATE with `[rows, rowCount]`
 * and SELECT/INSERT with `rows` (backend/CLAUDE.md §4); every call below
 * destructures accordingly.
 *
 * LOCK ORDER, everywhere: `box_queues` rows first — several at once only in
 * rid order — then `box_msgs` rows. `enqueue` must hold the queue while it
 * evicts a message, so any writer that deletes a message and then touches
 * the queue's counter (ack, the expiry sweep) takes the queue lock FIRST;
 * the opposite order deadlocks an ack against a flood on a full request
 * queue (40P01, reproduced by the integration suite). The FK cascades
 * (queue → msgs) already follow this order.
 */
@Injectable()
export class BoxService {
  constructor(private readonly db: DataSource) {}

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
   * holds the public request sid). The queue row is locked for the duration,
   * so the count check and the insert cannot interleave with another send.
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
      if (!queue) return { result: 'dropped' } as const;
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
           DELETE FROM public.box_msgs WHERE rid = $1 AND id = $2 RETURNING rid)
         UPDATE public.box_queues
            SET "msgCount" = "msgCount" - (SELECT count(*) FROM gone)
          WHERE rid = $1 AND EXISTS (SELECT 1 FROM gone)`,
        [rid, id],
      );
    });
  }

  /** Messages and the notifier go with it (FK cascades). */
  async deleteQueue(rid: Buffer): Promise<void> {
    await this.db.query(`DELETE FROM public.box_queues WHERE rid = $1`, [rid]);
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
   * Charges `bytes` to the daily budget of the NORMAL queue behind `sid`.
   * The check and the charge are one conditional UPDATE, so parallel uploads
   * cannot overdraw it.
   */
  async chargeMedia(sid: Buffer, bytes: number): Promise<MediaCharge> {
    const [, charged]: [unknown, number] = await this.db.query(
      `UPDATE public.box_queues
          SET "mediaBytesToday" = "mediaBytesToday" + $2
        WHERE sid = $1 AND kind = 'normal'
          AND "mediaBytesToday" + $2 <= $3`,
      [sid, bytes, BOX_MEDIA_DAILY_BUDGET_BYTES],
    );
    if (charged === 1) return 'charged';
    const known: unknown[] = await this.db.query(
      `SELECT 1 FROM public.box_queues WHERE sid = $1`,
      [sid],
    );
    return known.length === 1 ? 'over_budget' : 'unknown_sid';
  }

  async insertMedia(
    id: Buffer,
    path: string,
    sizeBucket: string,
    expiresAt: Date,
  ): Promise<void> {
    await this.db.query(
      `INSERT INTO public.box_media (id, path, "sizeBucket", "expiresAt")
       VALUES ($1, $2, $3, $4)`,
      [id, path, sizeBucket, expiresAt],
    );
  }

  async deleteMedia(ids: Buffer[]): Promise<void> {
    await this.db.query(
      `DELETE FROM public.box_media WHERE id = ANY($1::bytea[])`,
      [ids],
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
   * I3: expired messages go, and their queues' counts follow in the same
   * transaction. The queues are locked first (rid order) and only THEIR
   * messages are deleted, against one fixed cutoff, so a message expiring
   * mid-sweep on an unlocked queue cannot reintroduce the msg-then-queue order.
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
            RETURNING rid)
         UPDATE public.box_queues q
            SET "msgCount" = q."msgCount" - g.n
           FROM (SELECT rid, count(*)::int AS n FROM gone GROUP BY rid) g
          WHERE q.rid = g.rid`,
        [cutoff, locked.map((r) => r.rid)],
      );
    });
  }

  /**
   * I3: a queue never subscribed within 24 h of creation, and a queue not
   * subscribed for 90 whole days, are deleted with their messages and
   * notifier. Returns the rids so live delivery state can forget them.
   */
  async reapQueues(now: Date): Promise<Buffer[]> {
    const cutoff = new Date(now.getTime());
    cutoff.setUTCDate(cutoff.getUTCDate() - BOX_IDLE_REAP_DAYS);
    const [rows]: [{ rid: Buffer }[], number] = await this.db.query(
      `DELETE FROM public.box_queues
        WHERE rid IN (
          SELECT rid FROM public.box_queues
           WHERE ("claimBy" IS NOT NULL AND "claimBy" <= $1)
              OR ("touchedDay" IS NOT NULL AND "touchedDay" < $2::date)
           ORDER BY rid FOR UPDATE)
        RETURNING rid`,
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
