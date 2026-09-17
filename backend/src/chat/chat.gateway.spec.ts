import { JwtService } from '@nestjs/jwt';
import { ChatGateway } from './chat.gateway';
import { UsersService } from '../users/users.service';
import { DevicesService } from '../key-bundles/devices.service';
import { Socket } from 'socket.io';

interface GatewayWithKeyExchange {
  chatKeyExchangeService: {
    handleCheckOwnKeyBundle: jest.Mock;
  };
}

function createGateway(): ChatGateway {
  const noop = {} as any;
  const keyExchange = {
    deliverPendingSessionRebuilds: jest.fn(),
    handleCheckOwnKeyBundle: jest.fn(),
  } as any;
  // The device row is touched on every connect (Phase 1, spec §4); it must
  // never be able to break the connection, so it is stubbed and ignored here.
  // `isRevoked` is the §5.5 connect gate: the default answer is "not revoked",
  // and the revocation suite drives the true case.
  const devices: Pick<DevicesService, 'touch' | 'isRevoked'> = {
    touch: jest.fn(),
    isRevoked: jest.fn<Promise<boolean>, [number, number]>(() =>
      Promise.resolve(false),
    ),
  };
  return new ChatGateway(
    { verify: jest.fn() } as unknown as JwtService,
    { findById: jest.fn() } as unknown as UsersService,
    noop,
    noop,
    noop,
    keyExchange,
    noop,
    noop,
    noop,
    noop,
    noop,
    noop,
    devices as DevicesService,
    noop,
    noop,
  );
}

function createMockClient(
  overrides: Partial<{
    token: string | undefined;
    emit: jest.Mock;
    disconnect: jest.Mock;
    join: jest.Mock;
    id: string;
  }> = {},
) {
  const emit = overrides.emit ?? jest.fn();
  const disconnect = overrides.disconnect ?? jest.fn();
  const join = overrides.join ?? jest.fn();
  return {
    id: overrides.id ?? 'socket-test-1',
    handshake: {
      auth: overrides.token !== undefined ? { token: overrides.token } : {},
    },
    data: {} as Record<string, unknown>,
    emit,
    disconnect,
    join,
  };
}

/** Typed view over a mock client's emits, so payload reads stay lint-clean. */
function emittedPayload(
  client: { emit: jest.Mock },
  event: string,
): Record<string, unknown> | undefined {
  const calls = client.emit.mock.calls as [string, Record<string, unknown>][];
  return calls.find((call) => call[0] === event)?.[1];
}

/**
 * Test-only backdoor to the gateway's private presence map. A cast is the
 * only option here — the field is deliberately private and a runtime check
 * would prove nothing the class does not already guarantee.
 */
function onlineUsersOf(gateway: ChatGateway): Map<number, string> {
  const withPresence = gateway as unknown as {
    onlineUsers: Map<number, string>;
  };
  return withPresence.onlineUsers;
}

describe('ChatGateway handleConnection', () => {
  let gateway: ChatGateway;
  let jwtService: { verify: jest.Mock };
  let usersService: { findById: jest.Mock };

  beforeEach(() => {
    gateway = createGateway();
    jwtService = (gateway as any).jwtService;
    usersService = (gateway as any).usersService;
  });

  it('emits socketReady after successful JWT auth and user lookup', async () => {
    const client = createMockClient({ token: 'valid-jwt' });
    jwtService.verify.mockReturnValue({ sub: 42 });
    usersService.findById.mockResolvedValue({
      id: 42,
      username: 'alice',
      tag: '0001',
    });

    await gateway.handleConnection(client as any);

    expect(jwtService.verify).toHaveBeenCalledWith('valid-jwt');
    expect(usersService.findById).toHaveBeenCalledWith(42);
    expect(client.join).toHaveBeenCalledWith('user:42');
    expect(
      (gateway as any).chatKeyExchangeService.deliverPendingSessionRebuilds,
    ).toHaveBeenCalledWith(client);
    expect(client.emit).toHaveBeenCalledWith('socketReady', {
      serverTime: expect.any(String) as unknown,
      // The client cannot derive which device it is, and a fan-out send must
      // know: it addresses every OTHER own device and never its own (spec §5.3).
      deviceId: 1,
    });
    // The client parses this and refuses to destroy expired plaintext when it
    // cannot. An unparseable stamp would silently disable that path forever.
    const ready = emittedPayload(client, 'socketReady');
    expect(Number.isNaN(Date.parse(String(ready?.serverTime)))).toBe(false);
    expect(client.disconnect).not.toHaveBeenCalled();
    expect(client.data.user).toEqual({
      id: 42,
      username: 'alice',
      tag: '0001',
      // A token issued before the claim existed is device 1 (§8) — key
      // material has to land in the account's original namespace, never in
      // an "unknown" one.
      deviceId: 1,
    });
  });

  it('does not emit socketReady when token is missing', async () => {
    const client = createMockClient();

    await gateway.handleConnection(client as any);

    expect(client.emit).not.toHaveBeenCalledWith(
      'socketReady',
      expect.anything(),
    );
    expect(client.disconnect).toHaveBeenCalled();
    expect(jwtService.verify).not.toHaveBeenCalled();
  });

  describe('the revoked-device connect gate (§5.5, amendment (xxii))', () => {
    const devicesOf = (g: ChatGateway) =>
      (g as unknown as { devicesService: { isRevoked: jest.Mock } })
        .devicesService;

    it('refuses a revoked device holding a still-valid JWT, and says why', async () => {
      const client = createMockClient({ token: 'valid-jwt' });
      jwtService.verify.mockReturnValue({ sub: 42, deviceId: 2 });
      usersService.findById.mockResolvedValue({
        id: 42,
        username: 'alice',
        tag: '0001',
      });
      devicesOf(gateway).isRevoked.mockResolvedValue(true);

      await gateway.handleConnection(client as unknown as Socket);

      // Told, then dropped (amendment (xxvi)) — otherwise a kicked device
      // shows only the generic connection-lost banner and keeps retrying.
      expect(client.emit).toHaveBeenCalledWith('deviceRevoked', {
        userId: 42,
        deviceId: 2,
      });
      expect(client.disconnect).toHaveBeenCalled();
      expect(client.emit).not.toHaveBeenCalledWith(
        'socketReady',
        expect.anything(),
      );
      // The session was refused BEFORE any room join or row touch.
      expect(client.join).not.toHaveBeenCalled();
      expect(client.data.user).toBeUndefined();
    });

    it('admits a device whose row does not exist yet (legacy §8 accounts)', async () => {
      const client = createMockClient({ token: 'valid-jwt' });
      jwtService.verify.mockReturnValue({ sub: 42 });
      usersService.findById.mockResolvedValue({
        id: 42,
        username: 'alice',
        tag: '0001',
      });
      // A missing row answers false, never true — the whole point of the
      // predicate's polarity.
      devicesOf(gateway).isRevoked.mockResolvedValue(false);

      await gateway.handleConnection(client as unknown as Socket);

      expect(client.emit).toHaveBeenCalledWith(
        'socketReady',
        expect.objectContaining({ deviceId: 1 }),
      );
      expect(client.disconnect).not.toHaveBeenCalled();
    });

    it('checks the gate for the device named in the claim', async () => {
      const client = createMockClient({ token: 'valid-jwt' });
      jwtService.verify.mockReturnValue({ sub: 42, deviceId: 3 });
      usersService.findById.mockResolvedValue({
        id: 42,
        username: 'alice',
        tag: '0001',
      });

      await gateway.handleConnection(client as unknown as Socket);

      expect(devicesOf(gateway).isRevoked).toHaveBeenCalledWith(42, 3);
    });
  });

  it('takes the device from the token claim when the session names one', async () => {
    const client = createMockClient({ token: 'valid-jwt' });
    jwtService.verify.mockReturnValue({ sub: 42, deviceId: 3 });
    usersService.findById.mockResolvedValue({
      id: 42,
      username: 'alice',
      tag: '0001',
    });

    await gateway.handleConnection(client as any);

    // Defaulting to 1 here would hand this session another device's key
    // namespace: its bundle, its one-time pre-keys, its epoch.
    expect((client.data.user as { deviceId?: number }).deviceId).toBe(3);
  });

  it('does not emit socketReady when user is not found', async () => {
    const client = createMockClient({ token: 'valid-jwt' });
    jwtService.verify.mockReturnValue({ sub: 99 });
    usersService.findById.mockResolvedValue(null);

    await gateway.handleConnection(client as any);

    expect(client.emit).not.toHaveBeenCalledWith(
      'socketReady',
      expect.anything(),
    );
    expect(client.disconnect).toHaveBeenCalled();
  });

  it('does not emit socketReady when JWT verification fails', async () => {
    const client = createMockClient({ token: 'bad-jwt' });
    jwtService.verify.mockImplementation(() => {
      throw new Error('invalid token');
    });

    await gateway.handleConnection(client as any);

    expect(client.emit).not.toHaveBeenCalledWith(
      'socketReady',
      expect.anything(),
    );
    expect(client.disconnect).toHaveBeenCalled();
    expect(usersService.findById).not.toHaveBeenCalled();
  });

  it('disconnects when the token predates a password change', async () => {
    const client = createMockClient({ token: 'old-jwt' });
    jwtService.verify.mockReturnValue({ sub: 7, iat: 1000 });
    usersService.findById.mockResolvedValue({
      id: 7,
      username: 'me',
      tag: '0007',
      passwordChangedAt: new Date(2000 * 1000), // changedAt=2000s > iat=1000s -> invalid
    });

    await gateway.handleConnection(client as unknown as Socket);

    expect(client.disconnect).toHaveBeenCalled();
    expect(client.emit).not.toHaveBeenCalledWith(
      'socketReady',
      expect.anything(),
    );
  });
});

describe('ChatGateway presence is room-based (BE-007)', () => {
  let gateway: ChatGateway;
  let jwtService: { verify: jest.Mock };
  let usersService: { findById: jest.Mock };

  /** Mock clients are structural stand-ins; Socket has far more surface. */
  interface GatewayInternals {
    jwtService: { verify: jest.Mock };
    usersService: { findById: jest.Mock };
  }

  /** Mock clients are structural stand-ins; Socket has far more surface. */
  const asSocket = (client: unknown): Socket => client as Socket;

  beforeEach(() => {
    gateway = createGateway();
    // Private collaborators, reachable only by assertion in a unit test.
    const internals = gateway as unknown as GatewayInternals;
    jwtService = internals.jwtService;
    usersService = internals.usersService;
    jwtService.verify.mockReturnValue({ sub: 37 });
    usersService.findById.mockResolvedValue({
      id: 37,
      username: 'me',
      tag: '0037',
    });
  });

  // iOS PWA suspend/resume: the device reconnects with a NEW socket while the
  // abandoned OLD socket lingers on the server until its ping times out (~20s).
  // The gateway used to keep a userId -> socketId map, so that stale disconnect
  // could evict the live socket and silently push peers' newMessage to push
  // instead of delivering it. Room membership has no such failure mode: both
  // sockets are in `user:37`, and Socket.IO removes each on its own disconnect.
  it('every authenticated socket joins the per-user room, so a second tab is addressable', async () => {
    const oldSocket = createMockClient({ token: 'jwt', id: 'OLD' });
    const newSocket = createMockClient({ token: 'jwt', id: 'NEW' });

    await gateway.handleConnection(asSocket(oldSocket));
    await gateway.handleConnection(asSocket(newSocket));

    // Both tabs joined the SAME room — this is what makes multi-tab delivery
    // work. Under the old map the second connect overwrote the first.
    expect(oldSocket.join).toHaveBeenCalledWith('user:37');
    expect(newSocket.join).toHaveBeenCalledWith('user:37');
  });

  // Ciphertext is addressed per device (spec §5.3), so the socket must be in a
  // device room too — otherwise a fan-out send reaches nobody.
  it('every authenticated socket also joins its per-DEVICE room', async () => {
    const client = createMockClient({ token: 'jwt' });

    await gateway.handleConnection(asSocket(client));

    expect(client.join).toHaveBeenCalledWith('user:37');
    // A token predating the deviceId claim is device 1 (§8), never "unknown".
    expect(client.join).toHaveBeenCalledWith('device:37:1');
  });

  it('a stale old-socket disconnect does not evict anything (no presence bookkeeping left)', async () => {
    const oldSocket = createMockClient({ token: 'jwt', id: 'OLD' });
    const newSocket = createMockClient({ token: 'jwt', id: 'NEW' });

    await gateway.handleConnection(asSocket(oldSocket));
    await gateway.handleConnection(asSocket(newSocket));

    // Must not throw and must not touch the live socket. The guarded-delete
    // dance this replaced existed only because a single-socket map could be
    // clobbered; there is nothing left to clobber.
    expect(() => gateway.handleDisconnect(asSocket(oldSocket))).not.toThrow();
    expect(newSocket.disconnect).not.toHaveBeenCalled();
  });

  it('disconnect of an unauthenticated socket is a no-op', () => {
    const socket = createMockClient({ token: undefined, id: 'ANON' });
    socket.data = {};

    expect(() => gateway.handleDisconnect(asSocket(socket))).not.toThrow();
  });
});

describe('ChatGateway handleCheckOwnKeyBundle', () => {
  it('delegates the authenticated caller socket without accepting a user id', async () => {
    const gateway = createGateway();
    const client = createMockClient();
    // Test-only access to the gateway's injected service.
    const gatewayWithKeyExchange = gateway as unknown as GatewayWithKeyExchange;
    const keyExchange = gatewayWithKeyExchange.chatKeyExchangeService;

    await gateway.handleCheckOwnKeyBundle(client as unknown as Socket);

    expect(keyExchange.handleCheckOwnKeyBundle).toHaveBeenCalledWith(client);
  });
});

describe('ChatGateway handleGetServerTime', () => {
  it('answers with a parseable ISO serverTime on the serverTime event', () => {
    const gateway = createGateway();
    const client = createMockClient();

    gateway.handleGetServerTime(client as any);

    expect(client.emit).toHaveBeenCalledWith('serverTime', {
      serverTime: expect.any(String) as unknown,
    });
    // Same contract as socketReady: the client refuses to destroy expired
    // plaintext without a clock it can parse, so an unparseable stamp would
    // silently disable the in-session sweep this event exists to feed.
    const payload = emittedPayload(client, 'serverTime');
    expect(Number.isNaN(Date.parse(String(payload?.serverTime)))).toBe(false);
  });
});
