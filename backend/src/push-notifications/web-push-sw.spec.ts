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

function makeWorker(options: {
  endpoint?: string;
  pages?: Page[];
  store?: Record<string, unknown>;
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
                  }, 0);
                  return get;
                },
                put: (value: unknown, key: string) => {
                  kv.set(key, structuredClone(value));
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
        Promise.resolve({ endpoint: options.endpoint ?? CHROME }),
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

  const context = createContext({
    self,
    indexedDB,
    setTimeout,
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
    isNaN,
    Date,
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
});
