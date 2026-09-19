// backend/src/secret-notes/secret-notes.service.ts
import { Injectable, Logger } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { InjectRepository } from '@nestjs/typeorm';
import { LessThan, Repository } from 'typeorm';
import { SecretNote } from './secret-note.entity';
import * as crypto from 'crypto';

@Injectable()
export class SecretNotesService {
  private readonly logger = new Logger(SecretNotesService.name);

  constructor(
    @InjectRepository(SecretNote)
    private readonly repo: Repository<SecretNote>,
  ) {}

  async create(
    ciphertext: string,
    expiresInSeconds: number,
  ): Promise<{ token: string }> {
    const token = crypto.randomBytes(16).toString('hex'); // 32-char hex
    const expiresAt = new Date(Date.now() + expiresInSeconds * 1000);
    const note = this.repo.create({ token, ciphertext, expiresAt });
    await this.repo.save(note);
    return { token };
  }

  async findByToken(token: string): Promise<SecretNote | null> {
    const note = await this.repo.findOne({ where: { token } });
    if (!note) return null;
    if (new Date(note.expiresAt).getTime() < Date.now()) {
      await this.repo.delete({ token });
      return null;
    }
    return note;
  }

  async revealAndDelete(token: string): Promise<{ ciphertext: string } | null> {
    // Column is camelCase (TypeORM default naming from the entity property) —
    // raw SQL MUST quote it: unquoted expires_at was 42703 and broke reveal.
    // Postgres driver returns [rows, rowCount] for DELETE — destructure rows.
    const [rows] = await this.repo.query(
      `DELETE FROM secret_notes WHERE token = $1 AND "expiresAt" > NOW() RETURNING ciphertext`,
      [token],
    );
    if (!Array.isArray(rows) || rows.length === 0) return null;
    return { ciphertext: rows[0].ciphertext };
  }

  // Per-minute, matching MessageCleanupService. Daily-at-3am left an UNREAD
  // expired note's ciphertext in the table for up to ~24h past its TTL. The
  // API refuses to serve it, but the AES key travels in the note URL, which is
  // stored as ordinary plaintext message content — so DB access plus device
  // access reads a note the UI already called self-destructed.
  @Cron(CronExpression.EVERY_MINUTE)
  async deleteExpiredNotes(): Promise<number> {
    const result = await this.repo.delete({ expiresAt: LessThan(new Date()) });
    const deleted = result.affected ?? 0;
    if (deleted > 0) {
      this.logger.log(`Deleted ${deleted} expired secret notes`);
    }
    return deleted;
  }
}
