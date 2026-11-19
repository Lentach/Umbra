import {
  Check,
  Column,
  CreateDateColumn,
  Entity,
  JoinColumn,
  ManyToOne,
  PrimaryGeneratedColumn,
} from 'typeorm';
import { User } from '../users/user.entity';

export type RecoveryVerifierKind = 'phrase_v1' | 'auth_v2';

/**
 * Optional recovery key for the identity reset ceremony (Phase 0b,
 * multi-device spec §6.2.1). One per account.
 *
 * The stored value is an Argon2id verifier hash and nothing else — never the
 * phrase, never a fast hash. Since plan B7 it is a verifier of the
 * client-derived `authSecret` (`verifierKind` `auth_v2`); rows enrolled by
 * clients up to 0.2.89 are verifiers of the plaintext phrase (`phrase_v1`). Presenting a valid phrase SHORTENS the reset
 * delay from 72 h to 1 h; it never silences the notifications and never grants
 * an immediate identity replacement. Single-use: spent on a successful
 * presentation and invalidated by any completed reset.
 *
 * Prod truth is migration 0014; the backup columns are migration 0017;
 * `verifierKind` is migration 0030.
 */
@Check(
  'CHK_recovery_keys_verifierKind',
  `"verifierKind" IN ('phrase_v1','auth_v2')`,
)
@Entity('recovery_keys')
export class RecoveryKey {
  @PrimaryGeneratedColumn()
  id: number;

  @Column({ unique: true })
  userId: number;

  @ManyToOne(() => User, { onDelete: 'CASCADE' })
  @JoinColumn({ name: 'userId' })
  user: User;

  /** Argon2id PHC string. Parameters are self-encoded for verification. */
  @Column('text')
  verifierHash: string;

  /**
   * What `verifierHash` was computed over (migration 0030): `phrase_v1` is the
   * plaintext phrase (legacy), `auth_v2` the client-derived authSecret. A row
   * verifies only the credential of its own kind.
   */
  @Column({ type: 'varchar', length: 16, default: 'phrase_v1' })
  verifierKind: RecoveryVerifierKind;

  @CreateDateColumn()
  createdAt: Date;

  @Column({ type: 'timestamp', nullable: true })
  usedAt: Date | null;

  @Column({ default: 0 })
  failedAttempts: number;

  @Column({ type: 'timestamp', nullable: true })
  lockedUntil: Date | null;

  /**
   * Identity key backup (amendment (lxxviii)): AES-256-GCM blob sealed under
   * a key derived from the phrase — base64(iv12 || ct). Version 2 blobs are
   * sealed under an HKDF output the server never receives; version 1 blobs
   * (PBKDF2 over the phrase) are only server-blind once the phrase stops
   * crossing the wire. Null until the client uploads one.
   */
  @Column({ type: 'text', nullable: true })
  backupBlob: string | null;

  /** base64 salt the blob's key was derived with (v2: the HKDF salt). */
  @Column({ type: 'text', nullable: true })
  backupSalt: string | null;

  /** PBKDF2 iteration count (v1, bounded by the DTO); 0 for v2 (no stretching). */
  @Column({ type: 'int', nullable: true })
  backupIterations: number | null;

  /** Blob format version: 1 (PBKDF2 over the phrase) or 2 (HKDF seal key). */
  @Column({ type: 'int', nullable: true })
  backupVersion: number | null;

  @Column({ type: 'timestamp', nullable: true })
  backupUpdatedAt: Date | null;
}
