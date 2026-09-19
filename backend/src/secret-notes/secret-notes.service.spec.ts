// backend/src/secret-notes/secret-notes.service.spec.ts
import { Test } from '@nestjs/testing';
import { CronExpression } from '@nestjs/schedule';
import { getRepositoryToken } from '@nestjs/typeorm';
import { SecretNotesService } from './secret-notes.service';
import { SecretNote } from './secret-note.entity';

const mockRepo = () => ({
  create: jest.fn(),
  save: jest.fn(),
  findOne: jest.fn(),
  delete: jest.fn(),
  query: jest.fn(),
});

describe('SecretNotesService', () => {
  let service: SecretNotesService;
  let repo: ReturnType<typeof mockRepo>;

  beforeEach(async () => {
    const module = await Test.createTestingModule({
      providers: [
        SecretNotesService,
        { provide: getRepositoryToken(SecretNote), useFactory: mockRepo },
      ],
    }).compile();

    service = module.get(SecretNotesService);
    repo = module.get(getRepositoryToken(SecretNote));
  });

  describe('create', () => {
    it('returns a token and saves the note', async () => {
      const note = { token: 'abc123', ciphertext: 'enc', expiresAt: new Date() };
      repo.create.mockReturnValue(note);
      repo.save.mockResolvedValue(note);

      const before = Date.now();
      const result = await service.create('enc', 7200);
      const after = Date.now();

      expect(repo.save).toHaveBeenCalled();
      expect(result.token).toHaveLength(32);
      // Field-mapping + TTL-scaling contract: ciphertext forwarded verbatim and
      // nothing about the caller (the server does not know whose note this is),
      // expiresAt = now + expiresInSeconds*1000 (ms, not seconds).
      const [createArg] = repo.create.mock.calls[0] as [
        { ciphertext: string; expiresAt: Date },
      ];
      expect(Object.keys(createArg).sort()).toEqual([
        'ciphertext',
        'expiresAt',
        'token',
      ]);
      expect(createArg.ciphertext).toBe('enc');
      const expiresAtMs = new Date(createArg.expiresAt).getTime();
      expect(expiresAtMs).toBeGreaterThanOrEqual(before + 7200 * 1000);
      expect(expiresAtMs).toBeLessThanOrEqual(after + 7200 * 1000);
    });
  });

  describe('revealAndDelete', () => {
    it('returns ciphertext when note found and not expired', async () => {
      // TypeORM postgres driver returns [rows, rowCount] for DELETE ... RETURNING.
      repo.query.mockResolvedValue([[{ ciphertext: 'enc' }], 1]);
      const result = await service.revealAndDelete('tok');
      expect(result).toEqual({ ciphertext: 'enc' });
      expect(repo.query).toHaveBeenCalledWith(
        expect.stringContaining('DELETE FROM secret_notes'),
        ['tok'],
      );
    });

    it('returns null when note not found or expired', async () => {
      repo.query.mockResolvedValue([[], 0]);
      const result = await service.revealAndDelete('missing');
      expect(result).toBeNull();
    });

    it('returns null when the driver yields a non-array rows slot', async () => {
      // The Array.isArray guard turns a non-array rows slot into null, not a crash.
      repo.query.mockResolvedValue([undefined, 0]);
      const result = await service.revealAndDelete('weird');
      expect(result).toBeNull();
    });

    it('queries the quoted camelCase column, never snake_case', async () => {
      // Regression: unquoted expires_at raised Postgres 42703 and 500'd reveal forever.
      repo.query.mockResolvedValue([[], 0]);
      await service.revealAndDelete('tok');
      const sql = repo.query.mock.calls[0][0] as string;
      expect(sql).toContain('"expiresAt"');
      expect(sql).not.toContain('expires_at');
    });
  });

  describe('findByToken', () => {
    it('returns null when note is expired', async () => {
      const past = new Date(Date.now() - 1000);
      repo.findOne.mockResolvedValue({ id: 1, token: 'tok', expiresAt: past });
      repo.delete.mockResolvedValue({});

      const result = await service.findByToken('tok');
      expect(result).toBeNull();
      expect(repo.delete).toHaveBeenCalledWith({ token: 'tok' });
    });

    it('returns note when valid', async () => {
      const future = new Date(Date.now() + 60000);
      const note = { id: 1, token: 'tok', ciphertext: 'enc', expiresAt: future };
      repo.findOne.mockResolvedValue(note);

      const result = await service.findByToken('tok');
      expect(result).toBe(note);
    });
  });

  describe('deleteExpiredNotes', () => {
    it('deletes expired unread notes in one repository call', async () => {
      repo.delete.mockResolvedValue({ affected: 3 });

      const deleted = await service.deleteExpiredNotes();

      expect(deleted).toBe(3);
      expect(repo.delete).toHaveBeenCalledWith({
        expiresAt: expect.objectContaining({
          _type: 'lessThan',
        }),
      });
    });

    // The cadence IS the fix. Reverting to daily would leave an unread expired
    // note's ciphertext readable for up to ~24h past its TTL while its AES key
    // sits in plaintext message content, and no behavioural test would notice.
    it('is scheduled per minute, matching message cleanup', () => {
      // Read the descriptor rather than naming the method: a bare
      // `Prototype.method` reference trips unbound-method, and Reflect's
      // `any` return trips the no-unsafe-* rules. Both push the ratchet floor.
      const handler = Object.getOwnPropertyDescriptor(
        SecretNotesService.prototype,
        'deleteExpiredNotes',
      )?.value as object;
      const options = Reflect.getMetadata('SCHEDULE_CRON_OPTIONS', handler) as
        | { cronTime?: string }
        | undefined;

      expect(options?.cronTime).toBe(CronExpression.EVERY_MINUTE);
    });
  });
});
