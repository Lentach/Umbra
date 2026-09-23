import { Column, Entity, PrimaryColumn, Unique } from 'typeorm';
import type { QueueKind } from '../box-wire';

/**
 * One inbound queue (metadata-privacy PR1.1, design §4.1). Every id is random
 * bytes minted here; NOTHING in this row names an account, a device, a sender
 * or a peer (I2) — the box cannot tell whose queue this is.
 *
 * - `rid` addresses the queue to its recipient (subscribe/ack/delete, signed
 *   by `recipientAuthPub`); `sid` is the sender's bearer capability, handed
 *   out only inside E2E; `nid` names its push notifier. Three values, so that
 *   holding one never yields another.
 * - `touchedDay` is the UTC DAY of the last subscribe — day granularity on
 *   purpose, it only feeds the 90-day reaper (I3).
 * - `claimBy` is set at creation and cleared by the first subscribe: a queue
 *   still carrying it past its instant was never claimed and is deleted (I3,
 *   24 h). It is the only creation-time trace, and it is gone once claimed.
 *
 * Prod truth is migration 0022; dev `synchronize` runs after the runner, so
 * every name here matches that file exactly (the integration suite asserts
 * `synchronize` would change nothing).
 */
@Entity('box_queues')
@Unique('uq_box_queues_sid', ['sid'])
@Unique('uq_box_queues_nid', ['nid'])
@Unique('uq_box_queues_auth_pub', ['recipientAuthPub'])
export class BoxQueue {
  @PrimaryColumn({ type: 'bytea', primaryKeyConstraintName: 'pk_box_queues' })
  rid: Buffer;

  @Column({ type: 'bytea' })
  sid: Buffer;

  @Column({ type: 'bytea' })
  nid: Buffer;

  @Column({ type: 'bytea' })
  recipientAuthPub: Buffer;

  @Column({ type: 'varchar', length: 8 })
  kind: QueueKind;

  @Column({ type: 'date', nullable: true })
  touchedDay: string | null;

  @Column({ type: 'timestamptz', nullable: true })
  claimBy: Date | null;

  @Column({ type: 'int', default: 0 })
  msgCount: number;

  @Column({ type: 'int', default: 0 })
  mediaBytesToday: number;
}
