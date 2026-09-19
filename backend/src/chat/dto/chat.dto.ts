import { Transform, Type, type TransformFnParams } from 'class-transformer';
import {
  IsNumber,
  IsInt,
  IsString,
  IsPositive,
  MinLength,
  MaxLength,
  IsOptional,
  Min,
  Max,
  Matches,
  ValidateIf,
  ValidateNested,
  IsIn,
  IsArray,
  ArrayMinSize,
  ArrayMaxSize,
} from 'class-validator';
import {
  DISAPPEARING_MAX_SECONDS,
  DISAPPEARING_MIN_SECONDS,
} from '../../messages/disappearing.constants';
import { MessageType } from '../../messages/message.entity';
import { MAX_DEVICE_ID } from '../../key-bundles/key-bundles.service';

/** Cloudinary (https only) or self-hosted media under MEDIA_BASE_URL — prevents SSRF */
const _mediaOriginEscaped = (
  process.env.MEDIA_BASE_URL ?? 'http://localhost:3000'
).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
// The self-hosted branch is anchored to a single `avatars|msgs/<filename>.<ext>`
// segment (no `/`, so no `..` traversal) — `mediaUrl` is later turned into a
// filesystem path and unlinked (H-02). The `$` anchor applies to both branches.
export const MEDIA_URL_REGEX = new RegExp(
  `^(https://res\\.cloudinary\\.com/[a-zA-Z0-9_-]+/(video|image|raw)/upload/.+|${_mediaOriginEscaped}/media/(avatars|msgs)/[A-Za-z0-9_-]+\\.[A-Za-z0-9]+)$`,
);

/**
 * The most per-device ciphertexts one message may carry.
 *
 * A fan-out addresses the recipient's live devices plus the sender's OTHER
 * live devices, and each account's device ids are bounded by
 * `MAX_DEVICE_ID` — so two accounts can never legitimately need more than
 * twice that. The bound exists so a crafted client cannot make one send
 * allocate unbounded envelope rows.
 */
export const MAX_ENVELOPES_PER_MESSAGE = 2 * MAX_DEVICE_ID;

/**
 * One recipient device's ciphertext in a fan-out send (spec §5.2 + §12
 * amendment (v)).
 *
 * Exactly one envelope per (userId, deviceId): Signal decryption consumes the
 * message key, so two envelopes for one device would brick that device's
 * ratchet. `userId` is the recipient for inbound copies and the SENDER for
 * self-sync copies to the sender's OTHER devices (§5.4).
 */
export class SendEnvelopeDto {
  @IsInt()
  @IsPositive()
  userId: number;

  @IsInt()
  @IsPositive()
  @Max(MAX_DEVICE_ID)
  deviceId: number;

  @IsString()
  @MinLength(1)
  @MaxLength(65536)
  ciphertext: string; // Signal ciphertext ("{type}:{base64}") for this device
}

export class SendMessageDto {
  @IsNumber()
  @IsPositive()
  recipientId: number;

  @IsString()
  @ValidateIf(
    (o: SendMessageDto) =>
      !o.encryptedContent &&
      !o.envelopes?.length &&
      !['VOICE', 'PING', 'VIDEO'].includes(o.messageType ?? ''),
  )
  @MinLength(1, { message: 'Message cannot be empty' })
  @MaxLength(5000, { message: 'Message cannot exceed 5000 characters' })
  content: string;

  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(65536)
  encryptedContent?: string; // Base64-encoded Signal Protocol ciphertext

  @IsOptional()
  @IsNumber()
  @IsPositive()
  @Min(DISAPPEARING_MIN_SECONDS)
  @Max(DISAPPEARING_MAX_SECONDS)
  expiresIn?: number; // disappearing TTL frozen at send (read-based countdown)

  @IsOptional()
  @IsString()
  tempId?: string; // Client-generated ID for optimistic message matching

  /**
   * Client-generated token making a send idempotent across a lost ack
   * (Phase 1, spec §5.4). The sending device holds the ONLY plaintext copy
   * until the ack lands, so a retry must match the row the server already
   * committed instead of creating a second message. UNIQUE per sender.
   */
  @IsOptional()
  @IsString()
  @MinLength(8)
  @MaxLength(64)
  sendToken?: string;

  @IsOptional()
  @IsString()
  @IsIn(Object.values(MessageType))
  messageType?: string; // TEXT | PING | IMAGE | VOICE | GIF | FILE | VIDEO

  @IsOptional()
  @IsString()
  @ValidateIf((o) => o.mediaUrl != null && o.mediaUrl !== '')
  @Matches(MEDIA_URL_REGEX, {
    message: 'mediaUrl must be a valid Cloudinary or self-hosted media URL',
  })
  mediaUrl?: string; // Validated self-hosted or legacy Cloudinary media URL

  @IsOptional()
  @IsNumber()
  @IsPositive()
  mediaDuration?: number; // duration in seconds

  @IsOptional()
  @IsNumber()
  @IsPositive()
  replyToMessageId?: number; // ID of the message being replied to

  /**
   * Per-device ciphertexts (spec §5.2 + §12 amendment (v)). Presence makes
   * this a NEW-MODEL send: the row's `encryptedContent` stays NULL and every
   * ciphertext lives in `message_envelopes`. A legacy single-`encryptedContent`
   * send is normalized to a one-element device-1 envelope AT INGEST, so
   * exactly one downstream write path exists (§8 compat).
   */
  @IsOptional()
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(MAX_ENVELOPES_PER_MESSAGE)
  @ValidateNested({ each: true })
  @Type(() => SendEnvelopeDto)
  envelopes?: SendEnvelopeDto[];

  /**
   * The sender's and recipient's DAK-signed device-list versions at encrypt
   * time (spec §5.2 freshness layer 1). Checked only for a party that is
   * enrolled; a mismatch refuses the send ATOMICALLY with `deviceListStale`.
   */
  @IsOptional()
  @IsInt()
  @IsPositive()
  senderListVersion?: number;

  @IsOptional()
  @IsInt()
  @IsPositive()
  recipientListVersion?: number;
}

export class SendFriendRequestDto {
  @IsNumber()
  @IsPositive()
  recipientId: number;
}

export class SearchUsersDto {
  @IsString()
  @Matches(/^[a-zA-Z0-9_]{3,20}#[0-9]{4}$/, {
    message: 'Enter username#tag (e.g. username#1234)',
  })
  handle: string; // username#tag, e.g. ziomek1#1234
}

export class AcceptFriendRequestDto {
  @IsNumber()
  @IsPositive()
  requestId: number;
}

export class RejectFriendRequestDto {
  @IsNumber()
  @IsPositive()
  requestId: number;
}

export class EnsureInvitationChatDto {
  @IsInt()
  @IsPositive()
  peerUserId: number;

  @IsString()
  @Matches(/^[A-Za-z0-9_-]{1,64}$/)
  // `enableImplicitConversion` would coerce a numeric correlationId into a string
  // that then satisfies @Matches, so a non-string is rejected here rather than
  // silently accepted. class-transformer types both fields of `TransformFnParams`
  // as `any`; funnel them through `unknown` locals and narrow before reading, so
  // the callback still matches the library signature and stays off the repo's
  // no-unsafe-* lint ratchet.
  @Transform(
    (params: TransformFnParams): unknown => {
      const source: unknown = params.obj;
      const value: unknown = params.value;
      if (source === null || typeof source !== 'object') return undefined;
      if (!('correlationId' in source)) return undefined;
      return typeof source.correlationId === 'string' ? value : undefined;
    },
    { toClassOnly: true },
  )
  correlationId: string;
}

export class GetMessagesDto {
  @IsNumber()
  @IsPositive()
  conversationId: number;

  @IsOptional()
  @IsNumber()
  @IsPositive()
  limit?: number;

  @IsOptional()
  @IsNumber()
  @Min(0)
  offset?: number;
}

export class StartConversationDto {
  @IsNumber()
  @IsPositive()
  recipientId: number;
}

export class UnfriendDto {
  @IsNumber()
  @IsPositive()
  userId: number;
}

export class BlockUserDto {
  @IsNumber()
  @IsPositive()
  userId: number;
}

export * from './clear-chat-history.dto';
export * from './set-disappearing-timer.dto';
export * from './delete-conversation-only.dto';
export * from './delete-message.dto';
export * from './set-conversation-mute.dto';
export * from './served-message-ids.dto';

/**
 * A blinded reaction token: `base64url(HMAC-SHA256(K_react, "umbra.reaction.v1"
 * || emoji)[0..15])`, so exactly 22 base64url characters
 * (`docs/design/reaction-privacy.md` §3). The server can neither read nor
 * guess the emoji behind it — it holds no `K_react`.
 *
 * The ONLY accepted shape since 2026-09-19 (D10 closed). The compat window
 * that also took a plain emoji grapheme (design §3.3) ended once every live
 * install was ≥ 0.2.49: a plaintext emoji here was the one piece of message
 * content the server stored in the clear. A client below that floor gets its
 * reaction refused with the DTO's stable validation error, not written.
 */
const REACTION_TOKEN_REGEX = /^[A-Za-z0-9_-]{22}$/;

export class AddReactionDto {
  @IsNumber()
  @IsPositive()
  messageId: number;

  @IsString()
  @MaxLength(32)
  @Matches(REACTION_TOKEN_REGEX, { message: 'emoji must be a reaction token' })
  emoji: string;
}

export class RemoveReactionDto {
  @IsNumber()
  @IsPositive()
  messageId: number;

  @IsString()
  @MaxLength(32)
  @Matches(REACTION_TOKEN_REGEX, { message: 'emoji must be a reaction token' })
  emoji: string;
}
