import { Test } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import { CronExpression } from '@nestjs/schedule';
import { Repository } from 'typeorm';
import { UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  RefreshTokensService,
  REFRESH_TOKEN_TTL_DAYS,
} from './refresh-tokens.service';
import { RefreshToken } from './refresh-token.entity';

describe('RefreshTokensService', () => {
  let service: RefreshTokensService;
  let repo: jest.Mocked<Repository<RefreshToken>>;
  const live = jest.fn<Promise<boolean>, [number, number | null]>();

  beforeEach(async () => {
    const mockRepo = {
      create: jest.fn((x) => x),
      save: jest.fn(),
      findOne: jest.fn(),
      remove: jest.fn(),
      delete: jest.fn(),
      update: jest.fn().mockResolvedValue({ affected: 1 }),
      query: jest.fn(),
    };

    const module = await Test.createTestingModule({
      providers: [
        RefreshTokensService,
        {
          provide: getRepositoryToken(RefreshToken),
          useValue: mockRepo,
        },
        // No JWT_SECRET: the dev fallback keys the rotation chain.
        { provide: ConfigService, useValue: { get: () => undefined } },
      ],
    }).compile();

    service = module.get(RefreshTokensService);
    repo = module.get(getRepositoryToken(RefreshToken));
    jest.clearAllMocks();
    // A device that is not revoked, unless a test says otherwise.
    live.mockResolvedValue(false);
  });

  it('hashToken is deterministic', () => {
    const a = RefreshTokensService.hashToken('plain-one');
    const b = RefreshTokensService.hashToken('plain-one');
    expect(a).toBe(b);
    expect(a.length).toBe(64);
  });

  it('createToken persists the hashed token, named by its session, with ~365d expiry', async () => {
    repo.save.mockImplementation(async (e: RefreshToken) => e);

    const plain = await service.createToken(42);

    expect(repo.save).toHaveBeenCalled();
    const saved = repo.save.mock.calls[0][0] as RefreshToken;
    expect(saved.userId).toBe(42);
    expect(saved.tokenHash).toBe(RefreshTokensService.hashToken(plain));
    expect(saved.prevTokenHash).toBeNull();
    // `<sessionId>.<secret>`: reuse of an old token is told by its session.
    expect(RefreshTokensService.familyOf(plain)).toBe(saved.id);
    expect(plain.length).toBeGreaterThan(saved.id.length + 60);
    const msUntilExpiry = saved.expiresAt.getTime() - Date.now();
    expect(msUntilExpiry).toBeGreaterThan(
      (REFRESH_TOKEN_TTL_DAYS - 2) * 86400 * 1000,
    );
  });

  it('familyOf reads only a uuid prefix; a token from before plan B4 names none', () => {
    const id = '0b7e6c1a-5d0f-4c2e-9a51-3f6f2f1d9e10';
    expect(RefreshTokensService.familyOf(`${id}.abc`)).toBe(id);
    expect(RefreshTokensService.familyOf('Zm9vYmFy-legacy_token')).toBeNull();
    expect(RefreshTokensService.familyOf('not-a-uuid.abc')).toBeNull();
    expect(RefreshTokensService.familyOf('.abc')).toBeNull();
  });

  it('redeem refuses an unknown token that names no session, asking nothing else', async () => {
    repo.findOne.mockResolvedValue(null);
    await expect(
      service.redeem('unknown', live, { rotate: true }),
    ).rejects.toThrow(new UnauthorizedException('Invalid refresh token'));
    expect(repo.findOne).toHaveBeenCalledTimes(1);
    expect(live).not.toHaveBeenCalled();
    expect(repo.delete).not.toHaveBeenCalled();
  });

  it('redeem without rotate keeps the token and slides only the expiry, by a write that cannot undo a rotation', async () => {
    const row = {
      id: 'session-id',
      userId: 42,
      deviceId: 3,
      tokenHash: RefreshTokensService.hashToken('old-plain'),
      prevTokenHash: null,
      expiresAt: new Date(Date.now() + 60_000),
    } as RefreshToken;
    repo.findOne.mockResolvedValue(row);

    const result = await service.redeem('old-plain', live, { rotate: false });

    expect(repo.findOne).toHaveBeenCalledWith({
      where: [
        { tokenHash: RefreshTokensService.hashToken('old-plain') },
        { prevTokenHash: RefreshTokensService.hashToken('old-plain') },
      ],
    });
    // The reissued access token has to keep naming the same device.
    expect(result).toEqual({
      userId: 42,
      deviceId: 3,
      refreshToken: 'old-plain',
    });
    const [criteria, values] = repo.update.mock.calls[0] as [
      Record<string, unknown>,
      { expiresAt: Date },
    ];
    expect(criteria).toEqual({ id: 'session-id', tokenHash: row.tokenHash });
    expect(Object.keys(values)).toEqual(['expiresAt']);
    expect(values.expiresAt.getTime()).toBeGreaterThan(
      Date.now() + (REFRESH_TOKEN_TTL_DAYS - 2) * 86400 * 1000,
    );
    expect(repo.save).not.toHaveBeenCalled();
  });

  it('redeem removes an expired session and rejects without issuing a replacement', async () => {
    const expiredRow = {
      id: 'expired-token-id',
      userId: 42,
      tokenHash: RefreshTokensService.hashToken('expired-plain'),
      expiresAt: new Date(Date.now() - 1),
    } as RefreshToken;
    repo.findOne.mockResolvedValue(expiredRow);

    await expect(
      service.redeem('expired-plain', live, { rotate: true }),
    ).rejects.toThrow(new UnauthorizedException('Refresh token expired'));

    expect(repo.remove).toHaveBeenCalledWith(expiredRow);
    expect(repo.update).not.toHaveBeenCalled();
  });

  // Decision 130 (E130a): a device closed past its access JWT's 24 h can only
  // ask /auth/refresh whether it was revoked, so the answer has to be its own
  // — not the `Invalid refresh token` that logout, a password change, reuse
  // and an expiry also give — and the refusal must neither extend, rotate nor
  // delete the row (it is the proof of the revocation).
  it.each([
    ['current', true],
    ['current', false],
    ['older', true],
  ])(
    "redeem refuses a revoked device's %s token (rotate: %s) as 'Device revoked', keeping the row as it was",
    async (which, rotate) => {
      const familyId = '0b7e6c1a-5d0f-4c2e-9a51-3f6f2f1d9e10';
      const presented = `${familyId}.revoked-plain`;
      const oldExpiry = new Date(Date.now() + 60_000);
      const row = {
        id: familyId,
        userId: 42,
        deviceId: 2,
        tokenHash:
          which === 'current'
            ? RefreshTokensService.hashToken(presented)
            : 'f'.repeat(64),
        expiresAt: oldExpiry,
      } as RefreshToken;
      if (which === 'current') {
        repo.findOne.mockResolvedValue(row);
      } else {
        repo.findOne.mockResolvedValueOnce(null).mockResolvedValueOnce(row);
      }
      live.mockResolvedValue(true);

      await expect(service.redeem(presented, live, { rotate })).rejects.toThrow(
        new UnauthorizedException('Device revoked'),
      );

      expect(live).toHaveBeenCalledWith(42, 2);
      // Named once: reading these off the class-typed repo trips `unbound-method`.
      const writes = repo as unknown as {
        save: jest.Mock;
        remove: jest.Mock;
        update: jest.Mock;
        delete: jest.Mock;
      };
      expect(writes.save).not.toHaveBeenCalled();
      expect(writes.remove).not.toHaveBeenCalled();
      expect(writes.update).not.toHaveBeenCalled();
      expect(writes.delete).not.toHaveBeenCalled();
      expect(row.expiresAt).toBe(oldExpiry);
    },
  );

  it('redeem asks about the pre-Phase-1 (NULL device) row as it is stored; the caller reads it as device 1', async () => {
    repo.findOne.mockResolvedValue({
      userId: 7,
      deviceId: null,
      tokenHash: RefreshTokensService.hashToken('legacy-plain'),
      expiresAt: new Date(Date.now() + 60_000),
    } as RefreshToken);

    await service.redeem('legacy-plain', live, { rotate: false });

    expect(live).toHaveBeenCalledWith(7, null);
  });

  it('revokeByPlain ends the session its current or just-replaced token names, and ignores unknown tokens', async () => {
    const row = {
      id: 'token-id',
      userId: 42,
      tokenHash: RefreshTokensService.hashToken('plain-to-revoke'),
      expiresAt: new Date(Date.now() + 60_000),
    } as RefreshToken;
    repo.findOne.mockResolvedValueOnce(row).mockResolvedValueOnce(null);

    await service.revokeByPlain('plain-to-revoke');
    await service.revokeByPlain('unknown-plain');

    const hash = RefreshTokensService.hashToken('plain-to-revoke');
    expect(repo.findOne).toHaveBeenNthCalledWith(1, {
      where: [{ tokenHash: hash }, { prevTokenHash: hash }],
    });
    expect(repo.remove).toHaveBeenCalledTimes(1);
    expect(repo.remove).toHaveBeenCalledWith(row);
  });

  it("revokeAllForUser deletes the account's sessions EXCEPT those of an already-revoked device", async () => {
    await service.revokeAllForUser(42);

    // Named once: reading `query` off the class-typed repo trips `unbound-method`.
    const query = (repo as unknown as { query: jest.Mock }).query;
    const [sql, params] = query.mock.calls[0] as [string, unknown[]];
    const flat = sql.replace(/\s+/g, ' ');
    expect(params).toEqual([42]);
    // The rows of a revoked device are what /auth/refresh answers "Device
    // revoked" from; a NULL device_id (pre-Phase-1) is nobody's and goes.
    expect(flat).toContain(
      'DELETE FROM public.refresh_tokens WHERE user_id = $1',
    );
    expect(flat).toContain('device_id IS NULL OR device_id NOT IN (');
    expect(flat).toContain(
      'SELECT "deviceId" FROM public.devices WHERE "userId" = $1 AND "revokedAt" IS NOT NULL',
    );
    expect(query).toHaveBeenCalledTimes(1);
  });

  // The §6.2 roster teardown (amendment (xxviii)) is atomic ONLY if these
  // writes ride the caller's transaction. The roster spec pins that a manager
  // is PASSED; this pins that it is HONOURED. Without it, dropping the
  // `manager ? … : this.refreshRepo` branch leaves both specs green while the
  // session wipe silently returns to the autocommit connection — it could then
  // commit while the roster mutation rolls back, which is the exact false
  // guarantee the amendment exists to deny.
  describe('honours a caller-supplied EntityManager', () => {
    // Raw jest.Mock handles throughout, for the reason the suite already
    // relies on elsewhere: a bare jest.fn has no `this` to lose, while
    // asserting through the class-typed repo method trips `unbound-method`.
    let txSave: jest.Mock<Promise<RefreshToken>, [RefreshToken]>;
    let txQuery: jest.Mock;
    let getRepository: jest.Mock;
    let manager: { getRepository: jest.Mock };
    let defaultSave: jest.Mock;
    let defaultQuery: jest.Mock;

    beforeEach(() => {
      txSave = jest.fn((e: RefreshToken) => Promise.resolve(e));
      txQuery = jest.fn().mockResolvedValue([[], 1]);
      getRepository = jest.fn().mockReturnValue({
        create: jest.fn((e: RefreshToken) => e),
        save: txSave,
        query: txQuery,
      });
      manager = { getRepository };
      // Re-typed as plain jest.Mock properties: reading them off the
      // class-typed repo directly is what trips `unbound-method`.
      const raw = repo as unknown as { save: jest.Mock; query: jest.Mock };
      defaultSave = raw.save;
      defaultQuery = raw.query;
    });

    it('createToken writes through the manager, not the default repo', async () => {
      await service.createToken(42, 4, null, manager as never);

      expect(getRepository).toHaveBeenCalledWith(RefreshToken);
      const saved = txSave.mock.calls[0][0];
      expect(saved.userId).toBe(42);
      expect(saved.deviceId).toBe(4);
      expect(defaultSave).not.toHaveBeenCalled();
    });

    it('revokeAllForUser deletes through the manager, not the default repo', async () => {
      await service.revokeAllForUser(42, manager as never);

      expect(getRepository).toHaveBeenCalledWith(RefreshToken);
      expect(txQuery).toHaveBeenCalledTimes(1);
      expect(txQuery.mock.calls[0][1]).toEqual([42]);
      expect(defaultQuery).not.toHaveBeenCalled();
    });
  });

  // BE-08: nothing else removed the rows of abandoned installs and of revoked
  // devices (kept on purpose, by `revokeAllForUser`) once their year was up.
  describe('deleteExpired (daily reaper)', () => {
    it('a failing delete is logged by code and does not reject into the scheduler', async () => {
      repo.delete.mockRejectedValue(new Error('connection lost'));

      await expect(service.deleteExpired()).resolves.toBe(0);
    });

    it('runs once a day', () => {
      // The descriptor, not `Prototype.method`: unbound-method and the
      // no-unsafe-* rules would push the ratchet floor.
      const handler = Object.getOwnPropertyDescriptor(
        RefreshTokensService.prototype,
        'deleteExpired',
      )?.value as object;
      const options = Reflect.getMetadata('SCHEDULE_CRON_OPTIONS', handler) as
        { cronTime?: string; timeZone?: string } | undefined;

      expect(options?.cronTime).toBe(CronExpression.EVERY_DAY_AT_4AM);
      expect(options?.timeZone).toBe('UTC');
    });
  });
});
