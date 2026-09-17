import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsInt,
  IsPositive,
  ValidateNested,
} from 'class-validator';
import { MAX_ENVELOPES_PER_MESSAGE, SendEnvelopeDto } from './chat.dto';

/**
 * Publish the conversation's reaction key, wrapped once per participant device
 * (`docs/design/reaction-privacy.md` §3.1).
 *
 * `envelopes` reuses `SendEnvelopeDto` and `MAX_ENVELOPES_PER_MESSAGE`: a
 * reaction-key fan-out addresses exactly the devices a SEND addresses (both
 * participants' live devices), so the shape and the bound are the same, and
 * the bound is what stops a crafted client allocating unbounded rows.
 *
 * `epoch` is the epoch the client BELIEVES it is publishing; the server
 * adjudicates it against `conversations.reactionKeyEpoch` and refuses
 * `stale_epoch`. There is deliberately no uploader field — the producing
 * device is taken from the authenticated socket, because the receiver needs
 * the Signal session with that device to decrypt.
 */
export class UploadReactionKeyDto {
  @IsInt()
  @IsPositive()
  conversationId: number;

  @IsInt()
  @IsPositive()
  epoch: number;

  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(MAX_ENVELOPES_PER_MESSAGE)
  @ValidateNested({ each: true })
  @Type(() => SendEnvelopeDto)
  envelopes: SendEnvelopeDto[];
}

/**
 * Ask for THIS device's wrapped copy. No device field: the row served is the
 * caller's own `(userId, deviceId)` from the session, so one device can never
 * ask for another's ciphertext.
 */
export class FetchReactionKeyDto {
  @IsInt()
  @IsPositive()
  conversationId: number;
}
