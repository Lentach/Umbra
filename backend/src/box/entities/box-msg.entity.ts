import {
  Column,
  Entity,
  Index,
  JoinColumn,
  ManyToOne,
  PrimaryColumn,
} from 'typeorm';
import { BoxQueue } from './box-queue.entity';

/**
 * One undelivered blob. `ack` deletes it (I3); otherwise it expires 30 days
 * after `createdAt`. There is no sender column and none may be added (I2):
 * `send` is unsigned and carries no sender key.
 */
@Entity('box_msgs')
@Index('idx_box_msgs_rid_created', ['rid', 'createdAt', 'id'])
@Index('idx_box_msgs_expires', ['expiresAt'])
export class BoxMsg {
  @PrimaryColumn({ type: 'bytea', primaryKeyConstraintName: 'pk_box_msgs' })
  id: Buffer;

  @Column({ type: 'bytea' })
  rid: Buffer;

  @ManyToOne(() => BoxQueue, { onDelete: 'CASCADE' })
  @JoinColumn({ name: 'rid', foreignKeyConstraintName: 'fk_box_msgs_rid' })
  queue?: BoxQueue;

  /** Exactly 16384 bytes (I5). */
  @Column({ type: 'bytea' })
  blob: Buffer;

  @Column({ type: 'timestamptz' })
  createdAt: Date;

  @Column({ type: 'timestamptz' })
  expiresAt: Date;
}
