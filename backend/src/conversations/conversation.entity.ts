import {
  Entity,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  ManyToOne,
  JoinColumn,
  Column,
  Index,
} from 'typeorm';
import { User } from '../users/user.entity';

// A conversation links two users.
// In this MVP there are no groups — 1-on-1 chat only.
// Dev-side guard for the one-row-per-pair invariant (BE-250). TypeORM decorators
// cannot express a functional index, so this composite unique only catches exact
// (user_one_id, user_two_id) duplicates in dev auto-DDL. Production truth — and
// the unordered (A,B)==(B,A) enforcement — is the LEAST/GREATEST functional
// unique index in migration 0011_unique_conversation_user_pair.sql, which also
// runs in dev via the migration runner.
@Index('UQ_conversations_user_pair_columns', ['userOne', 'userTwo'], {
  unique: true,
})
@Entity('conversations')
export class Conversation {
  @PrimaryGeneratedColumn()
  id: number;

  @ManyToOne(() => User, { eager: true })
  @JoinColumn({ name: 'user_one_id' })
  userOne: User;

  @ManyToOne(() => User, { eager: true })
  @JoinColumn({ name: 'user_two_id' })
  userTwo: User;

  @CreateDateColumn()
  createdAt: Date;

  @Column({ type: 'int', nullable: true, default: null })
  disappearingTimer: number | null; // Timer in seconds, null = off until user enables

  @Column({ type: 'int', nullable: true, default: null })
  pinnedMessageId: number | null;

  @Column({ type: 'timestamp', nullable: true, default: null })
  pinnedAt: Date | null;

  @Column({ type: 'int', nullable: true, default: null })
  pinnedByUserId: number | null;

  /**
   * Server-assigned epoch of this conversation's reaction key
   * (`docs/design/reaction-privacy.md` §3.1); 0 = none was ever uploaded.
   *
   * The server owns this number, not the client: two clients racing to create
   * the first key would otherwise both publish epoch 1 and one side's tokens
   * would be permanently undecodable. Prod truth is migration 0018.
   */
  @Column({ type: 'int', nullable: false, default: 0 })
  reactionKeyEpoch: number;
}
