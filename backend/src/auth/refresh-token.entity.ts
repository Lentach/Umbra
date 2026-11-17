import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  CreateDateColumn,
  ManyToOne,
  JoinColumn,
  Index,
} from 'typeorm';
import { User } from '../users/user.entity';

/**
 * One row is one SESSION (a token family, plan B4): its [id] is the family id
 * every token it issues carries as `<id>.<secret>`, and the row follows the
 * family's current token as it rotates (`RefreshTokensService.redeem`).
 */
@Entity('refresh_tokens')
@Index(['tokenHash'], { unique: true })
@Index('idx_refresh_tokens_prev_token_hash', ['prevTokenHash'])
export class RefreshToken {
  @PrimaryGeneratedColumn('uuid')
  id: string;

  @Column({ name: 'user_id' })
  userId: number;

  @ManyToOne(() => User, { onDelete: 'CASCADE' })
  @JoinColumn({ name: 'user_id' })
  user: User;

  /** SHA-256 hex of the session's CURRENT opaque refresh token. */
  @Column({ name: 'token_hash', type: 'varchar', length: 64 })
  tokenHash: string;

  /**
   * SHA-256 hex of the token the current one replaced; NULL until the first
   * rotation. A rotating client that presents it again lost the response
   * that carried the current token (it was never used, or this would have
   * moved on), so it gets that same token back. Older tokens are not kept:
   * the family id they carry is enough to end the session on their reuse.
   */
  @Column({
    name: 'prev_token_hash',
    type: 'varchar',
    length: 64,
    nullable: true,
  })
  prevTokenHash: string | null;

  @Column({ name: 'expires_at', type: 'timestamptz' })
  expiresAt: Date;

  /**
   * Which device this session belongs to (Phase 1, spec §4). NULL for sessions
   * issued before the column existed — device 1 by definition (§8), but left
   * honest rather than backfilled with a guess. Per-device revoke deletes this
   * device's rows and kicks its sockets.
   */
  @Column({ name: 'device_id', type: 'int', nullable: true })
  deviceId: number | null;

  @Column({ name: 'device_name', type: 'text', nullable: true })
  deviceName: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'timestamptz' })
  createdAt: Date;
}
