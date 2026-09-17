import { Injectable } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource, EntityManager } from 'typeorm';

/** One device's wrapped copy in an upload. */
export interface ReactionKeyEnvelope {
  userId: number;
  deviceId: number;
  ciphertext: string;
}

/** Who produced the ciphertext — the authenticated uploader, never a claim. */
export interface ReactionKeyUploader {
  userId: number;
  deviceId: number;
}

/**
 * The outcome of an upload. `accepted: false` carries the epoch the server
 * actually holds, so the caller can re-wrap at `epoch + 1` instead of guessing.
 */
export type ReactionKeyUploadResult =
  { accepted: true; epoch: number } | { accepted: false; epoch: number };

/** The caller's own row at the conversation's current epoch. */
export interface ReactionKeyRow {
  epoch: number;
  senderUserId: number | null;
  senderDeviceId: number | null;
  ciphertext: string | null;
}

/**
 * Storage for the per-conversation reaction key
 * (`docs/design/reaction-privacy.md` §3.1).
 *
 * This service owns the one genuinely new server-side invariant of the design:
 * the epoch is SERVER-assigned. Everything else about reactions — merge,
 * toggle, the `FOR UPDATE` atomicity, the fan-out — is unchanged and blind to
 * whether the column holds emoji or tokens.
 */
@Injectable()
export class ReactionKeysService {
  constructor(@InjectDataSource() private readonly dataSource: DataSource) {}

  /**
   * Publish wrapped copies of a conversation's reaction key at `epoch`.
   *
   * Accepted in exactly two shapes, and the conversation row is locked for the
   * whole decision so two clients racing cannot both win:
   *
   *  - `epoch === current + 1` — a NEW key (creation or rotation). The
   *    conversation's epoch advances in the same transaction as the rows, so a
   *    half-published rotation can never leave the epoch pointing at rows that
   *    were never written.
   *  - `epoch === current` AND every row already at that epoch was uploaded by
   *    this same uploader — the top-up path: a retry after a lost ack, or the
   *    `deviceListChanged` re-upload that seals the SAME key to a newly linked
   *    device. A different uploader owning the epoch is refused, because its
   *    ciphertext is bound to a Signal session with a different device.
   *
   * Anything else is refused with the current epoch and writes NOTHING.
   */
  async upload(
    conversationId: number,
    epoch: number,
    uploader: ReactionKeyUploader,
    envelopes: ReactionKeyEnvelope[],
  ): Promise<ReactionKeyUploadResult> {
    // Epoch 0 means "no key has ever been uploaded" and is never a row's
    // epoch; accepting it would make the vacuous same-epoch branch below
    // publish under the sentinel.
    if (!Number.isInteger(epoch) || epoch < 1) {
      return { accepted: false, epoch: 0 };
    }

    return this.dataSource.transaction(async (manager) => {
      const locked: Array<{ reactionKeyEpoch: number | null }> =
        await manager.query(
          `SELECT "reactionKeyEpoch" FROM public.conversations WHERE id = $1 FOR UPDATE`,
          [conversationId],
        );
      // Raced against a conversation delete; its key rows went with it.
      if (!locked.length) return { accepted: false, epoch: 0 };

      const current = Number(locked[0].reactionKeyEpoch ?? 0);
      const advancing = epoch === current + 1;
      if (
        !advancing &&
        !(
          epoch === current &&
          (await this.ownedBy(manager, conversationId, epoch, uploader))
        )
      ) {
        return { accepted: false, epoch: current };
      }

      await this.upsertEnvelopes(
        manager,
        conversationId,
        epoch,
        uploader,
        envelopes,
      );
      if (advancing) {
        await manager.query(
          `UPDATE public.conversations SET "reactionKeyEpoch" = $1 WHERE id = $2`,
          [epoch, conversationId],
        );
      }
      return { accepted: true, epoch };
    });
  }

  /**
   * The caller's OWN wrapped copy at the conversation's current epoch.
   *
   * The `(userId, deviceId)` predicate lives in the JOIN, so the query can
   * never surface another device's row, and the epoch is still answered when
   * no row exists — a device whose copy has not been uploaded yet learns that
   * it is behind rather than that reactions are broken.
   */
  async fetchOwn(
    conversationId: number,
    userId: number,
    deviceId: number,
  ): Promise<ReactionKeyRow | null> {
    const rows: Array<{
      epoch: number | null;
      senderUserId: number | null;
      senderDeviceId: number | null;
      ciphertext: string | null;
    }> = await this.dataSource.query(
      `SELECT c."reactionKeyEpoch" AS epoch,
              k."senderUserId" AS "senderUserId",
              k."senderDeviceId" AS "senderDeviceId",
              k.ciphertext AS ciphertext
         FROM public.conversations c
         LEFT JOIN public.reaction_keys k
           ON k."conversationId" = c.id
          AND k.epoch = c."reactionKeyEpoch"
          AND k."userId" = $2
          AND k."deviceId" = $3
        WHERE c.id = $1`,
      [conversationId, userId, deviceId],
    );
    if (!rows.length) return null;

    const row = rows[0];
    const ciphertext = row.ciphertext ?? null;
    return {
      epoch: Number(row.epoch ?? 0),
      // Meaningless without a ciphertext, so they travel together.
      senderUserId: ciphertext === null ? null : (row.senderUserId ?? null),
      senderDeviceId: ciphertext === null ? null : (row.senderDeviceId ?? null),
      ciphertext,
    };
  }

  /** Whether `epoch`'s existing rows were all uploaded by this uploader. */
  private async ownedBy(
    manager: EntityManager,
    conversationId: number,
    epoch: number,
    uploader: ReactionKeyUploader,
  ): Promise<boolean> {
    const owners: Array<{ senderUserId: number; senderDeviceId: number }> =
      await manager.query(
        `SELECT DISTINCT "senderUserId", "senderDeviceId"
           FROM public.reaction_keys
          WHERE "conversationId" = $1 AND epoch = $2`,
        [conversationId, epoch],
      );
    return owners.every(
      (owner) =>
        Number(owner.senderUserId) === uploader.userId &&
        Number(owner.senderDeviceId) === uploader.deviceId,
    );
  }

  /**
   * One multi-row upsert: a re-upload replaces the ciphertext (and its
   * attribution) for that device rather than failing on the primary key.
   */
  private async upsertEnvelopes(
    manager: EntityManager,
    conversationId: number,
    epoch: number,
    uploader: ReactionKeyUploader,
    envelopes: ReactionKeyEnvelope[],
  ): Promise<void> {
    const params: unknown[] = [
      conversationId,
      epoch,
      uploader.userId,
      uploader.deviceId,
    ];
    const values = envelopes.map((envelope) => {
      const base = params.length;
      params.push(envelope.userId, envelope.deviceId, envelope.ciphertext);
      return `($1, $${base + 1}, $${base + 2}, $2, $3, $4, $${base + 3})`;
    });

    await manager.query(
      `INSERT INTO public.reaction_keys
         ("conversationId", "userId", "deviceId", epoch, "senderUserId", "senderDeviceId", ciphertext)
       VALUES ${values.join(', ')}
       ON CONFLICT ("conversationId", "userId", "deviceId", epoch)
       DO UPDATE SET ciphertext = EXCLUDED.ciphertext,
                     "senderUserId" = EXCLUDED."senderUserId",
                     "senderDeviceId" = EXCLUDED."senderDeviceId",
                     "createdAt" = now()`,
      params,
    );
  }
}
