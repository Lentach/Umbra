import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createContext, runInContext } from 'node:vm';

/**
 * The PWA push service worker (`frontend/web/web-push-sw.js`) has no runner of
 * its own, and what it must never do is easy to break silently: Safari
 * REVOKES a push subscription after 3 pushes that post no notification, and a
 * box wake-up has to land on the right chat. The REAL file is loaded into a
 * `node:vm` context with a fake `self`, tray and IndexedDB.
 */
const SW_SOURCE = readFileSync(
  join(__dirname, '../../../frontend/web/web-push-sw.js'),
  'utf8',
);

interface Card {
  title: string;
  body: string;
  tag: string;
  data: Record<string, unknown>;
}

interface Page {
  id: string;
  focused: boolean;
  visibilityState: 'visible' | 'hidden';
  postMessage: () => void;
}

interface SwEvent {
  data?: { json: () => unknown };
  waitUntil: (work: Promise<unknown>) => void;
}

type Listener = (event: SwEvent | MessageEventLike) => void;

interface MessageEventLike {
  data: Record<string, unknown>;
  source: { id: string };
  waitUntil: (work: Promise<unknown>) => void;
}

const APPLE = 'https://web.push.apple.com/Q';
const CHROME = 'https://fcm.googleapis.com/fcm/send/x';

const hiddenPage = (): Page[] => [
  {
    id: 'c1',
    focused: false,
    visibilityState: 'hidden',
    postMessage: () => {},
  },
];
const visiblePage = (): Page[] => [
  {
    id: 'c1',
    focused: true,
    visibilityState: 'visible',
    postMessage: () => {},
  },
];

interface FetchInit {
  method: string;
  headers: Record<string, string>;
  body: string;
  credentials: string;
  cache: string;
  signal?: AbortSignal;
}

interface FetchAnswer {
  status: number;
  ok: boolean;
  json: () => Promise<unknown>;
}

function makeWorker(options: {
  endpoint?: string;
  pages?: Page[];
  store?: Record<string, unknown>;
  /** No push subscription at all (it was already dropped). */
  noSubscription?: boolean;
  /** The `fetch` of the worker; absent = the worker has none. */
  fetch?: (url: string, init: FetchInit) => Promise<FetchAnswer>;
  /** `unsubscribe()` fails. */
  unsubscribeFails?: boolean;
}) {
  const listeners: Record<string, Listener> = {};
  const tray: Card[] = [];
  const shown: Card[] = [];
  const badge: number[] = [];
  const kv = new Map<string, unknown>(Object.entries(options.store ?? {}));

  const indexedDB = {
    open: () => {
      const request: {
        result?: unknown;
        onupgradeneeded?: () => void;
        onsuccess?: () => void;
      } = {};
      setTimeout(() => {
        request.result = {
          createObjectStore: () => {},
          close: () => {},
          transaction: () => {
            const tx: { oncomplete?: () => void } = {};
            return Object.assign(tx, {
              objectStore: () => ({
                get: (key: string) => {
                  const get: { result?: unknown; onsuccess?: () => void } = {};
                  setTimeout(() => {
                    get.result = kv.has(key)
                      ? structuredClone(kv.get(key))
                      : undefined;
                    get.onsuccess?.();
                    // A transaction ends once its requests have run (a
                    // read-modify-write that leaves the value alone writes
                    // nothing, and still has to finish).
                    setTimeout(() => tx.oncomplete?.(), 0);
                  }, 0);
                  return get;
                },
                put: (value: unknown, key: string) => {
                  kv.set(key, structuredClone(value));
                  setTimeout(() => tx.oncomplete?.(), 0);
                },
                delete: (key: string) => {
                  kv.delete(key);
                  setTimeout(() => tx.oncomplete?.(), 0);
                },
              }),
            });
          },
        };
        request.onupgradeneeded?.();
        request.onsuccess?.();
      }, 0);
      return request;
    },
  };

  const clock = { now: 1_700_000_000_000 };
  const unsubscribed: number[] = [];
  const fetches: { url: string; init: FetchInit }[] = [];
  const registration = {
    showNotification: (
      title: string,
      opts: { body: string; tag: string; data: Record<string, unknown> },
    ) => {
      const card: Card = {
        title,
        body: opts.body,
        tag: opts.tag,
        data: opts.data,
      };
      shown.push(card);
      tray.push(card);
      return Promise.resolve();
    },
    getNotifications: (filter?: { tag?: string }) =>
      Promise.resolve(
        tray
          .filter((c) => !filter?.tag || c.tag === filter.tag)
          .map((c) => ({
            tag: c.tag,
            data: c.data,
            close: () => {
              const at = tray.indexOf(c);
              if (at >= 0) tray.splice(at, 1);
            },
          })),
      ),
    pushManager: {
      getSubscription: () =>
        Promise.resolve(
          options.noSubscription
            ? null
            : {
                endpoint: options.endpoint ?? CHROME,
                unsubscribe: () => {
                  if (options.unsubscribeFails) {
                    return Promise.reject(new Error('unsubscribe refused'));
                  }
                  unsubscribed.push(clock.now);
                  return Promise.resolve(true);
                },
              },
        ),
    },
  };

  const self = {
    addEventListener: (type: string, fn: Listener) => {
      listeners[type] = fn;
    },
    registration,
    skipWaiting: () => {},
    navigator: {
      setAppBadge: (n: number) => {
        badge.push(n);
        return Promise.resolve();
      },
      clearAppBadge: () => {
        badge.push(0);
        return Promise.resolve();
      },
    },
  };

  const answer = options.fetch;
  const context = createContext({
    self,
    indexedDB,
    setTimeout,
    clearTimeout,
    clients: {
      matchAll: () => Promise.resolve(options.pages ?? hiddenPage()),
      openWindow: () => Promise.resolve(),
    },
    console,
    Promise,
    Set,
    Number,
    Object,
    Array,
    JSON,
    AbortController,
    isNaN,
    // Every `Date` the worker reads is `Date.now()`; the test moves it.
    Date: { now: () => clock.now },
    ...(answer
      ? {
          fetch: (url: string, init: FetchInit) => {
            fetches.push({ url, init });
            return answer(url, init);
          },
        }
      : {}),
  });
  runInContext(SW_SOURCE, context);

  const run = async (
    type: string,
    event: Omit<SwEvent, 'waitUntil'> | Omit<MessageEventLike, 'waitUntil'>,
  ) => {
    const work: Promise<unknown>[] = [];
    listeners[type]({ ...event, waitUntil: (w) => work.push(w) });
    await Promise.all(work);
  };

  return {
    tray,
    shown,
    badge,
    kv,
    clock,
    unsubscribed,
    fetches,
    push: (payload: object) => run('push', { data: { json: () => payload } }),
    message: (data: Record<string, unknown>) =>
      run('message', { data, source: { id: 'c1' } }),
    tags: () => tray.map((c) => c.tag).sort(),
  };
}

const NIDS = { 'box-nids': { NID_A: 42, NID_B: 7 } };

describe('web-push-sw.js', () => {
  describe('a box wake-up (decision 77)', () => {
    it('cards the chat its nid names, with the count, and a tap target', async () => {
      const sw = makeWorker({ store: NIDS });

      await sw.push({ type: 'new_message', n: 'NID_A', c: 3 });

      expect(sw.tray).toEqual([
        {
          title: 'Umbra',
          body: '3 new messages',
          tag: 'conversation-42',
          data: expect.objectContaining({ conversationId: 42 }) as unknown,
        },
      ]);
      expect(sw.badge).toEqual([3]);
    });

    it('a repeated wake-up for a queue does not double its count', async () => {
      const sw = makeWorker({ store: NIDS });

      await sw.push({ type: 'new_message', n: 'NID_A', c: 2 });
      await sw.push({ type: 'new_message', n: 'NID_A', c: 2 });

      expect(sw.tray).toHaveLength(1);
      expect(sw.tray[0].body).toBe('2 new messages');
      expect(sw.badge.at(-1)).toBe(2);
    });

    it('a nid the page never told it about still posts a card, naming no chat', async () => {
      const sw = makeWorker({ store: NIDS });

      await sw.push({ type: 'new_message', n: 'NID_UNKNOWN', c: 1 });

      expect(sw.tags()).toEqual(['new-message']);
    });

    it('an unreadable table still posts a card instead of dropping the push', async () => {
      const sw = makeWorker({ store: { 'box-nids': 'not an object' } });

      await sw.push({ type: 'new_message', n: 'NID_A', c: 1 });

      expect(sw.tags()).toEqual(['new-message']);
    });

    it('while the app is on screen it moves the badge and posts no card', async () => {
      const sw = makeWorker({ store: NIDS, pages: visiblePage() });

      await sw.push({ type: 'new_message', n: 'NID_A', c: 1 });

      expect(sw.shown).toEqual([]);
      expect(sw.badge).toEqual([1]);
    });

    it('on an Apple endpoint a push may NEVER post nothing: Safari revokes after 3', async () => {
      const sw = makeWorker({
        endpoint: APPLE,
        store: NIDS,
        pages: visiblePage(),
      });

      await sw.push({ type: 'new_message', n: 'NID_A', c: 1 });

      // Posted, and closed at once: nothing stays in the tray.
      expect(sw.shown).toHaveLength(1);
      expect(sw.tray).toEqual([]);
    });

    it('the setup challenge posts and closes a card on an Apple endpoint', async () => {
      const sw = makeWorker({ endpoint: APPLE, pages: visiblePage() });

      await sw.push({ type: 'notifier_challenge', code: 'x' });

      expect(sw.shown).toHaveLength(1);
      expect(sw.tray).toEqual([]);
    });
  });

  describe('reading clears (decision 77, work item D)', () => {
    it('close-conv takes the chat card and the page total replaces the box counts', async () => {
      const sw = makeWorker({ store: NIDS });
      await sw.push({ type: 'new_message', n: 'NID_A', c: 3 });
      await sw.push({ type: 'new_message', n: 'NID_B', c: 2 });

      await sw.message({
        type: 'close-conv',
        conversationId: 42,
        unreadTotal: 1,
      });

      expect(sw.tags()).toEqual(['conversation-7']);
      expect(sw.kv.get('box-wake')).toEqual({ base: 1, waiting: {} });
      expect(sw.badge.at(-1)).toBe(1);
    });

    it('the generic card goes when the page reports nothing unread, and not before', async () => {
      const sw = makeWorker({ store: NIDS });
      await sw.push({ type: 'new_message', n: 'UNKNOWN', c: 1 });

      await sw.message({
        type: 'sweep',
        unreadConversationIds: [5],
        unreadTotal: 2,
      });
      expect(sw.tags()).toEqual(['new-message']);

      await sw.message({
        type: 'sweep',
        unreadConversationIds: [],
        unreadTotal: 0,
      });
      expect(sw.tags()).toEqual([]);
    });
  });

  describe('the page asks for a card (decision 76)', () => {
    it('posts one per chat and a bigger count replaces it', async () => {
      const sw = makeWorker({});

      await sw.message({ type: 'local-card', conversationId: 42, count: 1 });
      await sw.message({ type: 'local-card', conversationId: 42, count: 3 });

      expect(sw.tray).toHaveLength(1);
      expect(sw.tray[0]).toMatchObject({
        title: 'Umbra',
        body: '3 new messages',
        tag: 'conversation-42',
        data: { conversationId: 42 },
      });
    });

    it('stays silent when a push card already covers the chat (a thawed page re-reads its blob)', async () => {
      const sw = makeWorker({ store: NIDS });
      await sw.push({ type: 'new_message', n: 'NID_A', c: 1 });
      const before = sw.shown.length;

      await sw.message({ type: 'local-card', conversationId: 42, count: 1 });
      expect(sw.shown).toHaveLength(before);

      await sw.message({ type: 'local-card', conversationId: 42, count: 2 });
      expect(sw.shown).toHaveLength(before + 1);
      expect(sw.tray[0].body).toBe('2 new messages');
    });
  });

  describe('the old path is unchanged', () => {
    it('cards under the sender name and sweeps chats that are no longer unread', async () => {
      const sw = makeWorker({});

      await sw.push({
        type: 'new_message',
        conversationId: 42,
        senderName: 'Bob',
        unreadCount: 15,
        unreadTotal: 15,
        unreadConversationIds: [42],
      });
      await sw.push({
        type: 'new_message',
        conversationId: 7,
        unreadCount: 1,
        unreadTotal: 16,
        unreadConversationIds: [7],
      });

      expect(sw.shown[0]).toMatchObject({
        title: 'Bob',
        body: '15 new messages',
        tag: 'conversation-42',
      });
      expect(sw.tags()).toEqual(['conversation-7']);
    });
  });

  // Decision 130 (E130a): a device revoked while closed ends its own
  // wake-ups. The box cannot (it ties no queue to a device), so after a box
  // wake-up the worker asks `POST /auth/refresh`, with the token the page left
  // in `wake-session`, whether the device was revoked, and unsubscribes on the
  // explicit answer ONLY.
  describe('a revoked, closed device ends its own wake-ups (decision 130)', () => {
    const SESSION = {
      'wake-session': { refresh: 'RT-1', api: 'https://app.test' },
    };
    const WAKE = { type: 'new_message', n: 'NID_A', c: 1 };
    const HOUR = 60 * 60 * 1000;
    const MINUTE = 60 * 1000;

    const answer = (status: number, body?: unknown): FetchAnswer => ({
      status,
      ok: status >= 200 && status < 300,
      json: () =>
        body === undefined
          ? Promise.reject(new Error('not JSON'))
          : Promise.resolve(body),
    });
    const revoked = () =>
      Promise.resolve(answer(401, { message: 'Device revoked' }));
    const closed = (
      reply: (url: string, init: FetchInit) => Promise<FetchAnswer>,
    ) =>
      makeWorker({ store: { ...NIDS, ...SESSION }, pages: [], fetch: reply });

    it('unsubscribes and deletes its copy of the token on the explicit answer, after the card', async () => {
      const sw = closed(revoked);

      await sw.push(WAKE);

      // The wake-up itself is never delayed or dropped.
      expect(sw.shown).toHaveLength(1);
      expect(sw.unsubscribed).toHaveLength(1);
      expect(sw.kv.has('wake-session')).toBe(false);
      // The app's own refresh call: the refresh token and nothing else — no
      // nid, no chat, no device or user id, no Authorization header.
      expect(sw.fetches).toHaveLength(1);
      expect(sw.fetches[0].url).toBe('https://app.test/auth/refresh');
      expect(sw.fetches[0].init).toMatchObject({
        method: 'POST',
        credentials: 'omit',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: 'RT-1' }),
      });
    });

    it('does nothing while a window of ours exists: an open page owns its session', async () => {
      const sw = makeWorker({
        store: { ...NIDS, ...SESSION },
        pages: hiddenPage(),
        fetch: revoked,
      });

      await sw.push(WAKE);

      expect(sw.fetches).toEqual([]);
      expect(sw.unsubscribed).toEqual([]);
    });

    it('does nothing without a stored session (logged out, or a page that predates the record)', async () => {
      const sw = makeWorker({ store: NIDS, pages: [], fetch: revoked });

      await sw.push(WAKE);

      expect(sw.fetches).toEqual([]);
      expect(sw.unsubscribed).toEqual([]);
      expect(sw.shown).toHaveLength(1);
    });

    it.each([
      [
        'a 201 (what POST /auth/refresh really answers)',
        () => Promise.resolve(answer(201, { access_token: 'x' })),
      ],
      ['a 200', () => Promise.resolve(answer(200, { access_token: 'x' }))],
      [
        'a 401 for a session that is simply gone (logout, password change)',
        () =>
          Promise.resolve(answer(401, { message: 'Invalid refresh token' })),
      ],
    ])(
      '%s is "not revoked": nothing is dropped, and it stands for 24 hours',
      async (_name, reply) => {
        const sw = closed(reply);

        await sw.push(WAKE);
        expect(sw.unsubscribed).toEqual([]);
        expect(sw.kv.get('wake-session')).toMatchObject({
          refresh: 'RT-1',
          liveAt: sw.clock.now,
        });

        // Inside the 24 hours: not asked again.
        sw.clock.now += 24 * HOUR - MINUTE;
        await sw.push(WAKE);
        expect(sw.fetches).toHaveLength(1);

        // Past them: asked again.
        sw.clock.now += 2 * MINUTE;
        await sw.push(WAKE);
        expect(sw.fetches).toHaveLength(2);
      },
    );

    it.each([
      [
        'a throttle (429)',
        () => Promise.resolve(answer(429, { message: 'x' })),
      ],
      ['a 5xx', () => Promise.resolve(answer(503))],
      ['a network error', () => Promise.reject(new Error('offline'))],
      [
        'a 401 whose body is not JSON (a proxy)',
        () => Promise.resolve(answer(401)),
      ],
      [
        'a 401 whose body is a bare string',
        () => Promise.resolve(answer(401, 'Device revoked')),
      ],
    ])(
      '%s is NO verdict: nothing is dropped, and the next ask waits 15 minutes',
      async (_name, reply) => {
        const sw = closed(reply);

        await sw.push(WAKE);
        expect(sw.unsubscribed).toEqual([]);
        expect(sw.kv.has('wake-session')).toBe(true);
        expect(sw.kv.get('wake-session')).not.toHaveProperty('liveAt');

        sw.clock.now += 14 * MINUTE;
        await sw.push(WAKE);
        expect(sw.fetches).toHaveLength(1);

        sw.clock.now += 2 * MINUTE;
        await sw.push(WAKE);
        expect(sw.fetches).toHaveLength(2);
      },
    );

    it('a timeout is no verdict either: the ask is aborted and nothing is dropped', async () => {
      // Installed BEFORE the worker, so its own 8 s timer is the fake one.
      jest.useFakeTimers({
        doNotFake: ['nextTick', 'queueMicrotask', 'setImmediate'],
      });
      try {
        const sw = closed(
          (_url, init) =>
            new Promise((_resolve, reject) => {
              init.signal?.addEventListener('abort', () =>
                reject(new Error('aborted')),
              );
            }),
        );
        const pushed = sw.push(WAKE);
        await jest.advanceTimersByTimeAsync(9000);
        await pushed;

        expect(sw.unsubscribed).toEqual([]);
        expect(sw.fetches[0].init.signal?.aborted).toBe(true);
        expect(sw.kv.get('wake-session')).not.toHaveProperty('liveAt');
      } finally {
        jest.useRealTimers();
      }
    });

    it('a failed unsubscribe keeps the token, so a later wake-up tries again', async () => {
      const sw = makeWorker({
        store: { ...NIDS, ...SESSION },
        pages: [],
        fetch: revoked,
        unsubscribeFails: true,
      });

      await sw.push(WAKE);
      expect(sw.kv.has('wake-session')).toBe(true);

      sw.clock.now += 16 * MINUTE;
      await sw.push(WAKE);
      expect(sw.fetches).toHaveLength(2);
    });

    it('never drops a subscription a new login replaced meanwhile', async () => {
      const sw = closed(async () => {
        // The page logs in again while the ask is in flight.
        sw.kv.set('wake-session', { refresh: 'RT-2', api: 'https://app.test' });
        return revoked();
      });

      await sw.push(WAKE);

      expect(sw.unsubscribed).toEqual([]);
      // The new session is neither deleted nor stamped with the old one's.
      expect(sw.kv.get('wake-session')).toEqual({
        refresh: 'RT-2',
        api: 'https://app.test',
      });
    });

    it('asks one at a time: a burst of wake-ups makes one ask', async () => {
      const sw = closed(() => Promise.resolve(answer(503)));

      await Promise.all([sw.push(WAKE), sw.push(WAKE), sw.push(WAKE)]);

      expect(sw.fetches).toHaveLength(1);
    });

    it('a record with a bad refresh token or origin is ignored', async () => {
      for (const bad of [
        { refresh: '', api: 'https://app.test' },
        { refresh: 'RT-1', api: 'javascript:alert(1)' },
        { refresh: 7, api: 'https://app.test' },
        'junk',
      ]) {
        const sw = makeWorker({
          store: { ...NIDS, 'wake-session': bad },
          pages: [],
          fetch: revoked,
        });
        await sw.push(WAKE);
        expect(sw.fetches).toEqual([]);
      }
    });

    it('a clock that went back does not park the check for good', async () => {
      const sw = makeWorker({
        store: {
          ...NIDS,
          'wake-session': {
            ...SESSION['wake-session'],
            liveAt: 1_700_000_000_000 + 30 * HOUR,
            attemptAt: 1_700_000_000_000 + 30 * HOUR,
          },
        },
        pages: [],
        fetch: revoked,
      });

      await sw.push(WAKE);

      expect(sw.unsubscribed).toHaveLength(1);
    });
  });
});
