import { Column, Entity, Index, PrimaryColumn } from 'typeorm';

/**
 * One uploaded media blob. There is NO rid column and none may be added: the
 * upload charged a queue's daily budget, but the stored file is linked to
 * nothing (design §4.1, "budget without link"). `id` is the 32-byte
 * capability the sender puts inside the E2E message; `path` is relative to
 * `MEDIA_DIR/box/`.
 */
@Entity('box_media')
@Index('idx_box_media_expires', ['expiresAt'])
export class BoxMedia {
  @PrimaryColumn({ type: 'bytea', primaryKeyConstraintName: 'pk_box_media' })
  id: Buffer;

  @Column({ type: 'text' })
  path: string;

  /** A ladder rung label (`4k` … `32m`, I5). */
  @Column({ type: 'varchar', length: 8 })
  sizeBucket: string;

  @Column({ type: 'timestamptz' })
  expiresAt: Date;
}
