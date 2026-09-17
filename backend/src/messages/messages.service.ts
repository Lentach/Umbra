import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, In, Not, Repository } from 'typeorm';
import type { QueryDeepPartialEntity } from 'typeorm/query-builder/QueryPartialEntity';
import { Message, MessageDeliveryStatus, MessageType } from './message.entity';
import { MessageEnvelope } from './message-envelope.entity';
import { User } from '../users/user.entity';
import { Conversation } from '../conversations/conversation.entity';
import {
  ExpirableMessage,
  isMessageExpired,
  MESSAGE_NOT_EXPIRED_SQL,
} from './message-expiry.util';
import { MediaCleanupService } from '../media/media-cleanup.service';
import { parseReactions } from './message-reactions.util';

/** Projected row read by [MessagesService.findServedMessageIds]. */
type ServedMessageRow = ExpirableMessage & {
  id: number | string;
  hiddenByUserIds: string | null;
};

@Injectable()
export class MessagesService {
  constructor(
    @InjectRepository(Message)
    private msgRepo: Repository<Message>,
    private mediaCleanup: MediaCleanupService,
  ) {}

  /**
   * Null every reply pointer at [messageId] so the row can be hard-deleted.
   *
   * `messages.reply_to_message_id` is a self-FK with NO ON DELETE clause
   * (0001_baseline.sql), so deleting a replied-to row without this throws
   * 23503 and the caller's delete request fails outright. The reply rows keep
   * their own content; only the preview link goes away — which is correct,
   * because the referenced message no longer exists.
   */
  private async detachReplies(messageId: number): Promise<void> {
    await this.msgRepo.query(
      `UPDATE public.messages
         SET reply_to_message_id = NULL
       WHERE reply_to_message_id = $1`,
      [messageId],
    );
  }

  async create(
    content: string,
    sender: User,
    conversation: Conversation,
    options?: {
      deliveryStatus?: MessageDeliveryStatus;
      expiresAt?: Date | null;
      disappearAfterSeconds?: number | null;
      messageType?: MessageType;
      mediaUrl?: string | null;
      mediaDuration?: number | null;
      replyToMessageId?: number | null;
      encryptedContent?: string | null;
      /** Which of the sender's devices produced this (Phase 1, spec §5.4). */
      originDeviceId?: number | null;
      /** Client token making a retry idempotent (Phase 1, spec §5.4). */
      sendToken?: string | null;
      /**
       * Per-device ciphertexts written in the SAME transaction as the row
       * (spec §5.2 + §12 amendment (v)). When present this is a NEW-MODEL
       * send: `encryptedContent` stays NULL and every device reads its own
       * envelope through the §5.3 device-gated history join.
       */
      envelopes?: Array<{
        userId: number;
        deviceId: number;
        ciphertext: string;
      }>;
    },
  ): Promise<Message> {
    let replyTo: Message | null = null;
    if (options?.replyToMessageId != null) {
      const replyToMsg = await this.msgRepo.findOne({
        where: {
          id: options.replyToMessageId,
          conversation: { id: conversation.id },
        },
        relations: {
          sender: true,
        },
      });
      if (replyToMsg) {
        replyTo = replyToMsg;
      }
    }

    const msg = this.msgRepo.create({
      content,
      sender,
      conversation,
      deliveryStatus: options?.deliveryStatus || MessageDeliveryStatus.SENT,
      expiresAt: options?.expiresAt ?? null,
      disappearAfterSeconds: options?.disappearAfterSeconds ?? null,
      messageType: options?.messageType || MessageType.TEXT,
      mediaUrl: options?.mediaUrl || null,
      mediaDuration: options?.mediaDuration || null,
      encryptedContent: options?.encryptedContent || null,
      originDeviceId: options?.originDeviceId ?? null,
      sendToken: options?.sendToken ?? null,
      replyTo,
    });
    // One message row + N envelope rows in ONE transaction (spec §5.2): a
    // half-written fan-out would leave some devices permanently unable to read
    // a message the sender believes was sent. The envelope-less path keeps its
    // original single save so legacy and metadata sends are untouched.
    const envelopes = options?.envelopes;
    if (envelopes?.length) {
      return this.msgRepo.manager.transaction(async (manager) => {
        const saved = await manager.getRepository(Message).save(msg);
        await manager.getRepository(MessageEnvelope).insert(
          envelopes.map((envelope) => ({
            messageId: saved.id,
            recipientUserId: envelope.userId,
            recipientDeviceId: envelope.deviceId,
            ciphertext: envelope.ciphertext,
            deliveredAt: null,
            readAt: null,
          })),
        );
        if (replyTo) saved.replyTo = replyTo;
        return saved;
      });
    }

    const saved = await this.msgRepo.save(msg);
    if (replyTo) saved.replyTo = replyTo;
    return saved;
  }

  /**
   * The message a sender already committed under [sendToken], if any.
   *
   * A lost ack makes the client retry with the same token; answering with the
   * committed row keeps the send idempotent (Phase 1, spec §5.4) instead of
   * duplicating the message the sender cannot yet see.
   */
  async findBySendToken(
    senderId: number,
    sendToken: string,
  ): Promise<Message | null> {
    return this.msgRepo.findOne({
      where: { sender: { id: senderId }, sendToken },
      relations: { sender: true, conversation: true },
    });
  }

  /**
   * Apply an EDIT in one transaction: stamp `editedAt`, re-point the row at the
   * device that produced the new ciphertext, and rewrite every target device's
   * envelope (spec §5.7 + §12 amendments (xxx)/(xxxii)).
   *
   * Sender-only: returns null when the message is missing or the caller is not
   * the sender, exactly as before.
   *
   * A half-written re-fan would leave some devices reading the OLD text and
   * others the new one, with no way for either to tell which it holds — so the
   * row update and all envelope writes share one transaction.
   */
  async applyEdit(
    messageId: number,
    userId: number,
    fields: {
      encryptedContent?: string | null;
      content?: string;
      originDeviceId?: number | null;
      envelopes?: { userId: number; deviceId: number; ciphertext: string }[];
    },
  ): Promise<Message | null> {
    const msg = await this.msgRepo.findOne({
      where: { id: messageId },
      relations: {
        sender: true,
      },
    });
    if (!msg || msg.sender?.id !== userId) return null;

    const editedAt = new Date();
    const patch: QueryDeepPartialEntity<Message> = { editedAt };
    if (fields.encryptedContent !== undefined)
      patch.encryptedContent = fields.encryptedContent;
    if (fields.content !== undefined) patch.content = fields.content;
    if (fields.originDeviceId !== undefined)
      patch.originDeviceId = fields.originDeviceId;

    const envelopes = fields.envelopes;
    await this.msgRepo.manager.transaction(async (manager) => {
      // A COLUMN-SCOPED update, never a full-entity save: the row carries
      // `deliveryStatus` and the disappearing-message stamps, and an edit must
      // not write back whatever those held when this method loaded the row.
      await manager
        .getRepository(Message)
        .update({ id: messageId }, patch);
      if (envelopes?.length) {
        await this.upsertEnvelopeCiphertexts(messageId, envelopes, manager);
      }
    });

    Object.assign(msg, patch);
    return msg;
  }

  /**
   * Rewrite each named device's envelope ciphertext, INSERTing one for a device
   * that has none yet (spec §5.7).
   *
   * CONTENT-ONLY on conflict, and that is the whole point (durability finding
   * F8, falsification 24): `deliveredAt`/`readAt` SURVIVE the rewrite, because
   * an edit is not an un-delivery — the §4 delivery projection reads those
   * stamps and must never regress from `read` back to `sent` just because the
   * author fixed a typo. A `save()` or a delete-then-insert would silently zero
   * them, so the conflict clause names `ciphertext` and nothing else.
   *
   * A device that had no row is exactly the §5.7 case of one linked AFTER the
   * original send: its `none_for_device` placeholder upgrades to real
   * ciphertext. The reverse never happens here — this method only ever writes a
   * ciphertext, so a real envelope cannot regress to a placeholder.
   */
  async upsertEnvelopeCiphertexts(
    messageId: number,
    envelopes: { userId: number; deviceId: number; ciphertext: string }[],
    manager?: EntityManager,
  ): Promise<void> {
    if (envelopes.length === 0) return;
    const repo = (manager ?? this.msgRepo.manager).getRepository(
      MessageEnvelope,
    );
    await repo
      .createQueryBuilder()
      .insert()
      .into(MessageEnvelope)
      .values(
        envelopes.map((envelope) => ({
          messageId,
          recipientUserId: envelope.userId,
          recipientDeviceId: envelope.deviceId,
          ciphertext: envelope.ciphertext,
          deliveredAt: null,
          readAt: null,
        })),
      )
      // Conflict target = the entity's UNIQUE (messageId, recipientUserId,
      // recipientDeviceId). `orUpdate` lists ONLY `ciphertext`, so every other
      // column of an existing row — both stamps and `createdAt` — is untouched.
      .orUpdate(['ciphertext'], [
        'messageId',
        'recipientUserId',
        'recipientDeviceId',
      ])
      .execute();
  }

  /** Parse hiddenByUserIds string "1,2,3" to number[] */
  static parseHiddenIds(s: string | null | undefined): number[] {
    if (!s || typeof s !== 'string') return [];
    return s
      .split(',')
      .map((x) => parseInt(x.trim(), 10))
      .filter((n) => !isNaN(n));
  }

  // Get messages from a conversation with pagination support.
  // Fetches the N most recent messages (DESC), returns them oldest-first (ASC) for display.
  // offset=0: newest messages; offset=50: next 50 older messages.
  // Pass hiddenByUserId to filter out messages that user has "deleted for me".
  async findByConversation(
    conversationId: number,
    limit: number = 50,
    offset: number = 0,
    hiddenByUserId?: number,
  ): Promise<Message[]> {
    if (hiddenByUserId == null) {
      // No hidden messages: efficient DB-level pagination
      const messages = await this.msgRepo.find({
        where: { conversation: { id: conversationId } },
        relations: {
          sender: true,

          replyTo: {
            sender: true,
          },
        },
        order: { createdAt: 'DESC' },
        take: limit,
        skip: offset,
      });
      return messages.reverse();
    }

    // With hidden messages: fetch extra rows to account for filtered items.
    // No artificial 500-cap — use a generous multiple so deep offsets work.
    const fetchLimit = limit * 3 + offset + 50;
    const messages = await this.msgRepo.find({
      where: { conversation: { id: conversationId } },
      relations: {
        sender: true,

        replyTo: {
          sender: true,
        },
      },
      order: { createdAt: 'DESC' },
      take: fetchLimit,
      skip: 0,
    });

    const filtered = messages.filter(
      (m) =>
        !MessagesService.parseHiddenIds(m.hiddenByUserIds).includes(
          hiddenByUserId,
        ),
    );
    return filtered.slice(offset, offset + limit).reverse();
  }

  /**
   * Of [messageIds], the ones this user's history read path would still serve.
   *
   * The client destroys the local plaintext of every id NOT returned here, and
   * that plaintext is the only copy — the ciphertext on this server can never
   * be decrypted twice. So this MUST stay at least as permissive as
   * `findByConversation` + `ChatMessageService.handleGetMessages`:
   *   - a false "not served" is irreversible data loss;
   *   - a false "served" only leaves residue for a later pass to clear.
   * Bias every difference in the second direction. In particular do NOT copy
   * predicates from the unread-count queries below: they carry `sender != me`
   * and `deliveryStatus != READ`, either of which would report the user's own
   * outgoing history as gone.
   *
   * Deliberately reuses `parseHiddenIds` and `isMessageExpired` rather than
   * restating them as SQL, so the two paths cannot drift apart. The query is
   * projected to the five columns those two rules read: hydrating whole
   * message entities with nested user relations, per chunk, to emit a list of
   * ints is wasted work.
   */
  async findServedMessageIds(
    messageIds: number[],
    userId: number,
  ): Promise<number[]> {
    const ids = Array.from(
      new Set(
        messageIds
          .map((id) => Number(id))
          .filter((id) => Number.isInteger(id) && id > 0),
      ),
    );
    if (ids.length === 0) return [];

    const rows: ServedMessageRow[] = await this.msgRepo
      .createQueryBuilder('m')
      .innerJoin('m.conversation', 'c')
      .select('m.id', 'id')
      .addSelect('m."hiddenByUserIds"', 'hiddenByUserIds')
      .addSelect('m."expiresAt"', 'expiresAt')
      .addSelect('m."disappearAfterSeconds"', 'disappearAfterSeconds')
      .addSelect('m."createdAt"', 'createdAt')
      .where('m.id IN (:...ids)', { ids })
      .andWhere('(c.user_one_id = :userId OR c.user_two_id = :userId)', {
        userId,
      })
      .getRawMany();

    const now = new Date();
    const served: number[] = [];
    for (const row of rows) {
      if (
        MessagesService.parseHiddenIds(row.hiddenByUserIds).includes(userId)
      ) {
        continue;
      }
      if (isMessageExpired(row, now)) continue;
      const id = Number(row.id);
      if (!Number.isNaN(id)) served.push(id);
    }
    return served;
  }

  /** Find message by ID with conversation and sender loaded (for delete flow). */
  async findByIdWithConversation(messageId: number): Promise<Message | null> {
    const message = await this.msgRepo.findOne({
      where: { id: messageId },
      relations: {
        sender: true,

        conversation: {
          userOne: true,
          userTwo: true,
        },
      },
    });
    return message || null;
  }

  // Get the last (most recent) message from a conversation.
  // Pass hiddenByUserId to exclude messages that user has "deleted for me".
  async getLastMessage(
    conversationId: number,
    hiddenByUserId?: number,
  ): Promise<Message | null> {
    const messages = await this.msgRepo.find({
      where: { conversation: { id: conversationId } },
      relations: {
        sender: true,
      },
      order: { createdAt: 'DESC' },
      take: hiddenByUserId != null ? 50 : 1,
    });
    if (messages.length === 0) return null;
    if (hiddenByUserId == null) return messages[0];
    const visible = messages.find(
      (m) =>
        !MessagesService.parseHiddenIds(m.hiddenByUserIds).includes(
          hiddenByUserId,
        ),
    );
    return visible || null;
  }

  /** Status order: never downgrade (e.g. READ must not become DELIVERED when events are processed out of order). */
  private static readonly DELIVERY_STATUS_ORDER: Record<
    MessageDeliveryStatus,
    number
  > = {
    [MessageDeliveryStatus.SENDING]: 0,
    [MessageDeliveryStatus.SENT]: 1,
    [MessageDeliveryStatus.DELIVERED]: 2,
    [MessageDeliveryStatus.READ]: 3,
  };

  /**
   * Project the recipient's delivery state onto the row's single
   * `deliveryStatus` (spec §4).
   *
   * COLUMN-SCOPED by law: a full-entity `save()` here rewrites every column
   * from a possibly stale in-memory copy, so a concurrent write (a reaction, an
   * edit, an expiry stamp) can be silently reverted. The monotonic guard lives
   * in the WHERE clause so two racing reports cannot regress the status.
   * Mirrors `markConversationAsReadFromSender` below (falsification 19).
   */
  async updateDeliveryStatus(
    messageId: number,
    status: MessageDeliveryStatus,
  ): Promise<Message | null> {
    const message = await this.msgRepo.findOne({
      where: { id: messageId },
      relations: {
        sender: true,
        conversation: true,
      },
    });

    if (!message) {
      return null;
    }

    const currentOrder =
      MessagesService.DELIVERY_STATUS_ORDER[message.deliveryStatus];
    const newOrder = MessagesService.DELIVERY_STATUS_ORDER[status];
    if (newOrder <= currentOrder) {
      return message;
    }

    const lowerStatuses = Object.entries(MessagesService.DELIVERY_STATUS_ORDER)
      .filter(([, order]) => order < newOrder)
      .map(([name]) => name);
    await this.msgRepo
      .createQueryBuilder()
      .update(Message)
      .set({ deliveryStatus: status })
      .where('id = :messageId AND "deliveryStatus" IN (:...lowerStatuses)', {
        messageId,
        lowerStatuses,
      })
      .execute();

    message.deliveryStatus = status;
    return message;
  }

  /**
   * The ciphertext each of [messageIds] holds for ONE device, keyed by message
   * id (spec §5.3 per-device history read).
   *
   * Reached through the message repository's manager rather than an injected
   * envelope repository: the fan-out write in [create] does the same, so every
   * envelope access goes through one seam.
   */
  async findEnvelopeCiphertexts(
    messageIds: number[],
    recipientUserId: number,
    recipientDeviceId: number,
  ): Promise<Map<number, string>> {
    if (messageIds.length === 0) return new Map();
    const envelopes = await this.msgRepo.manager
      .getRepository(MessageEnvelope)
      .find({
        where: {
          messageId: In(messageIds),
          recipientUserId,
          recipientDeviceId,
        },
      });
    return new Map(
      envelopes.map((envelope) => [envelope.messageId, envelope.ciphertext]),
    );
  }

  /**
   * Stamp ONE device's envelope as delivered or read (spec §5.3).
   *
   * These stamps are per-device delivery bookkeeping ONLY. They must never
   * feed message expiry or the read-based disappearing TTL: that countdown
   * starts solely from the recipient user's `markConversationAsReadFromSender`
   * over the peer's rows (invariant I9, spec §5.6, durability rider F9).
   */
  async stampEnvelope(
    messageId: number,
    recipientUserId: number,
    recipientDeviceId: number,
    field: 'deliveredAt' | 'readAt',
  ): Promise<void> {
    await this.msgRepo.manager
      .getRepository(MessageEnvelope)
      .createQueryBuilder()
      .update(MessageEnvelope)
      .set({ [field]: () => 'now()' })
      .where(
        `"messageId" = :messageId AND "recipientUserId" = :recipientUserId
           AND "recipientDeviceId" = :recipientDeviceId AND "${field}" IS NULL`,
        { messageId, recipientUserId, recipientDeviceId },
      )
      .execute();
  }

  /**
   * Count unread messages for a recipient in a conversation.
   * Unread = messages sent by the other participant, not yet READ, not expired.
   * Excludes messages hidden by recipientUserId (delete for me).
   */
  async countUnreadForRecipient(
    conversationId: number,
    recipientUserId: number,
  ): Promise<number> {
    const qb = this.msgRepo
      .createQueryBuilder('m')
      .innerJoin('m.sender', 's')
      .where('m.conversation_id = :convId', { convId: conversationId })
      .andWhere('s.id != :userId', { userId: recipientUserId })
      .andWhere('m."deliveryStatus" != :status', {
        status: MessageDeliveryStatus.READ,
      });
    qb.andWhere(MESSAGE_NOT_EXPIRED_SQL, { now: new Date() });
    qb.andWhere(
      `(m."hiddenByUserIds" IS NULL OR m."hiddenByUserIds" = '' OR ` +
        `(',' || COALESCE(m."hiddenByUserIds", '') || ',' NOT LIKE '%,' || :uid::text || ',%'))`,
      { uid: recipientUserId },
    );
    return qb.getCount();
  }

  /**
   * Batch count unread for multiple conversations (I3: avoids N+1).
   * Returns Map<conversationId, unreadCount>.
   */
  async countUnreadForRecipientBatch(
    conversationIds: number[],
    recipientUserId: number,
  ): Promise<Map<number, number>> {
    if (conversationIds.length === 0) return new Map();
    const ids = conversationIds
      .map((id) => Number(id))
      .filter((id) => !Number.isNaN(id));
    if (ids.length === 0) return new Map();
    const rows = await this.msgRepo
      .createQueryBuilder('m')
      .innerJoin('m.sender', 's')
      .select('m.conversation_id', 'conversationId')
      .addSelect('COUNT(*)::int', 'count')
      .where('m.conversation_id IN (:...ids)', { ids })
      .andWhere('s.id != :userId', { userId: recipientUserId })
      .andWhere('m."deliveryStatus" != :status', {
        status: MessageDeliveryStatus.READ,
      })
      .andWhere(MESSAGE_NOT_EXPIRED_SQL, { now: new Date() })
      .andWhere(
        `(m."hiddenByUserIds" IS NULL OR m."hiddenByUserIds" = '' OR ` +
          `(',' || COALESCE(m."hiddenByUserIds", '') || ',' NOT LIKE '%,' || :uid::text || ',%'))`,
        { uid: recipientUserId },
      )
      .groupBy('m.conversation_id')
      .getRawMany();
    const map = new Map<number, number>();
    for (const r of rows) {
      map.set(Number(r.conversationId), Number(r.count));
    }
    for (const id of ids) {
      if (!map.has(id)) map.set(id, 0);
    }
    return map;
  }

  /**
   * Get total unread count and per-conversation breakdown for a user.
   * Single JOIN query across all conversations the user participates in.
   * Used by push-notification coalescing flush for live unread counts.
   */
  async getUnreadSummaryForUser(userId: number): Promise<{
    unreadTotal: number;
    unreadConversationIds: number[];
    countByConversationId: Map<number, number>;
  }> {
    const rows = await this.msgRepo
      .createQueryBuilder('m')
      .innerJoin('m.sender', 's')
      .innerJoin('m.conversation', 'c')
      .select('m.conversation_id', 'conversationId')
      .addSelect('COUNT(*)::int', 'count')
      .where('(c.user_one_id = :userId OR c.user_two_id = :userId)', { userId })
      .andWhere('s.id != :userId', { userId })
      .andWhere('m."deliveryStatus" != :status', {
        status: MessageDeliveryStatus.READ,
      })
      .andWhere(MESSAGE_NOT_EXPIRED_SQL, { now: new Date() })
      .andWhere(
        `(m."hiddenByUserIds" IS NULL OR m."hiddenByUserIds" = '' OR ` +
          `(',' || COALESCE(m."hiddenByUserIds", '') || ',' NOT LIKE '%,' || :uid::text || ',%'))`,
        { uid: userId },
      )
      .groupBy('m.conversation_id')
      .getRawMany();

    const countByConversationId = new Map<number, number>();
    let unreadTotal = 0;
    for (const r of rows) {
      const convId = Number(r.conversationId);
      const count = Number(r.count);
      countByConversationId.set(convId, count);
      unreadTotal += count;
    }
    return {
      unreadTotal,
      unreadConversationIds: Array.from(countByConversationId.keys()),
      countByConversationId,
    };
  }

  /**
   * Batch get last message per conversation (I3: avoids N+1).
   * Uses PostgreSQL DISTINCT ON. Returns Map<conversationId, Message | null>.
   */
  async getLastMessagesBatch(
    conversationIds: number[],
    hiddenByUserId?: number,
  ): Promise<Map<number, Message | null>> {
    if (conversationIds.length === 0) return new Map();
    const ids = conversationIds
      .map((id) => Number(id))
      .filter((id) => !Number.isNaN(id));
    if (ids.length === 0) return new Map();
    let hiddenClause = '';
    const queryParams: unknown[] = [ids];
    if (hiddenByUserId != null) {
      queryParams.push(hiddenByUserId);
      const uidParamIdx = queryParams.length;
      hiddenClause =
        ` AND ("hiddenByUserIds" IS NULL OR "hiddenByUserIds" = '' OR ` +
        `(',' || COALESCE("hiddenByUserIds", '') || ',' NOT LIKE '%,' || $${uidParamIdx}::text || ',%'))`;
    }
    const rawRows = await this.msgRepo.query(
      `SELECT id, conversation_id as "conversationId" FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY conversation_id ORDER BY "createdAt" DESC) as rn
        FROM messages
        WHERE conversation_id = ANY($1::int[])${hiddenClause}
      ) sub WHERE rn = 1`,
      queryParams,
    );
    const msgIds = rawRows
      .map((r: { id: unknown }) => Number(r.id))
      .filter((id) => !Number.isNaN(id));
    const convIdByMsgId = new Map<number, number>();
    for (const r of rawRows) {
      const mid = Number((r as { id: unknown }).id);
      const cid = Number((r as { conversationId: unknown }).conversationId);
      if (!Number.isNaN(mid) && !Number.isNaN(cid)) convIdByMsgId.set(mid, cid);
    }
    if (msgIds.length === 0) {
      const map = new Map<number, Message | null>();
      for (const id of conversationIds) map.set(Number(id), null);
      return map;
    }
    const messages = await this.msgRepo.find({
      where: { id: In(msgIds) },
      relations: {
        sender: true,
      },
    });
    const byConvId = new Map<number, Message>();
    for (const m of messages) {
      const convId = convIdByMsgId.get(m.id);
      if (convId != null) byConvId.set(convId, m);
    }
    const map = new Map<number, Message | null>();
    for (const id of conversationIds) {
      const numId = Number(id);
      map.set(numId, byConvId.get(numId) ?? null);
    }
    return map;
  }

  /**
   * Batch fetch pinned message rows for conversation list snapshots.
   * Returns Map<conversationId, Message | null>.
   */
  async getPinnedMessagesBatch(
    entries: Array<{ conversationId: number; pinnedMessageId: number | null }>,
    hiddenByUserId?: number,
  ): Promise<Map<number, Message | null>> {
    const map = new Map<number, Message | null>();
    const pinnedIds: number[] = [];
    const convIdByMsgId = new Map<number, number>();
    for (const entry of entries) {
      const convId = Number(entry.conversationId);
      map.set(convId, null);
      const pinnedId = entry.pinnedMessageId;
      if (pinnedId != null && !Number.isNaN(Number(pinnedId))) {
        const msgId = Number(pinnedId);
        pinnedIds.push(msgId);
        convIdByMsgId.set(msgId, convId);
      }
    }
    if (pinnedIds.length === 0) return map;

    const messages = await this.msgRepo.find({
      where: { id: In(pinnedIds) },
      relations: {
        sender: true,
        conversation: true,
      },
    });

    for (const m of messages) {
      const convId = convIdByMsgId.get(m.id);
      if (convId == null) continue;
      if (hiddenByUserId != null) {
        const hidden = m.hiddenByUserIds ?? '';
        if (hidden.length > 0) {
          const padded = `,${hidden},`;
          if (padded.includes(`,${hiddenByUserId},`)) {
            map.set(convId, null);
            continue;
          }
        }
      }
      map.set(convId, m);
    }
    return map;
  }

  /** Mark all messages in the conversation that were sent BY senderId (to the other participant) as READ. Returns only the messages that were actually changed (were not already READ). */
  async markConversationAsReadFromSender(
    conversationId: number,
    senderId: number,
  ): Promise<Message[]> {
    // Fetch messages that will actually be changed (not yet READ) before the update
    const toUpdate = await this.msgRepo.find({
      where: {
        conversation: { id: conversationId },
        sender: { id: senderId },
        deliveryStatus: Not(MessageDeliveryStatus.READ),
      },
      relations: {
        sender: true,
      },
    });

    if (toUpdate.length === 0) return [];

    // Batch update — single query instead of N individual saves
    await this.msgRepo
      .createQueryBuilder()
      .update(Message)
      .set({ deliveryStatus: MessageDeliveryStatus.READ })
      .where(
        'conversation_id = :convId AND sender_id = :senderId AND "deliveryStatus" != :status',
        {
          convId: conversationId,
          senderId,
          status: MessageDeliveryStatus.READ,
        },
      )
      .execute();

    const readMessages = toUpdate.map(
      (m) =>
        ({
          ...m,
          deliveryStatus: MessageDeliveryStatus.READ,
        }) as Message,
    );

    const now = new Date();
    const expiryUpdates: Message[] = [];
    for (const msg of readMessages) {
      if (msg.disappearAfterSeconds != null && msg.expiresAt == null) {
        msg.expiresAt = new Date(
          now.getTime() + msg.disappearAfterSeconds * 1000,
        );
        expiryUpdates.push(msg);
      }
    }
    if (expiryUpdates.length > 0) {
      await this.msgRepo.save(expiryUpdates);
    }

    return readMessages;
  }

  /** Non-null media URLs in a conversation (for disk cleanup before row delete). */
  async findMediaUrlsByConversation(conversationId: number): Promise<string[]> {
    const rows = await this.msgRepo
      .createQueryBuilder('m')
      .select('m.mediaUrl', 'mediaUrl')
      .where('m.conversation_id = :id', { id: conversationId })
      .andWhere('m.mediaUrl IS NOT NULL')
      .getRawMany();
    return rows
      .map((r: { mediaUrl: string | null }) => r.mediaUrl)
      .filter((u): u is string => !!u);
  }

  /**
   * Delete all messages in a conversation.
   * Used when clearing chat history.
   */
  async deleteAllByConversation(conversationId: number): Promise<void> {
    await this.msgRepo.delete({ conversation: { id: conversationId } });
  }

  /**
   * "Delete for me" — add userId to hiddenByUserIds so message is hidden from
   * that user, then hard-delete the row once EVERY conversation participant
   * has hidden it: a row nobody can ever read again is pure retention.
   *
   * The append is one atomic UPDATE, not read-modify-save: two participants
   * hiding concurrently serialize on the row lock, so the second UPDATE's
   * RETURNING value contains both ids and the hard delete fires. The old
   * read-modify-save let one hide clobber the other — the clobbered user saw
   * the message resurface AND the row could never qualify for deletion.
   *
   * The delete guard fails closed: the participant set comes from the
   * conversation relation (never a hardcoded count), and a missing relation
   * or empty set means "never delete". One participant hiding must NEVER
   * delete — the other side still reads the message.
   */
  async hideMessageForUser(
    messageId: number,
    userId: number,
  ): Promise<boolean> {
    const message = await this.msgRepo.findOne({
      where: { id: messageId },
      relations: {
        conversation: true,
      },
    });
    if (!message) return false;

    let hidden = MessagesService.parseHiddenIds(message.hiddenByUserIds);
    if (!hidden.includes(userId)) {
      // repo.query() returns [rows, rowCount] for UPDATE ... RETURNING.
      const result: unknown = await this.msgRepo.query(
        `UPDATE public.messages
           SET "hiddenByUserIds" = CASE
             WHEN "hiddenByUserIds" IS NULL OR "hiddenByUserIds" = '' THEN $2
             WHEN $2 = ANY (string_to_array("hiddenByUserIds", ',')) THEN "hiddenByUserIds"
             ELSE "hiddenByUserIds" || ',' || $2
           END
         WHERE id = $1
         RETURNING "hiddenByUserIds"`,
        [messageId, String(userId)],
      );
      const [rows] = result as [
        Array<{ hiddenByUserIds: string | null }>,
        number,
      ];
      if (!rows || rows.length === 0) return false; // row vanished mid-flight
      hidden = MessagesService.parseHiddenIds(rows[0].hiddenByUserIds);
    }

    const conv = message.conversation;
    const participantIds = [
      ...new Set(
        [conv?.userOne?.id, conv?.userTwo?.id].filter(
          (id): id is number => typeof id === 'number',
        ),
      ),
    ];
    const everyParticipantHid =
      participantIds.length > 0 &&
      participantIds.every((id) => hidden.includes(id));
    if (everyParticipantHid) {
      // Media before row (backend CLAUDE.md §8): a failed unlink after row
      // deletion would orphan the file with nothing pointing at it.
      if (message.mediaUrl) {
        await this.mediaCleanup.deleteMediaFile(message.mediaUrl);
      }
      await this.detachReplies(messageId);
      await this.msgRepo.delete({ id: messageId });
    }
    return true;
  }

  async addOrUpdateReaction(
    messageId: number,
    userId: number,
    emoji: string,
  ): Promise<Message | null> {
    // BE-152/BE-201: serialize the read-modify-write. Two users reacting to the
    // same message concurrently both load the old JSON and the later `save`
    // clobbers the earlier writer's emoji. Row-lock the messages row (raw SQL,
    // no join — the eager `sender` LEFT JOIN would make Postgres reject
    // FOR UPDATE) so the second reaction waits, then reads the first's result.
    return this.msgRepo.manager.transaction(async (manager) => {
      const rows: Array<{ reactions: string | null }> = await manager.query(
        `SELECT reactions FROM public.messages WHERE id = $1 FOR UPDATE`,
        [messageId],
      );
      if (rows.length === 0) return null;

      const reactions = parseReactions(rows[0].reactions);

      // Remove user's previous emoji (max 1 per user)
      for (const key of Object.keys(reactions)) {
        reactions[key] = reactions[key].filter((id) => id !== userId);
        if (reactions[key].length === 0) delete reactions[key];
      }

      // Add new emoji
      if (!reactions[emoji]) reactions[emoji] = [];
      reactions[emoji].push(userId);

      await manager.query(
        `UPDATE public.messages SET reactions = $2 WHERE id = $1`,
        [messageId, JSON.stringify(reactions)],
      );

      return manager.findOne(Message, {
        where: { id: messageId },
        relations: {
          sender: true,
          conversation: true,
        },
      });
    });
  }

  /**
   * Removes `userId`'s reaction from `messageId`, whatever key holds it.
   *
   * The reaction key is deliberately not a parameter: one reaction per user
   * is already an invariant of `addOrUpdateReaction`, so the caller does not
   * need to know whether it was stored as a blinded token or a plain emoji.
   */
  async removeReaction(
    messageId: number,
    userId: number,
  ): Promise<Message | null> {
    // BE-152/BE-201: same row-lock as addOrUpdateReaction — a remove racing an
    // add must not clobber; the later writer must observe the earlier result.
    return this.msgRepo.manager.transaction(async (manager) => {
      const rows: Array<{ reactions: string | null }> = await manager.query(
        `SELECT reactions FROM public.messages WHERE id = $1 FOR UPDATE`,
        [messageId],
      );
      if (rows.length === 0) return null;

      const reactions = parseReactions(rows[0].reactions);

      // Strip this user from EVERY key, not just the one named.
      //
      // `addOrUpdateReaction` already enforces at most one reaction per user,
      // so this removes exactly that one reaction — but it no longer depends
      // on the caller naming the key it was stored under. That matters during
      // the reaction-token compat window: a reaction placed by a client that
      // still writes the plain emoji is toggled off by an updated client that
      // sends a blinded token, and an exact-key delete left it lit forever
      // with no way to clear it.
      for (const key of Object.keys(reactions)) {
        reactions[key] = reactions[key].filter((id) => id !== userId);
        if (reactions[key].length === 0) delete reactions[key];
      }

      await manager.query(
        `UPDATE public.messages SET reactions = $2 WHERE id = $1`,
        [messageId, JSON.stringify(reactions)],
      );

      return manager.findOne(Message, {
        where: { id: messageId },
        relations: {
          sender: true,
          conversation: true,
        },
      });
    });
  }

  async updateLinkPreview(
    messageId: number,
    url: string,
    title: string | null,
    imageUrl: string | null,
  ): Promise<Message | null> {
    const message = await this.msgRepo.findOne({ where: { id: messageId } });
    if (!message) return null;
    message.linkPreviewUrl = url;
    message.linkPreviewTitle = title;
    message.linkPreviewImageUrl = imageUrl;
    return this.msgRepo.save(message);
  }

  /**
   * "Delete for everyone" — hard delete the message. Only sender can call this.
   *
   * Replies are detached first: the reply self-FK has no ON DELETE clause, so
   * deleting a replied-to message would otherwise fail with 23503 (see
   * [detachReplies]).
   */
  async deleteById(
    messageId: number,
    requesterId: number,
  ): Promise<Message | null> {
    const message = await this.msgRepo.findOne({
      where: { id: messageId },
      relations: {
        sender: true,
        conversation: true,
      },
    });
    if (!message) return null;
    if (message.sender.id !== requesterId) return null;
    await this.detachReplies(messageId);
    await this.msgRepo.remove(message);
    return message;
  }
}
