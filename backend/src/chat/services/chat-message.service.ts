import { Injectable, Logger } from '@nestjs/common';
import { Server, Socket } from 'socket.io';
import { MessagesService } from '../../messages/messages.service';
import { ConversationsService } from '../../conversations/conversations.service';
import { ChatValidationService } from './chat-validation.service';
import { UsersService } from '../../users/users.service';
import { ChatLinkPreviewService } from './chat-link-preview.service';
import { PushNotificationCoalescingService } from '../../push-notifications/push-notification-coalescing.service';
import { validateDto } from '../utils/dto.validator';
import {
  SendMessageDto,
  SendEnvelopeDto,
  GetMessagesDto,
  ClearChatHistoryDto,
  DeleteMessageDto,
  GetServedMessageIdsDto,
} from '../dto/chat.dto';
import { MessageDeliveredDto } from '../dto/message-delivered.dto';
import { MarkConversationReadDto } from '../dto/mark-conversation-read.dto';
import { Message, MessageDeliveryStatus } from '../../messages/message.entity';
import { MessageMapper } from '../../messages/message.mapper';
import { MediaCleanupService } from '../../media/media-cleanup.service';
import { isMessageExpired } from '../../messages/message-expiry.util';
import { EditMessageDto } from '../dto/edit-message.dto';
import {
  emitToDeviceNewestSocket,
  newestSocketForDevice,
  userRoom,
} from '../utils/user-room';
import { DEFAULT_DEVICE_ID } from '../../key-bundles/key-bundles.service';
import { DevicesService } from '../../key-bundles/devices.service';
import { DeviceListService } from '../../key-bundles/device-list.service';
import { AccountAuthorization } from '../../key-bundles/account-authorization.entity';

/**
 * The envelope-bearing subset of an inbound fan-out, shared by a send (spec
 * §5.2) and an EDIT (§5.7 + §12 amendment (xxxi)).
 *
 * Both shapes run the SAME shape and freshness checks, so the checks read this
 * narrow type rather than either DTO: an edit derives `recipientId` from the
 * conversation instead of quoting it, and carries no `tempId`.
 */
type EnvelopeCarrier = {
  recipientId: number;
  envelopes?: SendEnvelopeDto[];
  encryptedContent?: string | null;
  senderListVersion?: number;
  recipientListVersion?: number;
};

/** One (recipient user, device) ciphertext of a fan-out send (spec §5.2). */
type ResolvedEnvelope = {
  userId: number;
  deviceId: number;
  ciphertext: string;
};

/**
 * One party's signed-list record in a `deviceListStale` refusal (spec §5.2
 * layer 1 + §12 amendment (vi)). The client runs the I7 chain over this
 * itself — the server's word alone is never trusted (falsification 4).
 */
type StaleListEntry = {
  userId: number;
  version: number;
  listCanonical: string;
  listSignature: string;
  enrollment: {
    dakPub: string;
    enrollmentSig: string;
    enrollmentCreatedAt: number;
  };
};

/** Editing a sent message is only allowed within this window after it was created. */
const EDIT_WINDOW_MS = 15 * 60 * 1000;

/**
 * The socket's authenticated user id, or null before auth completed.
 *
 * `client.data` is `any` in socket.io's types; the gateway writes `data.user`
 * itself at auth time, so this narrows an INTERNAL shape rather than external
 * input. Runtime-narrowed instead of cast so the lint ratchet stays honest —
 * used by the served-ids handler; older handlers keep their historical
 * pattern untouched.
 */
function servedIdsCallerId(client: Socket): number | null {
  const data: unknown = client.data;
  if (!data || typeof data !== 'object' || !('user' in data)) return null;
  const user = data.user;
  if (!user || typeof user !== 'object' || !('id' in user)) return null;
  return typeof user.id === 'number' ? user.id : null;
}

/**
 * Which device this socket session is (Phase 1, spec §4). Absent on a token
 * issued before the claim existed; the column then stays NULL rather than
 * claiming a device the sender may not have used.
 */
function socketDeviceId(client: Socket): number | undefined {
  return (client.data as { user?: { deviceId?: number } }).user?.deviceId;
}

@Injectable()
export class ChatMessageService {
  private readonly logger = new Logger(ChatMessageService.name);

  constructor(
    private readonly messagesService: MessagesService,
    private readonly conversationsService: ConversationsService,
    private readonly chatValidationService: ChatValidationService,
    private readonly usersService: UsersService,
    private readonly chatLinkPreviewService: ChatLinkPreviewService,
    private readonly pushCoalescingService: PushNotificationCoalescingService,
    private readonly mediaCleanup: MediaCleanupService,
    private readonly devicesService: DevicesService,
    private readonly deviceListService: DeviceListService,
  ) {}

  /**
   * The fan-out shape of this send (spec §5.2 + §12 amendment (v)).
   *
   * A legacy single-ciphertext send is NORMALIZED to a one-element device-1
   * envelope so exactly one write path exists downstream (§8 compat); a send
   * carrying no ciphertext at all (PING and today's plaintext shapes) yields
   * no envelope and keeps its historical behaviour.
   */
  private resolveEnvelopes(send: EnvelopeCarrier): ResolvedEnvelope[] {
    if (send.envelopes?.length) {
      return send.envelopes.map((envelope) => ({
        userId: envelope.userId,
        deviceId: envelope.deviceId,
        ciphertext: envelope.ciphertext,
      }));
    }
    if (send.encryptedContent) {
      return [
        {
          userId: send.recipientId,
          deviceId: DEFAULT_DEVICE_ID,
          ciphertext: send.encryptedContent,
        },
      ];
    }
    return [];
  }

  /**
   * The refusal code for an unacceptable envelope set, or null when the set is
   * addressable (spec §12 amendment (v)).
   *
   * Every check runs BEFORE any persistence, so a refused send writes nothing
   * (falsification 5). Device 1 predates the devices table and is exempt from
   * the liveness check, exactly as the key-material upload gates are.
   */
  private async envelopeRefusal(
    envelopes: ResolvedEnvelope[],
    senderId: number,
    recipientId: number,
    originDeviceId: number,
  ): Promise<string | null> {
    const seen = new Set<string>();
    for (const envelope of envelopes) {
      const key = `${envelope.userId}:${envelope.deviceId}`;
      // Two ciphertexts for one device would consume the same message key
      // twice — Signal decryption is not idempotent, so last-wins would brick
      // that device's ratchet. Refuse instead.
      if (seen.has(key)) return 'duplicate_envelope_device';
      seen.add(key);

      // An envelope may only address this conversation's recipient or the
      // sender's OWN other devices (§5.4 self-sync). Anything else would have
      // the server deliver ciphertext to a third party the send never named.
      if (envelope.userId !== recipientId && envelope.userId !== senderId) {
        return 'unknown_envelope_user';
      }
      if (
        envelope.userId === senderId &&
        envelope.deviceId === originDeviceId
      ) {
        return 'self_envelope_for_origin_device';
      }
      if (
        envelope.deviceId !== DEFAULT_DEVICE_ID &&
        !(await this.devicesService.isActive(
          envelope.userId,
          envelope.deviceId,
        ))
      ) {
        return 'unknown_recipient_device';
      }
    }
    return null;
  }

  /**
   * Whether this send must be refused because a party owes a replacement
   * enrollment (spec §12 amendment (lx)), or null when it may proceed.
   *
   * (l) put this refusal on `getDeviceList`. The send path never opens that
   * door: `_resolveFanOut` deliberately does not fetch, and the client's
   * verified-list cache is memory-only, so the first send of every session goes
   * out in the LEGACY shape and is answered by the `deviceListStale` bounce —
   * which shipped the account's full signed record with no guard at all. The
   * peer then VERIFIES that orphaned roster (it was signed by exactly the key
   * the peer pinned, which is (l)'s own premise), adopts a roster of revoked
   * devices, and re-sends into it. Where the only live entry is device 1 the
   * envelope passes the liveness check, the row commits with a null ciphertext,
   * and the recovering device reads `none_for_device` forever while the sender
   * is shown success.
   *
   * A never-enrolled account post-reset is quieter still: `envelopeRefusal` is
   * skipped for a legacy send and `staleLists` contributes nothing for a party
   * with no row, so nothing bounces and the send commits to the revoked device
   * 1. So this check runs for BOTH shapes and BEFORE any persistence.
   *
   * BOTH directions are refused. A recipient that owes a replacement cannot
   * receive; a sender that owes one cannot be verified by the peer's accept
   * gate. Both are silent, permanent, bidirectional loss. The window is short —
   * the replacement offer rides `keyBundleUploaded` on every authenticated
   * upload and the client re-uploads on every connect.
   */
  private async replacementOwedRefusal(
    senderId: number,
    recipientId: number,
  ): Promise<string | null> {
    // Recipient first: it is the party whose freshness decides delivery.
    if (
      (await this.deviceListService.pendingReplacementVersion(recipientId)) !==
      null
    ) {
      return 'recipient_device_list_replacement_owed';
    }
    if (
      (await this.deviceListService.pendingReplacementVersion(senderId)) !==
      null
    ) {
      return 'sender_device_list_replacement_owed';
    }
    return null;
  }

  /**
   * The parties whose device list the sender must (re)learn before this send
   * can be delivered, recipient first (spec §5.2 freshness layer 1 + §12
   * amendments (vi)/(x)).
   *
   * Only an ENROLLED party is ever reported: an account with no authorization
   * row is single-device by construction (rows >= 2 are minted solely by the
   * provisioning commit), so it has no list to be stale against.
   *
   * For a NEW-MODEL send the test is the quoted stamp — and an ABSENT stamp
   * counts as a mismatch, so a client cannot skip the check by omitting the
   * field. For a LEGACY single-ciphertext send there is no stamp to quote at
   * all: being enrolled is itself the refusal, because that send would reach
   * device 1 alone and silently drop every other device (I5).
   */
  private async staleLists(
    send: EnvelopeCarrier,
    senderId: number,
    isNewModel: boolean,
  ): Promise<StaleListEntry[]> {
    const [recipientAuth, senderAuth] = await Promise.all([
      this.deviceListService.getAuthorization(send.recipientId),
      this.deviceListService.getAuthorization(senderId),
    ]);
    // Recipient first: it is the party whose freshness decides delivery.
    const parties: Array<[AccountAuthorization | null, number | undefined]> = [
      [recipientAuth, send.recipientListVersion],
      [senderAuth, send.senderListVersion],
    ];
    const stale: StaleListEntry[] = [];
    for (const [auth, quoted] of parties) {
      if (!auth) continue;
      if (isNewModel && quoted === auth.listVersion) continue;
      stale.push({
        userId: auth.userId,
        version: auth.listVersion,
        listCanonical: auth.listCanonical,
        listSignature: auth.listSignature,
        enrollment: {
          dakPub: auth.dakPub,
          enrollmentSig: auth.enrollmentSig,
          // Epoch ms, matching the landed `deviceList` echo — the enrollment
          // signature covers this timestamp, so it must survive transport
          // byte-exactly for the chain to verify.
          enrollmentCreatedAt: auth.enrollmentCreatedAt.getTime(),
        },
      });
    }
    return stale;
  }

  /**
   * The marker for a re-ack of an already-committed row (spec §12 (viii)/(ix)).
   *
   * A NEW-MODEL row keeps its ciphertext only in `message_envelopes`, and none
   * of those belong to the origin device, so the honest answer is `own_origin`
   * rather than a null ciphertext the client would try to decrypt. A legacy row
   * still has its column and re-acks exactly as before.
   */
  private ackEnvelopeStatus(message: Message): 'own_origin' | undefined {
    return message.content === '[encrypted]' && message.encryptedContent == null
      ? 'own_origin'
      : undefined;
  }

  async handleSendMessage(client: Socket, data: any, server: Server) {
    const senderId: number = client.data.user?.id;
    if (!senderId) return;

    // `data` stays `any` for the pre-existing reads below; the new Phase 1
    // fields go through the validated DTO so they are typed at the point of
    // use rather than adding more unchecked member access.
    let send: SendMessageDto;
    try {
      send = validateDto(SendMessageDto, data);
      data = send;
    } catch (error) {
      client.emit('error', { message: error.message });
      return;
    }

    const validation = await this.chatValidationService.validateCanMessage(
      senderId,
      data.recipientId,
    );
    if (!validation.valid) {
      client.emit('error', { message: validation.error });
      return;
    }

    const sender = await this.usersService.findById(senderId);
    const recipient = await this.usersService.findById(data.recipientId);
    if (!sender || !recipient) {
      client.emit('error', { message: 'User not found' });
      return;
    }

    const conversation = await this.conversationsService.findOrCreate(
      sender,
      recipient,
    );

    const ttlSeconds: number | null =
      data.expiresIn ?? conversation.disappearingTimer ?? null;
    const disappearAfterSeconds =
      ttlSeconds != null && ttlSeconds > 0 ? ttlSeconds : null;

    // A retry of a send whose ack was lost must find the row it already
    // committed. The sending device holds the ONLY plaintext copy until that
    // ack lands, so creating a second row here would duplicate the message and
    // leave the client unable to tell which one its record belongs to
    // (Phase 1, spec §5.4).
    //
    // The token is UNIQUE PER SENDER by spec, not per conversation, so a token
    // already spent on a DIFFERENT conversation is not a retry of this send:
    // re-acking it would report success for a message this conversation never
    // received, and writing it would violate the index. Say so instead.
    const committed = send.sendToken
      ? await this.messagesService.findBySendToken(senderId, send.sendToken)
      : null;
    if (committed) {
      if (committed.conversation?.id !== conversation.id) {
        client.emit('error', { message: 'duplicate_send_token' });
        return;
      }
      // Re-ack the committed row and stop: fanning it out again would deliver
      // the same ciphertext twice, and Signal decryption is not idempotent.
      client.emit(
        'messageSent',
        MessageMapper.toPayload(committed, {
          tempId: send.tempId,
          conversationId: conversation.id,
          includeSendToken: true,
          envelopeStatus: this.ackEnvelopeStatus(committed),
        }),
      );
      return;
    }

    // Fan-out shape and freshness (spec §5.2 + §12 amendment (v)/(vi)/(x)).
    // Every check below runs BEFORE any persistence, so a refused send writes
    // zero message rows and zero envelope rows (falsification 5).
    const originDeviceId = socketDeviceId(client) ?? DEFAULT_DEVICE_ID;
    const envelopes = this.resolveEnvelopes(send);
    const isNewModel = (send.envelopes?.length ?? 0) > 0;
    if (isNewModel) {
      const refusal = await this.envelopeRefusal(
        envelopes,
        senderId,
        send.recipientId,
        originDeviceId,
      );
      if (refusal) {
        client.emit('error', { message: refusal });
        return;
      }
    }

    // (lx) Shape-independent, and BEFORE the stale bounce below: that bounce
    // hands out the very orphaned record (l) refuses to serve on
    // `getDeviceList`, and a legacy send to a never-enrolled post-reset account
    // bounces nothing at all and commits straight to the revoked device 1.
    const owed = await this.replacementOwedRefusal(senderId, send.recipientId);
    if (owed) {
      this.logger.warn(`[send] REFUSED replacement owed reason=${owed}`);
      client.emit('error', { message: owed });
      return;
    }

    // A LEGACY single-ciphertext send reaches device 1 only. That is correct
    // while neither party is enrolled — a non-enrolled account is
    // single-device by construction — but the moment either side has a device
    // list, delivering to device 1 alone would silently DROP a device, which
    // invariant I5 forbids. So refuse it exactly like a stale send and hand
    // back both signed lists: the client adopts them and resends as a fan-out
    // (amendment (x)). This is what keeps the single-device fast path free of
    // a device-list round trip per send while never dropping a device.
    if (envelopes.length > 0) {
      const stale = await this.staleLists(send, senderId, isNewModel);
      if (stale.length > 0) {
        this.logger.warn(
          `[send] REFUSED ${isNewModel ? 'stale device list' : 'legacy send to an enrolled party'} staleVersions=${stale
            .map((entry) => `v${entry.version}`)
            .join(',')}`,
        );
        client.emit('deviceListStale', {
          success: false,
          error: 'device_list_stale',
          tempId: send.tempId,
          lists: stale,
        });
        return;
      }
    }

    let message: Message;
    try {
      message = await this.messagesService.create(
        data.encryptedContent || isNewModel ? '[encrypted]' : data.content,
        sender,
        conversation,
        {
          expiresAt: null,
          disappearAfterSeconds,
          messageType: data.messageType,
          mediaUrl: data.mediaUrl,
          mediaDuration: data.mediaDuration,
          replyToMessageId: data.replyToMessageId ?? null,
          // A NEW-MODEL row stores nothing in the legacy column: every device
          // reads its own envelope (§4). A legacy send keeps the column AND
          // gets a device-1 envelope, so its row stays readable to today's
          // clients through the whole §8 rollout window.
          encryptedContent: isNewModel ? null : (data.encryptedContent ?? null),
          originDeviceId: socketDeviceId(client) ?? null,
          sendToken: send.sendToken ?? null,
          envelopes: envelopes.length > 0 ? envelopes : undefined,
        },
      );
    } catch (error) {
      // Two retries can race past the read above; the partial unique index is
      // what actually decides. The loser re-acks the winner rather than
      // surfacing a write error for a message that WAS committed.
      const raced = send.sendToken
        ? await this.messagesService.findBySendToken(senderId, send.sendToken)
        : null;
      if (!raced) throw error;
      if (raced.conversation?.id !== conversation.id) {
        client.emit('error', { message: 'duplicate_send_token' });
        return;
      }
      client.emit(
        'messageSent',
        MessageMapper.toPayload(raced, {
          tempId: send.tempId,
          conversationId: conversation.id,
          includeSendToken: true,
          envelopeStatus: this.ackEnvelopeStatus(raced),
        }),
      );
      return;
    }

    // Base for the per-device fan-out below: carries NO `sendToken` (it is the
    // sender's private reconcile key) and NO `envelopeStatus` (a recipient's
    // copy has a real ciphertext and must be decrypted).
    const messagePayload = MessageMapper.toPayload(message, {
      tempId: data.tempId,
      conversationId: conversation.id,
    });

    // The sender's ack is a DIFFERENT payload: the origin device gets no
    // envelope by design, so it receives the lost-ack reconcile key instead of
    // a ciphertext (spec §12 amendment (ix)), consistent with what a history
    // read later serves that same device.
    client.emit(
      'messageSent',
      MessageMapper.toPayload(message, {
        tempId: data.tempId,
        conversationId: conversation.id,
        includeSendToken: true,
        envelopeStatus: isNewModel ? 'own_origin' : undefined,
      }),
    );

    // CIPHERTEXT — addressed PER DEVICE (spec §5.3), never room-broadcast.
    // Every device holds a DIFFERENT ciphertext, and Signal decryption is not
    // idempotent (it consumes the message key and advances the ratchet), so a
    // device must receive exactly its own envelope, once. Within one device the
    // newest socket wins, because tabs of one device share a session store.
    // See `utils/user-room.ts`.
    //
    // A send with NO ciphertext at all (PING and today's plaintext shapes)
    // produces no envelope, so it keeps its historical single-target delivery,
    // now named explicitly as the recipient's device 1 (§8: an account with no
    // enrollment is single-device by construction).
    const recipientId = send.recipientId;
    const deliveryTargets =
      envelopes.length > 0
        ? envelopes.map((envelope) => ({
            userId: envelope.userId,
            deviceId: envelope.deviceId,
            payload: {
              ...messagePayload,
              encryptedContent: envelope.ciphertext,
            },
          }))
        : [
            {
              userId: recipientId,
              deviceId: DEFAULT_DEVICE_ID,
              payload: messagePayload,
            },
          ];

    let deliveredToRecipient = false;
    for (const target of deliveryTargets) {
      const delivered = emitToDeviceNewestSocket(
        server,
        target.userId,
        target.deviceId,
        'newMessage',
        target.payload,
      );
      if (target.userId === recipientId && delivered) {
        deliveredToRecipient = true;
      }
    }
    this.logger.debug(
      deliveredToRecipient
        ? `[sendMessage] newMessage emitted to recipient`
        : `[sendMessage] Recipient NOT ONLINE - newMessage not emitted`,
    );

    // Coalesced push: minimized tabs stay connected via WS but still need a
    // wake-up. Suppression is PER DEVICE (spec §5.3): skip only when EVERY
    // device that was delivered to has this conversation focused, so a second
    // device that is not looking at the chat still gets its notification.
    const recipientDeviceIds = deliveryTargets
      .filter((target) => target.userId === recipientId)
      .map((target) => target.deviceId);
    const everyRecipientDeviceFocused =
      recipientDeviceIds.length > 0 &&
      recipientDeviceIds.every((deviceId) =>
        this.shouldSkipPushForFocusedRecipient(
          server,
          recipientId,
          deviceId,
          conversation.id,
        ),
      );
    if (!everyRecipientDeviceFocused) {
      this.pushCoalescingService
        .scheduleMessagePush(recipientId, conversation.id, sender.username)
        .catch(() => {});
    }

    // Async link preview — fire and forget, does not block send
    this.chatLinkPreviewService.fetchAndEmitIfNeeded({
      content: data.content,
      encryptedContent: data.encryptedContent ?? null,
      messageType: message.messageType,
      messageId: message.id,
      conversationId: conversation.id,
      client,
      recipientId: data.recipientId,
      server,
    });
  }

  async handleGetMessages(client: Socket, data: any) {
    const userId: number = client.data.user?.id;
    if (!userId) return;

    try {
      const dto = validateDto(GetMessagesDto, data);
      data = dto;
    } catch (error) {
      client.emit('error', { message: error.message });
      return;
    }

    // H-01: enforce conversation membership before serving history. Without this
    // any authenticated user could read any (sequential-id) conversation's
    // messages. Mirrors the membership check in handleMarkConversationRead.
    const conversation = await this.conversationsService.findById(
      data.conversationId,
    );
    if (
      !conversation ||
      (conversation.userOne.id !== userId && conversation.userTwo.id !== userId)
    ) {
      client.emit('messageHistory', {
        conversationId: data.conversationId,
        messages: [],
      });
      return;
    }

    try {
      const messages = await this.messagesService.findByConversation(
        data.conversationId,
        data.limit,
        data.offset,
        userId,
      );

      const now = new Date();
      const active = messages.filter((m) => !isMessageExpired(m, now));

      // Per-device history read (spec §5.3 + §12 amendment (viii)): serve THIS
      // device its own envelope, else the legacy column when this device owns
      // the row's session, else an explicit marker. Serving another device's
      // ciphertext would bind a foreign ratchet and fail terminally across the
      // whole pre-link history, which is what the gating exists to prevent.
      const deviceId = socketDeviceId(client) ?? DEFAULT_DEVICE_ID;
      const ciphertextByMessageId =
        await this.messagesService.findEnvelopeCiphertexts(
          active.map((m) => m.id),
          userId,
          deviceId,
        );

      const mapped = active.map((m) => {
        const options = { conversationId: data.conversationId as number };
        // A plaintext row (PING, pre-E2E content) has no ciphertext for anyone
        // and must never be marked.
        const isE2e = m.content === '[encrypted]' || m.encryptedContent != null;
        if (!isE2e) return MessageMapper.toPayload(m, options);

        const own = m.sender?.id === userId;
        // Backfilled and legacy-client rows carry originDeviceId NULL, which
        // means device 1 (durability rider F5a).
        const sessionOwnerDeviceId = own
          ? (m.originDeviceId ?? DEFAULT_DEVICE_ID)
          : DEFAULT_DEVICE_ID;
        const isSessionOwner = deviceId === sessionOwnerDeviceId;

        const envelope = ciphertextByMessageId.get(m.id);
        if (envelope) {
          return MessageMapper.toPayload(m, {
            ...options,
            deviceCiphertext: envelope,
            includeSendToken: own && isSessionOwner,
          });
        }
        if (isSessionOwner && m.encryptedContent != null) {
          return MessageMapper.toPayload(m, {
            ...options,
            deviceCiphertext: m.encryptedContent,
            includeSendToken: own && isSessionOwner,
          });
        }
        return MessageMapper.toPayload(m, {
          ...options,
          // The origin device of its own new-model row has no envelope BY
          // DESIGN — self-sync envelopes address the sender's OTHER devices —
          // and reads the plaintext from its local store.
          envelopeStatus:
            own && isSessionOwner ? 'own_origin' : 'none_for_device',
          includeSendToken: own && isSessionOwner,
        });
      });

      client.emit('messageHistory', {
        conversationId: data.conversationId,
        messages: mapped,
      });
    } catch (error) {
      this.logger.error(
        `Failed to get messages for conversation ${data.conversationId}: ${error.message}`,
        error.stack,
      );
      client.emit('messageHistory', {
        conversationId: data.conversationId,
        messages: [],
      });
    }
  }

  /**
   * Answer "which of these message ids do you still serve me?".
   *
   * The client destroys the local plaintext of every id it asked about that is
   * MISSING from the reply — that is how a message deleted or expired before
   * the device learned about it finally leaves the disk. Two consequences:
   *
   *  - An empty `messageIds` is a legitimate answer (a fully cleared history)
   *    and is read as "destroy all of them". It must therefore never be
   *    manufactured by a failure. Unlike `handleGetMessages`, which answers a
   *    database error with an empty history, this handler answers it with
   *    SILENCE: no reply leaves the client holding everything until next time.
   *  - `requestId` is echoed verbatim so a late or foreign reply cannot be
   *    applied to the wrong batch.
   */
  async handleGetServedMessageIds(client: Socket, data: unknown) {
    const userId = servedIdsCallerId(client);
    if (!userId) return;

    let dto: GetServedMessageIdsDto;
    try {
      dto = validateDto(GetServedMessageIdsDto, data);
    } catch (error) {
      client.emit('error', {
        message: error instanceof Error ? error.message : String(error),
      });
      return;
    }

    // I6 SILENCE (spec §5.5 + amendment (xxiii)). A revoked device must get
    // NO REPLY — not an error, not an empty list. An empty `messageIds` is a
    // legitimate "destroy all of them", so any answer-shaped refusal would
    // remotely wipe the local history §5.5 promises the user keeps. The
    // connect gate already refuses a revoked session; this covers the request
    // that was already in flight when the revocation committed.
    if (
      await this.devicesService.isRevoked(
        userId,
        socketDeviceId(client) ?? DEFAULT_DEVICE_ID,
      )
    ) {
      this.logger.warn(
        `[revoke] SILENCE on getServedMessageIds deviceId=${socketDeviceId(client) ?? DEFAULT_DEVICE_ID}`,
      );
      return;
    }

    try {
      const messageIds = await this.messagesService.findServedMessageIds(
        dto.messageIds,
        userId,
      );
      client.emit('servedMessageIds', {
        requestId: dto.requestId,
        messageIds,
      });
    } catch (error) {
      const err = error instanceof Error ? error : new Error(String(error));
      this.logger.error(
        `Failed to resolve served message ids: ${err.message}`,
        err.stack,
      );
      // No reply on purpose — see above.
    }
  }

  async handleMessageDelivered(client: Socket, data: any, server: Server) {
    const user = client.data.user;
    if (!user) return;
    const userId: number = user.id;

    let messageId: number;
    try {
      const dto = validateDto(MessageDeliveredDto, data);
      messageId = dto.messageId;
    } catch (error) {
      client.emit('error', { message: error.message });
      return;
    }

    // Verify caller is the recipient of this message
    const message =
      await this.messagesService.findByIdWithConversation(messageId);
    if (!message) return;

    const conv = message.conversation as any;
    const recipientId =
      conv.userOne?.id === message.sender.id
        ? conv.userTwo?.id
        : conv.userOne?.id;
    if (userId !== recipientId) return; // Silently ignore — not the intended recipient

    // Per-device bookkeeping (spec §5.3): stamp THIS device's envelope, so
    // "which of my devices actually received it" is answerable. Deliberately
    // separate from the row-level projection below, which stays a RECIPIENT-only
    // projection (§4) — and these stamps never feed expiry or the read TTL (I9).
    await this.messagesService.stampEnvelope(
      messageId,
      userId,
      socketDeviceId(client) ?? DEFAULT_DEVICE_ID,
      'deliveredAt',
    );

    const updated = await this.messagesService.updateDeliveryStatus(
      messageId,
      MessageDeliveryStatus.DELIVERED,
    );
    if (!updated) return;

    server.to(userRoom(updated.sender.id)).emit('messageDelivered', {
      messageId: updated.id,
      conversationId: updated.conversation?.id,
      deliveryStatus: updated.deliveryStatus,
    });
  }

  async handleMarkConversationRead(client: Socket, data: any, server: Server) {
    const user = client.data.user;
    if (!user) return;

    let conversationId: number;
    try {
      const dto = validateDto(MarkConversationReadDto, data);
      conversationId = dto.conversationId;
    } catch (error) {
      client.emit('error', { message: error.message });
      return;
    }

    const conversation =
      await this.conversationsService.findById(conversationId);
    if (!conversation) return;

    // Verify the caller is a member of this conversation
    const readerId = user.id;
    if (
      conversation.userOne.id !== readerId &&
      conversation.userTwo.id !== readerId
    ) {
      this.logger.warn(
        `handleMarkConversationRead: caller is not a member of conv ${conversationId}`,
      );
      return;
    }

    const otherUserId =
      conversation.userOne.id === readerId
        ? conversation.userTwo.id
        : conversation.userOne.id;

    const updated = await this.messagesService.markConversationAsReadFromSender(
      conversationId,
      otherUserId,
    );

    for (const message of updated) {
      const payload: Record<string, unknown> = {
        messageId: message.id,
        conversationId: Number(conversationId),
        deliveryStatus: MessageDeliveryStatus.READ,
      };
      if (message.expiresAt) {
        payload.expiresAt = new Date(message.expiresAt as Date).toISOString();
      }

      server.to(userRoom(message.sender.id)).emit('messageDelivered', payload);
      // Compared by USER id, not socket id. The old socket-id comparison was
      // incidentally correct because reader and sender are always different
      // users here (you mark the OTHER party's messages read); with rooms the
      // two are distinct rooms anyway, so this guard only documents that.
      if (readerId !== message.sender.id) {
        server.to(userRoom(readerId)).emit('messageDelivered', payload);
      }
    }
  }

  async handleClearChatHistory(client: Socket, data: any, server: Server) {
    const userId: number = client.data.user?.id;
    if (!userId) return;

    try {
      const dto = validateDto(ClearChatHistoryDto, data);
      data = dto;
    } catch (error) {
      client.emit('error', { message: error.message });
      return;
    }

    // Verify user belongs to this conversation
    const conversation = await this.conversationsService.findById(
      data.conversationId,
    );
    if (!conversation) {
      client.emit('error', { message: 'Conversation not found' });
      return;
    }

    const userBelongs =
      conversation.userOne.id === userId || conversation.userTwo.id === userId;
    if (!userBelongs) {
      client.emit('error', { message: 'Unauthorized' });
      return;
    }

    const mediaUrls = await this.messagesService.findMediaUrlsByConversation(
      data.conversationId,
    );
    await Promise.all(
      mediaUrls.map((url) => this.mediaCleanup.deleteMediaFile(url)),
    );
    await this.messagesService.deleteAllByConversation(data.conversationId);

    const otherUserId =
      conversation.userOne.id === userId
        ? conversation.userTwo.id
        : conversation.userOne.id;

    const payload = { conversationId: data.conversationId };

    // A clear is a MUTUAL, irreversible wipe: `deleteAllByConversation` drops
    // every row of the conversation for BOTH participants, so every device of
    // both users must purge its local plaintext. `client.emit` told only the
    // clearing socket, which left that user's OTHER devices displaying a
    // thread that no longer exists anywhere — and the client's history merge
    // deliberately never prunes rows the server stopped returning
    // (`_mergeHistorySnapshot`, messaging_provider.history.dart), so that
    // stale copy survived every future reconnect instead of healing.
    server
      .to(userRoom(userId))
      .to(userRoom(otherUserId))
      .emit('chatHistoryCleared', payload);

    this.logger.debug(
      `Cleared chat history for conversation ${data.conversationId}`,
    );
  }

  async handleDeleteMessage(client: Socket, data: any, server: Server) {
    const userId: number = client.data.user?.id;
    if (!userId) return;

    try {
      const dto = validateDto(DeleteMessageDto, data);
      data = dto;
    } catch (error) {
      client.emit('error', { message: error.message });
      return;
    }

    const { messageId, mode } = data;

    const message =
      await this.messagesService.findByIdWithConversation(messageId);
    if (!message) {
      client.emit('error', { message: 'Message not found' });
      return;
    }

    const conv = message.conversation;
    if (!conv) {
      client.emit('error', { message: 'Conversation not found' });
      return;
    }

    const userBelongs =
      conv.userOne.id === userId || conv.userTwo.id === userId;
    if (!userBelongs) {
      client.emit('error', { message: 'Unauthorized' });
      return;
    }

    const otherUserId =
      conv.userOne.id === userId ? conv.userTwo.id : conv.userOne.id;
    const conversationId = conv.id;

    if (mode === 'for_me') {
      const ok = await this.messagesService.hideMessageForUser(
        messageId,
        userId,
      );
      if (!ok) {
        client.emit('error', { message: 'Failed to hide message' });
        return;
      }
      // Per-USER state (`hiddenByUserIds`), so this fans out to the hiding
      // user's room ONLY — the peer must keep seeing the message. Every one of
      // this user's own devices has to hide it though: `client.emit` told just
      // the acting socket, and the row stays readable for the other side, so a
      // sibling device would go on showing a message this user deleted.
      server.to(userRoom(userId)).emit('messageDeleted', {
        messageId,
        conversationId,
        forEveryone: false,
      });
      this.logger.debug(`Hid message ${messageId} for self`);
      return;
    }

    if (mode === 'for_everyone') {
      // Authorization BEFORE the irreversible unlink. `deleteById` re-checks
      // the sender and is still the authority for the row, but the media
      // unlink used to run ahead of it while the only gate here was
      // conversation MEMBERSHIP (line ~968): a RECIPIENT emitting
      // `deleteMessage mode=for_everyone` destroyed the sender's file on
      // disk, was then refused the row delete, and left a surviving message
      // whose `mediaUrl` points at nothing — unrecoverable, and invisible
      // until someone opens the chat. Reproduced over the wire 2026-09-14
      // (msg 977: file gone, row intact). Media still goes BEFORE the row
      // (backend/CLAUDE.md §8 and the §12 checklist) — just never before
      // authorization.
      if (message.sender?.id !== userId) {
        client.emit('error', {
          message: 'Only the sender can delete for everyone',
        });
        return;
      }
      if (message.mediaUrl) {
        await this.mediaCleanup.deleteMediaFile(message.mediaUrl);
      }
      const deleted = await this.messagesService.deleteById(messageId, userId);
      if (!deleted) {
        client.emit('error', {
          message: 'Only the sender can delete for everyone',
        });
        return;
      }
      if (conv.pinnedMessageId === messageId) {
        await this.conversationsService.clearPinnedMessage(conversationId);
        const unpinPayload = { conversationId };
        server
          .to(userRoom(userId))
          .to(userRoom(otherUserId))
          .emit('messageUnpinned', unpinPayload);
      }
      // The row, its per-device envelopes (FK CASCADE) and its media are gone
      // for good, so EVERY device of BOTH users must drop its local copy. Both
      // emits used to skip the deleting user's other devices, which then kept
      // the decrypted plaintext on screen permanently — the history merge
      // never prunes rows missing from a server snapshot, so no later
      // reconnect could heal it. Deleting on a phone left the message
      // readable on that same account's other clients.
      server
        .to(userRoom(userId))
        .to(userRoom(otherUserId))
        .emit('messageDeleted', {
          messageId,
          conversationId,
          forEveryone: true,
        });
      this.logger.debug(`Deleted message ${messageId} for everyone`);
    }
  }

  async handleEditMessage(client: Socket, data: unknown, server: Server) {
    const userId: number | undefined = (
      client.data as { user?: { id?: number } }
    ).user?.id;
    if (!userId) return;

    // Read every field off the VALIDATED dto, never off the raw payload: an
    // envelope-bearing edit is trusted to fan ciphertext at other devices, so
    // the shape it is trusted for is the one class-validator just checked.
    let edit: EditMessageDto;
    try {
      edit = validateDto(EditMessageDto, data);
    } catch (error) {
      client.emit('error', { message: (error as Error).message });
      return;
    }

    const { messageId } = edit;

    const message =
      await this.messagesService.findByIdWithConversation(messageId);
    if (!message) {
      client.emit('editMessageFailed', { messageId, reason: 'not_found' });
      return;
    }

    const conv = message.conversation;
    if (!conv) {
      client.emit('editMessageFailed', { messageId, reason: 'not_found' });
      return;
    }

    // Membership first (mirror delete): only the two participants may touch the message.
    const userBelongs =
      conv.userOne.id === userId || conv.userTwo.id === userId;
    if (!userBelongs) {
      client.emit('editMessageFailed', { messageId, reason: 'not_sender' });
      return;
    }

    // Sender-only: only the author may edit their own message.
    if (message.sender?.id !== userId) {
      client.emit('editMessageFailed', { messageId, reason: 'not_sender' });
      return;
    }

    // 15-minute edit window.
    if (Date.now() - new Date(message.createdAt).getTime() > EDIT_WINDOW_MS) {
      client.emit('editMessageFailed', { messageId, reason: 'window_expired' });
      return;
    }

    // v1 is text-only: never let a crafted client swap a media row's ciphertext
    // (messageType is a server-visible column, so this is cheap defense-in-depth).
    if (message.messageType !== 'TEXT') {
      client.emit('editMessageFailed', { messageId, reason: 'not_text' });
      return;
    }

    const otherUserId =
      conv.userOne.id === userId ? conv.userTwo.id : conv.userOne.id;
    const conversationId = conv.id;

    // Fan-out shape and freshness, exactly as a send runs them (spec §5.7
    // "same staleness bounce as §5.2", pinned by §12 amendment (xxxi)). Every
    // check below runs BEFORE any write, so a refused edit leaves the row and
    // every envelope byte-identical.
    //
    // The EDITING device is the producer of these ciphertexts, so it is what
    // `self_envelope_for_origin_device` is keyed on and what the row's
    // `originDeviceId` becomes (amendment (xxx)) — the receiving side selects
    // its Signal session from that field, so an edit from a second device MUST
    // re-point it or every peer would decrypt against the wrong ratchet.
    const editingDeviceId = socketDeviceId(client) ?? DEFAULT_DEVICE_ID;
    const carrier: EnvelopeCarrier = {
      recipientId: otherUserId,
      envelopes: edit.envelopes,
      encryptedContent: edit.encryptedContent ?? null,
      senderListVersion: edit.senderListVersion,
      recipientListVersion: edit.recipientListVersion,
    };
    const envelopes = this.resolveEnvelopes(carrier);
    const isNewModel = (edit.envelopes?.length ?? 0) > 0;
    if (isNewModel) {
      const refusal = await this.envelopeRefusal(
        envelopes,
        userId,
        otherUserId,
        editingDeviceId,
      );
      if (refusal) {
        // The edit path answers shape faults on its OWN refusal event: they are
        // client-shape bugs carrying nothing to repair with, unlike the
        // staleness bounce below which hands back both signed lists.
        client.emit('editMessageFailed', { messageId, reason: refusal });
        return;
      }
    }

    // (lx) Same refusal as the send path, on the edit path's own event: the
    // bounce below ships the orphaned signed record too.
    const owed = await this.replacementOwedRefusal(userId, otherUserId);
    if (owed) {
      this.logger.warn(
        `[edit] REFUSED replacement owed messageId=${messageId} reason=${owed}`,
      );
      client.emit('editMessageFailed', { messageId, reason: owed });
      return;
    }

    if (envelopes.length > 0) {
      const stale = await this.staleLists(carrier, userId, isNewModel);
      if (stale.length > 0) {
        this.logger.warn(
          `[edit] REFUSED ${isNewModel ? 'stale device list' : 'legacy edit to an enrolled party'} messageId=${messageId} staleVersions=${stale
            .map((entry) => `v${entry.version}`)
            .join(',')}`,
        );
        client.emit('deviceListStale', {
          success: false,
          error: 'device_list_stale',
          messageId,
          lists: stale,
        });
        return;
      }
    }

    // Server stays blind: store the new ciphertext, keep content as the
    // placeholder. Expiry / deliveryStatus are intentionally left untouched.
    //
    // The legacy column is written ONLY for a legacy row (amendment (xxxii)):
    // a new-model row keeps it NULL, because `content === '[encrypted]' &&
    // encryptedContent == null` IS this file's new-model discriminator
    // (`ackEnvelopeStatus`), so writing it would silently reclassify the row as
    // legacy after a single edit.
    const rowIsNewModel = this.ackEnvelopeStatus(message) === 'own_origin';
    let updated: Message | null;
    try {
      updated = await this.messagesService.applyEdit(messageId, userId, {
        encryptedContent:
          isNewModel || rowIsNewModel
            ? undefined
            : (edit.encryptedContent ?? null),
        content: '[encrypted]',
        originDeviceId: editingDeviceId,
        envelopes: envelopes.length > 0 ? envelopes : undefined,
      });
    } catch (error) {
      // A delete racing this edit CASCADE-removes the row between the read and
      // the envelope write, so the write fails on the FK. The transaction keeps
      // the data consistent, but the CALLER must still be told: its edit was
      // applied optimistically, and an unanswered request leaves that device
      // showing text no one else has.
      // A raced CASCADE delete is an ordinary race and belongs at warn; ANY
      // other throw is an unexpected server fault and must not hide inside the
      // same line, or a systemic DB problem under load looks like users editing
      // deleted messages. 23503 is Postgres' foreign_key_violation.
      const racedDelete = (error as { code?: string }).code === '23503';
      const detail = `[edit] write failed messageId=${messageId}: ${
        (error as Error).message
      }`;
      if (racedDelete) {
        this.logger.warn(`${detail} (raced delete)`);
      } else {
        this.logger.error(detail);
      }
      client.emit('editMessageFailed', { messageId, reason: 'not_found' });
      return;
    }
    if (!updated || !updated.editedAt) {
      client.emit('editMessageFailed', { messageId, reason: 'not_found' });
      return;
    }

    const basePayload = {
      messageId,
      conversationId,
      content: '[encrypted]',
      editedAt: updated.editedAt.toISOString(),
      // The producer of every ciphertext of this row, now the editing device.
      originDeviceId: editingDeviceId,
    };

    // The editing device holds the plaintext already and gets NO envelope, so
    // its echo carries no ciphertext to decrypt — it reconciles `editedAt`.
    client.emit('messageEdited', { ...basePayload, encryptedContent: null });

    // CIPHERTEXT — per device (spec §5.3/§5.7): an edit carries a fresh Signal
    // payload over the existing session, so a second socket decrypting it would
    // consume a key the first already used. Each device therefore receives
    // exactly ITS OWN envelope, at its newest socket.
    if (envelopes.length > 0) {
      for (const envelope of envelopes) {
        emitToDeviceNewestSocket(
          server,
          envelope.userId,
          envelope.deviceId,
          'messageEdited',
          { ...basePayload, encryptedContent: envelope.ciphertext },
        );
      }
    } else {
      // No ciphertext at all (a plaintext-shaped edit): historical behaviour,
      // named explicitly as the peer's device 1.
      emitToDeviceNewestSocket(
        server,
        otherUserId,
        DEFAULT_DEVICE_ID,
        'messageEdited',
        { ...basePayload, encryptedContent: null },
      );
    }
    this.logger.debug(
      `Edited message ${messageId} deviceId=${editingDeviceId} envelopes=${envelopes.length}`,
    );
  }

  /**
   * When the socket that WILL RECEIVE the message reports foreground + this
   * conversation active, WS already delivers `newMessage` — no push needed.
   *
   * Evaluated PER DEVICE (spec §5.3) against the SAME socket
   * `emitToDeviceNewestSocket` delivers to, never "any focused tab". Polling
   * every tab would let a focused tab A suppress the push while the ciphertext
   * went to background tab B, leaving the user with neither the live message
   * nor a notification. Push is suppressed only when EVERY device that got an
   * envelope is focused on this conversation — a second device that is not
   * looking at the chat still deserves its notification.
   */
  private shouldSkipPushForFocusedRecipient(
    server: Server,
    recipientId: number,
    deviceId: number,
    conversationId: number,
  ): boolean {
    const state = newestSocketForDevice(server, recipientId, deviceId)?.data
      ?.pushClientState as
      | { activeConversationId?: number | null; clientVisible?: boolean }
      | undefined;
    if (!state?.clientVisible) return false;
    return state.activeConversationId === conversationId;
  }
}
