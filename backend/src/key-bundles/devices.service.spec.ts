import { Logger } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import { IsNull } from 'typeorm';
import { Device } from './device.entity';
import { DevicesService } from './devices.service';

/**
 * The account's device rows (Phase 1, multi-device spec §4).
 *
 * Three properties matter here: the row exists for every account that
 * connects (a table only a migration backfill ever wrote would be dead by the
 * time revocation needs it), ensuring it can never break a connection, and
 * a connect leaves no "last online" clock behind (metadata privacy step 0).
 */
describe('DevicesService', () => {
  let service: DevicesService;
  let repo: Record<string, jest.Mock>;
  let warnSpy: jest.SpyInstance;

  beforeEach(async () => {
    repo = {
      update: jest.fn().mockResolvedValue({ affected: 0 }),
      insert: jest.fn().mockResolvedValue({ identifiers: [] }),
      find: jest.fn().mockResolvedValue([]),
      findOne: jest.fn().mockResolvedValue(null),
      query: jest.fn().mockResolvedValue([[], 0]),
    };
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        DevicesService,
        { provide: getRepositoryToken(Device), useValue: repo },
      ],
    }).compile();
    service = module.get(DevicesService);
    warnSpy = jest
      .spyOn(Logger.prototype, 'warn')
      .mockImplementation(() => undefined);
  });

  afterEach(() => warnSpy.mockRestore());

  describe('ensureRow', () => {
    const insertBuilder = (execute: jest.Mock) => {
      const chain: Record<string, jest.Mock> = {
        insert: jest.fn(() => chain),
        into: jest.fn(() => chain),
        values: jest.fn(() => chain),
        orIgnore: jest.fn(() => chain),
        execute,
      };
      return chain;
    };

    it('creates device 1 as primary on first sight, insert-or-ignore', async () => {
      const chain = insertBuilder(jest.fn().mockResolvedValue({ raw: [] }));
      repo.createQueryBuilder = jest.fn(() => chain);

      await service.ensureRow(7, 1, 'android');

      expect(chain.values).toHaveBeenCalledWith({
        userId: 7,
        deviceId: 1,
        isPrimary: true,
        platform: 'android',
      });
      // ON CONFLICT DO NOTHING is what leaves an existing row exactly as it
      // is: rewriting isPrimary on every connect would undo a primary
      // handover the moment the new primary reconnects, and rewriting
      // platform would erase what the row already knows.
      expect(chain.orIgnore).toHaveBeenCalledTimes(1);
      expect(chain.execute).toHaveBeenCalledTimes(1);
    });

    it('writes no timestamp: the row carries no "last online" clock', async () => {
      const chain = insertBuilder(jest.fn().mockResolvedValue({ raw: [] }));
      repo.createQueryBuilder = jest.fn(() => chain);

      await service.ensureRow(7);

      const [values] = chain.values.mock.calls[0] as [Record<string, unknown>];
      expect(Object.keys(values).sort()).toEqual([
        'deviceId',
        'isPrimary',
        'platform',
        'userId',
      ]);
      expect(repo.update).not.toHaveBeenCalled();
    });

    it('never creates a row for a linked device id (amendment (b))', async () => {
      // Rows for ids >= 2 are created SOLELY by the provisioning commit
      // transaction: an auto-insert here would activate a deviceId no
      // ceremony ever committed. With no timestamp to refresh, a linked
      // device's connect writes nothing at all.
      repo.createQueryBuilder = jest.fn();

      await service.ensureRow(7, 2);

      expect(repo.createQueryBuilder).not.toHaveBeenCalled();
      expect(repo.insert).not.toHaveBeenCalled();
      expect(repo.update).not.toHaveBeenCalled();
    });

    it('a write failure costs a missing row, never the connection', async () => {
      const chain = insertBuilder(
        jest.fn().mockRejectedValue(new Error('db down')),
      );
      repo.createQueryBuilder = jest.fn(() => chain);

      await expect(service.ensureRow(7)).resolves.toBeUndefined();
      expect(warnSpy).toHaveBeenCalledTimes(1);
    });
  });

  describe('isActive', () => {
    // Gate for per-device key-material uploads (spec §5.1 / amendment (b)).
    it('false when no row exists (never activated)', async () => {
      await expect(service.isActive(7, 2)).resolves.toBe(false);
      expect(repo.findOne).toHaveBeenCalledWith({
        where: { userId: 7, deviceId: 2 },
      });
    });

    it('true for a live provisioned row', async () => {
      repo.findOne.mockResolvedValue({
        userId: 7,
        deviceId: 2,
        revokedAt: null,
      });
      await expect(service.isActive(7, 2)).resolves.toBe(true);
    });

    it('false for a revoked row', async () => {
      repo.findOne.mockResolvedValue({
        userId: 7,
        deviceId: 2,
        revokedAt: new Date(),
      });
      await expect(service.isActive(7, 2)).resolves.toBe(false);
    });
  });

  describe('isRevoked — the SESSION gate (amendment (xxii))', () => {
    it('false when NO row exists, so legacy accounts are never locked out', async () => {
      // Deliberately the inverse of isActive: every pre-Phase-1 account has no
      // devices row until its first connect writes one (§8), so denying a
      // session on absence would lock out the entire legacy install base.
      await expect(service.isRevoked(7, 1)).resolves.toBe(false);
    });

    it('false for a live row', async () => {
      repo.findOne.mockResolvedValue({
        userId: 7,
        deviceId: 2,
        revokedAt: null,
      });
      await expect(service.isRevoked(7, 2)).resolves.toBe(false);
    });

    it('true ONLY for an explicitly revoked row', async () => {
      repo.findOne.mockResolvedValue({
        userId: 7,
        deviceId: 2,
        revokedAt: new Date(),
      });
      await expect(service.isRevoked(7, 2)).resolves.toBe(true);
    });
  });

  describe('revoke / revokeAllExcept (§5.5, amendment (xxviii))', () => {
    /** Chainable stand-in for the query builder, capturing every clause. */
    const builder = (result: { affected?: number; raw?: unknown }) => {
      const calls: Array<[string, unknown]> = [];
      const chain: Record<string, jest.Mock> = {
        update: jest.fn(() => chain),
        set: jest.fn((patch: unknown) => {
          calls.push(['set', patch]);
          return chain;
        }),
        where: jest.fn((clause: string, params: unknown) => {
          calls.push([clause, params]);
          return chain;
        }),
        andWhere: jest.fn((clause: string, params: unknown) => {
          calls.push([clause, params]);
          return chain;
        }),
        returning: jest.fn((clause: string) => {
          calls.push(['returning', clause]);
          return chain;
        }),
        execute: jest.fn().mockResolvedValue(result),
      };
      return { chain, calls };
    };

    it('reports true when a live row was stamped', async () => {
      const { chain, calls } = builder({ affected: 1 });
      repo.createQueryBuilder = jest.fn(() => chain);

      await expect(service.revoke(7, 2)).resolves.toBe(true);
      // The IS NULL predicate is what serializes two racing revocations.
      expect(calls.map(([clause]) => clause)).toContain('"revokedAt" IS NULL');
    });

    it('reports false when the device was ALREADY revoked (idempotent, no re-teardown)', async () => {
      const { chain } = builder({ affected: 0 });
      repo.createQueryBuilder = jest.fn(() => chain);

      await expect(service.revoke(7, 2)).resolves.toBe(false);
    });

    it('revokeAllExcept returns the ids it stamped, from RETURNING', async () => {
      const { chain, calls } = builder({
        raw: [{ deviceId: 1 }, { deviceId: 2 }],
      });
      repo.createQueryBuilder = jest.fn(() => chain);

      await expect(service.revokeAllExcept(7, 4)).resolves.toEqual([1, 2]);
      // Authoritative set, not a re-read: a concurrent revoke between UPDATE
      // and a follow-up SELECT would hide a device from the teardown.
      expect(calls).toEqual(
        expect.arrayContaining([['returning', '"deviceId"']]),
      );
      expect(calls.map(([clause]) => clause)).toContain(
        '"deviceId" != :keepDeviceId',
      );
    });

    it('revokeAllExcept answers an empty list when nothing was live', async () => {
      const { chain } = builder({ raw: [] });
      repo.createQueryBuilder = jest.fn(() => chain);

      await expect(service.revokeAllExcept(7, 1)).resolves.toEqual([]);
    });
  });

  describe('resolveLoginDeviceId (amendment (xxviii) lockout guard)', () => {
    it('device 1 when the account has NO rows (every legacy account, §8)', async () => {
      repo.find.mockResolvedValue([]);
      await expect(service.resolveLoginDeviceId(7)).resolves.toBe(1);
    });

    it('the LIVE primary, not the lowest id', async () => {
      repo.find.mockResolvedValue([
        { deviceId: 2, isPrimary: false },
        { deviceId: 4, isPrimary: true },
      ]);
      await expect(service.resolveLoginDeviceId(7)).resolves.toBe(4);
    });

    it('queries LIVE rows only, so a revoked device can never be logged into', async () => {
      repo.find.mockResolvedValue([{ deviceId: 4, isPrimary: true }]);

      await service.resolveLoginDeviceId(7);

      const [args] = repo.find.mock.calls[0] as [
        { where: Record<string, unknown> },
      ];
      // `toHaveProperty` alone would survive an IsNull() -> Not(IsNull())
      // inversion: the property still exists and userId still matches, while
      // login resolves onto a REVOKED device. Assert the VALUE.
      expect(args.where).toEqual({ userId: 7, revokedAt: IsNull() });
      // The whole point: after a reset revokes device 1, a password login that
      // still claimed device 1 would be refused by both §5.5 session gates —
      // the owner locked out with the correct password.
    });

    it('falls back to the lowest live id when no row claims primary', async () => {
      repo.find.mockResolvedValue([
        { deviceId: 3, isPrimary: false },
        { deviceId: 5, isPrimary: false },
      ]);
      await expect(service.resolveLoginDeviceId(7)).resolves.toBe(3);
    });
  });

  describe('allocateDeviceId', () => {
    // Real Postgres shape for UPDATE ... RETURNING: [rows, rowCount].
    const returning = (allocatedId: number) => [[{ allocatedId }], 1];

    it('returns the PRE-increment value (first allocation on a fresh column is 2)', async () => {
      // The column starts at 2 (migration 0016 default: every existing
      // account is single-device device 1), so the first allocated id IS 2 —
      // decision record F4's off-by-one rider.
      repo.query.mockResolvedValue(returning(2));

      await expect(service.allocateDeviceId(7)).resolves.toBe(2);
    });

    it('two sequential allocations return N then N+1', async () => {
      repo.query
        .mockResolvedValueOnce(returning(2))
        .mockResolvedValueOnce(returning(3));

      await expect(service.allocateDeviceId(7)).resolves.toBe(2);
      await expect(service.allocateDeviceId(7)).resolves.toBe(3);
    });

    it('throws when the user does not exist (0 rows updated)', async () => {
      repo.query.mockResolvedValue([[], 0]);

      await expect(service.allocateDeviceId(999)).rejects.toThrow(
        /user not found/,
      );
    });

    it('allocates in ONE atomic UPDATE ... RETURNING statement', async () => {
      // The whole point of the allocator (spec §12 Stage-0 amendment (a)) is
      // that concurrent allocations serialize on the row lock of a single
      // statement — a read-then-write would hand two ceremonies the same id.
      repo.query.mockResolvedValue(returning(2));

      await service.allocateDeviceId(7);

      expect(repo.query).toHaveBeenCalledTimes(1);
      const [sql, params] = repo.query.mock.calls[0] as [string, unknown[]];
      expect(sql).toContain('UPDATE');
      expect(sql).toContain('"nextDeviceId" + 1');
      expect(sql).toContain('RETURNING');
      expect(sql).toContain('"nextDeviceId" - 1');
      expect(sql).not.toContain('SELECT'); // no read-then-write
      expect(params).toEqual([7]);
    });
  });
});
