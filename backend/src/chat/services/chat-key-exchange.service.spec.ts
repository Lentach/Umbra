import { Test, TestingModule } from '@nestjs/testing';
import { ChatKeyExchangeService } from './chat-key-exchange.service';
import {
  IdentityLockedError,
  IdentityRestoreRefusedError,
  KeyBundlesService,
  PreKeyBundleResponse,
} from '../../key-bundles/key-bundles.service';
import { ConversationsService } from '../../conversations/conversations.service';
import { PushNotificationsService } from '../../push-notifications/push-notifications.service';
import { IdentityResetService } from '../../key-bundles/identity-reset.service';
import { DevicesService } from '../../key-bundles/devices.service';
import { DeviceListService } from '../../key-bundles/device-list.service';
import { ResetRosterService } from '../../key-bundles/reset-roster.service';
import { UsersService } from '../../users/users.service';
import { JwtService } from '@nestjs/jwt';
import { FcmTokensService } from '../../fcm-tokens/fcm-tokens.service';
import { WebPushSubscriptionsService } from '../../web-push-subscriptions/web-push-subscriptions.service';
import { Socket, Server } from 'socket.io';
import { Logger } from '@nestjs/common';

describe('ChatKeyExchangeService', () => {
  let service: ChatKeyExchangeService;
  let keyBundlesService: jest.Mocked<KeyBundlesService>;
  let conversationsService: { findByUser: jest.Mock };
  let pushNotificationsService: {
    notifyIdentityChanged: jest.Mock;
    notifyIdentityReset: jest.Mock;
  };
  let identityResetService: {
    requestReset: jest.Mock;
    cancelReset: jest.Mock;
    getStatusForUser: jest.Mock;
    setRecoveryKey: jest.Mock;
    getIdentityBackup: jest.Mock;
    hasIdentityBackup: jest.Mock;
    hasRecoveryPhrase: jest.Mock;
  };
  let devicesService: { isActive: jest.Mock };
  let resetRosterService: { applyAfterReset: jest.Mock };
  let usersService: { findById: jest.Mock };
  let jwtService: { sign: jest.Mock };
  let fcmTokensService: { removeByUserId: jest.Mock };
  let webPushSubscriptionsService: { removeByUserId: jest.Mock };
  let deviceListService: { pendingReplacementVersion: jest.Mock };
  let clientRoomEmit: jest.Mock;

  /** Nonce the registration lock issues onto a socket session (§6.1). */
  interface LockNonce {
    nonce: string;
    expiresAt: number;
  }
  /**
   * The per-socket bag the gateway populates. Declared here so tests can read
   * what the service wrote without asserting a shape at each access.
   */
  interface MockSocketData {
    user: { id: number; deviceId?: number } | null;
    registrationLockNonce?: LockNonce;
  }
  // `Socket.data` is `any`, and `any & T` collapses back to `any` — omit it
  // first so the typed shape actually survives the intersection.
  let mockClient: Omit<Partial<Socket>, 'data'> & { data: MockSocketData };
  let mockServer: Partial<Server>;
  let roomsAdapter: Map<string, Set<string>>;
  /** Every broadcast the server mock actually delivered, per receiving socket. */
  let delivered: Array<{ socketId: string; event: string; payload: unknown }>;

  const mockBundle: PreKeyBundleResponse = {
    registrationId: 12345,
    identityPublicKey: 'base64-identity-key',
    signedPreKeyId: 1,
    signedPreKeyPublic: 'base64-signed-pre-key',
    signedPreKeySignature: 'base64-signature',
    oneTimePreKeyId: 7,
    oneTimePreKeyPublic: 'otp-pk-7',
  };

  beforeEach(async () => {
    clientRoomEmit = jest.fn();
    mockClient = {
      id: 'sock-caller',
      data: { user: { id: 1 } },
      emit: jest.fn(),
      to: jest.fn().mockReturnValue({ emit: clientRoomEmit }),
    };
    roomsAdapter = new Map<string, Set<string>>();
    // The server mock RESOLVES a broadcast instead of just recording it: `to`
    // and `except` accumulate the target, `emit` expands it against
    // `roomsAdapter` and appends one entry per receiving socket. Without this
    // an "the caller was not told" assertion would be vacuous — a mock that
    // merely returns `this` from `except` delivers to everyone regardless.
    delivered = [];
    let toRooms: string[] = [];
    let exceptIds: string[] = [];
    mockServer = {
      // `to`/`except` really return a BroadcastOperator; returning the mock
      // server keeps the chain callable, so the shape is asserted away with
      // the same idiom the `sockets` stub below already uses.
      to: jest.fn((room: string) => {
        toRooms.push(room);
        return mockServer;
      }) as unknown as Server['to'],
      except: jest.fn((socketId: string) => {
        exceptIds.push(socketId);
        return mockServer;
      }) as unknown as Server['except'],
      emit: jest.fn((event: string, payload: unknown) => {
        for (const room of toRooms) {
          for (const socketId of roomsAdapter.get(room) ?? []) {
            if (exceptIds.includes(socketId)) continue;
            delivered.push({ socketId, event, payload });
          }
        }
        toRooms = [];
        exceptIds = [];
        return true;
      }),
      sockets: {
        adapter: { rooms: roomsAdapter },
        sockets: new Map(),
      } as unknown as Server['sockets'],
    };
    conversationsService = {
      findByUser: jest.fn().mockResolvedValue([]),
    };
    pushNotificationsService = {
      notifyIdentityChanged: jest.fn().mockResolvedValue(undefined),
      notifyIdentityReset: jest.fn().mockResolvedValue(undefined),
    };
    identityResetService = {
      requestReset: jest.fn(),
      cancelReset: jest.fn().mockResolvedValue(false),
      getStatusForUser: jest.fn().mockResolvedValue(null),
      setRecoveryKey: jest.fn().mockResolvedValue(undefined),
      // (lxxviii): no backup stored unless a test opts in.
      getIdentityBackup: jest.fn().mockResolvedValue(null),
      hasIdentityBackup: jest.fn().mockResolvedValue(false),
      // (lxxxiii) clause 4: no phrase at all unless a test opts in.
      hasRecoveryPhrase: jest.fn().mockResolvedValue(false),
    };
    devicesService = {
      isActive: jest.fn().mockResolvedValue(true),
    };
    // §6.2 roster teardown (amendment (xxviii)): only a RESET-authorized
    // identity change reaches it, so it stays untouched in every other test.
    resetRosterService = {
      applyAfterReset: jest.fn().mockResolvedValue({
        deviceId: 4,
        revokedDeviceIds: [1],
        accessDeviceId: 4,
        refreshToken: 'fresh-refresh',
      }),
    };
    usersService = {
      findById: jest
        .fn()
        .mockResolvedValue({ id: 1, username: 'ann', tag: '0001' }),
    };
    jwtService = { sign: jest.fn().mockReturnValue('fresh-access') };
    fcmTokensService = {
      removeByUserId: jest.fn().mockResolvedValue(undefined),
    };
    webPushSubscriptionsService = {
      removeByUserId: jest.fn().mockResolvedValue(undefined),
    };
    deviceListService = {
      pendingReplacementVersion: jest.fn().mockResolvedValue(null),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ChatKeyExchangeService,
        {
          provide: KeyBundlesService,
          useValue: {
            upsertKeyBundle: jest.fn().mockResolvedValue({
              identityChanged: false,
              authorizedBy: null,
              previousIdentityPublicKey: null,
            }),
            uploadOneTimePreKeys: jest.fn().mockResolvedValue(undefined),
            purgeDeviceOneTimePreKeys: jest.fn().mockResolvedValue(undefined),
            fetchPreKeyBundle: jest.fn(),
            countUnusedPreKeys: jest.fn(),
            hasKeyBundle: jest.fn(),
            latestIdentityChange: jest.fn().mockResolvedValue(null),
            // (lxxiii) default: the ordinary pre-linking account, not enrolled.
            isEnrolled: jest.fn().mockResolvedValue(false),
          },
        },
        { provide: ConversationsService, useValue: conversationsService },
        {
          provide: PushNotificationsService,
          useValue: pushNotificationsService,
        },
        { provide: IdentityResetService, useValue: identityResetService },
        { provide: DevicesService, useValue: devicesService },
        { provide: ResetRosterService, useValue: resetRosterService },
        { provide: UsersService, useValue: usersService },
        { provide: JwtService, useValue: jwtService },
        { provide: FcmTokensService, useValue: fcmTokensService },
        {
          provide: WebPushSubscriptionsService,
          useValue: webPushSubscriptionsService,
        },
        {
          provide: DeviceListService,
          // (xlv) clause 1's retry offer. Null is the ordinary account: no
          // replacement enrollment owed, so the ack keeps its historic shape.
          useValue: deviceListService,
        },
      ],
    }).compile();

    service = module.get<ChatKeyExchangeService>(ChatKeyExchangeService);
    keyBundlesService = module.get(KeyBundlesService);
    jest.clearAllMocks();
  });

  describe('handleUploadKeyBundle', () => {
    const validData = {
      registrationId: 12345,
      identityPublicKey: 'base64-identity-key',
      signedPreKeyId: 1,
      signedPreKeyPublic: 'base64-signed-pre-key',
      signedPreKeySignature: 'base64-signature',
    };

    it('should call upsertKeyBundle and emit keyBundleUploaded on success', async () => {
      await service.handleUploadKeyBundle(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      expect(keyBundlesService.upsertKeyBundle).toHaveBeenCalledWith(
        1,
        {
          registrationId: validData.registrationId,
          identityPublicKey: validData.identityPublicKey,
          signedPreKeyId: validData.signedPreKeyId,
          signedPreKeyPublic: validData.signedPreKeyPublic,
          signedPreKeySignature: validData.signedPreKeySignature,
        },
        // No registration-lock proof on the normal re-upload path.
        undefined,
        // Device 1: this session's JWT names no other (§8).
        1,
      );
      // The ack tells the uploader whether ITS upload replaced the stored
      // identity, so a device never alarms about its own replacement.
      expect(mockClient.emit).toHaveBeenCalledWith('keyBundleUploaded', {
        success: true,
        identityChanged: false,
      });
      // Same-identity upload (the normal every-connect re-upload): NO alarm.
      await new Promise((resolve) => setImmediate(resolve));
      expect(mockClient.to).not.toHaveBeenCalled();
      expect(
        pushNotificationsService.notifyIdentityChanged,
      ).not.toHaveBeenCalled();
      expect(conversationsService.findByUser).not.toHaveBeenCalled();
    });

    it('should emit error when DTO validation fails', async () => {
      const invalidData = { registrationId: -1 };

      await service.handleUploadKeyBundle(
        mockClient as Socket,
        invalidData,
        mockServer as Server,
      );

      expect(keyBundlesService.upsertKeyBundle).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith(
        'error',
        expect.objectContaining({
          message: expect.stringContaining('Validation failed'),
        }),
      );
    });

    it('should return early when client has no userId', async () => {
      const noUserClient = { data: { user: null }, emit: jest.fn() };

      await service.handleUploadKeyBundle(
        noUserClient as unknown as Socket,
        validData,
        mockServer as Server,
      );

      expect(keyBundlesService.upsertKeyBundle).not.toHaveBeenCalled();
      expect(noUserClient.emit).not.toHaveBeenCalled();
    });

    // expect.any(String) is typed `any`; the unknown hop keeps the ratchet flat.
    const anyIsoString: unknown = expect.any(String);
    it('identity replacement alarms other sessions, pushes, and flags conversation peers', async () => {
      keyBundlesService.upsertKeyBundle.mockResolvedValue({
        identityChanged: true,
        // A SIGNED rotation, not a reset: the roster teardown must stay out.
        authorizedBy: 'signature',
        previousIdentityPublicKey: 'old-identity',
      });
      conversationsService.findByUser.mockResolvedValue([
        { userOne: { id: 1 }, userTwo: { id: 2 } },
        { userOne: { id: 3 }, userTwo: { id: 1 } },
      ]);

      await service.handleUploadKeyBundle(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );
      // The alarm is fire-and-forget — drain it.
      await new Promise((resolve) => setImmediate(resolve));

      // Upload is still acked normally.
      expect(mockClient.emit).toHaveBeenCalledWith('keyBundleUploaded', {
        success: true,
        identityChanged: true,
      });
      // Other sessions: client.to(room) EXCLUDES the uploading socket.
      expect(mockClient.to).toHaveBeenCalledWith('user:1');
      expect(clientRoomEmit).toHaveBeenCalledWith(
        'ownIdentityReplaced',
        expect.objectContaining({ occurredAt: anyIsoString }),
      );
      // Offline sessions: content-free push to every endpoint.
      expect(
        pushNotificationsService.notifyIdentityChanged,
      ).toHaveBeenCalledWith(1);
      // Conversation peers get the corroborating event in their rooms.
      expect(mockServer.to).toHaveBeenCalledWith('user:2');
      expect(mockServer.to).toHaveBeenCalledWith('user:3');
      expect(mockServer.to).not.toHaveBeenCalledWith('user:1');
      expect(mockServer.emit).toHaveBeenCalledWith(
        'peerIdentityChanged',
        expect.objectContaining({ userId: 1, occurredAt: anyIsoString }),
      );
    });

    it('a notify failure never breaks the upload ack', async () => {
      keyBundlesService.upsertKeyBundle.mockResolvedValue({
        identityChanged: true,
        // A SIGNED rotation, not a reset: the roster teardown must stay out.
        authorizedBy: 'signature',
        previousIdentityPublicKey: 'old-identity',
      });
      conversationsService.findByUser.mockRejectedValue(new Error('db down'));

      await service.handleUploadKeyBundle(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );
      await new Promise((resolve) => setImmediate(resolve));

      expect(mockClient.emit).toHaveBeenCalledWith('keyBundleUploaded', {
        success: true,
        identityChanged: true,
      });
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'error',
        expect.anything(),
      );
    });

    describe('§6.2 roster teardown wiring (amendments (f)/(xxviii))', () => {
      const resetAuthorized = () => {
        keyBundlesService.upsertKeyBundle.mockResolvedValue({
          identityChanged: true,
          authorizedBy: 'reset',
          previousIdentityPublicKey: 'old-identity',
        });
      };

      it('runs the teardown and hands the recovering device its NEW id and session', async () => {
        resetAuthorized();

        await service.handleUploadKeyBundle(
          mockClient as Socket,
          validData,
          mockServer as Server,
        );
        await new Promise((resolve) => setImmediate(resolve));

        expect(resetRosterService.applyAfterReset).toHaveBeenCalledWith(1, 1);
        // The client MUST adopt these before uploading one-time pre-keys, or
        // those keys land in the namespace the teardown just abandoned.
        expect(mockClient.emit).toHaveBeenCalledWith('keyBundleUploaded', {
          success: true,
          identityChanged: true,
          deviceId: 4,
          access_token: 'fresh-access',
          refresh_token: 'fresh-refresh',
        });
        expect(jwtService.sign).toHaveBeenCalledWith(
          expect.objectContaining({ sub: 1, deviceId: 4 }),
        );
      });

      // Amendment (xli). The teardown's database half is atomic, but BOTH
      // §5.5 session gates run at CONNECT time only and `getServedMessageIds`
      // is the sole per-event revocation re-check — so a superseded device
      // that never disconnects would keep the whole remaining gateway surface
      // after the very ceremony meant to evict it.
      it('EVICTS every device the teardown revoked', async () => {
        resetAuthorized();
        resetRosterService.applyAfterReset.mockResolvedValue({
          deviceId: 4,
          revokedDeviceIds: [1, 2],
          accessDeviceId: 4,
          refreshToken: 'fresh-refresh',
        });
        const kickedOne = { disconnect: jest.fn() };
        const kickedTwo = { disconnect: jest.fn() };
        roomsAdapter.set('device:1:1', new Set(['sock-a']));
        roomsAdapter.set('device:1:2', new Set(['sock-b']));
        const sockets = mockServer.sockets as unknown as {
          sockets: Map<string, unknown>;
        };
        sockets.sockets.set('sock-a', kickedOne);
        sockets.sockets.set('sock-b', kickedTwo);

        await service.handleUploadKeyBundle(
          mockClient as Socket,
          validData,
          mockServer as Server,
        );
        await new Promise((resolve) => setImmediate(resolve));

        // Told FIRST, so a live client can log itself out cleanly (xxvi)...
        expect(mockServer.to).toHaveBeenCalledWith('device:1:1');
        expect(mockServer.to).toHaveBeenCalledWith('device:1:2');
        expect(mockServer.emit).toHaveBeenCalledWith('deviceRevoked', {
          userId: 1,
          deviceId: 1,
          reason: 'reset',
          // Issue #205: device 1 is the caller's own pre-reset id. Another
          // tab of the recovering install still sits on it and shares its
          // box queues, so that client keeps them...
          rehomed: true,
        });
        // ...while any other superseded device deletes its own.
        expect(mockServer.emit).toHaveBeenCalledWith('deviceRevoked', {
          userId: 1,
          deviceId: 2,
          reason: 'reset',
          rehomed: false,
        });
        // ...then dropped, which is what actually ends the access.
        expect(kickedOne.disconnect).toHaveBeenCalled();
        expect(kickedTwo.disconnect).toHaveBeenCalled();

        // And strictly AFTER the ack. Order is the contract here, not just the
        // outcome: socket.io marks a socket disconnected synchronously, so any
        // eviction that runs first silently swallows the reissued session the
        // recovering client must adopt.
        const ackAt = (mockClient.emit as jest.Mock).mock
          .invocationCallOrder[0];
        const kickAt = kickedOne.disconnect.mock.invocationCallOrder[0];
        expect(ackAt).toBeLessThan(kickAt);

        // The exclusion must be narrow: a genuinely superseded sibling is
        // still told, or `except` would have silenced the whole announcement.
        expect(
          delivered
            .filter((d) => d.event === 'deviceRevoked')
            .map((d) => d.socketId),
        ).toEqual(['sock-a', 'sock-b']);
      });

      // THE ORDERING THAT MAKES RECOVERY WORK AT ALL. The recovering client is
      // still authenticated as its PRE-reset device id, so its own socket sits
      // in a room this teardown just revoked. Evicting before the ack would
      // disconnect the caller, and socket.io marks a socket disconnected
      // synchronously — so the emit carrying its new deviceId and session
      // would silently no-op. With its old refresh token revoked and its old
      // JWT gated, the recovery would strand on EVERY run.
      it('acks the recovering caller even though its OWN device id was revoked', async () => {
        resetAuthorized();
        resetRosterService.applyAfterReset.mockResolvedValue({
          deviceId: 4,
          // Device 1 is the caller's own pre-reset id.
          revokedDeviceIds: [1],
          accessDeviceId: 4,
          refreshToken: 'fresh-refresh',
        });
        const callerSocket = { id: 'sock-caller', disconnect: jest.fn() };
        roomsAdapter.set('device:1:1', new Set(['sock-caller']));
        const sockets = mockServer.sockets as unknown as {
          sockets: Map<string, unknown>;
        };
        sockets.sockets.set('sock-caller', callerSocket);

        await service.handleUploadKeyBundle(
          mockClient as Socket,
          validData,
          mockServer as Server,
        );
        await new Promise((resolve) => setImmediate(resolve));

        // The caller keeps its socket: it adopts the session and reconnects
        // itself, which disposes this socket anyway, and a client that ignores
        // the ack meets the connect gate on its next reconnect.
        expect(callerSocket.disconnect).not.toHaveBeenCalled();
        expect(mockClient.emit).toHaveBeenCalledWith('keyBundleUploaded', {
          success: true,
          identityChanged: true,
          deviceId: 4,
          access_token: 'fresh-access',
          refresh_token: 'fresh-refresh',
        });

        // AND IT IS NEVER TOLD IT WAS REVOKED. This matters more than the
        // disconnect: the client's handler does NOT filter on device id
        // (connection_provider.dart `_onOwnDeviceRevoked` logs out
        // unconditionally), so a room-wide announcement would make the
        // recovering device wipe the very session it adopted from the ack a
        // moment earlier.
        expect(
          delivered.filter(
            (d) => d.socketId === 'sock-caller' && d.event === 'deviceRevoked',
          ),
        ).toEqual([]);
      });

      it('does not evict the RECOVERING device', async () => {
        resetAuthorized();
        const survivor = { disconnect: jest.fn() };
        // The recovering device was moved to the freshly allocated id 4 before
        // the revocation stamp, so it is absent from revokedDeviceIds ([1])
        // and must not kick itself off the session it just recovered.
        roomsAdapter.set('device:1:4', new Set(['sock-new']));
        const sockets = mockServer.sockets as unknown as {
          sockets: Map<string, unknown>;
        };
        sockets.sockets.set('sock-new', survivor);

        await service.handleUploadKeyBundle(
          mockClient as Socket,
          validData,
          mockServer as Server,
        );
        await new Promise((resolve) => setImmediate(resolve));

        expect(survivor.disconnect).not.toHaveBeenCalled();
      });

      it('a SIGNED rotation evicts nothing — that account keeps its devices', async () => {
        keyBundlesService.upsertKeyBundle.mockResolvedValue({
          identityChanged: true,
          authorizedBy: 'signature',
          previousIdentityPublicKey: 'old-identity',
        });
        const untouched = { disconnect: jest.fn() };
        roomsAdapter.set('device:1:1', new Set(['sock-a']));
        const sockets = mockServer.sockets as unknown as {
          sockets: Map<string, unknown>;
        };
        sockets.sockets.set('sock-a', untouched);

        await service.handleUploadKeyBundle(
          mockClient as Socket,
          validData,
          mockServer as Server,
        );
        await new Promise((resolve) => setImmediate(resolve));

        expect(untouched.disconnect).not.toHaveBeenCalled();
      });

      it('drops every push endpoint of the account (amendment (xxiv))', async () => {
        resetAuthorized();

        await service.handleUploadKeyBundle(
          mockClient as Socket,
          validData,
          mockServer as Server,
        );
        await new Promise((resolve) => setImmediate(resolve));

        // Each row belonged to a device this teardown just revoked, and a
        // NULL-deviceId row cannot be attributed to any of them.
        expect(fcmTokensService.removeByUserId).toHaveBeenCalledWith(1);
        expect(webPushSubscriptionsService.removeByUserId).toHaveBeenCalledWith(
          1,
        );
      });

      it('a SIGNED rotation never tears the roster down', async () => {
        keyBundlesService.upsertKeyBundle.mockResolvedValue({
          identityChanged: true,
          authorizedBy: 'signature',
          previousIdentityPublicKey: 'old-identity',
        });

        await service.handleUploadKeyBundle(
          mockClient as Socket,
          validData,
          mockServer as Server,
        );
        await new Promise((resolve) => setImmediate(resolve));

        // That account still holds its other devices — revoking them would be
        // a data-loss event dressed as a key rotation.
        expect(resetRosterService.applyAfterReset).not.toHaveBeenCalled();
        expect(fcmTokensService.removeByUserId).not.toHaveBeenCalled();
        expect(mockClient.emit).toHaveBeenCalledWith('keyBundleUploaded', {
          success: true,
          identityChanged: true,
        });
      });

      it('a same-identity re-upload touches nothing', async () => {
        await service.handleUploadKeyBundle(
          mockClient as Socket,
          validData,
          mockServer as Server,
        );

        expect(resetRosterService.applyAfterReset).not.toHaveBeenCalled();
      });
    });

    // Amendment (lxxviii) clause 2: an identity RESTORE runs the same
    // teardown as a reset — the restoring install is a fresh wipe — but the
    // identity did not change, so none of the §6.0 alarm surface may fire.
    describe('(lxxviii) restore teardown wiring', () => {
      const restoreAuthorized = () => {
        keyBundlesService.upsertKeyBundle.mockResolvedValue({
          identityChanged: false,
          authorizedBy: 'restore',
          previousIdentityPublicKey: null,
        });
        resetRosterService.applyAfterReset.mockResolvedValue({
          deviceId: 4,
          revokedDeviceIds: [1, 2],
          accessDeviceId: 4,
          refreshToken: 'fresh-refresh',
          nextListVersion: 8,
        });
      };

      it('purges the caller device OTPs BEFORE the teardown moves its bundle (F8)', async () => {
        restoreAuthorized();

        await service.handleUploadKeyBundle(
          mockClient as Socket,
          validData,
          mockServer as Server,
        );
        await new Promise((resolve) => setImmediate(resolve));

        // The pre-wipe OTP private halves died with the wipe; served, they
        // would be unanswerable X3DH offers under the moved bundle.
        expect(
          keyBundlesService.purgeDeviceOneTimePreKeys,
        ).toHaveBeenCalledWith(1, 1);
        const purgeAt = (
          keyBundlesService.purgeDeviceOneTimePreKeys as jest.Mock
        ).mock.invocationCallOrder[0];
        const rosterAt =
          resetRosterService.applyAfterReset.mock.invocationCallOrder[0];
        expect(purgeAt).toBeLessThan(rosterAt);
        expect(resetRosterService.applyAfterReset).toHaveBeenCalledWith(1, 1);
      });

      it('acks the exact restore shape: restored + nextListVersion, identityChanged false', async () => {
        restoreAuthorized();

        await service.handleUploadKeyBundle(
          mockClient as Socket,
          validData,
          mockServer as Server,
        );
        await new Promise((resolve) => setImmediate(resolve));

        // NOT pendingReplacementVersion: the enrollment still verifies, the
        // client re-signs the list via updateDeviceList — no re-enrolment.
        expect(mockClient.emit).toHaveBeenCalledWith('keyBundleUploaded', {
          success: true,
          identityChanged: false,
          deviceId: 4,
          access_token: 'fresh-access',
          refresh_token: 'fresh-refresh',
          restored: true,
          nextListVersion: 8,
        });
        expect(
          // The roster branch owns the version; the (xlv) retry-offer
          // predicate must not even be consulted.
          deviceListService.pendingReplacementVersion,
        ).not.toHaveBeenCalled();
      });

      it('the identity did NOT change: no alarm, no peer flag — but the restored push fires BEFORE the push rows drop', async () => {
        restoreAuthorized();

        await service.handleUploadKeyBundle(
          mockClient as Socket,
          validData,
          mockServer as Server,
        );
        await new Promise((resolve) => setImmediate(resolve));

        expect(
          pushNotificationsService.notifyIdentityChanged,
        ).not.toHaveBeenCalled();
        expect(mockClient.to).not.toHaveBeenCalled();
        // Content-free wake-up to every endpoint the teardown is about to
        // orphan — order is the contract: after the drop there is nothing
        // left to deliver to.
        expect(
          pushNotificationsService.notifyIdentityReset,
        ).toHaveBeenCalledWith(1, 'identity_restored');
        const pushAt =
          pushNotificationsService.notifyIdentityReset.mock
            .invocationCallOrder[0];
        const dropAt =
          fcmTokensService.removeByUserId.mock.invocationCallOrder[0];
        expect(pushAt).toBeLessThan(dropAt);
      });

      it('revoked devices are told deviceRevoked with reason restored', async () => {
        restoreAuthorized();
        roomsAdapter.set('device:1:2', new Set(['sock-b']));
        const kicked = { disconnect: jest.fn() };
        const sockets = mockServer.sockets as unknown as {
          sockets: Map<string, unknown>;
        };
        sockets.sockets.set('sock-b', kicked);

        await service.handleUploadKeyBundle(
          mockClient as Socket,
          validData,
          mockServer as Server,
        );
        await new Promise((resolve) => setImmediate(resolve));

        expect(mockServer.emit).toHaveBeenCalledWith('deviceRevoked', {
          userId: 1,
          deviceId: 2,
          // (lxxviii): a restore is not a takeover; the client words the
          // logout accordingly.
          reason: 'restored',
          // Issue #205: not the restoring caller's own id, so it deletes its
          // box queues.
          rehomed: false,
        });
        expect(kicked.disconnect).toHaveBeenCalled();
      });

      it('a refused restore proof acks restore_refused and touches nothing', async () => {
        keyBundlesService.upsertKeyBundle.mockRejectedValue(
          new IdentityRestoreRefusedError(),
        );

        await service.handleUploadKeyBundle(
          mockClient as Socket,
          validData,
          mockServer as Server,
        );
        await new Promise((resolve) => setImmediate(resolve));

        expect(mockClient.emit).toHaveBeenCalledWith('keyBundleUploaded', {
          success: false,
          error: 'restore_refused',
        });
        expect(resetRosterService.applyAfterReset).not.toHaveBeenCalled();
        expect(
          keyBundlesService.purgeDeviceOneTimePreKeys,
        ).not.toHaveBeenCalled();
        expect(fcmTokensService.removeByUserId).not.toHaveBeenCalled();
      });
    });
  });

  // T3, spec §5.1 / §12 amendment (b): key material may land only on a
  // deviceId a provisioning commit actually activated. Device 1 predates the
  // devices table and stays exempt.
  describe('never-activated deviceId upload rejection', () => {
    const bundleData = {
      registrationId: 12345,
      identityPublicKey: 'base64-identity-key',
      signedPreKeyId: 1,
      signedPreKeyPublic: 'base64-signed-pre-key',
      signedPreKeySignature: 'base64-signature',
    };
    const otpData = { keys: [{ keyId: 1, publicKey: 'pk-1' }] };
    // `jest.Mocked<KeyBundlesService>` members are METHODS to the compiler,
    // so `expect(service.method)` trips unbound-method; this view types the
    // same mock objects as plain function properties for assertions.
    const kbMocks = () =>
      keyBundlesService as unknown as {
        upsertKeyBundle: jest.Mock;
        uploadOneTimePreKeys: jest.Mock;
      };

    it('refuses a bundle from a session on a never-activated deviceId', async () => {
      mockClient.data.user = { id: 1, deviceId: 2 };
      devicesService.isActive.mockResolvedValue(false);

      await service.handleUploadKeyBundle(
        mockClient as Socket,
        bundleData,
        mockServer as Server,
      );

      expect(devicesService.isActive).toHaveBeenCalledWith(1, 2);
      expect(kbMocks().upsertKeyBundle).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith('keyBundleUploaded', {
        success: false,
        error: 'device_not_active',
      });
    });

    it('refuses one-time pre-keys the same way, in this handler refusal shape', async () => {
      mockClient.data.user = { id: 1, deviceId: 2 };
      devicesService.isActive.mockResolvedValue(false);

      await service.handleUploadOneTimePreKeys(mockClient as Socket, otpData);

      expect(kbMocks().uploadOneTimePreKeys).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'device_not_active',
      });
    });

    it('a LIVE provisioned device uploads under its own id', async () => {
      mockClient.data.user = { id: 1, deviceId: 2 };
      devicesService.isActive.mockResolvedValue(true);

      await service.handleUploadKeyBundle(
        mockClient as Socket,
        bundleData,
        mockServer as Server,
      );

      expect(kbMocks().upsertKeyBundle).toHaveBeenCalledWith(
        1,
        expect.objectContaining({ registrationId: 12345 }),
        undefined,
        2,
      );
    });

    it('device 1 never consults the activation gate (§8 legacy exemption)', async () => {
      await service.handleUploadKeyBundle(
        mockClient as Socket,
        bundleData,
        mockServer as Server,
      );

      expect(devicesService.isActive).not.toHaveBeenCalled();
      expect(kbMocks().upsertKeyBundle).toHaveBeenCalled();
    });
  });

  describe('handleUploadOneTimePreKeys', () => {
    const validData = {
      keys: [
        { keyId: 1, publicKey: 'pk-1' },
        { keyId: 2, publicKey: 'pk-2' },
      ],
    };

    it('should call uploadOneTimePreKeys and emit oneTimePreKeysUploaded', async () => {
      await service.handleUploadOneTimePreKeys(mockClient as Socket, validData);

      // Legacy payloads remain observable at this boundary, but the key-bundle
      // service must reject them rather than infer an identity epoch.
      expect(keyBundlesService.uploadOneTimePreKeys).toHaveBeenCalledWith(
        1,
        validData.keys,
        undefined,
        1,
        undefined,
      );
      expect(mockClient.emit).toHaveBeenCalledWith('oneTimePreKeysUploaded', {
        count: 2,
      });
    });

    it('forwards the identity epoch tag when a new client supplies it', async () => {
      await service.handleUploadOneTimePreKeys(mockClient as Socket, {
        ...validData,
        identityPublicKey: 'epoch-2-identity',
      });

      expect(keyBundlesService.uploadOneTimePreKeys).toHaveBeenCalledWith(
        1,
        validData.keys,
        'epoch-2-identity',
        1,
        undefined,
      );
    });

    it('forwards the (lxiv) registrationId install proof when supplied', async () => {
      await service.handleUploadOneTimePreKeys(mockClient as Socket, {
        ...validData,
        identityPublicKey: 'epoch-2-identity',
        registrationId: 4242,
      });

      expect(keyBundlesService.uploadOneTimePreKeys).toHaveBeenCalledWith(
        1,
        validData.keys,
        'epoch-2-identity',
        1,
        4242,
      );
    });

    it('should emit error when DTO validation fails', async () => {
      const invalidData = { keys: 'not-an-array' };

      await service.handleUploadOneTimePreKeys(
        mockClient as Socket,
        invalidData,
      );

      expect(keyBundlesService.uploadOneTimePreKeys).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith(
        'error',
        expect.objectContaining({
          message: expect.stringContaining('Validation failed'),
        }),
      );
    });

    it('reports a lock refusal as identity_locked and logs it as a guard, not a fault', async () => {
      keyBundlesService.uploadOneTimePreKeys.mockRejectedValue(
        new IdentityLockedError(),
      );
      const warnSpy = jest
        .spyOn(Logger.prototype, 'warn')
        .mockImplementation(() => undefined);
      const errorSpy = jest
        .spyOn(Logger.prototype, 'error')
        .mockImplementation(() => undefined);

      await service.handleUploadOneTimePreKeys(mockClient as Socket, validData);

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'identity_locked',
      });
      expect(warnSpy).toHaveBeenCalledWith(
        expect.stringContaining('refused by registration lock'),
      );
      expect(errorSpy).not.toHaveBeenCalled();

      warnSpy.mockRestore();
      errorSpy.mockRestore();
    });

    it('should return early when client has no userId', async () => {
      const noUserClient = { data: { user: null }, emit: jest.fn() };

      await service.handleUploadOneTimePreKeys(
        noUserClient as unknown as Socket,
        validData,
      );

      expect(keyBundlesService.uploadOneTimePreKeys).not.toHaveBeenCalled();
      expect(noUserClient.emit).not.toHaveBeenCalled();
    });
  });

  describe('handleCheckOwnKeyBundle', () => {
    it.each([true, false])(
      'returns exists=%s only to the authenticated caller without fetching a pre-key',
      async (exists) => {
        keyBundlesService.hasKeyBundle.mockResolvedValue(exists);

        await service.handleCheckOwnKeyBundle(mockClient as Socket);

        expect(keyBundlesService.hasKeyBundle).toHaveBeenCalledWith(1, 1);
        expect(mockClient.emit).toHaveBeenCalledTimes(1);
        expect(mockClient.emit).toHaveBeenCalledWith('ownKeyBundleStatus', {
          exists,
          // (lxxiii) clause 2: the lock state rides the bundle answer.
          linkingEnabled: false,
          // (lxxviii) clause 1: the backup flag rides it too.
          hasIdentityBackup: false,
          // (lxxxiii) clause 4: the Chats nudge keys off THIS one.
          hasRecoveryPhrase: false,
          // 0b additions: additive, and null when the account is quiet.
          identityReset: null,
          identityReplacedAt: null,
          // (lxxx) clause 5: additive, and null in the same breath.
          identityReplacedTo: null,
        });
        expect(keyBundlesService.fetchPreKeyBundle).not.toHaveBeenCalled();
      },
    );
  });

  describe('handleCheckOwnKeyBundle — (lxxxiii) clause 4', () => {
    it('a pre-(lxxviii) verifier-only phrase reports hasRecoveryPhrase without a backup', async () => {
      // goonboy's shape (prod id 48): a row with a verifier and no blob.
      identityResetService.hasRecoveryPhrase.mockResolvedValue(true);
      identityResetService.hasIdentityBackup.mockResolvedValue(false);

      await service.handleCheckOwnKeyBundle(mockClient as Socket);

      expect(mockClient.emit).toHaveBeenCalledWith(
        'ownKeyBundleStatus',
        expect.objectContaining({
          hasRecoveryPhrase: true,
          hasIdentityBackup: false,
        }),
      );
    });
  });

  describe('handleFetchPreKeyBundle', () => {
    const validData = { userId: 2 };

    it('should call fetchPreKeyBundle and emit preKeyBundleResponse', async () => {
      keyBundlesService.fetchPreKeyBundle.mockResolvedValue(mockBundle);
      keyBundlesService.countUnusedPreKeys.mockResolvedValue(20);

      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      expect(keyBundlesService.fetchPreKeyBundle).toHaveBeenCalledWith(2, 1);
      expect(mockClient.emit).toHaveBeenCalledWith('preKeyBundleResponse', {
        userId: 2,
        deviceId: 1,
        bundle: mockBundle,
      });
    });

    // Register socket ids as members of a room (one entry per open tab),
    // mirroring `sockets.adapter.rooms` in utils/user-room.ts.
    const joinRoom = (userId: number, ...socketIds: string[]) => {
      roomsAdapter.set(`user:${userId}`, new Set(socketIds));
    };
    const joinDeviceRoom = (
      userId: number,
      deviceId: number,
      ...socketIds: string[]
    ) => {
      roomsAdapter.set(`device:${userId}:${deviceId}`, new Set(socketIds));
    };

    it('routes preKeysLow to the LOW DEVICE room, not the whole account', async () => {
      keyBundlesService.fetchPreKeyBundle.mockResolvedValue(mockBundle);
      keyBundlesService.countUnusedPreKeys.mockResolvedValue(5);
      joinDeviceRoom(2, 1, 'socket-id-2');

      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      expect(keyBundlesService.countUnusedPreKeys).toHaveBeenCalledWith(2, 1);
      // Per device (spec §5.2 rider): only the device whose pool is draining
      // can act on this, so telling every device would be noise.
      expect(mockServer.to).toHaveBeenCalledWith('device:2:1');
      expect(mockServer.to).not.toHaveBeenCalledWith('user:2');
      expect(mockServer.to).not.toHaveBeenCalledWith('socket-id-2');
      expect(mockServer.emit).toHaveBeenCalledWith('preKeysLow', {
        remaining: 5,
      });
    });

    it('should reach every tab of the low device with a single room emit (BE-007 multi-tab regression)', async () => {
      keyBundlesService.fetchPreKeyBundle.mockResolvedValue(mockBundle);
      keyBundlesService.countUnusedPreKeys.mockResolvedValue(4);
      // Two tabs of device 1 => two sockets in room `device:2:1`. The old
      // userId->socketId map kept only the newest socket, so the first tab
      // never learned to replenish its draining prekey pool.
      joinDeviceRoom(2, 1, 'socket-tab-a', 'socket-tab-b');

      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      // Exactly one room-addressed emit; a real adapter fans it out to both
      // sockets in the room, so BOTH tabs of that device receive preKeysLow.
      expect(mockServer.to).toHaveBeenCalledTimes(1);
      expect(mockServer.to).toHaveBeenCalledWith('device:2:1');
      expect(roomsAdapter.get('device:2:1')!.size).toBe(2);
      expect(mockServer.emit).toHaveBeenCalledWith('preKeysLow', {
        remaining: 4,
      });
    });

    it('should not emit preKeysLow when remaining count >= 10', async () => {
      keyBundlesService.fetchPreKeyBundle.mockResolvedValue(mockBundle);
      keyBundlesService.countUnusedPreKeys.mockResolvedValue(10);
      joinRoom(2, 'socket-id-2');

      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      expect(mockServer.to).not.toHaveBeenCalled();
    });

    it('should still address the device room when no socket is connected (empty-room no-op)', async () => {
      keyBundlesService.fetchPreKeyBundle.mockResolvedValue(mockBundle);
      keyBundlesService.countUnusedPreKeys.mockResolvedValue(3);
      // No sockets in room `device:2:1`. Emitting to an empty room is a safe
      // no-op, so there is no offline guard: delivery is still by room.

      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      expect(mockServer.to).toHaveBeenCalledWith('device:2:1');
    });

    /** How many times the caller was refused for pacing. */
    const rateLimitRefusals = () =>
      ((mockClient.emit as jest.Mock).mock.calls as unknown[][]).filter(
        (call) => {
          if (call[0] !== 'error') return false;
          const payload = call[1];
          if (
            !payload ||
            typeof payload !== 'object' ||
            !('message' in payload)
          ) {
            return false;
          }
          const message = payload.message;
          return typeof message === 'string' && message.includes('rate limit');
        },
      ).length;

    it('paces bundle fetches PER DEVICE — fan-out to a two-device peer is not throttled', async () => {
      keyBundlesService.fetchPreKeyBundle.mockResolvedValue(mockBundle);
      keyBundlesService.countUnusedPreKeys.mockResolvedValue(20);

      // Back-to-back fetches for two devices of ONE peer: both must succeed, or
      // a client can never build the sessions a fan-out send needs (spec §5.2).
      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        { userId: 2, deviceId: 1 },
        mockServer as Server,
      );
      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        { userId: 2, deviceId: 2 },
        mockServer as Server,
      );

      // Asserted through the answers rather than the service method, so the
      // deviceId echo is pinned at the same time.
      expect(mockClient.emit).toHaveBeenCalledWith('preKeyBundleResponse', {
        userId: 2,
        deviceId: 1,
        bundle: mockBundle,
      });
      expect(mockClient.emit).toHaveBeenCalledWith('preKeyBundleResponse', {
        userId: 2,
        deviceId: 2,
        bundle: mockBundle,
      });
      expect(rateLimitRefusals()).toBe(0);
    });

    it('still paces repeat fetches for the SAME device', async () => {
      keyBundlesService.fetchPreKeyBundle.mockResolvedValue(mockBundle);
      keyBundlesService.countUnusedPreKeys.mockResolvedValue(20);

      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        { userId: 2, deviceId: 2 },
        mockServer as Server,
      );
      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        { userId: 2, deviceId: 2 },
        mockServer as Server,
      );

      expect(rateLimitRefusals()).toBe(1);
    });

    it('should not check pre-key count when bundle is null', async () => {
      keyBundlesService.fetchPreKeyBundle.mockResolvedValue(null);

      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('preKeyBundleResponse', {
        userId: 2,
        deviceId: 1,
        bundle: null,
      });
      expect(keyBundlesService.countUnusedPreKeys).not.toHaveBeenCalled();
    });

    it('should emit error when DTO validation fails', async () => {
      const invalidData = { userId: -1 };

      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        invalidData,
        mockServer as Server,
      );

      expect(keyBundlesService.fetchPreKeyBundle).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith(
        'error',
        expect.objectContaining({
          message: expect.stringContaining('Validation failed'),
        }),
      );
    });

    it('should return early when client has no userId', async () => {
      const noUserClient = { data: { user: null }, emit: jest.fn() };

      await service.handleFetchPreKeyBundle(
        noUserClient as unknown as Socket,
        validData,
        mockServer as Server,
      );

      expect(keyBundlesService.fetchPreKeyBundle).not.toHaveBeenCalled();
      expect(noUserClient.emit).not.toHaveBeenCalled();
    });

    it('rate-limits rapid repeated pre-key fetches for same requester-target pair', async () => {
      keyBundlesService.fetchPreKeyBundle.mockResolvedValue(mockBundle);
      keyBundlesService.countUnusedPreKeys.mockResolvedValue(20);

      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      expect(keyBundlesService.fetchPreKeyBundle).toHaveBeenCalledTimes(1);
      expect(mockClient.emit).toHaveBeenCalledWith(
        'error',
        expect.objectContaining({
          message:
            'Pre-key bundle fetch rate limit exceeded. Please retry shortly.',
        }),
      );
    });

    it('removes stale pre-key fetch tracker entries during rate-limit checks', async () => {
      keyBundlesService.fetchPreKeyBundle.mockResolvedValue(mockBundle);
      keyBundlesService.countUnusedPreKeys.mockResolvedValue(20);
      const nowSpy = jest.spyOn(Date, 'now').mockReturnValue(1_000_000);
      (service as any).lastPreKeyFetchByPair.set('1:9', 1_000_000 - 700_000); // stale

      await service.handleFetchPreKeyBundle(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      const tracker: Map<string, number> = (service as any)
        .lastPreKeyFetchByPair;
      expect(tracker.has('1:9')).toBe(false);
      nowSpy.mockRestore();
    });
  });

  describe('handleRequestSessionRebuild', () => {
    const validData = { recipientId: 2 };

    it('relays sessionRebuildNeeded to the recipient user room', async () => {
      await service.handleRequestSessionRebuild(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      expect(mockServer.to).toHaveBeenCalledWith('user:2');
      expect(mockServer.emit).toHaveBeenCalledWith('sessionRebuildNeeded', {
        fromUserId: 1,
      });
    });

    it('emits to the recipient room even when the one-socket online map has no entry', async () => {
      await service.handleRequestSessionRebuild(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      expect(mockServer.to).toHaveBeenCalledWith('user:2');
      expect(mockServer.emit).toHaveBeenCalledWith('sessionRebuildNeeded', {
        fromUserId: 1,
      });
    });

    it('replays a pending rebuild request when the recipient connects later', async () => {
      await service.handleRequestSessionRebuild(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      const recipientClient = {
        data: { user: { id: 2 } },
        emit: jest.fn(),
      };
      service.deliverPendingSessionRebuilds(
        recipientClient as unknown as Socket,
      );

      expect(recipientClient.emit).toHaveBeenCalledWith(
        'sessionRebuildNeeded',
        { fromUserId: 1 },
      );
    });

    it('clears a pending rebuild request once the recipient fetches the requester bundle', async () => {
      await service.handleRequestSessionRebuild(
        mockClient as Socket,
        validData,
        mockServer as Server,
      );

      keyBundlesService.fetchPreKeyBundle.mockResolvedValue(mockBundle);
      keyBundlesService.countUnusedPreKeys.mockResolvedValue(20);
      const recipientClient = {
        data: { user: { id: 2 } },
        emit: jest.fn(),
      };
      await service.handleFetchPreKeyBundle(
        recipientClient as unknown as Socket,
        { userId: 1 },
        mockServer as Server,
      );

      (recipientClient.emit as jest.Mock).mockClear();
      service.deliverPendingSessionRebuilds(
        recipientClient as unknown as Socket,
      );

      expect(recipientClient.emit).not.toHaveBeenCalledWith(
        'sessionRebuildNeeded',
        expect.anything(),
      );
    });

    it('emits error when DTO validation fails (invalid recipientId)', async () => {
      await service.handleRequestSessionRebuild(
        mockClient as Socket,
        { recipientId: -1 },
        mockServer as Server,
      );

      expect(mockClient.emit).toHaveBeenCalledWith(
        'error',
        expect.objectContaining({
          message: expect.stringContaining('Validation failed'),
        }),
      );
    });

    it('returns early when client has no userId', async () => {
      const noUserClient = { data: { user: null }, emit: jest.fn() };

      await service.handleRequestSessionRebuild(
        noUserClient as unknown as Socket,
        validData,
        mockServer as Server,
      );

      expect(mockServer.to).not.toHaveBeenCalled();
    });
  });

  // Phase 0b: registration lock nonce lifecycle (§6.1).
  describe('registration lock nonce', () => {
    /**
     * The nonce this socket session currently holds. Non-null assertion is the
     * assertion under test: every caller here has just issued one.
     */
    const lockNonce = (): LockNonce => mockClient.data.registrationLockNonce!;

    /** Arguments of the most recent upsertKeyBundle call. */
    const lastUpsertArgs = (): unknown[] => {
      const calls = (keyBundlesService.upsertKeyBundle as unknown as jest.Mock)
        .mock.calls as unknown[][];
      return calls[calls.length - 1];
    };

    const proofPayload = (nonce: string) => ({
      registrationId: 12345,
      identityPublicKey: 'new-identity',
      signedPreKeyId: 1,
      signedPreKeyPublic: 'spk',
      signedPreKeySignature: 'sig',
      identitySignature: 'client-signature',
      nonce,
    });

    it('issues an unpredictable nonce bound to this socket session', () => {
      service.handleGetRegistrationLockNonce(mockClient as Socket);

      const calls = (mockClient.emit as jest.Mock).mock.calls as Array<
        [string, { nonce: string }]
      >;
      const payload = calls.find(
        (call) => call[0] === 'registrationLockNonce',
      )?.[1];
      expect(payload?.nonce).toEqual(expect.any(String));
      expect(Buffer.from(payload?.nonce ?? '', 'base64').length).toBe(32);
      // Held on the socket, so it dies with the connection.
      expect(lockNonce().nonce).toBe(payload?.nonce);
    });

    it('issues a different nonce every time', () => {
      service.handleGetRegistrationLockNonce(mockClient as Socket);
      const first = lockNonce().nonce;
      service.handleGetRegistrationLockNonce(mockClient as Socket);

      expect(lockNonce().nonce).not.toBe(first);
    });

    it('forwards a matching nonce and signature as the upload proof', async () => {
      service.handleGetRegistrationLockNonce(mockClient as Socket);
      const nonce = lockNonce().nonce;

      await service.handleUploadKeyBundle(
        mockClient as Socket,
        proofPayload(nonce),
        mockServer as Server,
      );

      expect(lastUpsertArgs()).toEqual([
        1,
        expect.any(Object),
        { signature: 'client-signature', nonce },
        // Device the session's JWT names (§4); 1 until provisioning ships.
        1,
      ]);
    });

    it('consumes the nonce, so a replay cannot reuse it', async () => {
      service.handleGetRegistrationLockNonce(mockClient as Socket);
      const nonce = lockNonce().nonce;

      await service.handleUploadKeyBundle(
        mockClient as Socket,
        proofPayload(nonce),
        mockServer as Server,
      );
      await service.handleUploadKeyBundle(
        mockClient as Socket,
        proofPayload(nonce),
        mockServer as Server,
      );

      // One nonce buys exactly one attempt.
      expect(lastUpsertArgs()).toEqual([1, expect.any(Object), undefined, 1]);
    });

    it('ignores a nonce never issued to this session', async () => {
      await service.handleUploadKeyBundle(
        mockClient as Socket,
        proofPayload(Buffer.alloc(32, 3).toString('base64')),
        mockServer as Server,
      );

      expect(lastUpsertArgs()).toEqual([1, expect.any(Object), undefined, 1]);
    });

    it('ignores an expired nonce', async () => {
      service.handleGetRegistrationLockNonce(mockClient as Socket);
      const nonce = lockNonce().nonce;
      lockNonce().expiresAt = Date.now() - 1;

      await service.handleUploadKeyBundle(
        mockClient as Socket,
        proofPayload(nonce),
        mockServer as Server,
      );

      expect(lastUpsertArgs()).toEqual([1, expect.any(Object), undefined, 1]);
    });
  });

  describe('refused identity replacement', () => {
    const lockedPayload = {
      registrationId: 12345,
      identityPublicKey: 'unauthorized-identity',
      signedPreKeyId: 1,
      signedPreKeyPublic: 'spk',
      signedPreKeySignature: 'sig',
    };

    beforeEach(() => {
      keyBundlesService.upsertKeyBundle.mockRejectedValue(
        new IdentityLockedError(),
      );
    });

    it('reports the refusal on the upload channel, not as a generic error', async () => {
      await service.handleUploadKeyBundle(
        mockClient as Socket,
        lockedPayload,
        mockServer as Server,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('keyBundleUploaded', {
        success: false,
        error: 'identity_locked',
      });
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'error',
        expect.anything(),
      );
    });

    it('raises no replacement alarm for an attempt that changed nothing', async () => {
      await service.handleUploadKeyBundle(
        mockClient as Socket,
        lockedPayload,
        mockServer as Server,
      );
      await new Promise((resolve) => setImmediate(resolve));

      expect(mockClient.to).not.toHaveBeenCalled();
      expect(
        pushNotificationsService.notifyIdentityChanged,
      ).not.toHaveBeenCalled();
    });
  });

  // Phase 0b: reset ceremony (§6.2).
  describe('handleResetIdentityRequest', () => {
    it('notifies every session and push endpoint when a ceremony starts', async () => {
      const deadlineAt = new Date(Date.now() + 1000);
      identityResetService.requestReset.mockResolvedValue({
        status: 'pending',
        deadlineAt,
        shortened: false,
        phraseTooNew: false,
      });

      await service.handleResetIdentityRequest(
        mockClient as Socket,
        {},
        mockServer as Server,
      );
      await new Promise((resolve) => setImmediate(resolve));

      expect(mockClient.emit).toHaveBeenCalledWith('identityResetStatus', {
        status: 'pending',
        deadlineAt: deadlineAt.toISOString(),
        shortened: false,
        phraseTooNew: false,
      });
      // Whole room, including the requesting session.
      expect(mockServer.to).toHaveBeenCalledWith('user:1');
      expect(mockServer.emit).toHaveBeenCalledWith('identityResetPending', {
        deadlineAt: deadlineAt.toISOString(),
        shortened: false,
        occurredAt: expect.any(String) as unknown,
      });
      expect(pushNotificationsService.notifyIdentityReset).toHaveBeenCalledWith(
        1,
        'identity_reset_pending',
      );
    });

    // Amendment (xlii), UX half: the requester learns WHY the shortcut was
    // denied. Without it the answer is byte-identical to a no-phrase start.
    it('tells the requester a correct phrase was too young — and tells nobody else', async () => {
      const deadlineAt = new Date(Date.now() + 1000);
      identityResetService.requestReset.mockResolvedValue({
        status: 'pending',
        deadlineAt,
        shortened: false,
        phraseTooNew: true,
      });

      await service.handleResetIdentityRequest(
        mockClient as Socket,
        {},
        mockServer as Server,
      );
      await new Promise((resolve) => setImmediate(resolve));

      expect(mockClient.emit).toHaveBeenCalledWith('identityResetStatus', {
        status: 'pending',
        deadlineAt: deadlineAt.toISOString(),
        shortened: false,
        phraseTooNew: true,
      });
      // The room-wide alarm carries the deadline and the cancel affordance,
      // never a verdict about the phrase: those sessions did not present one,
      // and the alarm is broadcast to devices the requester may not hold.
      expect(mockServer.emit).toHaveBeenCalledWith('identityResetPending', {
        deadlineAt: deadlineAt.toISOString(),
        shortened: false,
        occurredAt: expect.any(String) as unknown,
      });
    });

    it('passes a recovery phrase through and still rings every bell', async () => {
      const deadlineAt = new Date(Date.now() + 1000);
      const phrase =
        'legal winner thank year wave sausage worth useful legal winner thank yellow';
      identityResetService.requestReset.mockResolvedValue({
        status: 'pending',
        deadlineAt,
        shortened: true,
      });

      await service.handleResetIdentityRequest(
        mockClient as Socket,
        { recoveryPhrase: phrase },
        mockServer as Server,
      );
      await new Promise((resolve) => setImmediate(resolve));

      expect(identityResetService.requestReset).toHaveBeenCalledWith(1, phrase);
      // Shortened shortens the delay; it never silences the notifications.
      expect(pushNotificationsService.notifyIdentityReset).toHaveBeenCalledWith(
        1,
        'identity_reset_pending',
      );
      expect(mockServer.emit).toHaveBeenCalledWith(
        'identityResetPending',
        expect.objectContaining({ shortened: true }),
      );
    });

    it.each(['existing', 'cooldown', 'invalid_phrase', 'locked'])(
      're-notifies nobody when the answer is %s',
      async (status) => {
        identityResetService.requestReset.mockResolvedValue({
          status,
          deadlineAt: status === 'existing' ? new Date() : null,
          shortened: false,
        });

        await service.handleResetIdentityRequest(
          mockClient as Socket,
          {},
          mockServer as Server,
        );
        await new Promise((resolve) => setImmediate(resolve));

        expect(mockClient.emit).toHaveBeenCalledWith(
          'identityResetStatus',
          expect.objectContaining({ status }),
        );
        expect(
          pushNotificationsService.notifyIdentityReset,
        ).not.toHaveBeenCalled();
        expect(mockServer.emit).not.toHaveBeenCalledWith(
          'identityResetPending',
          expect.anything(),
        );
      },
    );

    it('rejects a malformed payload without starting anything', async () => {
      await service.handleResetIdentityRequest(
        mockClient as Socket,
        // Over the length cap: the memory-hard verifier must never be handed an
        // unbounded payload. (Scalars are implicitly coerced to strings by
        // validateDto, so a number is NOT a validation failure here.)
        { recoveryPhrase: 'x'.repeat(300) },
        mockServer as Server,
      );

      expect(identityResetService.requestReset).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith(
        'error',
        expect.objectContaining({ message: expect.any(String) as unknown }),
      );
    });
  });

  describe('handleResetIdentityCancel', () => {
    it('clears every surface and notifies endpoints on a real cancel', async () => {
      identityResetService.cancelReset.mockResolvedValue(true);

      await service.handleResetIdentityCancel(
        mockClient as Socket,
        mockServer as Server,
      );
      await new Promise((resolve) => setImmediate(resolve));

      expect(mockClient.emit).toHaveBeenCalledWith(
        'identityResetCancelResult',
        { cancelled: true },
      );
      expect(mockServer.to).toHaveBeenCalledWith('user:1');
      expect(mockServer.emit).toHaveBeenCalledWith('identityResetCancelled', {
        occurredAt: expect.any(String) as unknown,
      });
      expect(pushNotificationsService.notifyIdentityReset).toHaveBeenCalledWith(
        1,
        'identity_reset_cancelled',
      );
    });

    it('stays silent when there was nothing pending to cancel', async () => {
      identityResetService.cancelReset.mockResolvedValue(false);

      await service.handleResetIdentityCancel(
        mockClient as Socket,
        mockServer as Server,
      );
      await new Promise((resolve) => setImmediate(resolve));

      expect(mockClient.emit).toHaveBeenCalledWith(
        'identityResetCancelResult',
        { cancelled: false },
      );
      expect(mockServer.emit).not.toHaveBeenCalledWith(
        'identityResetCancelled',
        expect.anything(),
      );
      expect(
        pushNotificationsService.notifyIdentityReset,
      ).not.toHaveBeenCalled();
    });
  });

  describe('handleSetRecoveryKey', () => {
    const phrase =
      'legal winner thank year wave sausage worth useful legal winner thank yellow';

    it('stores the phrase verifier and confirms', async () => {
      await service.handleSetRecoveryKey(
        mockClient as Socket,
        { phrase },
        mockServer as Server,
      );

      expect(identityResetService.setRecoveryKey).toHaveBeenCalledWith(
        1,
        phrase,
        undefined,
      );
      expect(mockClient.emit).toHaveBeenCalledWith('recoveryKeySet', {
        success: true,
      });
    });

    it('reports failure without leaking the reason', async () => {
      identityResetService.setRecoveryKey.mockRejectedValue(
        new Error('db down'),
      );

      await service.handleSetRecoveryKey(
        mockClient as Socket,
        { phrase },
        mockServer as Server,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('recoveryKeySet', {
        success: false,
      });
    });

    it('rejects a too-short phrase', async () => {
      await service.handleSetRecoveryKey(
        mockClient as Socket,
        { phrase: 'short' },
        mockServer as Server,
      );

      expect(identityResetService.setRecoveryKey).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith('recoveryKeySet', {
        success: false,
      });
    });

    // Amendment (lxxviii) clause 1: the sealed blob rides the enrolment.
    const backup = {
      blob: 'c2VhbGVkLWJsb2I=',
      salt: 'c2FsdC1zaXh0ZWVuLWI=',
      iterations: 600000,
      version: 1,
    };

    it('passes the sealed backup through to the atomic enrolment write', async () => {
      await service.handleSetRecoveryKey(
        mockClient as Socket,
        { phrase, backup },
        mockServer as Server,
      );

      expect(identityResetService.setRecoveryKey).toHaveBeenCalledWith(
        1,
        phrase,
        expect.objectContaining(backup),
      );
      expect(mockClient.emit).toHaveBeenCalledWith('recoveryKeySet', {
        success: true,
      });
    });

    it.each([
      ['iterations below the floor', { ...backup, iterations: 99999 }],
      ['iterations above the cap', { ...backup, iterations: 2000001 }],
      ['an oversized blob', { ...backup, blob: 'A'.repeat(16385) }],
      ['a non-base64 salt', { ...backup, salt: 'not base64 at all!!' }],
      ['an unknown blob version', { ...backup, version: 2 }],
    ])('refuses %s without writing anything', async (_name, badBackup) => {
      await service.handleSetRecoveryKey(
        mockClient as Socket,
        { phrase, backup: badBackup },
        mockServer as Server,
      );

      expect(identityResetService.setRecoveryKey).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith('recoveryKeySet', {
        success: false,
      });
    });
  });

  describe('handleGetIdentityBackup (amendment (lxxviii))', () => {
    it('serves the caller its stored backup verbatim', async () => {
      identityResetService.getIdentityBackup.mockResolvedValue({
        blob: 'c2VhbGVkLWJsb2I=',
        salt: 'c2FsdC1zaXh0ZWVuLWI=',
        iterations: 600000,
        version: 1,
      });

      await service.handleGetIdentityBackup(mockClient as Socket);

      expect(identityResetService.getIdentityBackup).toHaveBeenCalledWith(1);
      expect(mockClient.emit).toHaveBeenCalledWith('identityBackup', {
        exists: true,
        blob: 'c2VhbGVkLWJsb2I=',
        salt: 'c2FsdC1zaXh0ZWVuLWI=',
        iterations: 600000,
        version: 1,
      });
    });

    it('answers exists=false when no backup is stored', async () => {
      await service.handleGetIdentityBackup(mockClient as Socket);

      expect(mockClient.emit).toHaveBeenCalledWith('identityBackup', {
        exists: false,
      });
    });

    it('returns early for an unauthenticated socket', async () => {
      const noUserClient = { data: { user: null }, emit: jest.fn() };

      await service.handleGetIdentityBackup(noUserClient as unknown as Socket);

      expect(identityResetService.getIdentityBackup).not.toHaveBeenCalled();
      expect(noUserClient.emit).not.toHaveBeenCalled();
    });
  });

  describe('handleCheckOwnKeyBundle (0b additions)', () => {
    it('reports a pending ceremony and the last identity replacement', async () => {
      const deadlineAt = new Date(Date.now() + 1000);
      const replacedAt = new Date(Date.now() - 5000);
      keyBundlesService.hasKeyBundle.mockResolvedValue(true);
      keyBundlesService.latestIdentityChange.mockResolvedValue({
        at: replacedAt,
        to: 'BfOreignKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      });
      identityResetService.getStatusForUser.mockResolvedValue({
        status: 'pending',
        deadlineAt,
        shortened: true,
      });

      await service.handleCheckOwnKeyBundle(mockClient as Socket);

      expect(mockClient.emit).toHaveBeenCalledWith('ownKeyBundleStatus', {
        exists: true,
        linkingEnabled: false,
        hasIdentityBackup: false,
        hasRecoveryPhrase: false,
        identityReset: {
          status: 'pending',
          deadlineAt: deadlineAt.toISOString(),
          // Without this a session reconnecting into a 1 h recovery-key
          // ceremony would describe it as the 72 h one.
          shortened: true,
        },
        // This is what gives a session offline at the time its banner.
        identityReplacedAt: replacedAt.toISOString(),
        // (lxxx) clause 5: the key the change ENDED at, so the client can
        // tell a foreign replacement from its own identity being republished.
        identityReplacedTo: 'BfOreignKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      });
    });

    it('reports nulls when there is no ceremony and no replacement', async () => {
      keyBundlesService.hasKeyBundle.mockResolvedValue(false);
      // (lxxiii): an ENROLLED account with no ceremony still reports its lock.
      keyBundlesService.isEnrolled.mockResolvedValue(true);

      await service.handleCheckOwnKeyBundle(mockClient as Socket);

      expect(mockClient.emit).toHaveBeenCalledWith('ownKeyBundleStatus', {
        exists: false,
        linkingEnabled: true,
        // (lxxviii): drives the "create your backup" nudge when false.
        hasIdentityBackup: false,
        hasRecoveryPhrase: false,
        identityReset: null,
        identityReplacedAt: null,
        identityReplacedTo: null,
      });
    });

    it('stays silent on failure so the client keeps treating it as UNKNOWN', async () => {
      keyBundlesService.hasKeyBundle.mockRejectedValue(new Error('db down'));

      await service.handleCheckOwnKeyBundle(mockClient as Socket);

      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'ownKeyBundleStatus',
        expect.anything(),
      );
    });
  });
});
