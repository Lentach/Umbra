import { Injectable, Logger } from '@nestjs/common';
import { Socket } from 'socket.io';
import { BlockedService } from '../../blocked/blocked.service';
import { ConversationsService } from '../../conversations/conversations.service';
import { DEFAULT_DEVICE_ID } from '../../key-bundles/key-bundles.service';
import { ReactionKeysService } from '../../reaction-keys/reaction-keys.service';
import {
  FetchReactionKeyDto,
  UploadReactionKeyDto,
} from '../dto/reaction-key.dto';
import { SendEnvelopeDto } from '../dto/chat.dto';
import { validateDto } from '../utils/dto.validator';

/**
 * socket.io declares `Socket.data` as `any`, so the session principal is
 * narrowed at runtime here, once per service, exactly like the rest of the
 * device surface. A missing `deviceId` means device 1 (§8): a token issued
 * before the claim existed belongs to the account's original device.
 */
function socketPrincipal(
  client: Socket,
): { userId: number; deviceId: number } | undefined {
  const data: unknown = client.data;
  if (data === null || typeof data !== 'object' || !('user' in data)) {
    return undefined;
  }
  const user = data.user;
  if (
    user === null ||
    typeof user !== 'object' ||
    !('id' in user) ||
    typeof user.id !== 'number'
  ) {
    return undefined;
  }
  const deviceId =
    'deviceId' in user && typeof user.deviceId === 'number'
      ? user.deviceId
      : DEFAULT_DEVICE_ID;
  return { userId: user.id, deviceId };
}

/** Every refusal code these two handlers can answer with. */
type ReactionKeyRefusal =
  | 'invalid_payload'
  | 'unauthorized'
  | 'duplicate_envelope_device'
  | 'foreign_recipient'
  | 'stale_epoch';

/**
 * Distribution of the per-conversation reaction key
 * (`docs/design/reaction-privacy.md` §3.1).
 *
 * Both handlers answer on their own response event with `success: false` plus a
 * stable code, never a bare `error` — a refusal a client cannot classify is
 * indistinguishable from "this conversation has no key", which would leave a
 * device rendering placeholder chips forever.
 *
 * Participation and block gates match `ChatReactionService`: a reaction key is
 * reaction state, so exactly the same people may touch it. Both refuse with
 * the SAME `unauthorized` code, deliberately — a distinct block code would
 * leak the moderation decision to the blocked side, which the reaction path
 * has never done.
 */
@Injectable()
export class ChatReactionKeyService {
  private readonly logger = new Logger(ChatReactionKeyService.name);

  constructor(
    private readonly conversationsService: ConversationsService,
    private readonly blockedService: BlockedService,
    private readonly reactionKeysService: ReactionKeysService,
  ) {}

  async handleUploadReactionKey(client: Socket, data: unknown): Promise<void> {
    const principal = socketPrincipal(client);
    if (!principal) return;

    let dto: UploadReactionKeyDto;
    try {
      dto = validateDto(UploadReactionKeyDto, data);
    } catch {
      // Includes the envelope-count bound: an over-bound upload is refused by
      // `ArrayMaxSize` before any participant lookup, so it writes nothing.
      // The conversation id is echoed from the RAW payload when it is usable,
      // so the client can retire exactly that pending upload instead of
      // waiting out its timeout.
      const claimed: unknown =
        data !== null && typeof data === 'object' && 'conversationId' in data
          ? data.conversationId
          : null;
      client.emit('reactionKeyUploaded', {
        conversationId: typeof claimed === 'number' ? claimed : null,
        success: false,
        error: 'invalid_payload' satisfies ReactionKeyRefusal,
      });
      return;
    }

    const participants = await this.participants(
      dto.conversationId,
      principal.userId,
    );
    if (!participants) {
      this.refuseUpload(principal.userId, dto.conversationId, 'unauthorized');
      client.emit('reactionKeyUploaded', {
        conversationId: dto.conversationId,
        success: false,
        error: 'unauthorized' satisfies ReactionKeyRefusal,
      });
      return;
    }

    const refusal = this.envelopeRefusal(dto.envelopes, participants);
    if (refusal) {
      this.refuseUpload(principal.userId, dto.conversationId, refusal);
      client.emit('reactionKeyUploaded', {
        conversationId: dto.conversationId,
        success: false,
        error: refusal,
      });
      return;
    }

    const result = await this.reactionKeysService.upload(
      dto.conversationId,
      dto.epoch,
      principal,
      dto.envelopes.map((envelope) => ({
        userId: envelope.userId,
        deviceId: envelope.deviceId,
        ciphertext: envelope.ciphertext,
      })),
    );
    if (!result.accepted) {
      // The server ASSIGNS epoch truth: the caller is told what it actually
      // holds so the loser of a race re-wraps at `epoch + 1` instead of
      // publishing tokens the peer can never decode.
      this.refuseUpload(principal.userId, dto.conversationId, 'stale_epoch');
      client.emit('reactionKeyUploaded', {
        conversationId: dto.conversationId,
        success: false,
        error: 'stale_epoch' satisfies ReactionKeyRefusal,
        epoch: result.epoch,
      });
      return;
    }

    // The conversation id is REQUIRED in the answer, not decoration: the
    // client allows one upload in flight at a time and releases that slot on
    // timeout, so an answer that cannot be attributed could complete a later
    // upload for a different conversation — persisting a key the server never
    // accepted for it.
    client.emit('reactionKeyUploaded', {
      conversationId: dto.conversationId,
      success: true,
      epoch: result.epoch,
    });
  }

  async handleFetchReactionKey(client: Socket, data: unknown): Promise<void> {
    const principal = socketPrincipal(client);
    if (!principal) return;

    let dto: FetchReactionKeyDto;
    try {
      dto = validateDto(FetchReactionKeyDto, data);
    } catch {
      // Correlate the refusal to a conversation when the raw payload at least
      // carries a usable id, so the client can clear exactly that row's state.
      const claimed: unknown =
        data !== null && typeof data === 'object' && 'conversationId' in data
          ? data.conversationId
          : null;
      client.emit('reactionKeyResponse', {
        conversationId: typeof claimed === 'number' ? claimed : null,
        success: false,
        error: 'invalid_payload' satisfies ReactionKeyRefusal,
      });
      return;
    }

    const participants = await this.participants(
      dto.conversationId,
      principal.userId,
    );
    if (!participants) {
      client.emit('reactionKeyResponse', {
        conversationId: dto.conversationId,
        success: false,
        error: 'unauthorized' satisfies ReactionKeyRefusal,
      });
      return;
    }

    const row = await this.reactionKeysService.fetchOwn(
      dto.conversationId,
      principal.userId,
      principal.deviceId,
    );
    client.emit('reactionKeyResponse', {
      conversationId: dto.conversationId,
      epoch: row?.epoch ?? 0,
      senderUserId: row?.senderUserId ?? null,
      senderDeviceId: row?.senderDeviceId ?? null,
      ciphertext: row?.ciphertext ?? null,
    });
  }

  /**
   * The conversation's two participant ids, or null when the caller may not
   * touch this conversation's key at all — not a member, or a block in either
   * direction (a block outlives the conversation, so it is re-checked here
   * exactly as the reaction handlers do).
   */
  private async participants(
    conversationId: number,
    userId: number,
  ): Promise<[number, number] | null> {
    const conv = await this.conversationsService.findById(conversationId);
    const one = conv?.userOne?.id;
    const two = conv?.userTwo?.id;
    if (one == null || two == null) return null;
    if (one !== userId && two !== userId) return null;

    const otherId = one === userId ? two : one;
    if (await this.blockedService.isBlockedByEither(userId, otherId)) {
      return null;
    }
    return [one, two];
  }

  /**
   * The refusal code for an unacceptable envelope set, or null. Every check
   * runs BEFORE the write, so a refused upload stores nothing.
   */
  private envelopeRefusal(
    envelopes: SendEnvelopeDto[],
    participants: [number, number],
  ): ReactionKeyRefusal | null {
    const seen = new Set<string>();
    for (const envelope of envelopes) {
      const key = `${envelope.userId}:${envelope.deviceId}`;
      // One row per device: the primary key would otherwise make an upload's
      // own duplicates fight each other for the same slot, and only one of
      // two ciphertexts would survive at random.
      if (seen.has(key)) return 'duplicate_envelope_device';
      seen.add(key);

      // Only the two participants' devices may be addressed. A third party's
      // userId would have the server hold key material for someone the
      // conversation never included.
      if (!participants.includes(envelope.userId)) return 'foreign_recipient';
    }
    return null;
  }

  private refuseUpload(
    userId: number,
    conversationId: number,
    reason: ReactionKeyRefusal,
  ): void {
    this.logger.warn(
      `[reaction-key] REFUSED upload conversationId=${conversationId} reason=${reason}`,
    );
  }
}
