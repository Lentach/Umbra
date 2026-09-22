import { ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import {
  ThrottlerException,
  ThrottlerLimitDetail,
  ThrottlerStorageService,
} from '@nestjs/throttler';
import { MESSAGE_METADATA } from '@nestjs/websockets/constants';
import { RATE_LIMITED, WsThrottlerGuard } from './ws-throttler.guard';

// Typed view of the two protected methods under test (avoids `as any`).
type GuardInternals = {
  getRequestResponse(context: ExecutionContext): {
    req: Record<string, unknown>;
    res: { header(name: string, value?: string | number): unknown };
  };
  getTracker(req: Record<string, unknown>): Promise<string>;
};

describe('WsThrottlerGuard', () => {
  let guard: WsThrottlerGuard;

  beforeEach(() => {
    // WsThrottlerGuard extends ThrottlerGuard; we only test the two overridden methods
    guard = new WsThrottlerGuard({} as any, {} as any, {} as any);
  });

  describe('getRequestResponse', () => {
    it('returns req derived from socket handshake headers', () => {
      const mockSocket = {
        handshake: { headers: { 'x-forwarded-for': '1.2.3.4' }, address: '127.0.0.1' },
        data: { user: { id: 42 } },
      };
      const context = {
        switchToWs: () => ({ getClient: () => mockSocket }),
      } as unknown as ExecutionContext;

      const { req, res } = (guard as any).getRequestResponse(context);

      // req must expose headers
      expect(req.headers).toEqual(mockSocket.handshake.headers);
      // res.header must be callable without throwing (no-op mock)
      expect(() => res.header('X-RateLimit-Limit', '100')).not.toThrow();
    });

    it('res.header() returns the res object for chaining', () => {
      const mockSocket = {
        handshake: { headers: {}, address: '127.0.0.1' },
        data: { user: { id: 1 } },
      };
      const context = {
        switchToWs: () => ({ getClient: () => mockSocket }),
      } as unknown as ExecutionContext;

      const { res } = (guard as any).getRequestResponse(context);
      const result = res.header('X-Test', 'value');
      expect(result).toBe(res);
    });
  });

  describe('getTracker', () => {
    it('returns user id string when socket.data.user is set', async () => {
      const req = { data: { user: { id: 99 } }, handshake: { address: '1.2.3.4' } };
      const tracker = await (guard as any).getTracker(req);
      expect(tracker).toBe('99');
    });

    it('falls back to handshake address when no user', async () => {
      const req = { data: {}, handshake: { address: '5.6.7.8' } };
      const tracker = await (guard as any).getTracker(req);
      expect(tracker).toBe('5.6.7.8');
    });

    it('falls back to "unknown" when neither user nor address', async () => {
      const req = { data: {}, handshake: {} };
      const tracker = await (guard as any).getTracker(req);
      expect(tracker).toBe('unknown');
    });
  });

  describe('getRequestResponse -> getTracker integration', () => {
    it('tracks the authenticated user id through the req produced by getRequestResponse', async () => {
      const mockSocket = {
        handshake: { headers: { 'x-forwarded-for': '1.2.3.4' }, address: '9.9.9.9' },
        data: { user: { id: 42 } },
      };
      const context = {
        switchToWs: () => ({ getClient: () => mockSocket }),
      } as unknown as ExecutionContext;

      const internals = guard as unknown as GuardInternals;
      const { req } = internals.getRequestResponse(context);
      // The spread must preserve `data` enumerability so getTracker can read the user.
      expect(await internals.getTracker(req)).toBe('42');
    });

    it('falls back to handshake.address through the req when no user is set', async () => {
      const mockSocket = {
        handshake: { headers: {}, address: '5.6.7.8' },
        data: {},
      };
      const context = {
        switchToWs: () => ({ getClient: () => mockSocket }),
      } as unknown as ExecutionContext;

      const internals = guard as unknown as GuardInternals;
      const { req } = internals.getRequestResponse(context);
      expect(await internals.getTracker(req)).toBe('5.6.7.8');
    });
  });
});

/**
 * Whose flood is it? The tracker decides which requests share a bucket, and
 * behind nginx every socket's `handshake.address` is the PROXY's. Keying a
 * tokenless socket on it put every such client in ONE bucket, so one client's
 * flood locked all of them out — on the unauthenticated `/box` namespace
 * (metadata-privacy Phase 1) that would be a remote DoS. These drive the real
 * `canActivate` over the real in-memory storage with a limit of ONE, so the
 * only thing under test is who shares a bucket with whom.
 */
describe('WsThrottlerGuard — which requests share a bucket', () => {
  /** Every socket reaches the backend through the proxy, as in prod. */
  const NGINX = '127.0.0.1';

  // The storage key is built from the gateway and handler NAMES.
  class Gateway {}
  function handler() {}

  let storage: ThrottlerStorageService;
  let guard: WsThrottlerGuard;

  beforeEach(async () => {
    storage = new ThrottlerStorageService();
    guard = new WsThrottlerGuard(
      { throttlers: [{ limit: 1, ttl: 60_000 }] },
      storage,
      new Reflector(),
    );
    await guard.onModuleInit();
  });

  // The storage arms one expiry timer per hit; leave none behind.
  afterEach(() => storage.onApplicationShutdown());

  /** A socket as the guard sees it behind the proxy. */
  type ProxiedSocket = {
    handshake: { headers: Record<string, string | string[]>; address: string };
    data: { user?: { id: number } };
    emit: jest.Mock;
  };

  function socket(
    headers: Record<string, string | string[]>,
    userId?: number,
  ): ProxiedSocket {
    return {
      handshake: { headers, address: NGINX },
      data: userId === undefined ? {} : { user: { id: userId } },
      emit: jest.fn(),
    };
  }

  /**
   * Served → true; refused by THIS limit → false. Any other throw is a broken
   * fixture and must fail the test, never read as a refusal.
   */
  async function admits(client: ProxiedSocket): Promise<boolean> {
    const context = {
      getClass: () => Gateway,
      getHandler: () => handler,
      switchToWs: () => ({ getClient: () => client, getData: () => ({}) }),
    } as unknown as ExecutionContext;
    try {
      return await guard.canActivate(context);
    } catch (error) {
      if (error instanceof ThrottlerException) return false;
      throw error;
    }
  }

  it('gives two tokenless clients behind the same proxy a bucket each, keyed on X-Real-IP', async () => {
    const a = socket({ 'x-real-ip': '203.0.113.7' });
    const b = socket({ 'x-real-ip': '198.51.100.9' });

    expect(await admits(a)).toBe(true);
    // The control: the limit really bites, so B's answer is about WHOSE
    // bucket it is, not about a limit that never engages.
    expect(await admits(a)).toBe(false);
    expect(await admits(b)).toBe(true);
  });

  it('never lets a spoofed X-Forwarded-For buy a fresh bucket', async () => {
    // nginx REPLACES X-Real-IP but APPENDS to X-Forwarded-For, so XFF's first
    // hop is whatever the client typed; rotating it must not reset the limit.
    const first = socket({
      'x-real-ip': '203.0.113.7',
      'x-forwarded-for': '1.1.1.1, 203.0.113.7',
    });
    const rotated = socket({
      'x-real-ip': '203.0.113.7',
      'x-forwarded-for': '2.2.2.2, 203.0.113.7',
    });

    expect(await admits(first)).toBe(true);
    expect(await admits(rotated)).toBe(false);
  });

  const duplicated: Array<[string, (ip: string) => string | string[]]> = [
    ['a string[]', (ip) => [ip, '::1']],
    ['a comma-joined string', (ip) => `${ip}, ::1`],
  ];
  it.each(duplicated)(
    'keys a duplicated X-Real-IP (%s) on its first hop',
    async (_shape, duplicate) => {
      expect(
        await admits(socket({ 'x-real-ip': duplicate('203.0.113.7') })),
      ).toBe(true);
      // The same first hop sent once is the same client: the same bucket.
      expect(await admits(socket({ 'x-real-ip': '203.0.113.7' }))).toBe(false);
      // The same LAST hop behind a different first one is a different client.
      expect(
        await admits(socket({ 'x-real-ip': duplicate('198.51.100.9') })),
      ).toBe(true);
    },
  );

  it('keeps an authenticated socket on its account, whatever IP it arrives from', async () => {
    expect(await admits(socket({ 'x-real-ip': '203.0.113.7' }, 42))).toBe(true);
    // The same account from another IP spends the same budget, not a new one.
    expect(await admits(socket({ 'x-real-ip': '198.51.100.9' }, 42))).toBe(
      false,
    );
    // Another account behind the same IP (a shared NAT) has its own.
    expect(await admits(socket({ 'x-real-ip': '203.0.113.7' }, 43))).toBe(true);
  });

  it('a lapsed block on one client never freezes the window of another', async () => {
    // A lapsed block is followed by a reset of THAT tracker's record. In
    // @nestjs/throttler 6.5.0 the reset cancelled the pending expiry of EVERY
    // record under the same throttler name — every `@Throttle({ default })` in
    // this app, HTTP and WS alike, share one storage — so another client's hits
    // stopped expiring and it was refused inside a limit it never exceeded.
    jest.useFakeTimers();
    try {
      const a = socket({ 'x-real-ip': '203.0.113.7' });
      const b = socket({ 'x-real-ip': '198.51.100.9' });
      expect(await admits(a)).toBe(true);
      expect(await admits(a)).toBe(false); // A is blocked for one window.
      jest.advanceTimersByTime(61_000);
      expect(await admits(b)).toBe(true); // B's one hit expires at +60 s...
      expect(await admits(a)).toBe(true); // ...and A's lapsed block resets A.
      jest.advanceTimersByTime(61_000);
      // B's earlier hit has expired: this is B's first request in its window.
      expect(await admits(b)).toBe(true);
    } finally {
      storage.onApplicationShutdown();
      jest.useRealTimers();
    }
  });
});

/**
 * A throttled WS request must ANSWER, not go silent.
 *
 * `ThrottlerGuard` throws, Nest turns an unhandled WS exception into an
 * `exception` event, and this app's client listens to named events plus `error`
 * — never `exception`. Silence therefore strands any client state staked on the
 * answer: a throttled `editMessage` used to leave an optimistically applied
 * edit on that device forever while the server and the peer kept the old text.
 */
describe('WsThrottlerGuard — a throttled request answers in its own contract', () => {
  const detail = { timeToExpire: 42 } as ThrottlerLimitDetail;

  /** A guard whose `super.throwThrottlingException` is observable. */
  class TestGuard extends WsThrottlerGuard {
    threw = false;
    // The real base method throws ThrottlerException; the contract under test is
    // "answers AND still refuses", so record the refusal instead of asserting on
    // Nest's exception type.
    protected async throwThrottlingException(
      context: ExecutionContext,
      d: ThrottlerLimitDetail,
    ): Promise<void> {
      // ONLY the rejection may set this. Setting it unconditionally after the
      // await made both refusal tests unable to fail: dropping the guard's
      // `return super.…` — i.e. telling the caller it is rate limited and then
      // SERVING it — would have kept them green.
      await super.throwThrottlingException(context, d).catch(() => {
        this.threw = true;
      });
    }

    async refuse(context: ExecutionContext) {
      await this.throwThrottlingException(context, detail);
    }
  }

  function contextFor(
    event: string | undefined,
    data: unknown,
  ): { context: ExecutionContext; emit: jest.Mock } {
    const emit = jest.fn();
    const client = { data: { user: { id: 7 } }, emit };
    const handler = function handler() {};
    if (event) Reflect.defineMetadata(MESSAGE_METADATA, event, handler);
    const context = {
      switchToWs: () => ({ getClient: () => client, getData: () => data }),
      getHandler: () => handler,
    } as unknown as ExecutionContext;
    return { context, emit };
  }

  function guard(): TestGuard {
    // The storage/options/reflector are never reached: the refusal path does not
    // consult them. Passing stubs keeps the fixture from pre-arming behaviour
    // the code under test is supposed to derive itself.
    return new TestGuard(
      { throttlers: [] } as never,
      { increment: jest.fn() } as never,
      { get: jest.fn(), getAllAndOverride: jest.fn() } as never,
    );
  }

  it('answers a throttled editMessage on editMessageFailed so the optimistic edit reverts', async () => {
    const { context, emit } = contextFor('editMessage', { messageId: 501 });

    await guard().refuse(context);

    // The client's existing onEditMessageFailed handler reverts on THIS shape —
    // which is exactly why the refusal rides the request's own event instead of
    // some new global one.
    expect(emit).toHaveBeenCalledWith('editMessageFailed', {
      messageId: 501,
      reason: RATE_LIMITED,
      retryAfterMs: 42_000,
    });
  });

  it('answers a throttled pinMessage on messagePinFailed, carrying the conversation it was asked about', async () => {
    const { context, emit } = contextFor('pinMessage', {
      conversationId: 91,
      messageId: 77,
    });

    await guard().refuse(context);

    // The conversation id must come FROM THE REQUEST: the client keys its
    // pre-pin snapshot by conversation, so a hardcoded or absent id reverts
    // nothing. 91 is deliberately unlike the 7 the fixture uses for the user.
    expect(emit).toHaveBeenCalledWith('messagePinFailed', {
      conversationId: 91,
      reason: RATE_LIMITED,
      retryAfterMs: 42_000,
    });
  });

  it('answers a throttled setDisappearingTimer on disappearingTimerFailed, carrying the conversation it was asked about', async () => {
    const { context, emit } = contextFor('setDisappearingTimer', {
      conversationId: 91,
      seconds: 60,
    });

    await guard().refuse(context);

    // Same contract as the pin, and the same reason it is a DEDICATED event:
    // this guard refuses pre-handler, so it knows the requested `seconds` but
    // not the timer being displaced. Echoing `disappearingTimerUpdated` would
    // CONFIRM a change that never happened — and this value is a safety
    // promise, so a device left showing a timer the server never accepted tells
    // the user messages will vanish when they will not.
    //
    // The `seconds` must NOT appear: the client reverts from its own snapshot,
    // and shipping the attempted value back invites a client to apply it.
    expect(emit).toHaveBeenCalledWith('disappearingTimerFailed', {
      conversationId: 91,
      reason: RATE_LIMITED,
      retryAfterMs: 42_000,
    });
  });

  it('never answers a throttled unpinMessage in-contract — it stakes no optimistic state', async () => {
    const { context, emit } = contextFor('unpinMessage', { conversationId: 91 });

    await guard().refuse(context);

    // An `unpinMessage` entry would be an answer no client code drives to a
    // conclusion, which is the unreachable-code case the table forbids (it is
    // why `uploadKeyBundle` was removed). The visible `error` fallback is the
    // whole contract here.
    expect(emit).toHaveBeenCalledWith('error', {
      message: RATE_LIMITED,
      event: 'unpinMessage',
      retryAfterMs: 42_000,
    });
  });

  it.each([
    ['openProvisioning', 'provisioningOpened'],
    ['provisioningHello', 'provisioningHelloAck'],
    ['provisionDevice', 'provisionDeviceAck'],
    ['provisioningComplete', 'provisioningCompleted'],
    ['cancelProvisioning', 'provisioningCancelled'],
    ['revokeDevice', 'deviceRevocationCompleted'],
    ['updateDeviceList', 'deviceListUpdated'],
  ])('answers %s on its own %s event', async (request, answer) => {
    const { context, emit } = contextFor(request, {});

    await guard().refuse(context);

    expect(emit).toHaveBeenCalledWith(answer, {
      success: false,
      error: RATE_LIMITED,
      retryAfterMs: 42_000,
    });
  });

  it('falls back to the error event for an unmapped handler — never silence', async () => {
    const { context, emit } = contextFor('typing', {});

    await guard().refuse(context);

    // `error` is already wired on the client and already marks in-flight sends
    // failed, so an unlisted handler degrades to a visible error.
    expect(emit).toHaveBeenCalledWith('error', {
      message: RATE_LIMITED,
      event: 'typing',
      retryAfterMs: 42_000,
    });
  });

  it('still answers when the handler carries no message metadata', async () => {
    const { context, emit } = contextFor(undefined, {});

    await guard().refuse(context);

    expect(emit).toHaveBeenCalledWith('error', {
      message: RATE_LIMITED,
      event: undefined,
      retryAfterMs: 42_000,
    });
  });

  it('STILL REFUSES after answering — the answer is a courtesy, not an escape', async () => {
    const { context } = contextFor('editMessage', { messageId: 1 });
    const g = guard();

    await g.refuse(context);

    // Without this the limit would have no teeth: the caller would be told it is
    // rate limited and then be served anyway.
    expect(g.threw).toBe(true);
  });

  it('survives a client that cannot be emitted to, and still refuses', async () => {
    const handler = function handler() {};
    Reflect.defineMetadata(MESSAGE_METADATA, 'editMessage', handler);
    const context = {
      switchToWs: () => ({
        getClient: () => {
          throw new Error('socket gone');
        },
        getData: () => ({}),
      }),
      getHandler: () => handler,
    } as unknown as ExecutionContext;
    const g = guard();

    await g.refuse(context);

    expect(g.threw).toBe(true);
  });
});
