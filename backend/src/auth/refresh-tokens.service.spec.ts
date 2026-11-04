import { Test } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { UnauthorizedException } from '@nestjs/common';
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
      query: jest.fn(),
    };

    const module = await Test.createTestingModule({
      providers: [
        RefreshTokensService,
        {
          provide: getRepositoryToken(RefreshToken),
          useValue: mockRepo,
        },
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

  it('createToken persists hashed token with ~365d expiry', async () => {
    repo.save.mockImplementation(async (e: RefreshToken) => e);

    const plain = await service.createToken(42);

    expect(plain.length).toBeGreaterThan(40);
    expect(repo.save).toHaveBeenCalled();
    const saved = repo.save.mock.calls[0][0] as RefreshToken;
    expect(saved.userId).toBe(42);
    expect(saved.tokenHash).toBe(RefreshTokensService.hashToken(plain));
    const msUntilExpiry = saved.expiresAt.getTime() - Date.now();
    expect(msUntilExpiry).toBeGreaterThan(
      (REFRESH_TOKEN_TTL_DAYS - 2) * 86400 * 1000,
    );
  });

  it('consumeAndSlide throws when token unknown', async () => {
    repo.findOne.mockResolvedValue(null);
    await expect(service.consumeAndSlide('unknown', live)).rejects.toThrow(
      new UnauthorizedException('Invalid refresh token'),
    );
    expect(live).not.toHaveBeenCalled();
  });

  it('consumeAndSlide extends the existing refresh token instead of invalidating a lost response retry', async () => {
    const oldExpiry = new Date(Date.now() + 60_000);
    const oldRow = {
      id: 'old-token-id',
      userId: 42,
      tokenHash: RefreshTokensService.hashToken('old-plain'),
      expiresAt: oldExpiry,
    } as RefreshToken;
    repo.findOne.mockResolvedValue(oldRow);
    repo.save.mockImplementation(async (e: RefreshToken) => e);

    const result = await service.consumeAndSlide('old-plain', live);

    expect(repo.findOne).toHaveBeenCalledWith({
      where: { tokenHash: RefreshTokensService.hashToken('old-plain') },
    });
    expect(repo.remove).not.toHaveBeenCalled();
    expect(repo.save).toHaveBeenCalledWith(oldRow);
    // The reissued access token has to keep naming the same device.
    expect(result).toEqual({ userId: 42, deviceId: oldRow.deviceId });
    expect(oldRow.expiresAt.getTime()).toBeGreaterThan(oldExpiry.getTime());
    expect(oldRow.expiresAt.getTime()).toBeGreaterThan(
      Date.now() + (REFRESH_TOKEN_TTL_DAYS - 2) * 86400 * 1000,
    );
  });

  it('consumeAndSlide removes expired tokens and rejects without issuing a replacement', async () => {
    const expiredRow = {
      id: 'expired-token-id',
      userId: 42,
      tokenHash: RefreshTokensService.hashToken('expired-plain'),
      expiresAt: new Date(Date.now() - 1),
    } as RefreshToken;
    repo.findOne.mockResolvedValue(expiredRow);

    await expect(
      service.consumeAndSlide('expired-plain', live),
    ).rejects.toThrow(new UnauthorizedException('Refresh token expired'));

    expect(repo.remove).toHaveBeenCalledWith(expiredRow);
    expect(repo.save).not.toHaveBeenCalled();
  });

  // Decision 130 (E130a): a device closed past its access JWT's 24 h can only
  // ask /auth/refresh whether it was revoked, so the answer has to be its own
  // — not the `Invalid refresh token` that logout, a password change and an
  // expiry also give — and the refusal must not extend the row.
  it("consumeAndSlide refuses a revoked device's row as 'Device revoked' — before the slide, keeping the row", async () => {
    const oldExpiry = new Date(Date.now() + 60_000);
    const row = {
      id: 'revoked-token-id',
      userId: 42,
      deviceId: 2,
      tokenHash: RefreshTokensService.hashToken('revoked-plain'),
      expiresAt: oldExpiry,
    } as RefreshToken;
    repo.findOne.mockResolvedValue(row);
    live.mockResolvedValue(true);

    await expect(
      service.consumeAndSlide('revoked-plain', live),
    ).rejects.toThrow(new UnauthorizedException('Device revoked'));

    expect(live).toHaveBeenCalledWith(42, 2);
    // Named once: reading these off the class-typed repo trips `unbound-method`.
    const writes = repo as unknown as { save: jest.Mock; remove: jest.Mock };
    expect(writes.save).not.toHaveBeenCalled();
    expect(writes.remove).not.toHaveBeenCalled();
    expect(row.expiresAt).toBe(oldExpiry);
  });

  it('consumeAndSlide asks about the pre-Phase-1 (NULL device) row as it is stored; the caller reads it as device 1', async () => {
    repo.findOne.mockResolvedValue({
      userId: 7,
      deviceId: null,
      expiresAt: new Date(Date.now() + 60_000),
    } as RefreshToken);
    repo.save.mockImplementation(async (e: RefreshToken) => e);

    await service.consumeAndSlide('legacy-plain', live);

    expect(live).toHaveBeenCalledWith(7, null);
  });

  it('revokeByPlain removes matching tokens and ignores unknown tokens', async () => {
    const row = {
      id: 'token-id',
      userId: 42,
      tokenHash: RefreshTokensService.hashToken('plain-to-revoke'),
      expiresAt: new Date(Date.now() + 60_000),
    } as RefreshToken;
    repo.findOne.mockResolvedValueOnce(row).mockResolvedValueOnce(null);

    await service.revokeByPlain('plain-to-revoke');
    await service.revokeByPlain('unknown-plain');

    expect(repo.findOne).toHaveBeenNthCalledWith(1, {
      where: { tokenHash: RefreshTokensService.hashToken('plain-to-revoke') },
    });
    expect(repo.findOne).toHaveBeenNthCalledWith(2, {
      where: { tokenHash: RefreshTokensService.hashToken('unknown-plain') },
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
});
