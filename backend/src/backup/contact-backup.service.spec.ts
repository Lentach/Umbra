// backend/src/backup/contact-backup.service.spec.ts
import { Test } from '@nestjs/testing';
import { ConflictException, NotFoundException } from '@nestjs/common';
import { getRepositoryToken } from '@nestjs/typeorm';
import { ContactBackupService } from './contact-backup.service';
import { ContactBackup } from './contact-backup.entity';
import { PutContactBackupDto } from './dto/contact-backup.dto';

/**
 * The update path is a CONDITIONAL UPDATE, not `save`: the builder is mocked
 * chainably and handed back on the repo so a test can read what the guard
 * was actually compiled with.
 *
 * Typed explicitly rather than inferred — a bare object literal of `jest.fn`s
 * returning itself infers as `any`, which costs the backend lint ratchet four
 * `no-unsafe-*` errors it refuses to absorb.
 */
interface MockBuilder {
  update: jest.Mock;
  set: jest.Mock;
  where: jest.Mock;
  execute: jest.Mock;
}

const mockRepo = () => {
  const builder: MockBuilder = {
    update: jest.fn((): MockBuilder => builder),
    set: jest.fn((): MockBuilder => builder),
    where: jest.fn((): MockBuilder => builder),
    execute: jest.fn(() => Promise.resolve({ affected: 1 })),
  };
  return {
    create: jest.fn(),
    save: jest.fn(),
    findOne: jest.fn(),
    createQueryBuilder: jest.fn((): MockBuilder => builder),
    builder,
  };
};

const SALT = 'c2FsdC1zYWx0LXNhbHQtc2FsdA';
const CK_ID = 'AAAAAAAAAAAAAAAAAAAAAA';
const OTHER_CK_ID = 'BBBBBBBBBBBBBBBBBBBBBB';
// Opaque fixtures stay inside the base64 charset the DTO enforces, so no
// fixture here describes a body the endpoint would have refused.
const STORED_WRAPS = JSON.stringify([{ kind: 'password', ct: 'wrapPw' }]);
const STORED_AT = new Date('2026-09-01T10:00:00.000Z');

const storedRow = (): ContactBackup =>
  ({
    id: 7,
    userId: 42,
    version: 1,
    rev: 3,
    salt: SALT,
    ckId: CK_ID,
    wraps: STORED_WRAPS,
    blob: 'sealedContacts',
    updatedAt: STORED_AT,
  }) as ContactBackup;

const putDto = (
  over: Partial<PutContactBackupDto> = {},
): PutContactBackupDto => ({
  v: 1,
  baseRev: 3,
  salt: SALT,
  ckId: CK_ID,
  wraps: [{ kind: 'password', ct: 'wrapPw' }],
  blob: 'sealedContacts',
  ...over,
});

describe('ContactBackupService', () => {
  let service: ContactBackupService;
  let repo: ReturnType<typeof mockRepo>;

  beforeEach(async () => {
    const module = await Test.createTestingModule({
      providers: [
        ContactBackupService,
        { provide: getRepositoryToken(ContactBackup), useFactory: mockRepo },
      ],
    }).compile();

    service = module.get(ContactBackupService);
    repo = module.get(getRepositoryToken(ContactBackup));
  });

  describe('get', () => {
    it('404s when the account has no row so the client mints a salt', async () => {
      repo.findOne.mockResolvedValue(null);

      await expect(service.get(42)).rejects.toBeInstanceOf(NotFoundException);
    });

    it('returns the stored triple with its rev and stamp', async () => {
      repo.findOne.mockResolvedValue(storedRow());

      await expect(service.get(42)).resolves.toEqual({
        v: 1,
        rev: 3,
        salt: SALT,
        ckId: CK_ID,
        wraps: [{ kind: 'password', ct: 'wrapPw' }],
        blob: 'sealedContacts',
        updatedAt: STORED_AT,
      });
    });
  });

  describe('put', () => {
    it('creates the row at rev 1 when the account is empty and baseRev is 0', async () => {
      repo.findOne.mockResolvedValue(null);
      repo.create.mockImplementation((v: Partial<ContactBackup>) => v);
      repo.save.mockImplementation((v: ContactBackup) => Promise.resolve(v));

      const result = await service.put(42, putDto({ baseRev: 0 }));

      expect(result.rev).toBe(1);
      expect(repo.save).toHaveBeenCalledWith(
        expect.objectContaining({
          userId: 42,
          version: 1,
          rev: 1,
          salt: SALT,
          ckId: CK_ID,
          wraps: STORED_WRAPS,
          blob: 'sealedContacts',
        }),
      );
    });

    it('rejects baseRev 0 when a row already exists, writing nothing', async () => {
      repo.findOne.mockResolvedValue(storedRow());

      // Without this the second device's "I am the first" upload would
      // overwrite an existing backup sealed under a key it never saw.
      await expect(
        service.put(42, putDto({ baseRev: 0 })),
      ).rejects.toMatchObject({ response: { error: 'stale_backup', rev: 3 } });
      expect(repo.save).not.toHaveBeenCalled();
    });

    it('rejects a stale baseRev with the server rev, writing nothing', async () => {
      repo.findOne.mockResolvedValue(storedRow());

      const error: unknown = await service
        .put(42, putDto({ baseRev: 2, blob: 'newer' }))
        .catch((e: unknown) => e);

      expect(error).toBeInstanceOf(ConflictException);
      expect((error as ConflictException).getResponse()).toEqual({
        error: 'stale_backup',
        rev: 3,
      });
      expect(repo.save).not.toHaveBeenCalled();
    });

    it('rejects a changed salt, writing nothing', async () => {
      repo.findOne.mockResolvedValue(storedRow());

      // A salt that could change would orphan every device that already
      // derived its password key under the stored one.
      const error: unknown = await service
        .put(42, putDto({ salt: 'ZGlmZmVyZW50LXNhbHQtaGVyZQ' }))
        .catch((e: unknown) => e);

      expect(error).toBeInstanceOf(ConflictException);
      expect((error as ConflictException).getResponse()).toEqual({
        error: 'salt_mismatch',
      });
      expect(repo.save).not.toHaveBeenCalled();
    });

    it('bumps rev and moves updatedAt when only the blob changes', async () => {
      repo.findOne.mockResolvedValue(storedRow());

      const result = await service.put(42, putDto({ blob: 'sealedContacts2' }));

      expect(result.rev).toBe(4);
      expect(result.updatedAt.getTime()).toBeGreaterThan(STORED_AT.getTime());
      expect(repo.builder.set).toHaveBeenCalledWith(
        expect.objectContaining({ blob: 'sealedContacts2' }),
      );
    });

    it('guards the write on the rev it read, in the statement itself', async () => {
      repo.findOne.mockResolvedValue(storedRow());

      // Check-then-save would let two PUTs at the same baseRev both land, and
      // a lost WRAP upload is unrecoverable: resetPassword publishes the new
      // password's wrap and then changes the password, so no later session
      // holds a secret that could re-merge the loser back in.
      await service.put(42, putDto({ blob: 'sealedContacts2' }));

      expect(repo.builder.where).toHaveBeenCalledWith(
        '"userId" = :userId AND "rev" = :baseRev',
        { userId: 42, baseRev: 3 },
      );
    });

    it('refuses with the fresh rev when the guarded update matches no row', async () => {
      // Someone committed between the read and the statement: the row is at a
      // rev this write was not based on, so it must not be reported as stored.
      repo.findOne
        .mockResolvedValueOnce(storedRow())
        .mockResolvedValueOnce({ ...storedRow(), rev: 9 });
      repo.builder.execute.mockResolvedValue({ affected: 0 });

      const error: unknown = await service
        .put(42, putDto({ blob: 'sealedContacts2' }))
        .catch((e: unknown) => e);

      expect(error).toBeInstanceOf(ConflictException);
      expect((error as ConflictException).getResponse()).toEqual({
        error: 'stale_backup',
        rev: 9,
      });
    });

    it('answers 409, not 500, when another device inserted the row first', async () => {
      // The unique userId constraint fires between the findOne and the save.
      // A 500 would look like a server fault the client cannot act on; 409
      // puts it back on the re-read-and-retry path it already implements.
      repo.findOne
        .mockResolvedValueOnce(null)
        .mockResolvedValueOnce({ ...storedRow(), rev: 1 });
      repo.create.mockImplementation((v: Partial<ContactBackup>) => v);
      repo.save.mockRejectedValue(new Error('duplicate key value'));

      const error: unknown = await service
        .put(42, putDto({ baseRev: 0 }))
        .catch((e: unknown) => e);

      expect(error).toBeInstanceOf(ConflictException);
      expect((error as ConflictException).getResponse()).toEqual({
        error: 'stale_backup',
        rev: 1,
      });
    });

    it('accepts a re-minted ckId with new wraps at the current rev', async () => {
      repo.findOne.mockResolvedValue(storedRow());

      // Phrase restore: the client re-wraps a fresh content key for both
      // secrets and re-seals the blob under it, all in one write.
      const result = await service.put(
        42,
        putDto({
          ckId: OTHER_CK_ID,
          wraps: [
            { kind: 'password', ct: 'wrapPw2' },
            { kind: 'phrase', ct: 'wrapPhrase' },
          ],
          blob: 'resealed',
        }),
      );

      expect(result.rev).toBe(4);
      expect(repo.builder.set).toHaveBeenCalledWith(
        expect.objectContaining({
          ckId: OTHER_CK_ID,
          wraps: JSON.stringify([
            { kind: 'password', ct: 'wrapPw2' },
            { kind: 'phrase', ct: 'wrapPhrase' },
          ]),
          blob: 'resealed',
        }),
      );
    });

    it('writes nothing and re-stamps nothing for an unchanged re-upload', async () => {
      repo.findOne.mockResolvedValue(storedRow());

      // The presence-clock guard (docs/agents/traps.md): if this check goes,
      // updatedAt becomes "this account was online at <time>" — exactly what
      // key_bundles.updatedAt became, and what this PR series removes.
      const result = await service.put(42, putDto());

      expect(result).toEqual({ rev: 3, updatedAt: STORED_AT });
      expect(repo.save).not.toHaveBeenCalled();
    });
  });
});
