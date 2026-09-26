import { Server, Socket } from 'socket.io';
import { ChatSearchService } from './chat-search.service';
import { UsersService } from '../../users/users.service';
import { FriendsService } from '../../friends/friends.service';
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
  let friends: { getFriends: jest.Mock };
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
      [number, number, Server]
    >;
  };
  let client: FakeClient;
  const server = {} as Server;

  const stranger = {
    id: 2,
    username: 'alice',
    tag: '1234',
    profilePictureUrl: null,
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
    friends = { getFriends: jest.fn().mockResolvedValue([]) };
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
        (_userId: number, deviceId: number, _server: Server) =>
          Promise.resolve<PreKeyBundleResponse | null>(bundleFor(deviceId)),
      ),
    };
    service = new ChatSearchService(
      users as unknown as UsersService,
      friends as unknown as FriendsService,
      devices as unknown as DevicesService,
      deviceLists as unknown as DeviceListService,
      keyExchange as unknown as ChatKeyExchangeService,
    );
    client = { data: { user: { id: 1, deviceId: 1 } }, emit: jest.fn() };
  });

  describe('searchUsers', () => {
    it('ignores an unauthenticated socket', async () => {
      client.data = {};
      await search('alice#1234');
      expect(client.emit).not.toHaveBeenCalled();
    });

    it('serves every addressable device of a stranger: its bundle, its request queue, and the signed list', async () => {
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
        [2, 1, server],
        [2, 3, server],
      ]);
      expect(payloadOf('searchUsersResult')).toEqual([
        {
          id: 2,
          username: 'alice',
          tag: '1234',
          about: null,
          profilePictureUrl: null,
          profilePhotos: [],
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

    it('answers empty for yourself and claims none of your own pre-keys', async () => {
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

    it('answers empty for a friend and claims none of their pre-keys', async () => {
      users.findByUsernameAndTag.mockResolvedValue(stranger);
      friends.getFriends.mockResolvedValue([{ id: 2 }]);

      await search('alice#1234');

      expect(payloadOf('searchUsersResult')).toEqual([]);
      expect(keyExchange.claimBundle).not.toHaveBeenCalled();
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
