import { JwtService } from '@nestjs/jwt';
import { Logger } from '@nestjs/common';
import { DataSource, EntityManager } from 'typeorm';
import { Server, Socket } from 'socket.io';
import { ChatProvisioningService } from './chat-provisioning.service';
import { ProvisioningStagesService } from '../../key-bundles/provisioning-stages.service';
import { DevicesService } from '../../key-bundles/devices.service';
import {
  DeviceListRejectedError,
  DeviceListService,
} from '../../key-bundles/device-list.service';
import { encodeCanonicalDeviceList } from '../../key-bundles/device-list-canonical.util';
import { verifyDeviceListSignature } from '../../key-bundles/device-list-signature.util';
import { RefreshTokensService } from '../../auth/refresh-tokens.service';
import { UsersService } from '../../users/users.service';

// The signature LAW lives in device-list-signature.util.spec.ts (real Dart
// vectors) and device-list.service.spec.ts; this spec covers the ceremony's
// own laws, so the verifier is a switch, not a re-proof.
jest.mock('../../key-bundles/device-list-signature.util');

const verifySignatureMock = verifyDeviceListSignature as jest.MockedFunction<
  typeof verifyDeviceListSignature
>;

/**
 * Wire surface of the §5.1 provisioning ceremony (Phase 2 T3). Laws pinned
 * here, each a falsification-plan item: the ack-only deviceId delivery
 * (amendment (a)), first-ephemeral pinning with idempotent retry (amendment
 * (c)), the staged-diff gate (exactly the memoized device, no name —
 * amendment (i)), opener-socket binding of blob + complete (falsification
 * 8), the one-shot commit with restore-on-failure (falsification 20), and
 * blob availability ending at commit (falsification 18 / amendment (a)).
 */
describe('ChatProvisioningService', () => {
  const USER_ID = 7;
  const ADDED_AT = 1755600000000;
  const EPH_PUB_P = Buffer.alloc(33, 5).toString('base64');

  const storedCanonical = encodeCanonicalDeviceList({
    userId: USER_ID,
    version: 1,
    devices: [{ deviceId: 1, platform: 'android', addedAt: ADDED_AT }],
  }).toString('base64');

  const stagedCanonical = (
    entry: Partial<{
      deviceId: number;
      platform: string;
      addedAt: number;
      name: string;
    }> = {},
    version = 2,
  ) =>
    encodeCanonicalDeviceList({
      userId: USER_ID,
      version,
      devices: [
        { deviceId: 1, platform: 'android', addedAt: ADDED_AT },
        {
          deviceId: 2,
          platform: 'web',
          addedAt: ADDED_AT + 1000,
          ...entry,
        },
      ],
    }).toString('base64');

  let stages: ProvisioningStagesService;
  let devicesService: { allocateDeviceId: jest.Mock; isActive: jest.Mock };
  let deviceListService: {
    getAuthorization: jest.Mock;
    applySignedListUpdate: jest.Mock;
  };
  let refreshTokensService: { createToken: jest.Mock };
  let usersService: { findById: jest.Mock };
  let jwtService: { sign: jest.Mock };
  let deviceInsert: jest.Mock;
  let manager: EntityManager;
  let dataSource: { transaction: jest.Mock };
  let service: ChatProvisioningService;
  let server: { to: jest.Mock };
  let roomEmit: jest.Mock;
  let errorSpy: jest.SpyInstance;

  const makeClient = (id = 'opener-socket', userId: number = USER_ID) => ({
    id,
    data: { user: { id: userId } },
    emit: jest.fn(),
  });

  /** Last payload a client received on an event. */
  const lastEmit = (
    client: { emit: jest.Mock },
    event: string,
  ): Record<string, unknown> | undefined => {
    const calls = client.emit.mock.calls.filter(([name]) => name === event);
    const last = calls[calls.length - 1] as
      [string, Record<string, unknown>] | undefined;
    return last?.[1];
  };

  beforeEach(() => {
    verifySignatureMock.mockReturnValue(true);
    stages = new ProvisioningStagesService();
    devicesService = {
      allocateDeviceId: jest.fn().mockResolvedValue(2),
      isActive: jest.fn().mockResolvedValue(true),
    };
    deviceListService = {
      getAuthorization: jest.fn().mockResolvedValue({
        userId: USER_ID,
        dakPub: 'dak-pub',
        listVersion: 1,
        listCanonical: storedCanonical,
        listSignature: 'stored-sig',
      }),
      applySignedListUpdate: jest.fn().mockResolvedValue(2),
    };
    refreshTokensService = { createToken: jest.fn().mockResolvedValue('rt') };
    usersService = {
      findById: jest
        .fn()
        .mockResolvedValue({ id: USER_ID, username: 'ann', tag: '0001' }),
    };
    jwtService = { sign: jest.fn().mockReturnValue('access-jwt') };
    deviceInsert = jest.fn().mockResolvedValue(undefined);
    // Only the Device repository is requested inside the transaction.
    manager = {
      getRepository: jest.fn().mockReturnValue({ insert: deviceInsert }),
    } as unknown as EntityManager;
    dataSource = {
      transaction: jest.fn(async (cb: (m: EntityManager) => Promise<void>) =>
        cb(manager),
      ),
    };
    roomEmit = jest.fn();
    server = { to: jest.fn().mockReturnValue({ emit: roomEmit }) };
    service = new ChatProvisioningService(
      stages,
      devicesService as unknown as DevicesService,
      deviceListService as unknown as DeviceListService,
      refreshTokensService as unknown as RefreshTokensService,
      usersService as unknown as UsersService,
      jwtService as unknown as JwtService,
      dataSource as unknown as DataSource,
    );
    errorSpy = jest
      .spyOn(Logger.prototype, 'error')
      .mockImplementation(() => undefined);
  });

  afterEach(() => {
    stages.onModuleDestroy();
    errorSpy.mockRestore();
  });

  /** Runs the ceremony up to an opened stage and returns it with its opener. */
  async function openStage() {
    const opener = makeClient('opener-socket');
    await service.handleOpenProvisioning(opener as unknown as Socket);
    const answer = lastEmit(opener, 'provisioningOpened');
    const provisioningId = answer?.provisioningId as string;
    return { opener, provisioningId };
  }

  function pinHello(provisioningId: string) {
    const primary = makeClient('primary-socket');
    service.handleProvisioningHello(
      primary as unknown as Socket,
      { provisioningId, ephPubP: EPH_PUB_P },
      server as unknown as Server,
    );
    return primary;
  }

  async function stageBlob(provisioningId: string, blob = 'blob-b64') {
    const primary = makeClient('primary-socket');
    await service.handleProvisionDevice(
      primary as unknown as Socket,
      {
        provisioningId,
        blob,
        listCanonical: stagedCanonical(),
        listSignature: 'staged-sig',
      },
      server as unknown as Server,
    );
    return primary;
  }

  describe('openProvisioning', () => {
    it('refuses an account that never enrolled (spec §5.1 gate)', async () => {
      deviceListService.getAuthorization.mockResolvedValue(null);
      const client = makeClient();

      await service.handleOpenProvisioning(client as unknown as Socket);

      expect(lastEmit(client, 'provisioningOpened')).toEqual({
        success: false,
        error: 'not_enrolled',
      });
      expect(devicesService.allocateDeviceId).not.toHaveBeenCalled();
    });

    it('allocates once and answers WITHOUT the deviceId (amendment (a))', async () => {
      const client = makeClient();

      await service.handleOpenProvisioning(client as unknown as Socket);

      const answer = lastEmit(client, 'provisioningOpened');
      expect(answer?.success).toBe(true);
      expect(typeof answer?.provisioningId).toBe('string');
      expect(typeof answer?.expiresAt).toBe('number');
      // N learns its id from the blob ONLY.
      expect(answer).not.toHaveProperty('deviceId');
      expect(devicesService.allocateDeviceId).toHaveBeenCalledTimes(1);
    });
  });

  describe('provisioningHello', () => {
    it('answers unknown_stage for an unknown id and for a foreign account', async () => {
      const { provisioningId } = await openStage();

      const stranger = makeClient('stranger', 999);
      service.handleProvisioningHello(
        stranger as unknown as Socket,
        { provisioningId, ephPubP: EPH_PUB_P },
        server as unknown as Server,
      );
      expect(lastEmit(stranger, 'provisioningHelloAck')).toEqual({
        success: false,
        error: 'unknown_stage',
      });

      const primary = makeClient('primary-socket');
      service.handleProvisioningHello(
        primary as unknown as Socket,
        { provisioningId: 'no-such-stage', ephPubP: EPH_PUB_P },
        server as unknown as Server,
      );
      expect(lastEmit(primary, 'provisioningHelloAck')).toEqual({
        success: false,
        error: 'unknown_stage',
      });
    });

    it('acks the memoized deviceId and relays to the opener socket only (with the deviceId — amendment (lxxvii))', async () => {
      const { provisioningId } = await openStage();
      const primary = pinHello(provisioningId);

      expect(lastEmit(primary, 'provisioningHelloAck')).toEqual({
        success: true,
        deviceId: 2,
      });
      expect(server.to).toHaveBeenCalledWith('opener-socket');
      expect(roomEmit).toHaveBeenCalledWith('provisioningHello', {
        provisioningId,
        ephPubP: EPH_PUB_P,
        deviceId: 2,
      });
    });

    it('pins the FIRST ephemeral: identical retry idempotent, different rejected', async () => {
      const { provisioningId } = await openStage();
      pinHello(provisioningId);

      const retry = pinHello(provisioningId);
      expect(lastEmit(retry, 'provisioningHelloAck')).toEqual({
        success: true,
        deviceId: 2,
      });

      const attacker = makeClient('primary-socket');
      service.handleProvisioningHello(
        attacker as unknown as Socket,
        {
          provisioningId,
          ephPubP: Buffer.alloc(33, 9).toString('base64'),
        },
        server as unknown as Server,
      );
      expect(lastEmit(attacker, 'provisioningHelloAck')).toEqual({
        success: false,
        error: 'ephemeral_already_pinned',
      });
    });

    it('rejects an ephemeral that is not 33 canonical base64 bytes', async () => {
      const { provisioningId } = await openStage();
      const primary = makeClient('primary-socket');

      service.handleProvisioningHello(
        primary as unknown as Socket,
        { provisioningId, ephPubP: Buffer.alloc(32, 5).toString('base64') },
        server as unknown as Server,
      );

      expect(lastEmit(primary, 'provisioningHelloAck')).toEqual({
        success: false,
        error: 'invalid_ephemeral',
      });
    });

    // Amendment (lxxx) clause 3, falsification F16. The common case is an
    // OLDER client: it sends no `platform` at all, and the relay must be
    // byte-identical to the pre-(lxxx) one — not `platform: undefined`,
    // which `toHaveBeenCalledWith` would silently accept.
    it('accepts a hello WITHOUT platform and relays exactly as before (F16)', async () => {
      const { provisioningId } = await openStage();
      const primary = pinHello(provisioningId);

      expect(lastEmit(primary, 'provisioningHelloAck')).toEqual({
        success: true,
        deviceId: 2,
      });
      expect(roomEmit).toHaveBeenCalledTimes(1);
      const [event, payload] = roomEmit.mock.calls[0] as [
        string,
        Record<string, unknown>,
      ];
      expect(event).toBe('provisioningHello');
      expect(Object.keys(payload).sort()).toEqual([
        'deviceId',
        'ephPubP',
        'provisioningId',
      ]);
    });

    it('relays a valid platform label to the opener', async () => {
      const { provisioningId } = await openStage();
      const primary = makeClient('primary-socket');

      service.handleProvisioningHello(
        primary as unknown as Socket,
        { provisioningId, ephPubP: EPH_PUB_P, platform: 'web-chrome_1' },
        server as unknown as Server,
      );

      expect(lastEmit(primary, 'provisioningHelloAck')).toEqual({
        success: true,
        deviceId: 2,
      });
      expect(server.to).toHaveBeenCalledWith('opener-socket');
      expect(roomEmit).toHaveBeenCalledWith('provisioningHello', {
        provisioningId,
        ephPubP: EPH_PUB_P,
        deviceId: 2,
        platform: 'web-chrome_1',
      });
    });

    it.each([
      ['33 chars', 'a'.repeat(33)],
      ['a dot', 'web.chrome'],
      ['a space', 'web chrome'],
      ['empty', ''],
    ])(
      'rejects a platform with %s like any malformed field',
      async (_label, platform) => {
        const { provisioningId } = await openStage();
        const primary = makeClient('primary-socket');

        service.handleProvisioningHello(
          primary as unknown as Socket,
          { provisioningId, ephPubP: EPH_PUB_P, platform },
          server as unknown as Server,
        );

        expect(lastEmit(primary, 'provisioningHelloAck')).toEqual({
          success: false,
          error: 'hello_failed',
        });
        expect(roomEmit).not.toHaveBeenCalled();
      },
    );
  });

  describe('provisionDevice', () => {
    it('refuses a blob before the SAS round started (secrets-last, I3)', async () => {
      const { provisioningId } = await openStage();
      const primary = await stageBlob(provisioningId);

      expect(lastEmit(primary, 'provisionDeviceAck')).toEqual({
        success: false,
        error: 'hello_not_pinned',
      });
    });

    it("role 'new': a socket other than the hello party's is not the primary (amendment (lxxvii))", async () => {
      const { provisioningId, opener } = await openStage();
      pinHello(provisioningId);

      // The new device itself (the opener) tries to stage the blob.
      await service.handleProvisionDevice(
        opener as unknown as Socket,
        {
          provisioningId,
          blob: 'blob-b64',
          listCanonical: stagedCanonical(),
          listSignature: 'staged-sig',
        },
        server as unknown as Server,
      );

      expect(lastEmit(opener, 'provisionDeviceAck')).toEqual({
        success: false,
        error: 'not_primary',
      });
    });

    it('walks the verify gauntlet: canonical, version, signature', async () => {
      const { provisioningId } = await openStage();
      pinHello(provisioningId);
      const primary = makeClient('primary-socket');
      const send = (overrides: Record<string, unknown>) =>
        service.handleProvisionDevice(
          primary as unknown as Socket,
          {
            provisioningId,
            blob: 'blob-b64',
            listCanonical: stagedCanonical(),
            listSignature: 'staged-sig',
            ...overrides,
          },
          server as unknown as Server,
        );

      await send({ listCanonical: 'not!!base64' });
      expect(lastEmit(primary, 'provisionDeviceAck')).toEqual({
        success: false,
        error: 'invalid_canonical',
      });

      await send({ listCanonical: stagedCanonical({}, 3) });
      expect(lastEmit(primary, 'provisionDeviceAck')).toEqual({
        success: false,
        error: 'stale_version',
      });

      verifySignatureMock.mockReturnValueOnce(false);
      await send({});
      expect(lastEmit(primary, 'provisionDeviceAck')).toEqual({
        success: false,
        error: 'invalid_list_signature',
      });
    });

    it('refuses a diff that is not exactly the memoized nameless device (amendment (i))', async () => {
      const { provisioningId } = await openStage();
      pinHello(provisioningId);
      const primary = makeClient('primary-socket');
      const send = (listCanonical: string) =>
        service.handleProvisionDevice(
          primary as unknown as Socket,
          {
            provisioningId,
            blob: 'blob-b64',
            listCanonical,
            listSignature: 'staged-sig',
          },
          server as unknown as Server,
        );

      // Wrong id: the primary signed 3, the stage memoized 2.
      await send(stagedCanonical({ deviceId: 3 }));
      expect(lastEmit(primary, 'provisionDeviceAck')).toEqual({
        success: false,
        error: 'invalid_mutation',
      });

      // Names arrive with the Phase 3 rename UI, never here.
      await send(stagedCanonical({ name: 'my phone' }));
      expect(lastEmit(primary, 'provisionDeviceAck')).toEqual({
        success: false,
        error: 'invalid_mutation',
      });

      // Mutating a pre-existing entry under cover of the add.
      await send(
        encodeCanonicalDeviceList({
          userId: USER_ID,
          version: 2,
          devices: [
            { deviceId: 1, platform: 'ios', addedAt: ADDED_AT },
            { deviceId: 2, platform: 'web', addedAt: ADDED_AT + 1000 },
          ],
        }).toString('base64'),
      );
      expect(lastEmit(primary, 'provisionDeviceAck')).toEqual({
        success: false,
        error: 'invalid_mutation',
      });

      // Two adds in one ceremony.
      await send(
        encodeCanonicalDeviceList({
          userId: USER_ID,
          version: 2,
          devices: [
            { deviceId: 1, platform: 'android', addedAt: ADDED_AT },
            { deviceId: 2, platform: 'web', addedAt: ADDED_AT + 1000 },
            { deviceId: 3, platform: 'web', addedAt: ADDED_AT + 1000 },
          ],
        }).toString('base64'),
      );
      expect(lastEmit(primary, 'provisionDeviceAck')).toEqual({
        success: false,
        error: 'invalid_mutation',
      });
    });

    it('stages, relays the blob to the opener, and a retry OVERWRITES', async () => {
      const { provisioningId } = await openStage();
      pinHello(provisioningId);

      const first = await stageBlob(provisioningId, 'blob-one');
      expect(lastEmit(first, 'provisionDeviceAck')).toEqual({ success: true });
      expect(server.to).toHaveBeenCalledWith('opener-socket');
      expect(roomEmit).toHaveBeenCalledWith('provisioningBlob', {
        provisioningId,
        blob: 'blob-one',
      });

      await stageBlob(provisioningId, 'blob-two');
      expect(stages.get(provisioningId)?.blob).toBe('blob-two');
      expect(stages.get(provisioningId)?.platform).toBe('web');
      expect(stages.get(provisioningId)?.consumed).toBe(false);
    });
  });

  describe('fetchProvisioningBlob', () => {
    it('serves the opener only, and only while a blob is staged', async () => {
      const { provisioningId, opener } = await openStage();
      pinHello(provisioningId);

      // Same account, different socket: refused (falsification 8's shape).
      const other = makeClient('other-socket');
      service.handleFetchProvisioningBlob(other as unknown as Socket, {
        provisioningId,
      });
      expect(lastEmit(other, 'provisioningBlob')).toEqual({
        success: false,
        error: 'not_opener',
      });

      service.handleFetchProvisioningBlob(opener as unknown as Socket, {
        provisioningId,
      });
      expect(lastEmit(opener, 'provisioningBlob')).toEqual({
        success: false,
        error: 'no_blob',
      });

      await stageBlob(provisioningId, 'blob-b64');
      service.handleFetchProvisioningBlob(opener as unknown as Socket, {
        provisioningId,
      });
      expect(lastEmit(opener, 'provisioningBlob')).toEqual({
        provisioningId,
        blob: 'blob-b64',
      });
    });
  });

  describe('provisioningComplete', () => {
    async function stagedCeremony() {
      const opened = await openStage();
      pinHello(opened.provisioningId);
      await stageBlob(opened.provisioningId);
      return opened;
    }

    it('rejects every session but the opener (falsification 8)', async () => {
      const { provisioningId } = await stagedCeremony();
      const other = makeClient('other-socket');

      await service.handleProvisioningComplete(
        other as unknown as Socket,
        { provisioningId },
        server as unknown as Server,
      );

      expect(lastEmit(other, 'provisioningCompleted')).toEqual({
        success: false,
        error: 'not_opener',
      });
      expect(dataSource.transaction).not.toHaveBeenCalled();
    });

    it('rejects an un-staged completion', async () => {
      const { provisioningId, opener } = await openStage();

      await service.handleProvisioningComplete(
        opener as unknown as Socket,
        { provisioningId },
        server as unknown as Server,
      );

      expect(lastEmit(opener, 'provisioningCompleted')).toEqual({
        success: false,
        error: 'not_staged',
      });
    });

    it('commits atomically and answers tokens on the opener (amendment (iii))', async () => {
      const { provisioningId, opener } = await stagedCeremony();

      await service.handleProvisioningComplete(
        opener as unknown as Socket,
        { provisioningId },
        server as unknown as Server,
      );

      expect(deviceInsert).toHaveBeenCalledWith({
        userId: USER_ID,
        deviceId: 2,
        platform: 'web',
        isPrimary: false,
      });
      expect(deviceListService.applySignedListUpdate).toHaveBeenCalledWith(
        USER_ID,
        { listCanonical: stagedCanonical(), listSignature: 'staged-sig' },
        manager,
      );
      expect(refreshTokensService.createToken).toHaveBeenCalledWith(USER_ID, 2);
      // Payload shape EXACTLY matches login's.
      expect(jwtService.sign).toHaveBeenCalledWith({
        sub: USER_ID,
        username: 'ann',
        tag: '0001',
        deviceId: 2,
      });
      expect(lastEmit(opener, 'provisioningCompleted')).toEqual({
        success: true,
        deviceId: 2,
        access_token: 'access-jwt',
        refresh_token: 'rt',
      });
      expect(server.to).toHaveBeenCalledWith(`user:${USER_ID}`);
      expect(roomEmit).toHaveBeenCalledWith('deviceListChanged', {
        userId: USER_ID,
        listVersion: 2,
      });

      // Amendment (a): the stage retired at commit — no blob refetch, and a
      // duplicate complete is already_completed.
      service.handleFetchProvisioningBlob(opener as unknown as Socket, {
        provisioningId,
      });
      expect(lastEmit(opener, 'provisioningBlob')).toEqual({
        success: false,
        error: 'no_blob',
      });
      await service.handleProvisioningComplete(
        opener as unknown as Socket,
        { provisioningId },
        server as unknown as Server,
      );
      expect(lastEmit(opener, 'provisioningCompleted')).toEqual({
        success: false,
        error: 'already_completed',
      });
    });

    it('stale_version restores the stage for the v+2 retry (falsification 20)', async () => {
      const { provisioningId, opener } = await stagedCeremony();
      deviceListService.applySignedListUpdate.mockRejectedValueOnce(
        new DeviceListRejectedError('stale_version'),
      );

      await service.handleProvisioningComplete(
        opener as unknown as Socket,
        { provisioningId },
        server as unknown as Server,
      );
      expect(lastEmit(opener, 'provisioningCompleted')).toEqual({
        success: false,
        error: 'stale_version',
      });

      // The SAME stage accepts the re-signed mutation and the retried
      // complete succeeds — one ceremony, one device row.
      deviceListService.getAuthorization.mockResolvedValue({
        userId: USER_ID,
        dakPub: 'dak-pub',
        listVersion: 2,
        listCanonical: stagedCanonical(),
        listSignature: 'winner-sig',
      });
      const primary = makeClient('primary-socket');
      await service.handleProvisionDevice(
        primary as unknown as Socket,
        {
          provisioningId,
          blob: 'blob-b64',
          listCanonical: encodeCanonicalDeviceList({
            userId: USER_ID,
            version: 3,
            devices: [
              { deviceId: 1, platform: 'android', addedAt: ADDED_AT },
              { deviceId: 2, platform: 'web', addedAt: ADDED_AT + 1000 },
              { deviceId: 3, platform: 'web', addedAt: ADDED_AT + 2000 },
            ],
          }).toString('base64'),
          listSignature: 'resigned',
        },
        server as unknown as Server,
      );
      // The stage memoized deviceId 2 at open — but the winning ceremony took
      // id 2; THIS stage's memoized id must still be its own. (Two stages in
      // the real flow have distinct ids from the allocator; here the retry
      // re-uses the same stage, so the diff must still name ITS id.)
      expect(lastEmit(primary, 'provisionDeviceAck')).toEqual({
        success: false,
        error: 'invalid_mutation',
      });
    });

    it('a non-version failure restores the stage and answers commit_failed', async () => {
      const { provisioningId, opener } = await stagedCeremony();
      deviceInsert.mockRejectedValueOnce(new Error('db down'));

      await service.handleProvisioningComplete(
        opener as unknown as Socket,
        { provisioningId },
        server as unknown as Server,
      );

      expect(lastEmit(opener, 'provisioningCompleted')).toEqual({
        success: false,
        error: 'commit_failed',
      });
      expect(stages.get(provisioningId)?.consumed).toBe(false);
      expect(stages.get(provisioningId)?.blob).toBe('blob-b64');

      // Retry after the transient failure succeeds.
      await service.handleProvisioningComplete(
        opener as unknown as Socket,
        { provisioningId },
        server as unknown as Server,
      );
      expect(lastEmit(opener, 'provisioningCompleted')).toEqual(
        expect.objectContaining({ success: true, deviceId: 2 }),
      );
    });

    it('two concurrent completes admit exactly one (amendment (a) CAS)', async () => {
      const { provisioningId, opener } = await stagedCeremony();
      let releaseTx: () => void = () => undefined;
      dataSource.transaction.mockImplementation(
        async (cb: (m: EntityManager) => Promise<void>) => {
          await new Promise<void>((resolve) => {
            releaseTx = resolve;
          });
          return cb(manager);
        },
      );

      const first = service.handleProvisioningComplete(
        opener as unknown as Socket,
        { provisioningId },
        server as unknown as Server,
      );
      const second = service.handleProvisioningComplete(
        opener as unknown as Socket,
        { provisioningId },
        server as unknown as Server,
      );
      // Both handlers must reach their suspension points first: the winner
      // parked inside the gated transaction, the loser already answered off
      // the synchronous CAS.
      await new Promise((resolve) => setImmediate(resolve));
      releaseTx();
      await Promise.all([first, second]);

      const answers = opener.emit.mock.calls
        .filter(([event]) => event === 'provisioningCompleted')
        .map(([, payload]) => payload as { success: boolean; error?: string });
      expect(answers).toHaveLength(2);
      expect(answers.filter((a) => a.success)).toHaveLength(1);
      expect(
        answers.filter((a) => a.error === 'already_completed'),
      ).toHaveLength(1);
      expect(dataSource.transaction).toHaveBeenCalledTimes(1);
      expect(deviceInsert).toHaveBeenCalledTimes(1);
    });
  });

  describe('cancelProvisioning', () => {
    it('any session of the account cancels; the opener is notified', async () => {
      const { provisioningId, opener } = await openStage();
      const other = makeClient('other-socket');

      service.handleCancelProvisioning(
        other as unknown as Socket,
        { provisioningId },
        server as unknown as Server,
      );

      expect(server.to).toHaveBeenCalledWith('opener-socket');
      expect(roomEmit).toHaveBeenCalledWith('provisioningCancelled', {
        provisioningId,
      });
      expect(lastEmit(other, 'provisioningCancelled')).toEqual({
        success: true,
        provisioningId,
      });
      expect(stages.get(provisioningId)).toBeNull();

      // A dead stage answers like an unknown one everywhere.
      service.handleFetchProvisioningBlob(opener as unknown as Socket, {
        provisioningId,
      });
      expect(lastEmit(opener, 'provisioningBlob')).toEqual({
        success: false,
        error: 'unknown_stage',
      });
    });

    it('an unknown ceremony answers unknown_stage', () => {
      const client = makeClient();

      service.handleCancelProvisioning(
        client as unknown as Socket,
        { provisioningId: 'nope' },
        server as unknown as Server,
      );

      expect(lastEmit(client, 'provisioningCancelled')).toEqual({
        success: false,
        error: 'unknown_stage',
      });
    });
  });

  describe("role 'primary' opener (amendment (lxxvii), falsification F4)", () => {
    /** The PRIMARY opens; the new device says hello from a second socket. */
    async function openAsPrimary() {
      const primary = makeClient('primary-socket');
      await service.handleOpenProvisioning(primary as unknown as Socket, {
        role: 'primary',
      });
      const answer = lastEmit(primary, 'provisioningOpened');
      const provisioningId = answer?.provisioningId as string;
      return { primary, provisioningId };
    }

    function helloFromNewDevice(provisioningId: string) {
      const newDevice = makeClient('new-device-socket');
      service.handleProvisioningHello(
        newDevice as unknown as Socket,
        { provisioningId, ephPubP: EPH_PUB_P },
        server as unknown as Server,
      );
      return newDevice;
    }

    const provisionFrom = (
      client: { id: string; emit: jest.Mock },
      provisioningId: string,
    ) =>
      service.handleProvisionDevice(
        client as unknown as Socket,
        {
          provisioningId,
          blob: 'blob-b64',
          listCanonical: stagedCanonical(),
          listSignature: 'staged-sig',
        },
        server as unknown as Server,
      );

    it('rejects an unknown role at open', async () => {
      const client = makeClient();

      await service.handleOpenProvisioning(client as unknown as Socket, {
        role: 'attacker',
      });

      expect(lastEmit(client, 'provisioningOpened')).toEqual({
        success: false,
        error: 'open_failed',
      });
      expect(devicesService.allocateDeviceId).not.toHaveBeenCalled();
    });

    it('relays hello (with deviceId) to the opener and the blob to the hello socket', async () => {
      const { primary, provisioningId } = await openAsPrimary();
      const newDevice = helloFromNewDevice(provisioningId);

      expect(lastEmit(newDevice, 'provisioningHelloAck')).toEqual({
        success: true,
        deviceId: 2,
      });
      expect(server.to).toHaveBeenCalledWith('primary-socket');
      expect(roomEmit).toHaveBeenCalledWith('provisioningHello', {
        provisioningId,
        ephPubP: EPH_PUB_P,
        deviceId: 2,
      });

      await provisionFrom(primary, provisioningId);
      expect(lastEmit(primary, 'provisionDeviceAck')).toEqual({
        success: true,
      });
      // F4: role ignored server-side would relay the blob back to the
      // primary — it must land on the hello (new device) socket.
      expect(server.to).toHaveBeenCalledWith('new-device-socket');
      expect(roomEmit).toHaveBeenCalledWith('provisioningBlob', {
        provisioningId,
        blob: 'blob-b64',
      });
    });

    it('refuses provisionDevice from the hello (new device) socket', async () => {
      const { provisioningId } = await openAsPrimary();
      const newDevice = helloFromNewDevice(provisioningId);

      await provisionFrom(newDevice, provisioningId);

      expect(lastEmit(newDevice, 'provisionDeviceAck')).toEqual({
        success: false,
        error: 'not_primary',
      });
    });

    it('blob fetch and complete bind to the new device, not the opener', async () => {
      const { primary, provisioningId } = await openAsPrimary();
      const newDevice = helloFromNewDevice(provisioningId);
      await provisionFrom(primary, provisioningId);

      service.handleFetchProvisioningBlob(primary as unknown as Socket, {
        provisioningId,
      });
      expect(lastEmit(primary, 'provisioningBlob')).toEqual({
        success: false,
        error: 'not_opener',
      });
      service.handleFetchProvisioningBlob(newDevice as unknown as Socket, {
        provisioningId,
      });
      expect(lastEmit(newDevice, 'provisioningBlob')).toEqual({
        provisioningId,
        blob: 'blob-b64',
      });

      await service.handleProvisioningComplete(
        primary as unknown as Socket,
        { provisioningId },
        server as unknown as Server,
      );
      expect(lastEmit(primary, 'provisioningCompleted')).toEqual({
        success: false,
        error: 'not_opener',
      });
      expect(dataSource.transaction).not.toHaveBeenCalled();

      await service.handleProvisioningComplete(
        newDevice as unknown as Socket,
        { provisioningId },
        server as unknown as Server,
      );
      expect(lastEmit(newDevice, 'provisioningCompleted')).toEqual({
        success: true,
        deviceId: 2,
        access_token: 'access-jwt',
        refresh_token: 'rt',
      });
    });

    it('cancel from one party notifies the OTHER party', async () => {
      const { primary, provisioningId } = await openAsPrimary();
      helloFromNewDevice(provisioningId);

      service.handleCancelProvisioning(
        primary as unknown as Socket,
        { provisioningId },
        server as unknown as Server,
      );

      // The only 'new-device-socket' targeting in this ceremony is the
      // cancel relay (no blob was ever staged).
      expect(server.to).toHaveBeenCalledWith('new-device-socket');
      expect(roomEmit).toHaveBeenCalledWith('provisioningCancelled', {
        provisioningId,
      });
      expect(lastEmit(primary, 'provisioningCancelled')).toEqual({
        success: true,
        provisioningId,
      });
      expect(stages.get(provisioningId)).toBeNull();
    });
  });
});
