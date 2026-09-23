import { Column, Entity, JoinColumn, ManyToOne, PrimaryColumn } from 'typeorm';
import type { NotifierPlatform } from '../box-wire';
import { BoxQueue } from './box-queue.entity';

/**
 * A VERIFIED push endpoint for one queue's `nid`. A row exists only after the
 * push-channel challenge came back signed by the queue's auth key (SMP NTF
 * pattern), so a stolen token cannot be pointed at someone's queue to bomb
 * it. Deleted with its queue.
 */
@Entity('box_notifiers')
export class BoxNotifier {
  @PrimaryColumn({
    type: 'bytea',
    primaryKeyConstraintName: 'pk_box_notifiers',
  })
  nid: Buffer;

  @ManyToOne(() => BoxQueue, { onDelete: 'CASCADE' })
  @JoinColumn({
    name: 'nid',
    referencedColumnName: 'nid',
    foreignKeyConstraintName: 'fk_box_notifiers_nid',
  })
  queue?: BoxQueue;

  /** An FCM registration token, or a Web Push subscription as JSON. */
  @Column({ type: 'text' })
  token: string;

  @Column({ type: 'varchar', length: 8 })
  platform: NotifierPlatform;

  @Column({ type: 'timestamptz' })
  verifiedAt: Date;
}
