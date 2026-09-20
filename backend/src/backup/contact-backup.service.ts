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
   * The guard is a CONDITIONAL UPDATE (`WHERE rev = :baseRev`), not
   * check-then-save. Two PUTs at the same baseRev would both pass a
   * read-then-compare and both save, and for a WRAP upload that lost update
   * is unrecoverable: `resetPassword` publishes the new password's wrap and
   * then immediately changes the password, so no later session holds a
   * secret that could re-merge the loser back in. Postgres makes the guard
   * free; the loser gets the 409 it already knows how to handle.
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
      try {
        await this.repo.save(created);
      } catch {
        // Another device inserted between the findOne and here (the userId
        // unique constraint). That is a stale baseRev, not a server fault:
        // answering 409 puts the loser back on its re-read-and-retry path
        // instead of a 500 it treats as an unexplained failure.
        const now = await this.repo.findOne({ where: { userId } });
        throw new ConflictException({
          error: 'stale_backup',
          rev: now?.rev ?? 0,
        });
      }
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
    const result = await this.repo
      .createQueryBuilder()
      .update(ContactBackup)
      .set({
        version: dto.v,
        ckId: dto.ckId,
        wraps,
        blob: dto.blob,
        rev: () => '"rev" + 1',
        updatedAt,
      })
      .where('"userId" = :userId AND "rev" = :baseRev', {
        userId,
        baseRev: dto.baseRev,
      })
      .execute();
    if (result.affected === 0) {
      // Someone committed between the read above and this statement.
      const now = await this.repo.findOne({ where: { userId } });
      throw new ConflictException({
        error: 'stale_backup',
        rev: now?.rev ?? 0,
      });
    }
    return { rev: existing.rev + 1, updatedAt };
  }
}
