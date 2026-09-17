import {
  Column,
  CreateDateColumn,
  Entity,
  JoinColumn,
  ManyToOne,
  PrimaryColumn,
} from 'typeorm';
import { Conversation } from '../conversations/conversation.entity';

/**
 * One device's wrapped copy of a conversation's reaction key
 * (`docs/design/reaction-privacy.md` §3.1).
 *
 * The server stores reaction tokens, not emoji, and the key that maps one to
 * the other never reaches it in the clear: every row here is Signal ciphertext
 * sealed to exactly one `(userId, deviceId)` of one of the two participants.
 *
 * The table is a MAILBOX the reader owns: clients PULL their own row
 * (`fetchReactionKey`) instead of the server pushing, so a device that was
 * offline or did not exist at upload time needs no delivery state — it just
 * reads the row addressed to it once the peer's client re-uploads.
 *
 * `epoch` is SERVER-assigned truth (`conversations.reactionKeyEpoch`): two
 * clients racing to create the first key would otherwise both write epoch 1
 * and one side's tokens would be permanently undecodable (falsification R3).
 * Old epochs are RETAINED so chips written under a rotated-away key stay
 * readable.
 *
 * `senderUserId` / `senderDeviceId` are the UPLOADER, attributed from the
 * authenticated socket and never from the payload: decrypting the ciphertext
 * requires the Signal session with the producing device, so a client-claimed
 * sender would let a hostile client point a victim's device at the wrong
 * session.
 */
@Entity('reaction_keys')
export class ReactionKey {
  @PrimaryColumn()
  conversationId: number;

  /**
   * The load-bearing CASCADE: a deleted conversation must not leave wrapped
   * key material behind. Scalar `conversationId` stays the API.
   */
  @ManyToOne(() => Conversation, { onDelete: 'CASCADE' })
  @JoinColumn({ name: 'conversationId' })
  conversation: Conversation;

  /** Which participant this copy is sealed to. */
  @PrimaryColumn()
  userId: number;

  /** Which of that participant's devices — per-account device number from 1. */
  @PrimaryColumn()
  deviceId: number;

  @PrimaryColumn()
  epoch: number;

  @Column()
  senderUserId: number;

  @Column()
  senderDeviceId: number;

  /** Signal ciphertext ("{type}:{base64}") of the 32-byte reaction key. */
  @Column('text')
  ciphertext: string;

  @CreateDateColumn()
  createdAt: Date;
}
