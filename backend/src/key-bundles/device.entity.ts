import {
  Column,
  CreateDateColumn,
  Entity,
  JoinColumn,
  ManyToOne,
  PrimaryColumn,
} from 'typeorm';
import { User } from '../users/user.entity';

/**
 * One device of one account (Phase 1, multi-device spec §4).
 *
 * `deviceId` is a small per-account integer from 1, NOT a global id: it is the
 * same number Signal addresses carry (`SignalProtocolAddress(name, deviceId)`),
 * so key material, sessions and envelopes can be namespaced by it.
 *
 * Existing accounts are device 1 and stay single-device until provisioning
 * ships (Phase 2) — nothing here grants a second device, it only makes one
 * representable. Rows of a revoked device are KEPT (`revokedAt` set) so a
 * returning session can be told it was revoked instead of quietly
 * re-authorizing.
 *
 * Prod truth is migration 0015.
 */
@Entity('devices')
export class Device {
  @PrimaryColumn()
  userId: number;

  @PrimaryColumn()
  deviceId: number;

  @ManyToOne(() => User, { onDelete: 'CASCADE' })
  @JoinColumn({ name: 'userId' })
  user: User;

  /** User-chosen, server-readable label. Never used for authorization. */
  @Column({ type: 'text', nullable: true })
  name: string | null;

  @Column({ type: 'text', nullable: true })
  platform: string | null;

  /**
   * Only a Keystore-capable device may be primary (invariant I2). Until Phase 2
   * every account has exactly one device and it is the primary.
   */
  @Column({ default: false })
  isPrimary: boolean;

  @CreateDateColumn()
  addedAt: Date;

  @Column({ type: 'timestamp', nullable: true })
  revokedAt: Date | null;
}
