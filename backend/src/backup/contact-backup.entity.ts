import {
  Column,
  Entity,
  JoinColumn,
  ManyToOne,
  PrimaryGeneratedColumn,
} from 'typeorm';
import { User } from '../users/user.entity';

/**
 * The account's sealed contact backup (metadata-privacy PR2.4). One per
 * account: a browser-storage wipe on a PWA would otherwise take the whole
 * contact graph with it, and the server is not allowed to hold that graph.
 *
 * WHAT THE SERVER SEES: that this account has a backup, the BUCKETED size of
 * the opaque strings, the `rev` it is at and `updatedAt`. `blob` is the
 * sealed contact list and `wraps[].ct` are the wrapped copies of the content
 * key — every one of them is ciphertext the server has no key for, and the
 * server never parses either. `salt` and `ckId` are public labels the client
 * needs back verbatim to derive its key and recognise the content key.
 *
 * WHAT THE SERVER CANNOT SEE: any contact, any name, any handle, any exact
 * count.
 *
 * The size is bucketed, not hidden. AES-GCM is length-preserving, so a raw
 * `length(blob)` would divide by the per-contact record size into a contact
 * estimate readable straight out of a `pg_dump` with no key. The client pads
 * the plaintext to whole 4 KiB blocks before sealing
 * (`kContactBackupPadBlock`), so what survives here is the block count — an
 * upper band, not a count of anything. See docs/METADATA.md.
 *
 * `rev` is optimistic concurrency over the WHOLE triple (ckId, wraps, blob).
 * A write carries the rev it was based on; a mismatch is rejected and nothing
 * is written. That is what makes a half-write — a fresh `blob` next to stale
 * `wraps`, i.e. a row nobody can ever open again — structurally impossible.
 *
 * `updatedAt` moves ONLY on a write that actually changes the triple. An
 * unchanged re-upload must not re-stamp it: `key_bundles.updatedAt` turned
 * into a per-device presence clock exactly that way (docs/agents/traps.md),
 * and this PR series exists to stop the server holding activity clocks.
 *
 * Prod truth is migration 0021; `synchronize` creates this table in dev, so
 * the two must agree exactly.
 */
@Entity('contact_backups')
export class ContactBackup {
  @PrimaryGeneratedColumn()
  id: number;

  @Column({ unique: true })
  userId: number;

  @ManyToOne(() => User, { onDelete: 'CASCADE' })
  @JoinColumn({ name: 'userId' })
  user: User;

  /** Backup format version; 1 is the only one defined. */
  @Column('int')
  version: number;

  /** Optimistic-concurrency counter over (ckId, wraps, blob). Fresh row = 1. */
  @Column({ type: 'int', default: 0 })
  rev: number;

  /**
   * The client's password-KDF salt, minted once by the first device and then
   * IMMUTABLE — every other device derives its key under the salt a GET
   * returned, so a salt that could change would silently orphan them all.
   */
  @Column('text')
  salt: string;

  /** Public label of the content key the blob is sealed under. Opaque here. */
  @Column('text')
  ckId: string;

  /**
   * The wrapped content keys, serialized as a JSON array of `{kind, ct}`.
   * The server serializes and compares this envelope; it never looks inside
   * `ct`, which is ciphertext.
   */
  @Column('text')
  wraps: string;

  /** The sealed contact list. Opaque ciphertext; never parsed. */
  @Column('text')
  blob: string;

  /** Moves only when the triple actually changes — never a presence clock. */
  @Column({ type: 'timestamp' })
  updatedAt: Date;
}
