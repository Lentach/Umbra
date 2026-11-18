import { ConfigService } from '@nestjs/config';
import { Server, Socket } from 'socket.io';
import {
  ChatSearchService,
  SEARCH_OTP_BUDGET,
  SEARCH_OTP_WINDOW_MS,
} from './chat-search.service';
import { UsersService } from '../../users/users.service';
import { DevicesService } from '../../key-bundles/devices.service';
import { DeviceListService } from '../../key-bundles/device-list.service';
import { PreKeyBundleResponse } from '../../key-bundles/key-bundles.service';
import { ChatKeyExchangeService } from './chat-key-exchange.service';

/**
 * First contact (metadata-privacy PR3.2, design §4.4): `searchUsers` answers
 * with everything a new client needs to reach a stranger WITHOUT a second
 * identity call — per live device a bundle (one-time pre-key included), the
 * request queue that device published, and the account's DAK-signed list so
 * the searcher checks the device set instead of trusting the server's word.
 * `setRequestQueue` is how a device publishes that queue.
 */
describe('ChatSearchService', () => {
  interface FakeClient {
    data: { user?: { id: number; deviceId?: number } };
    emit: jest.Mock<void, [string, unknown]>;
  }
  interface Address {
    deviceId: number;
    requestSid: string | null;
    requestSealPub: string | null;
  }

  let service: ChatSearchService;
  let users: { findByUsernameAndTag: jest.Mock };
  // The env as `ConfigService` serves it; `BOX_ENABLED` set per test.
  let env: Record<string, string | undefined>;
  let devices: {
    firstContactDevices: jest.Mock<Promise<Address[]>, [number]>;
    setRequestQueue: jest.Mock<
      Promise<boolean>,
      [number, number, string, string]
    >;
  };
  let deviceLists: {
    pendingReplacementVersion: jest.Mock<Promise<number | null>, [number]>;
    getAuthorization: jest.Mock;
  };
  let keyExchange: {
    claimBundle: jest.Mock<
      Promise<PreKeyBundleResponse | null>,
      [number, number, Server, boolean]
    >;
  };
  let client: FakeClient;
  const server = {} as Server;

  // The account HAS a legacy server photo and a gallery: decision 138, the
  // search answer must show neither (a photo reaches a friend over the box).
  const stranger = {
    id: 2,
    username: 'alice',
    tag: '1234',
    profilePictureUrl: '/avatars/alice.jpg',
    profilePhotos: [
      {
        id: 9,
        url: '/avatars/alice.jpg',
        isPrimary: true,
        createdAt: new Date('2026-01-01'),
      },
    ],
  };
  const bundleFor = (deviceId: number): PreKeyBundleResponse => ({
    registrationId: 100 + deviceId,
    identityPublicKey: 'IK',
    signedPreKeyId: 1,
    signedPreKeyPublic: `spk-${deviceId}`,
    signedPreKeySignature: `sig-${deviceId}`,
    oneTimePreKeyId: 40 + deviceId,
    oneTimePreKeyPublic: `otp-${deviceId}`,
  });
  // The one canonical unpadded base64url spelling of 32 bytes (43 chars, the
  // last one carrying two zero spare bits) — the box's id convention.
  const sid = Buffer.alloc(32, 7).toString('base64url');
  const sealPub = Buffer.alloc(32, 9).toString('base64url');

  const socket = () => client as unknown as Socket;
  const search = (handle: string) =>
    service.handleSearchUsers(socket(), { handle }, server);
  const payloadOf = (event: string): unknown =>
    client.emit.mock.calls.find(([name]) => name === event)?.[1];

  beforeEach(() => {
    users = { findByUsernameAndTag: jest.fn() };
    env = { BOX_ENABLED: 'true' };
    devices = {
      firstContactDevices: jest.fn().mockResolvedValue([]),
      setRequestQueue: jest.fn().mockResolvedValue(true),
    };
    deviceLists = {
      pendingReplacementVersion: jest.fn().mockResolvedValue(null),
      getAuthorization: jest.fn().mockResolvedValue(null),
    };
    keyExchange = {
      claimBundle: jest.fn(
        (_userId: number, deviceId: number, _server: Server, spend: boolean) =>
          Promise.resolve<PreKeyBundleResponse | null>(
            spend
              ? bundleFor(deviceId)
              : {
                  ...bundleFor(deviceId),
                  oneTimePreKeyId: null,
                  oneTimePreKeyPublic: null,
                },
          ),
      ),
    };
    service = new ChatSearchService(
      users as unknown as UsersService,
      devices as unknown as DevicesService,
      deviceLists as unknown as DeviceListService,
      keyExchange as unknown as ChatKeyExchangeService,
      { get: (key: string) => env[key] } as unknown as ConfigService,
    );
    client = { data: { user: { id: 1, deviceId: 1 } }, emit: jest.fn() };
  });

  describe('searchUsers', () => {
    it('ignores an unauthenticated socket', async () => {
      client.data = {};
      await search('alice#1234');
      expect(client.emit).not.toHaveBeenCalled();
    });

    it('serves every addressable device of any other account, a friend exactly like a stranger (owner decision 4): its bundle, its request queue, and the signed list', async () => {
      // Box on (the default here): a friendship made over the box has no
      // server row, so the answer cannot (and must not) depend on one.
      users.findByUsernameAndTag.mockResolvedValue(stranger);
      devices.firstContactDevices.mockResolvedValue([
        { deviceId: 1, requestSid: sid, requestSealPub: sealPub },
        // Linked, but still on a build that publishes no request queue.
        { deviceId: 3, requestSid: null, requestSealPub: null },
      ]);
      deviceLists.getAuthorization.mockResolvedValue({
        userId: 2,
        dakPub: 'dak',
        enrollmentSig: 'esig',
        enrollmentCreatedAt: new Date(1_700_000_000_123),
        listVersion: 4,
        listSignature: 'lsig',
        listCanonical: 'canon',
        updatedAt: new Date(),
      });

      await search('alice#1234');

      expect(users.findByUsernameAndTag).toHaveBeenCalledWith('alice', '1234');
      expect(devices.firstContactDevices).toHaveBeenCalledWith(2);
      expect(keyExchange.claimBundle.mock.calls).toEqual([
        [2, 1, server, true],
        [2, 3, server, true],
      ]);
      expect(payloadOf('searchUsersResult')).toEqual([
        {
          id: 2,
          username: 'alice',
          tag: '1234',
          about: null,
          devices: [
            { deviceId: 1, bundle: bundleFor(1), requestSid: sid, sealPub },
            {
              deviceId: 3,
              bundle: bundleFor(3),
              requestSid: null,
              sealPub: null,
            },
          ],
          // Byte-exact, like the `deviceList` answer: the enrollment signature
          // covers the integer milliseconds.
          authorization: {
            dakPub: 'dak',
            enrollmentSig: 'esig',
            enrollmentCreatedAt: 1_700_000_000_123,
            listVersion: 4,
            listSignature: 'lsig',
            listCanonical: 'canon',
          },
        },
      ]);
    });

    describe('one-time pre-key budget per target device (plan B5)', () => {
      const otpOf = () =>
        (
          payloadOf('searchUsersResult') as Array<{
            devices: Array<{ deviceId: number; bundle: PreKeyBundleResponse }>;
          }>
        )[0].devices.map((d) => [d.deviceId, d.bundle.oneTimePreKeyPublic]);
      const spends = () =>
        keyExchange.claimBundle.mock.calls.filter(([, , , s]) => s).length;

      beforeEach(() => {
        users.findByUsernameAndTag.mockResolvedValue(stranger);
        devices.firstContactDevices.mockResolvedValue([
          { deviceId: 1, requestSid: sid, requestSealPub: sealPub },
        ]);
      });
      afterEach(() => jest.useRealTimers());

      it('repeated searches by one caller spend at most the budget; past it the answer still serves a usable signed-pre-key bundle', async () => {
        for (let i = 0; i < SEARCH_OTP_BUDGET + 20; i++) {
          client.emit.mockClear();
          await search('alice#1234');
        }
        expect(spends()).toBe(SEARCH_OTP_BUDGET);
        expect(keyExchange.claimBundle).toHaveBeenCalledTimes(
          SEARCH_OTP_BUDGET + 20,
        );
        // The last answer: same device, same signed pre-key, no OTP.
        expect(otpOf()).toEqual([[1, null]]);
        const [result] = payloadOf('searchUsersResult') as Array<{
          devices: Array<{ bundle: PreKeyBundleResponse }>;
        }>;
        expect(result.devices[0].bundle.signedPreKeyPublic).toBe('spk-1');
        expect(result.devices[0].bundle.signedPreKeySignature).toBe('sig-1');
      });

      it('many callers share ONE budget per target: a sybil swarm cannot drain the pool', async () => {
        for (let caller = 10; caller < 10 + SEARCH_OTP_BUDGET * 4; caller++) {
          client = {
            data: { user: { id: caller, deviceId: 1 } },
            emit: jest.fn(),
          };
          await search('alice#1234');
        }
        expect(spends()).toBe(SEARCH_OTP_BUDGET);
      });

      it('the first contact gets an OTP, and the budget is per device: a fresh device of the target is not starved by its sibling', async () => {
        await search('alice#1234');
        expect(otpOf()).toEqual([[1, 'otp-1']]);
        for (let i = 1; i < SEARCH_OTP_BUDGET + 3; i++)
          await search('alice#1234');

        devices.firstContactDevices.mockResolvedValue([
          { deviceId: 1, requestSid: sid, requestSealPub: sealPub },
          { deviceId: 4, requestSid: sid, requestSealPub: sealPub },
        ]);
        client.emit.mockClear();
        await search('alice#1234');
        expect(otpOf()).toEqual([
          [1, null],
          [4, 'otp-4'],
        ]);
      });

      it('the budget refills once the window has passed', async () => {
        jest.useFakeTimers({ now: 1_800_000_000_000 });
        for (let i = 0; i < SEARCH_OTP_BUDGET + 2; i++)
          await search('alice#1234');
        expect(spends()).toBe(SEARCH_OTP_BUDGET);

        jest.setSystemTime(1_800_000_000_000 + SEARCH_OTP_WINDOW_MS);
        client.emit.mockClear();
        await search('alice#1234');
        expect(otpOf()).toEqual([[1, 'otp-1']]);
        expect(spends()).toBe(SEARCH_OTP_BUDGET + 1);
      });

      it('an empty pool or a vanished device refunds its slot: nothing was spent, so the hour is not burned', async () => {
        keyExchange.claimBundle.mockImplementation((_u, deviceId) =>
          Promise.resolve({
            ...bundleFor(deviceId),
            oneTimePreKeyId: null,
            oneTimePreKeyPublic: null,
          }),
        );
        for (let i = 0; i < SEARCH_OTP_BUDGET * 3; i++)
          await search('alice#1234');
        keyExchange.claimBundle.mockResolvedValueOnce(null);
        await search('alice#1234');
        keyExchange.claimBundle.mockRejectedValueOnce(new Error('db down'));
        await search('alice#1234');
        // Every slot was given back: the next search still spends.
        const last = keyExchange.claimBundle.mock.calls.length;
        keyExchange.claimBundle.mockImplementation((_u, d) =>
          Promise.resolve(bundleFor(d)),
        );
        await search('alice#1234');
        expect(keyExchange.claimBundle.mock.calls[last][3]).toBe(true);
      });

      it('a full table never evicts a drained target into a fresh budget (fail-closed)', async () => {
        // Drain target 2 first, the oldest entry in the table.
        for (let i = 0; i < SEARCH_OTP_BUDGET + 1; i++)
          await search('alice#1234');
        // Fill the table with 10k other live targets.
        for (let t = 1000; t < 1000 + 10_000; t++) {
          users.findByUsernameAndTag.mockResolvedValue({ ...stranger, id: t });
          await search('alice#1234');
        }
        keyExchange.claimBundle.mockClear();
        // The drained target is still refused an OTP...
        users.findByUsernameAndTag.mockResolvedValue(stranger);
        await search('alice#1234');
        expect(keyExchange.claimBundle.mock.calls[0][3]).toBe(false);
        // ...and so is a brand-new target while the table is full.
        users.findByUsernameAndTag.mockResolvedValue({
          ...stranger,
          id: 99999,
        });
        await search('alice#1234');
        expect(keyExchange.claimBundle.mock.calls[1][3]).toBe(false);
      });

      it('another target has its own budget', async () => {
        for (let i = 0; i < SEARCH_OTP_BUDGET + 2; i++)
          await search('alice#1234');
        users.findByUsernameAndTag.mockResolvedValue({ ...stranger, id: 7 });
        client.emit.mockClear();
        await search('bob#5678');
        expect(otpOf()).toEqual([[1, 'otp-1']]);
      });
    });

    it('leaves out a device whose bundle is gone by the time it is claimed', async () => {
      users.findByUsernameAndTag.mockResolvedValue(stranger);
      devices.firstContactDevices.mockResolvedValue([
        { deviceId: 1, requestSid: sid, requestSealPub: sealPub },
        { deviceId: 2, requestSid: sid, requestSealPub: sealPub },
      ]);
      keyExchange.claimBundle.mockImplementation((_u, deviceId) =>
        Promise.resolve(deviceId === 2 ? null : bundleFor(deviceId)),
      );

      await search('alice#1234');

      const [result] = payloadOf('searchUsersResult') as Array<{
        devices: unknown;
        authorization: unknown;
      }>;
      expect(result.devices).toEqual([
        { deviceId: 1, bundle: bundleFor(1), requestSid: sid, sealPub },
      ]);
      expect(result.authorization).toBeNull();
    });

    it('serves NO device and NO list for an account that owes a replacement enrollment, and claims no pre-key', async () => {
      // The `getDeviceList` refusal of amendment (xlv) clause 2: that roster
      // cannot receive, so a first contact addressed to it is lost in silence.
      users.findByUsernameAndTag.mockResolvedValue(stranger);
      deviceLists.pendingReplacementVersion.mockResolvedValue(5);
      devices.firstContactDevices.mockResolvedValue([
        { deviceId: 1, requestSid: sid, requestSealPub: sealPub },
      ]);

      await search('alice#1234');

      expect(keyExchange.claimBundle).not.toHaveBeenCalled();
      const [result] = payloadOf('searchUsersResult') as Array<{
        id: number;
        devices: unknown;
        authorization: unknown;
      }>;
      expect([result.id, result.devices, result.authorization]).toEqual([
        2,
        [],
        null,
      ]);
    });

    describe('while the box is off', () => {
      // Since Phase 4 step 5 the server keeps no friend rows, so with the box
      // off a friend can no longer be told from a stranger: both are answered
      // with no device, no list and no pre-key claimed.
      it.each([
        ['BOX_ENABLED=false', 'false'],
        ['BOX_ENABLED unset', undefined],
      ])(
        '%s: answers with no device, no list and no pre-key claimed: nothing can use them while the box is off',
        async (_label, value) => {
          env = { BOX_ENABLED: value };
          users.findByUsernameAndTag.mockResolvedValue(stranger);
          devices.firstContactDevices.mockResolvedValue([
            { deviceId: 1, requestSid: sid, requestSealPub: sealPub },
          ]);

          await search('alice#1234');

          const [result] = payloadOf('searchUsersResult') as Array<{
            id: number;
            username: string;
            devices: unknown[];
            authorization: unknown;
          }>;
          expect([
            result.id,
            result.username,
            result.devices,
            result.authorization,
          ]).toEqual([2, stranger.username, [], null]);
          expect(keyExchange.claimBundle).not.toHaveBeenCalled();
        },
      );
    });

    it('answers empty for yourself and claims none of your own pre-keys', async () => {
      users.findByUsernameAndTag.mockResolvedValue({ ...stranger, id: 1 });

      await search('myself#1001');

      expect(payloadOf('searchUsersResult')).toEqual([]);
      expect(keyExchange.claimBundle).not.toHaveBeenCalled();
    });

    it('answers empty for yourself with the box off too', async () => {
      env = { BOX_ENABLED: 'false' };
      users.findByUsernameAndTag.mockResolvedValue({ ...stranger, id: 1 });

      await search('myself#1001');

      expect(payloadOf('searchUsersResult')).toEqual([]);
      expect(keyExchange.claimBundle).not.toHaveBeenCalled();
    });

    it('answers empty when the user is not found', async () => {
      users.findByUsernameAndTag.mockResolvedValue(null);

      await search('nobody#9999');

      expect(payloadOf('searchUsersResult')).toEqual([]);
    });

    it('answers an invalid handle with the format hint', async () => {
      await search('invalid');

      const error = payloadOf('error') as { message: string };
      expect(error.message).toContain('Enter username#tag');
    });
  });

  describe('setRequestQueue', () => {
    it("publishes on the SESSION's device, never on a device the payload names", async () => {
      client.data = { user: { id: 1, deviceId: 3 } };

      await service.handleSetRequestQueue(socket(), {
        sid,
        sealPub,
        deviceId: 9,
      });

      expect(devices.setRequestQueue).toHaveBeenCalledWith(1, 3, sid, sealPub);
      expect(payloadOf('requestQueueSet')).toEqual({ success: true });
    });

    it('treats a token without a device claim as device 1 (pre-Phase-1 sessions)', async () => {
      client.data = { user: { id: 1 } };

      await service.handleSetRequestQueue(socket(), { sid, sealPub });

      expect(devices.setRequestQueue).toHaveBeenCalledWith(1, 1, sid, sealPub);
    });

    it.each([
      ['a padded spelling', { sid: `${sid}=`, sealPub }],
      [
        'non-zero spare bits (a second spelling of the same bytes)',
        { sid, sealPub: `${sealPub.slice(0, 42)}B` },
      ],
      ['the standard base64 alphabet', { sid: `+/${sid.slice(2)}`, sealPub }],
      ['31 bytes', { sid: Buffer.alloc(31, 7).toString('base64url'), sealPub }],
      ['a missing seal key', { sid }],
    ])(
      'refuses %s as invalid_payload and writes nothing',
      async (_label, payload) => {
        await service.handleSetRequestQueue(socket(), payload);

        expect(devices.setRequestQueue).not.toHaveBeenCalled();
        expect(payloadOf('requestQueueSet')).toEqual({
          success: false,
          error: 'invalid_payload',
        });
      },
    );

    it('answers unknown_device when the session has no live device row', async () => {
      devices.setRequestQueue.mockResolvedValue(false);

      await service.handleSetRequestQueue(socket(), { sid, sealPub });

      expect(payloadOf('requestQueueSet')).toEqual({
        success: false,
        error: 'unknown_device',
      });
    });

    it('ignores an unauthenticated socket', async () => {
      client.data = {};

      await service.handleSetRequestQueue(socket(), { sid, sealPub });

      expect(client.emit).not.toHaveBeenCalled();
    });
  });

  describe('getOwnRequestQueues', () => {
    const own = () => service.handleGetOwnRequestQueues(socket());

    it("serves the caller's OWN other devices and their request queues, never the calling device, and spends no pre-key", async () => {
      client.data = { user: { id: 1, deviceId: 3 } };
      devices.firstContactDevices.mockResolvedValue([
        { deviceId: 1, requestSid: sid, requestSealPub: sealPub },
        { deviceId: 3, requestSid: sid, requestSealPub: sealPub },
        // Linked, but on a build that has not published a request queue yet.
        { deviceId: 4, requestSid: null, requestSealPub: null },
      ]);

      await own();

      expect(devices.firstContactDevices).toHaveBeenCalledWith(1);
      expect(keyExchange.claimBundle).not.toHaveBeenCalled();
      expect(payloadOf('ownRequestQueues')).toEqual({
        success: true,
        devices: [
          { deviceId: 1, requestSid: sid, sealPub },
          { deviceId: 4, requestSid: null, sealPub: null },
        ],
      });
    });

    it('treats a token without a device claim as device 1 (pre-Phase-1 sessions)', async () => {
      client.data = { user: { id: 1 } };
      devices.firstContactDevices.mockResolvedValue([
        { deviceId: 1, requestSid: sid, requestSealPub: sealPub },
        { deviceId: 2, requestSid: sid, requestSealPub: sealPub },
      ]);

      await own();

      expect(payloadOf('ownRequestQueues')).toEqual({
        success: true,
        devices: [{ deviceId: 2, requestSid: sid, sealPub }],
      });
    });

    it('answers internal when the lookup fails, never a partial list', async () => {
      devices.firstContactDevices.mockRejectedValue(new Error('db down'));

      await own();

      expect(payloadOf('ownRequestQueues')).toEqual({
        success: false,
        error: 'internal',
      });
    });

    it('ignores an unauthenticated socket', async () => {
      client.data = {};

      await own();

      expect(devices.firstContactDevices).not.toHaveBeenCalled();
      expect(client.emit).not.toHaveBeenCalled();
    });
  });
});
