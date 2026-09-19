import { Logger } from '@nestjs/common';
import { DataSource, EntityManager } from 'typeorm';
import { ChatDeviceRevocationService } from './chat-device-revocation.service';
import { DevicesService } from '../../key-bundles/devices.service';
import { KeyBundlesService } from '../../key-bundles/key-bundles.service';
import {
  DeviceListRejectedError,
  DeviceListService,
} from '../../key-bundles/device-list.service';
import { encodeCanonicalDeviceList } from '../../key-bundles/device-list-canonical.util';
import { ProvisioningStagesService } from '../../key-bundles/provisioning-stages.service';
import { RefreshTokensService } from '../../auth/refresh-tokens.service';
import { FcmTokensService } from '../../fcm-tokens/fcm-tokens.service';
import { WebPushSubscriptionsService } from '../../web-push-subscriptions/web-push-subscriptions.service';
import { Device } from '../../key-bundles/device.entity';

/**
 * Revocation's wire surface (Phase 2 T6, spec §5.5 + §12 amendments
 * (xxi)–(xxvi)).
 *
 * The signature law lives in `device-list.service.spec.ts`; this spec covers
 * revocation's own laws: the pre-write gauntlet (primary-only, never self,
 * never the primary, request-must-match-the-signed-bytes), the one-transaction
 * teardown, the post-commit ordering that may only run once the decision is
 * durable, and the stage preemption.
 */
describe('ChatDeviceRevocationService', () => {
  const USER_ID = 7;
  const ADDED_AT = 1755600000000;

  const deviceRow = (overrides: Partial<Device> = {}): Device =>
    ({
      userId: USER_ID,
      deviceId: 1,
      name: null,
      platform: 'android',
      isPrimary: true,
      addedAt: new Date(ADDED_AT),
      revokedAt: null,
      ...overrides,
    }) as Device;

  /** A v2 list whose device 2 entry carries `revokedAt` — what a revoke signs. */
  const revokingCanonical = (
    revokedDeviceId = 2,
    revokedAt = ADDED_AT + 5000,
  ) =>
    encodeCanonicalDeviceList({
      userId: USER_ID,
      version: 2,
      devices: [
        { deviceId: 1, platform: 'android', addedAt: ADDED_AT },
        {
          deviceId: 2,
          platform: 'web',
          addedAt: ADDED_AT + 1000,
          ...(revokedDeviceId === 2 ? { revokedAt } : {}),
        },
      ],
    }).toString('base64');

  /** A v2 list that changes nothing about device 2's liveness. */
  const nonRevokingCanonical = encodeCanonicalDeviceList({
    userId: USER_ID,
    version: 2,
    devices: [
      { deviceId: 1, platform: 'android', addedAt: ADDED_AT },
      { deviceId: 2, platform: 'web', addedAt: ADDED_AT + 1000 },
    ],
  }).toString('base64');

  let devicesService: { listForUser: jest.Mock; revoke: jest.Mock };
  let deviceListService: { applySignedListUpdate: jest.Mock };
  let keyBundlesService: { purgeDeviceMaterial: jest.Mock };
  let refreshTokensService: { revokeForDevice: jest.Mock };
  let fcmTokensService: { removeForDevice: jest.Mock };
  let webPushService: { removeForDevice: jest.Mock };
  let stages: ProvisioningStagesService;
  let manager: EntityManager;
  let dataSource: { transaction: jest.Mock };
  let service: ChatDeviceRevocationService;
  let server: { to: jest.Mock; sockets: unknown };
  let roomEmit: jest.Mock;
  let kickedSocket: { id: string; disconnect: jest.Mock };
  let warnSpy: jest.SpyInstance;
  let errorSpy: jest.SpyInstance;

  interface MockClient {
    id: string;
    data: { user: { id: number; deviceId: number } };
    emit: jest.Mock;
  }

  const makeClient = (deviceId = 1): MockClient => ({
    id: 'caller-socket',
    data: { user: { id: USER_ID, deviceId } },
    emit: jest.fn(),
  });

  const lastEmit = (
    client: { emit: jest.Mock },
    event: string,
  ): Record<string, unknown> | undefined => {
    const calls = client.emit.mock.calls.filter(([name]) => name === event);
    const last = calls[calls.length - 1] as
      [string, Record<string, unknown>] | undefined;
    return last?.[1];
  };

  const validRequest = () => ({
    deviceId: 2,
    listCanonical: revokingCanonical(),
    listSignature: 'dak-sig',
  });

  beforeEach(() => {
    devicesService = {
      listForUser: jest
        .fn()
        .mockResolvedValue([
          deviceRow(),
          deviceRow({ deviceId: 2, isPrimary: false, platform: 'web' }),
        ]),
      revoke: jest.fn().mockResolvedValue(true),
    };
    deviceListService = {
      applySignedListUpdate: jest.fn().mockResolvedValue(2),
    };
    keyBundlesService = { purgeDeviceMaterial: jest.fn() };
    refreshTokensService = { revokeForDevice: jest.fn().mockResolvedValue(1) };
    fcmTokensService = { removeForDevice: jest.fn() };
    webPushService = { removeForDevice: jest.fn() };
    stages = new ProvisioningStagesService();
    manager = { getRepository: jest.fn() } as unknown as EntityManager;
    dataSource = {
      transaction: jest.fn(async (cb: (m: EntityManager) => Promise<void>) =>
        cb(manager),
      ),
    };
    roomEmit = jest.fn();
    kickedSocket = { id: 'revoked-socket', disconnect: jest.fn() };
    server = {
      to: jest.fn().mockReturnValue({ emit: roomEmit }),
      sockets: {
        adapter: {
          rooms: new Map([['device:7:2', new Set(['revoked-socket'])]]),
        },
        sockets: new Map([['revoked-socket', kickedSocket]]),
      },
    };
    service = new ChatDeviceRevocationService(
      dataSource as unknown as DataSource,
      deviceListService as unknown as DeviceListService,
      devicesService as unknown as DevicesService,
      keyBundlesService as unknown as KeyBundlesService,
      refreshTokensService as unknown as RefreshTokensService,
      stages,
      fcmTokensService as unknown as FcmTokensService,
      webPushService as unknown as WebPushSubscriptionsService,
    );
    warnSpy = jest.spyOn(Logger.prototype, 'warn').mockImplementation();
    errorSpy = jest.spyOn(Logger.prototype, 'error').mockImplementation();
  });

  afterEach(() => {
    warnSpy.mockRestore();
    errorSpy.mockRestore();
    stages.onModuleDestroy();
  });

  const run = async (client: MockClient, body: unknown = validRequest()) => {
    await service.handleRevokeDevice(client as never, body, server as never);
  };

  describe('pre-write gauntlet (amendment (xxi)) — nothing is written', () => {
    it('refuses revoking the caller itself', async () => {
      const client = makeClient(2);
      await run(client, { ...validRequest(), deviceId: 2 });

      expect(lastEmit(client, 'deviceRevocationCompleted')).toEqual({
        success: false,
        error: 'cannot_revoke_self',
      });
      expect(dataSource.transaction).not.toHaveBeenCalled();
      expect(devicesService.revoke).not.toHaveBeenCalled();
    });

    it('refuses a caller that is not the primary', async () => {
      devicesService.listForUser.mockResolvedValue([
        deviceRow(),
        deviceRow({ deviceId: 2, isPrimary: false }),
        deviceRow({ deviceId: 3, isPrimary: false }),
      ]);
      const client = makeClient(3);
      await run(client);

      expect(lastEmit(client, 'deviceRevocationCompleted')).toEqual({
        success: false,
        error: 'not_primary',
      });
      expect(dataSource.transaction).not.toHaveBeenCalled();
    });

    it('refuses revoking the primary — it is the only DAK holder (§3)', async () => {
      // A device flagged primary is refused as a TARGET; the caller here is
      // itself primary, so the request reaches the target check.
      devicesService.listForUser.mockResolvedValue([
        deviceRow({ deviceId: 1, isPrimary: true }),
        deviceRow({ deviceId: 2, isPrimary: true, platform: 'web' }),
      ]);
      const client = makeClient(1);
      await run(client);

      expect(lastEmit(client, 'deviceRevocationCompleted')).toEqual({
        success: false,
        error: 'cannot_revoke_primary',
      });
      expect(dataSource.transaction).not.toHaveBeenCalled();
    });

    it('refuses an unknown device', async () => {
      devicesService.listForUser.mockResolvedValue([deviceRow()]);
      const client = makeClient(1);
      await run(client);

      expect(lastEmit(client, 'deviceRevocationCompleted')).toEqual({
        success: false,
        error: 'unknown_device',
      });
    });

    it('refuses a device already revoked', async () => {
      devicesService.listForUser.mockResolvedValue([
        deviceRow(),
        deviceRow({
          deviceId: 2,
          isPrimary: false,
          revokedAt: new Date(ADDED_AT + 10),
        }),
      ]);
      const client = makeClient(1);
      await run(client);

      expect(lastEmit(client, 'deviceRevocationCompleted')).toEqual({
        success: false,
        error: 'already_revoked',
      });
      expect(dataSource.transaction).not.toHaveBeenCalled();
    });

    it('refuses when the SIGNED bytes do not revoke the requested device', async () => {
      const client = makeClient(1);
      await run(client, {
        deviceId: 2,
        listCanonical: nonRevokingCanonical,
        listSignature: 'dak-sig',
      });

      expect(lastEmit(client, 'deviceRevocationCompleted')).toEqual({
        success: false,
        error: 'list_device_mismatch',
      });
      expect(dataSource.transaction).not.toHaveBeenCalled();
    });

    it('refuses unparseable canonical bytes without throwing', async () => {
      const client = makeClient(1);
      await run(client, {
        deviceId: 2,
        listCanonical: Buffer.from('{"not":"a list"}').toString('base64'),
        listSignature: 'dak-sig',
      });

      expect(lastEmit(client, 'deviceRevocationCompleted')).toEqual({
        success: false,
        error: 'invalid_canonical',
      });
    });

    it('treats device 1 with NO row as the primary (§8 legacy accounts)', async () => {
      devicesService.listForUser.mockResolvedValue([
        deviceRow({ deviceId: 2, isPrimary: false, platform: 'web' }),
      ]);
      const client = makeClient(1);
      await run(client);

      expect(lastEmit(client, 'deviceRevocationCompleted')).toMatchObject({
        success: true,
      });
    });
  });

  describe('the durable half is ONE transaction', () => {
    it('stamps, mutates the list, drops sessions and purges material with the SAME manager', async () => {
      const client = makeClient(1);
      await run(client);

      expect(dataSource.transaction).toHaveBeenCalledTimes(1);
      expect(devicesService.revoke).toHaveBeenCalledWith(USER_ID, 2, manager);
      expect(deviceListService.applySignedListUpdate).toHaveBeenCalledWith(
        USER_ID,
        { listCanonical: revokingCanonical(), listSignature: 'dak-sig' },
        manager,
      );
      expect(refreshTokensService.revokeForDevice).toHaveBeenCalledWith(
        USER_ID,
        2,
        manager,
      );
      expect(keyBundlesService.purgeDeviceMaterial).toHaveBeenCalledWith(
        USER_ID,
        2,
        manager,
      );
      expect(lastEmit(client, 'deviceRevocationCompleted')).toEqual({
        success: true,
        deviceId: 2,
        listVersion: 2,
      });
    });

    it('stamps BEFORE mutating the list, so a racing duplicate loses on the stamp', async () => {
      const client = makeClient(1);
      await run(client);

      expect(devicesService.revoke.mock.invocationCallOrder[0]).toBeLessThan(
        deviceListService.applySignedListUpdate.mock.invocationCallOrder[0],
      );
    });

    it('answers already_revoked when the stamp affected no row (concurrent revoke)', async () => {
      devicesService.revoke.mockResolvedValue(false);
      const client = makeClient(1);
      await run(client);

      expect(lastEmit(client, 'deviceRevocationCompleted')).toEqual({
        success: false,
        error: 'already_revoked',
      });
      expect(deviceListService.applySignedListUpdate).not.toHaveBeenCalled();
    });

    it('surfaces a refused list mutation by its own code and tears nothing down', async () => {
      deviceListService.applySignedListUpdate.mockRejectedValue(
        new DeviceListRejectedError('stale_version'),
      );
      const client = makeClient(1);
      await run(client);

      expect(lastEmit(client, 'deviceRevocationCompleted')).toEqual({
        success: false,
        error: 'stale_version',
      });
      // Post-commit teardown must not run for a rolled-back revocation.
      expect(fcmTokensService.removeForDevice).not.toHaveBeenCalled();
      expect(webPushService.removeForDevice).not.toHaveBeenCalled();
      expect(kickedSocket.disconnect).not.toHaveBeenCalled();
    });
  });

  describe('post-commit teardown', () => {
    it('deletes the revoked device push rows, preempts stages, tells then kicks', async () => {
      const stage = stages.open(USER_ID, 'some-socket', 3);
      const client = makeClient(1);
      await run(client);

      expect(fcmTokensService.removeForDevice).toHaveBeenCalledWith(USER_ID, 2);
      expect(webPushService.removeForDevice).toHaveBeenCalledWith(USER_ID, 2);
      // Amendment (xxv): account-wide, even though this stage holds device 3.
      expect(stages.get(stage.provisioningId)).toBeNull();
      expect(roomEmit).toHaveBeenCalledWith('deviceRevoked', {
        userId: USER_ID,
        deviceId: 2,
      });
      expect(server.to).toHaveBeenCalledWith('device:7:2');
      expect(kickedSocket.disconnect).toHaveBeenCalledTimes(1);
      expect(roomEmit).toHaveBeenCalledWith('deviceListChanged', {
        userId: USER_ID,
        listVersion: 2,
      });
    });

    it('tells the device BEFORE disconnecting it (amendment (xxvi))', async () => {
      const client = makeClient(1);
      await run(client);

      const noticeOrder = roomEmit.mock.calls.findIndex(
        ([event]) => event === 'deviceRevoked',
      );
      expect(noticeOrder).toBeGreaterThanOrEqual(0);
      expect(roomEmit.mock.invocationCallOrder[noticeOrder]).toBeLessThan(
        kickedSocket.disconnect.mock.invocationCallOrder[0],
      );
    });

    it('still reports success when the push teardown fails, and says so loudly', async () => {
      webPushService.removeForDevice.mockRejectedValue(new Error('pg down'));
      const client = makeClient(1);
      await run(client);

      expect(lastEmit(client, 'deviceRevocationCompleted')).toMatchObject({
        success: true,
      });
      expect(errorSpy).toHaveBeenCalledWith(
        expect.stringContaining('push teardown FAILED'),
      );
      // The revocation is durable, so the kick must still happen.
      expect(kickedSocket.disconnect).toHaveBeenCalledTimes(1);
    });
  });

  it('ignores an unauthenticated socket without emitting', async () => {
    const client = { id: 's', data: {}, emit: jest.fn() };
    await service.handleRevokeDevice(
      client as never,
      validRequest(),
      server as never,
    );

    expect(client.emit).not.toHaveBeenCalled();
    expect(dataSource.transaction).not.toHaveBeenCalled();
  });
});
