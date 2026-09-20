import {
  ConflictException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { ContactBackup } from './contact-backup.entity';
import {
  ContactBackupWrapDto,
  PutContactBackupDto,
} from './dto/contact-backup.dto';

/** What a GET hands back: the stored triple plus its rev and stamp. */
export interface ContactBackupView {
  v: number;
  rev: number;
  salt: string;
  ckId: string;
  wraps: ContactBackupWrapDto[];
  blob: string;
  updatedAt: Date;
}

@Injectable()
export class ContactBackupService {
  constructor(
    @InjectRepository(ContactBackup)
    private readonly repo: Repository<ContactBackup>,
  ) {}

  async get(userId: number): Promise<ContactBackupView> {
    const row = await this.repo.findOne({ where: { userId } });
    // 404 is the "mint a salt and PUT" signal, not an error state.
    if (!row) throw new NotFoundException();
    return {
      v: row.version,
      rev: row.rev,
      salt: row.salt,
      ckId: row.ckId,
      wraps: JSON.parse(row.wraps) as ContactBackupWrapDto[],
      blob: row.blob,
      updatedAt: row.updatedAt,
    };
  }

  /**
   * Writes the account's backup, or refuses.
   *
   * The rev guard is what keeps the row openable: a client that lost the race
   * gets 409 stale_backup with the server's rev, re-GETs, re-merges and
   * retries — it never lands a blob sealed to a content key whose wraps it
   * did not also upload. Every accepted write replaces the whole triple, so
   * the row is never internally inconsistent.
   *
   * A truly simultaneous pair of PUTs from two devices at the same baseRev is
   * a last-writer-wins lost update (check-then-save, not a conditional
   * UPDATE); the surviving row is still a complete, openable triple and the
   * loser's next GET/merge repairs it.
   */
  async put(
    userId: number,
    dto: PutContactBackupDto,
  ): Promise<{ rev: number; updatedAt: Date }> {
    const existing = await this.repo.findOne({ where: { userId } });
    // Canonical envelope: field order fixed so a byte compare against the
    // stored column answers "did anything change?". `ct` is never inspected.
    const wraps = JSON.stringify(
      dto.wraps.map((w) => ({ kind: w.kind, ct: w.ct })),
    );

    if (!existing) {
      // baseRev 0 means "I expect no row" — anything else read a rev that no
      // longer exists (the account was wiped under it).
      if (dto.baseRev !== 0) {
        throw new ConflictException({ error: 'stale_backup', rev: 0 });
      }
      const updatedAt = new Date();
      const created = this.repo.create({
        userId,
        version: dto.v,
        rev: 1,
        salt: dto.salt,
        ckId: dto.ckId,
        wraps,
        blob: dto.blob,
        updatedAt,
      });
      await this.repo.save(created);
      return { rev: 1, updatedAt };
    }

    if (dto.baseRev !== existing.rev) {
      throw new ConflictException({ error: 'stale_backup', rev: existing.rev });
    }

    // The salt is minted once. Accepting a new one would orphan every device
    // that derived its key under the old one.
    if (dto.salt !== existing.salt) {
      throw new ConflictException({ error: 'salt_mismatch' });
    }

    // Presence-clock guard (docs/agents/traps.md): an unchanged re-upload
    // writes nothing and re-stamps nothing. `updatedAt` must never become a
    // "this account was online at <time>" record the server holds.
    const unchanged =
      existing.version === dto.v &&
      existing.ckId === dto.ckId &&
      existing.blob === dto.blob &&
      existing.wraps === wraps;
    if (unchanged) {
      return { rev: existing.rev, updatedAt: existing.updatedAt };
    }

    const updatedAt = new Date();
    existing.version = dto.v;
    existing.ckId = dto.ckId;
    existing.wraps = wraps;
    existing.blob = dto.blob;
    existing.rev = existing.rev + 1;
    existing.updatedAt = updatedAt;
    await this.repo.save(existing);
    return { rev: existing.rev, updatedAt };
  }
}
