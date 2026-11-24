import { Logger } from '@nestjs/common';
import { DataSource, EntityManager } from 'typeorm';
import { Device } from './device.entity';
import { DevicesService } from './devices.service';
import { KeyBundle } from './key-bundle.entity';
import { OneTimePreKey } from './one-time-pre-key.entity';
import { ResetRosterService } from './reset-roster.service';
import { RefreshTokensService } from '../refresh-tokens/refresh-tokens.service';

/**
 * The §6.2 reset roster teardown (spec §12 amendments (f) and (xxviii)) —
 * falsification 12.
 *
 * The property under test is that recovery lands the account on a FRESH device
 * id with exactly one live device, and that nothing in the path can reach a
 * surviving device's material by accident.
 */
describe('ResetRosterService', () => {
  const USER_ID = 7;

  let devicesService: {
    allocateDeviceId: jest.Mock;
    revokeAllExcept: jest.Mock;
  };
  let refreshTokensService: {
    revokeAllForUser: jest.Mock;
    createToken: jest.Mock;
  };
  let deviceInsert: jest.Mock;
  let bundleUpdate: jest.Mock;
  let otpUpdate: jest.Mock;
  let authorizationQuery: jest.Mock;
  let manager: EntityManager;
  let dataSource: { transaction: jest.Mock };
  let service: ResetRosterService;
  let warnSpy: jest.SpyInstance;

  beforeEach(() => {
    devicesService = {
      allocateDeviceId: jest.fn().mockResolvedValue(4),
      revokeAllExcept: jest.fn().mockResolvedValue([1, 2]),
    };
    refreshTokensService = {
      revokeAllForUser: jest.fn().mockResolvedValue(undefined),
      createToken: jest.fn().mockResolvedValue('fresh-refresh'),
    };
    deviceInsert = jest.fn().mockResolvedValue({ identifiers: [] });
    bundleUpdate = jest.fn().mockResolvedValue({ affected: 1 });
    otpUpdate = jest.fn().mockResolvedValue({ affected: 0 });
    // The surviving enrollment row (xxix) leaves in place. Its version is the
    // one (xlv) clause 1 must advance past; an account that never enrolled
    // answers with no row at all, which the dedicated test below overrides.
    authorizationQuery = jest.fn().mockResolvedValue([{ listVersion: 7 }]);
    manager = {
      getRepository: jest.fn((entity: unknown) => {
        if (entity === Device) return { insert: deviceInsert };
        if (entity === KeyBundle) return { update: bundleUpdate };
        if (entity === OneTimePreKey) return { update: otpUpdate };
        throw new Error('unexpected repository request');
      }),
      query: authorizationQuery,
    } as unknown as EntityManager;
    dataSource = {
      transaction: jest.fn(async (cb: (m: EntityManager) => Promise<void>) =>
        cb(manager),
      ),
    };
    service = new ResetRosterService(
      dataSource as unknown as DataSource,
      devicesService as unknown as DevicesService,
      refreshTokensService as unknown as RefreshTokensService,
    );
    warnSpy = jest.spyOn(Logger.prototype, 'warn').mockImplementation();
  });

  afterEach(() => warnSpy.mockRestore());

  it('allocates a FRESH id and never re-mints device 1 ((f)(i))', async () => {
    const result = await service.applyAfterReset(USER_ID, 1);

    // Re-using id 1 would let the §5.3 legacy fallback serve the OLD device
    // 1's ciphertext to a device holding a brand-new identity — a
    // foreign-ratchet decrypt over the only copy of that plaintext.
    expect(devicesService.allocateDeviceId).toHaveBeenCalledWith(USER_ID);
    expect(result.deviceId).toBe(4);
    expect(deviceInsert).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: USER_ID,
        deviceId: 4,
        isPrimary: true,
      }),
    );
  });

  it('moves the uploaded material onto the new id, per namespace', async () => {
    await service.applyAfterReset(USER_ID, 1);

    expect(bundleUpdate).toHaveBeenCalledWith(
      { userId: USER_ID, deviceId: 1 },
      { deviceId: 4 },
    );
    expect(otpUpdate).toHaveBeenCalledWith(
      { userId: USER_ID, deviceId: 1 },
      { deviceId: 4 },
    );
  });

  it('revokes every OTHER device and reports which ((f)(ii), falsification 12)', async () => {
    const result = await service.applyAfterReset(USER_ID, 1);

    expect(devicesService.revokeAllExcept).toHaveBeenCalledWith(
      USER_ID,
      4,
      manager,
    );
    expect(result.revokedDeviceIds).toEqual([1, 2]);
  });

  it('drops every pre-reset session and issues one for the new id', async () => {
    const result = await service.applyAfterReset(USER_ID, 1);

    // BOTH inside the caller's transaction (amendment (xxviii)): a session
    // wipe that committed while the roster mutation rolled back would leave
    // the account signed out of an un-revoked roster, with the reset ceremony
    // already spent.
    expect(refreshTokensService.revokeAllForUser).toHaveBeenCalledWith(
      USER_ID,
      manager,
    );
    expect(refreshTokensService.createToken).toHaveBeenCalledWith(
      USER_ID,
      4,
      null,
      manager,
    );
    expect(result.refreshToken).toBe('fresh-refresh');
  });

  it('inserts the recovering row BEFORE revoking the rest, so the account is never device-less', async () => {
    await service.applyAfterReset(USER_ID, 1);

    expect(deviceInsert.mock.invocationCallOrder[0]).toBeLessThan(
      devicesService.revokeAllExcept.mock.invocationCallOrder[0],
    );
  });

  it('runs the roster half inside ONE transaction', async () => {
    await service.applyAfterReset(USER_ID, 1);

    expect(dataSource.transaction).toHaveBeenCalledTimes(1);
    // A half-applied teardown would leave either two live primaries or key
    // material stranded under a revoked id.
    expect(deviceInsert).toHaveBeenCalledTimes(1);
  });

  it('propagates a failure instead of reporting a recovery that did not happen', async () => {
    devicesService.revokeAllExcept.mockRejectedValue(new Error('pg down'));

    await expect(service.applyAfterReset(USER_ID, 1)).rejects.toThrow(
      'pg down',
    );
  });

  // --- (xlv) clause 1: the version the replacement enrollment must carry ---

  it('names the version AFTER the surviving enrollment, so the replacement advances', async () => {
    const result = await service.applyAfterReset(USER_ID, 1);

    // The row itself is left alone ((xxix)); only its version is borrowed. A
    // replacement at or below it is refused as `stale_version`, which would
    // leave the account addressable by nobody.
    expect(result.nextListVersion).toBe(8);
  });

  it('names version 1 when the account never enrolled', async () => {
    authorizationQuery.mockResolvedValue([]);

    // The majority shape: one device, never linked, therefore never enrolled.
    // Its replacement is a FIRST enrollment, and the server refuses a first
    // enrollment at any version but 1.
    expect((await service.applyAfterReset(USER_ID, 1)).nextListVersion).toBe(1);
  });
});
