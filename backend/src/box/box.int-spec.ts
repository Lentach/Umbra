import type { INestApplication } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { APP_GUARD } from '@nestjs/core';
import { Test } from '@nestjs/testing';
import { ThrottlerModule } from '@nestjs/throttler';
import { TypeOrmModule } from '@nestjs/typeorm';
import { generateKeyPairSync, randomBytes, sign, type KeyObject } from 'crypto';
import { mkdtempSync, readdirSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { request as httpRequest } from 'http';
import { join } from 'path';
import { Client } from 'pg';
import { io, type Socket as ClientSocket } from 'socket.io-client';
import { setTimeout as sleep } from 'timers/promises';
import { DataSource } from 'typeorm';
import { HttpThrottlerGuard } from '../common/http-throttler.guard';
import { runMigrations } from '../database/migration-runner';
import {
  BOX_PUSH_TRANSPORT,
  type BoxPushTransport,
} from './box-push.transport';
import { BoxReaper } from './box-reaper.service';
import {
  ackFields,
  boxSignedMessage,
  createQueueFields,
  notifierActivateFields,
  notifierChallengeFields,
  type BoxSignedVerb,
} from './box-signature';
import { takeRefusalCounts } from './box-throttler.guard';
import { BOX_MEDIA_DAILY_BUDGET_BYTES } from './box.constants';
import { BOX_ENTITIES, BoxModule } from './box.module';

/**
 * The box end to end: real socket.io connections and HTTP against the real
 * module, on a FRESH Postgres database built by the real migration runner
 * (0001 baseline … 0022). Nothing is mocked but the push relay.
 *
 * `BOX_IT_DATABASE_URL` names a server this suite may create and drop a
 * database on (e.g. `postgres://postgres:postgres@localhost:5433/postgres`
 * against the dev stack). CI sets it; a CI run without it FAILS rather than
 * skipping, so the suite can never go silently dark.
 */
const ADMIN_URL = process.env.BOX_IT_DATABASE_URL;
if (!ADMIN_URL && process.env.CI) {
  throw new Error(
    'BOX_IT_DATABASE_URL is not set: in CI the box integration suite must run, never skip',
  );
}
const describeWithDb = ADMIN_URL ? describe : describe.skip;

interface Key {
  privateKey: KeyObject;
  pub: Buffer;
}
interface Queue {
  key: Key;
  rid: string;
  sid: string;
  nid: string;
}
interface Delivered {
  rid: string;
  id: string;
  blob: string;
}

let ipCounter = 0;
/** A distinct client address per call, so throttle buckets never collide across tests. */
function nextIp(): string {
  ipCounter++;
  return `10.77.${ipCounter >> 8}.${ipCounter & 255}`;
}

function mintKey(): Key {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const jwk = publicKey.export({ format: 'jwk' });
  return { privateKey, pub: Buffer.from(jwk.x as string, 'base64url') };
}

function signFor(
  socket: ClientSocket,
  key: Key,
  verb: BoxSignedVerb,
  fields: Buffer,
): string {
  const sockId = socket.id;
  if (!sockId) throw new Error('socket is not connected');
  return sign(
    null,
    boxSignedMessage(verb, sockId, fields),
    key.privateKey,
  ).toString('base64url');
}

function blob(): string {
  return randomBytes(16384).toString('base64url');
}

async function until(
  condition: () => boolean,
  timeoutMs = 5000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error('condition not met in time');
    await sleep(20);
  }
}

/** What a box ack carries: one shape with optional fields reads every verb's answer. */
interface Answer {
  ok: boolean;
  code?: string;
  retryAfterMs?: number;
  rid?: string;
  sid?: string;
  nid?: string;
  refused?: { rid: string; code: string }[];
  state?: string;
}

/** Emits one box event and resolves with its ack. */
async function call(
  socket: ClientSocket,
  event: string,
  payload: unknown,
): Promise<Answer> {
  const answer: unknown = await socket.emitWithAck(event, payload);
  return answer as Answer;
}

async function readJson<T>(res: Response): Promise<T> {
  const body: unknown = await res.json();
  return body as T;
}

describeWithDb('box over real sockets and Postgres', () => {
  let app: INestApplication;
  let db: DataSource;
  let base: string;
  let admin: Client;
  let dbName: string;
  let mediaDir: string;
  const pushes: {
    platform: string;
    token: string;
    data: Record<string, string>;
  }[] = [];
  const transport: BoxPushTransport = {
    send: (platform, token, data) => {
      pushes.push({ platform, token, data });
      return Promise.resolve('sent');
    },
  };
  const sockets: ClientSocket[] = [];

  async function connect(ip = nextIp()): Promise<ClientSocket> {
    const socket = io(`${base}/box`, {
      transports: ['websocket'],
      forceNew: true,
      reconnection: false,
      extraHeaders: { 'x-real-ip': ip },
    });
    sockets.push(socket);
    // Executor form on purpose: the tsconfig lib predates Promise.withResolvers.
    await new Promise<void>((resolve, reject) => {
      socket.once('connect', () => resolve());
      socket.once('connect_error', reject);
    });
    return socket;
  }

  async function createQueue(
    socket: ClientSocket,
    kind: 'normal' | 'request' = 'normal',
  ): Promise<Queue> {
    const key = mintKey();
    const answer = await call(socket, 'createQueue', {
      v: 1,
      kind,
      authPub: key.pub.toString('base64url'),
      sig: signFor(
        socket,
        key,
        'createQueue',
        createQueueFields(kind, key.pub),
      ),
    });
    const { rid, sid, nid } = answer;
    if (!answer.ok || !rid || !sid || !nid) {
      throw new Error(`createQueue refused: ${answer.code}`);
    }
    return { key, rid, sid, nid };
  }

  function subscribe(socket: ClientSocket, queues: Queue[]) {
    return call(socket, 'subscribe', {
      v: 1,
      subs: queues.map((q) => ({
        rid: q.rid,
        sig: signFor(
          socket,
          q.key,
          'subscribe',
          Buffer.from(q.rid, 'base64url'),
        ),
      })),
    });
  }

  function ackMessage(socket: ClientSocket, queue: Queue, id: string) {
    return call(socket, 'ack', {
      v: 1,
      rid: queue.rid,
      id,
      sig: signFor(
        socket,
        queue.key,
        'ack',
        ackFields(
          Buffer.from(queue.rid, 'base64url'),
          Buffer.from(id, 'base64url'),
        ),
      ),
    });
  }

  function collect(socket: ClientSocket): Delivered[] {
    const got: Delivered[] = [];
    socket.on('msg', (m: Delivered) => got.push(m));
    return got;
  }

  async function queueRow(rid: string) {
    const rows: { msgCount: number; mediaBytesToday: number }[] =
      await db.query(
        `SELECT "msgCount", "mediaBytesToday" FROM box_queues WHERE rid = $1`,
        [Buffer.from(rid, 'base64url')],
      );
    return rows[0];
  }

  async function storedIds(rid: string): Promise<string[]> {
    const rows: { id: Buffer }[] = await db.query(
      `SELECT id FROM box_msgs WHERE rid = $1 ORDER BY "createdAt", id`,
      [Buffer.from(rid, 'base64url')],
    );
    return rows.map((r) => r.id.toString('base64url'));
  }

  function upload(sid: string, body: Buffer, ip = nextIp()) {
    return fetch(`${base}/box/media`, {
      method: 'POST',
      headers: {
        'content-type': 'application/octet-stream',
        'box-sid': sid,
        'x-real-ip': ip,
      },
      body: new Uint8Array(body),
    });
  }

  beforeAll(async () => {
    const url = new URL(ADMIN_URL as string);
    admin = new Client({ connectionString: ADMIN_URL });
    await admin.connect();
    dbName = `box_it_${randomBytes(6).toString('hex')}`;
    await admin.query(`CREATE DATABASE ${dbName}`);
    const connection = {
      host: url.hostname,
      port: Number(url.port || 5432),
      username: decodeURIComponent(url.username),
      password: decodeURIComponent(url.password),
      database: dbName,
    };
    // The runner reads DB_*; set them before it runs (dotenv never overrides).
    Object.assign(process.env, {
      DB_HOST: connection.host,
      DB_PORT: String(connection.port),
      DB_USER: connection.username,
      DB_PASS: connection.password,
      DB_NAME: dbName,
    });
    await runMigrations({
      dir: join(__dirname, '..', '..', 'migrations'),
      log: () => undefined,
    });
    mediaDir = mkdtempSync(join(tmpdir(), 'box-it-'));
    process.env.MEDIA_DIR = mediaDir;

    const moduleRef = await Test.createTestingModule({
      imports: [
        ConfigModule.forRoot({ isGlobal: true, ignoreEnvFile: true }),
        ThrottlerModule.forRoot([{ ttl: 900_000, limit: 100 }]),
        TypeOrmModule.forRoot({
          type: 'postgres',
          ...connection,
          entities: BOX_ENTITIES,
          synchronize: false,
        }),
        BoxModule,
      ],
      // As in AppModule: the global guard throttles the box HTTP routes.
      providers: [{ provide: APP_GUARD, useClass: HttpThrottlerGuard }],
    })
      .overrideProvider(BOX_PUSH_TRANSPORT)
      .useValue(transport)
      .compile();
    app = moduleRef.createNestApplication();
    await app.listen(0, '127.0.0.1');
    base = await app.getUrl();
    db = app.get(DataSource);
  });

  afterEach(() => {
    for (const socket of sockets.splice(0)) socket.disconnect();
    pushes.length = 0;
  });

  afterAll(async () => {
    await app?.close();
    if (admin) {
      await admin.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`);
      await admin.end();
    }
    if (mediaDir) rmSync(mediaDir, { recursive: true, force: true });
  });

  describe('schema', () => {
    it('migration 0022 and the entities agree: dev synchronize would change nothing', async () => {
      const log = await db.driver.createSchemaBuilder().log();
      expect(log.upQueries.map((q) => q.query)).toEqual([]);
    });

    it('no box table has a column that could name an account, a device or a sender (I2)', async () => {
      const rows: { table_name: string; column_name: string }[] =
        await db.query(
          `SELECT table_name, column_name FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name LIKE 'box\\_%'
            ORDER BY table_name, ordinal_position`,
        );
      const columns: Record<string, string[]> = {};
      for (const r of rows) (columns[r.table_name] ??= []).push(r.column_name);
      expect(columns).toEqual({
        box_media: ['id', 'path', 'sizeBucket', 'expiresAt'],
        box_msgs: ['id', 'rid', 'blob', 'createdAt', 'expiresAt'],
        box_notifiers: ['nid', 'token', 'platform', 'verifiedAt'],
        box_queues: [
          'rid',
          'sid',
          'nid',
          'recipientAuthPub',
          'kind',
          'touchedDay',
          'claimBy',
          'msgCount',
          'mediaBytesToday',
        ],
      });
    });
  });

  describe('messages', () => {
    it('delivers a sent blob to the subscribed recipient, and ack deletes it', async () => {
      const bob = await connect();
      const alice = await connect();
      const queue = await createQueue(bob);
      const got = collect(bob);
      expect(await subscribe(bob, [queue])).toEqual({ ok: true, refused: [] });

      const payload = blob();
      expect(
        await call(alice, 'send', { v: 1, sid: queue.sid, blob: payload }),
      ).toEqual({ ok: true });
      await until(() => got.length === 1);
      const [delivered] = got;
      expect(delivered.rid).toBe(queue.rid);
      expect(delivered.blob).toBe(payload);
      expect(delivered.id).toMatch(/^[A-Za-z0-9_-]{22}$/);

      expect(await ackMessage(bob, queue, delivered.id)).toEqual({ ok: true });
      expect(await storedIds(queue.rid)).toEqual([]);
      expect((await queueRow(queue.rid)).msgCount).toBe(0);
    });

    it('holds messages for an offline recipient and delivers them after the ACK of a new subscribe; a signature from the old connection is refused', async () => {
      const bob1 = await connect();
      const queue = await createQueue(bob1);
      expect(await subscribe(bob1, [queue])).toEqual({ ok: true, refused: [] });
      const oldSig = signFor(
        bob1,
        queue.key,
        'subscribe',
        Buffer.from(queue.rid, 'base64url'),
      );
      bob1.disconnect();

      const alice = await connect();
      for (let i = 0; i < 3; i++) {
        await call(alice, 'send', { v: 1, sid: queue.sid, blob: blob() });
      }

      const bob2 = await connect();
      const events: string[] = [];
      bob2.on('msg', () => events.push('msg'));
      expect(
        await call(bob2, 'subscribe', {
          v: 1,
          subs: [{ rid: queue.rid, sig: oldSig }],
        }),
      ).toEqual({
        ok: true,
        refused: [{ rid: queue.rid, code: 'auth_failed' }],
      });

      const answer = await subscribe(bob2, [queue]);
      events.push('ack');
      expect(answer).toEqual({ ok: true, refused: [] });
      await until(() => events.length === 4);
      expect(events).toEqual(['ack', 'msg', 'msg', 'msg']);
    });

    it('keeps at most 16 frames unacked per socket, rotating across queues; each ack releases the next', async () => {
      const bob = await connect();
      const alice = await connect();
      const a = await createQueue(bob);
      const b = await createQueue(bob);
      for (let i = 0; i < 20; i++) {
        await call(alice, 'send', { v: 1, sid: a.sid, blob: blob() });
        await call(alice, 'send', { v: 1, sid: b.sid, blob: blob() });
      }
      const got = collect(bob);
      await subscribe(bob, [a, b]);
      await until(() => got.length === 16);
      await sleep(300);
      expect(got).toHaveLength(16);
      expect(got.filter((m) => m.rid === a.rid)).toHaveLength(8);
      expect(got.filter((m) => m.rid === b.rid)).toHaveLength(8);

      const first = got[0];
      await ackMessage(bob, first.rid === a.rid ? a : b, first.id);
      await until(() => got.length === 17);
      await sleep(200);
      expect(got).toHaveLength(17);
    });

    it('gives a queue to its NEWEST subscriber: the stale connection receives nothing more', async () => {
      const oldConnection = await connect();
      const newConnection = await connect();
      const alice = await connect();
      const queue = await createQueue(oldConnection);
      await subscribe(oldConnection, [queue]);
      const oldGot = collect(oldConnection);
      const newGot = collect(newConnection);
      await subscribe(newConnection, [queue]);

      await call(alice, 'send', { v: 1, sid: queue.sid, blob: blob() });
      await until(() => newGot.length === 1);
      await sleep(200);
      expect(oldGot).toHaveLength(0);
    });

    it('refuses a send to a full normal queue (128) with queue_full', async () => {
      const bob = await connect();
      const alice = await connect();
      const queue = await createQueue(bob);
      const answers = await Promise.all(
        Array.from({ length: 128 }, () =>
          call(alice, 'send', { v: 1, sid: queue.sid, blob: blob() }),
        ),
      );
      expect(answers.every((a) => a.ok === true)).toBe(true);
      expect(
        await call(alice, 'send', { v: 1, sid: queue.sid, blob: blob() }),
      ).toEqual({ ok: false, code: 'queue_full' });
      expect(await storedIds(queue.rid)).toHaveLength(128);
      expect((await queueRow(queue.rid)).msgCount).toBe(128);
    });

    it('drops the OLDEST of a full request queue (50) instead of refusing', async () => {
      const bob = await connect();
      const stranger = await connect();
      const queue = await createQueue(bob, 'request');
      for (let i = 0; i < 50; i++) {
        await call(stranger, 'send', { v: 1, sid: queue.sid, blob: blob() });
      }
      const before = await storedIds(queue.rid);
      expect(
        await call(stranger, 'send', { v: 1, sid: queue.sid, blob: blob() }),
      ).toEqual({ ok: true });
      const after = await storedIds(queue.rid);
      expect(after).toHaveLength(50);
      expect(after).not.toContain(before[0]);
      expect(after.slice(0, 49)).toEqual(before.slice(1));
      expect((await queueRow(queue.rid)).msgCount).toBe(50);
    });

    it('never deadlocks a full request queue that is acked while it is flooded', async () => {
      const bob = await connect();
      const stranger = await connect();
      const queue = await createQueue(bob, 'request');
      for (let i = 0; i < 50; i++) {
        await call(stranger, 'send', { v: 1, sid: queue.sid, blob: blob() });
      }
      const oldest = await storedIds(queue.rid);
      // Acks of the oldest rows race sends that evict exactly those rows.
      const answers = await Promise.all([
        ...oldest.slice(0, 25).map((id) => ackMessage(bob, queue, id)),
        ...Array.from({ length: 25 }, () =>
          call(stranger, 'send', { v: 1, sid: queue.sid, blob: blob() }),
        ),
      ]);
      expect(answers.filter((a) => !a.ok)).toEqual([]);
      const rows = await storedIds(queue.rid);
      expect((await queueRow(queue.rid)).msgCount).toBe(rows.length);
    });
  });

  describe('no oracles, strict frames, idempotence', () => {
    it('answers a send to an unknown sid exactly like a stored one, and stores nothing', async () => {
      const alice = await connect();
      const before: { n: number }[] = await db.query(
        `SELECT count(*)::int AS n FROM box_msgs`,
      );
      expect(
        await call(alice, 'send', {
          v: 1,
          sid: randomBytes(32).toString('base64url'),
          blob: blob(),
        }),
      ).toEqual({ ok: true });
      const after: { n: number }[] = await db.query(
        `SELECT count(*)::int AS n FROM box_msgs`,
      );
      expect(after[0].n).toBe(before[0].n);
    });

    it('answers auth_failed alike for an unknown rid and for a wrong key on a live one', async () => {
      const bob = await connect();
      const live = await createQueue(bob);
      const intruder = mintKey();
      const unknown: Queue = {
        ...live,
        key: intruder,
        rid: randomBytes(32).toString('base64url'),
      };
      const forged: Queue = { ...live, key: intruder };
      for (const target of [unknown, forged]) {
        const rid = Buffer.from(target.rid, 'base64url');
        const id = randomBytes(16).toString('base64url');
        expect(await ackMessage(bob, target, id)).toEqual({
          ok: false,
          code: 'auth_failed',
        });
        expect(
          await call(bob, 'deleteQueue', {
            v: 1,
            rid: target.rid,
            sig: signFor(bob, intruder, 'deleteQueue', rid),
          }),
        ).toEqual({ ok: false, code: 'auth_failed' });
        expect(await subscribe(bob, [target])).toEqual({
          ok: true,
          refused: [{ rid: target.rid, code: 'auth_failed' }],
        });
      }
      expect(await queueRow(live.rid)).toBeDefined();
    });

    it('refuses a frame carrying an unknown key as invalid_payload', async () => {
      const bob = await connect();
      const queue = await createQueue(bob);
      expect(
        await call(bob, 'send', {
          v: 1,
          sid: queue.sid,
          blob: blob(),
          from: 'alice',
        }),
      ).toEqual({ ok: false, code: 'invalid_payload' });
      expect(await storedIds(queue.rid)).toEqual([]);
    });

    it('gives the same queue back when the same key creates again (a lost answer is retried, not orphaned)', async () => {
      const bob = await connect();
      const key = mintKey();
      const frame = () => ({
        v: 1,
        kind: 'normal',
        authPub: key.pub.toString('base64url'),
        sig: signFor(
          bob,
          key,
          'createQueue',
          createQueueFields('normal', key.pub),
        ),
      });
      const first = await call(bob, 'createQueue', frame());
      const again = await call(bob, 'createQueue', frame());
      expect(again).toEqual(first);
      const rows: { n: number }[] = await db.query(
        `SELECT count(*)::int AS n FROM box_queues WHERE "recipientAuthPub" = $1`,
        [key.pub],
      );
      expect(rows[0].n).toBe(1);
    });

    it('deleteQueue removes the queue with its messages; a repeat reads auth_failed (gone)', async () => {
      const bob = await connect();
      const alice = await connect();
      const queue = await createQueue(bob);
      await call(alice, 'send', { v: 1, sid: queue.sid, blob: blob() });
      const frame = () => ({
        v: 1,
        rid: queue.rid,
        sig: signFor(
          bob,
          queue.key,
          'deleteQueue',
          Buffer.from(queue.rid, 'base64url'),
        ),
      });
      expect(await call(bob, 'deleteQueue', frame())).toEqual({ ok: true });
      expect(await queueRow(queue.rid)).toBeUndefined();
      expect(await storedIds(queue.rid)).toEqual([]);
      expect(await call(bob, 'deleteQueue', frame())).toEqual({
        ok: false,
        code: 'auth_failed',
      });
      // And the sender cannot tell: its sid now drops silently.
      expect(
        await call(alice, 'send', { v: 1, sid: queue.sid, blob: blob() }),
      ).toEqual({ ok: true });
    });
  });

  describe('rate limits and broken clients', () => {
    it('answers a throttled event on its ACK, one bucket per IPv6 /64, while another address proceeds', async () => {
      const first = await connect('2001:db8:77:1::1');
      const sibling = await connect('2001:db8:77:1::2');
      const other = await connect('198.51.100.77');
      for (let i = 0; i < 30; i++) {
        await call(first, 'subscribe', {});
        await call(sibling, 'subscribe', {});
      }
      const refused = await call(sibling, 'subscribe', {});
      expect(refused).toMatchObject({ ok: false, code: 'rate_limited' });
      expect(refused.retryAfterMs).toBeGreaterThan(0);
      // The operator's only abuse signal: a per-event count, no address.
      expect(takeRefusalCounts()).toEqual(new Map([['subscribe', 1]]));
      expect(await call(other, 'subscribe', {})).toEqual({
        ok: false,
        code: 'invalid_payload',
      });
    });

    it('disconnects a client that sends an event without an ack callback', async () => {
      const socket = await connect();
      // Executor form on purpose: the tsconfig lib predates Promise.withResolvers.
      const reason = new Promise<string>((resolve) =>
        socket.once('disconnect', resolve),
      );
      socket.emit('send', {
        v: 1,
        sid: randomBytes(32).toString('base64url'),
        blob: blob(),
      });
      expect(await reason).toBe('io server disconnect');
    });
  });

  describe('push notifier', () => {
    it('activates only with the pushed code signed by the queue key, then wakes the device once per burst', async () => {
      const bob = await connect();
      const alice = await connect();
      const queue = await createQueue(bob);
      const nid = Buffer.from(queue.nid, 'base64url');
      const token = 'fcm-token_box:1';

      expect(
        await call(bob, 'registerNotifier', {
          v: 1,
          nid: queue.nid,
          platform: 'fcm',
          token,
          sig: signFor(
            bob,
            queue.key,
            'registerNotifier',
            notifierChallengeFields(nid, 'fcm', token),
          ),
        }),
      ).toEqual({ ok: true, state: 'challenged' });
      expect(pushes).toHaveLength(1);
      const [challenge] = pushes;
      expect(challenge.platform).toBe('fcm');
      expect(challenge.token).toBe(token);
      // Content-free apart from the one-time code: FCM data transits Google.
      expect(Object.keys(challenge.data).sort()).toEqual(['code', 'type']);
      expect(challenge.data.type).toBe('notifier_challenge');
      expect(challenge.data.code).toMatch(/^[A-Za-z0-9_-]{22}$/);
      const code = Buffer.from(challenge.data.code, 'base64url');
      const activate = (candidate: Buffer) =>
        call(bob, 'registerNotifier', {
          v: 1,
          nid: queue.nid,
          code: candidate.toString('base64url'),
          sig: signFor(
            bob,
            queue.key,
            'registerNotifier',
            notifierActivateFields(nid, candidate),
          ),
        });
      expect(await activate(randomBytes(16))).toEqual({
        ok: false,
        code: 'auth_failed',
      });
      const unverified: unknown[] = await db.query(
        `SELECT 1 FROM box_notifiers WHERE nid = $1`,
        [nid],
      );
      expect(unverified).toHaveLength(0);
      expect(await activate(code)).toEqual({ ok: true, state: 'active' });
      expect(await activate(code)).toEqual({ ok: true, state: 'active' });

      pushes.length = 0;
      await call(alice, 'send', { v: 1, sid: queue.sid, blob: blob() });
      await call(alice, 'send', { v: 1, sid: queue.sid, blob: blob() });
      await until(() => pushes.length === 1, 8000);
      await sleep(500);
      expect(pushes).toEqual([
        { platform: 'fcm', token, data: { type: 'new_message' } },
      ]);
    });
  });

  describe('media', () => {
    it('stores a ladder-sized upload with no link to its queue and serves it back uncached', async () => {
      const bob = await connect();
      const queue = await createQueue(bob);
      const body = randomBytes(256 * 1024);
      const posted = await upload(queue.sid, body);
      expect(posted.status).toBe(201);
      const answer = await readJson<{
        id: string;
        bucket: string;
        expiresAt: string;
      }>(posted);
      expect(Object.keys(answer).sort()).toEqual(['bucket', 'expiresAt', 'id']);
      expect(answer.id).toMatch(/^[A-Za-z0-9_-]{43}$/);
      expect(answer.bucket).toBe('256k');
      // I3: media lives 14 days.
      expect(Date.parse(answer.expiresAt) - Date.now()).toBeGreaterThan(
        14 * 24 * 60 * 60 * 1000 - 60_000,
      );
      expect((await queueRow(queue.rid)).mediaBytesToday).toBe(256 * 1024);

      const fetched = await fetch(`${base}/box/media/${answer.id}`);
      expect(fetched.status).toBe(200);
      expect(fetched.headers.get('cache-control')).toBe('no-store');
      expect(Buffer.from(await fetched.arrayBuffer())).toEqual(body);
    });

    it('refuses an off-ladder body, and one over the top rung, with 413 bad_size', async () => {
      const bob = await connect();
      const queue = await createQueue(bob);
      for (const size of [5000, 16 * 1024 * 1024 + 1]) {
        const res = await upload(queue.sid, randomBytes(size));
        expect(res.status).toBe(413);
        expect(await res.json()).toEqual({ error: 'bad_size' });
      }
      expect((await queueRow(queue.rid)).mediaBytesToday).toBe(0);
    });

    it('refuses an off-ladder Content-Length before reading one byte of the unauthenticated body', async () => {
      const bob = await connect();
      const queue = await createQueue(bob);
      const url = new URL(`${base}/box/media`);
      // Headers only: not one body byte is ever sent. A server that read
      // the body first would never answer.
      const req = httpRequest({
        host: url.hostname,
        port: url.port,
        path: url.pathname,
        method: 'POST',
        headers: {
          'content-type': 'application/octet-stream',
          'content-length': String(16 * 1024 * 1024 - 1),
          'box-sid': queue.sid,
          'x-real-ip': nextIp(),
        },
      });
      // Executor form on purpose: the tsconfig lib predates Promise.withResolvers.
      const status = await new Promise<number>((resolve, reject) => {
        // A server that waits for the body never answers: fail in 5 s rather
        // than leave an open request that stalls the suite's teardown.
        const unanswered = setTimeout(() => resolve(0), 5000);
        req.on('response', (res) => {
          clearTimeout(unanswered);
          res.resume();
          resolve(res.statusCode ?? 0);
        });
        req.on('error', reject);
        req.flushHeaders();
      });
      req.destroy();
      expect(status).toBe(413);
    });

    it('answers an unknown sid 201 with an id that is never stored', async () => {
      const res = await upload(
        randomBytes(32).toString('base64url'),
        randomBytes(4096),
      );
      expect(res.status).toBe(201);
      const { id } = await readJson<{ id: string }>(res);
      expect((await fetch(`${base}/box/media/${id}`)).status).toBe(404);
    });

    it('refuses a request queue and an exhausted daily budget with 429 quota_exceeded', async () => {
      const bob = await connect();
      const request = await createQueue(bob, 'request');
      const normal = await createQueue(bob);
      await db.query(
        `UPDATE box_queues SET "mediaBytesToday" = $2 WHERE rid = $1`,
        [
          Buffer.from(normal.rid, 'base64url'),
          BOX_MEDIA_DAILY_BUDGET_BYTES - 1000,
        ],
      );
      for (const sid of [request.sid, normal.sid]) {
        const res = await upload(sid, randomBytes(4096));
        expect(res.status).toBe(429);
        expect(await res.json()).toEqual({ error: 'quota_exceeded' });
      }
    });
  });

  describe('reaper (I3)', () => {
    it('sweeps expired messages and media, unclaimed and 90-day-idle queues; live queues survive', async () => {
      const bob = await connect();
      const alice = await connect();
      const live = await createQueue(bob);
      const unclaimed = await createQueue(bob);
      const idle = await createQueue(bob);
      const boundary = await createQueue(bob);
      await subscribe(bob, [live, idle, boundary]);
      for (let i = 0; i < 2; i++) {
        await call(alice, 'send', { v: 1, sid: live.sid, blob: blob() });
      }
      await call(alice, 'send', { v: 1, sid: idle.sid, blob: blob() });
      const expiring = await readJson<{ id: string }>(
        await upload(live.sid, randomBytes(4096)),
      );
      const kept = await readJson<{ id: string }>(
        await upload(live.sid, randomBytes(4096)),
      );
      const pathOf = async (id: string) => {
        const rows: { path: string }[] = await db.query(
          `SELECT path FROM box_media WHERE id = $1`,
          [Buffer.from(id, 'base64url')],
        );
        return rows[0]?.path;
      };
      const expiringPath = await pathOf(expiring.id);
      const keptPath = await pathOf(kept.id);
      expect(readdirSync(join(mediaDir, 'box'))).toEqual(
        expect.arrayContaining([expiringPath, keptPath]),
      );

      const [expiredId] = await storedIds(live.rid);
      await db.query(
        `UPDATE box_msgs SET "expiresAt" = now() - interval '1 second' WHERE id = $1`,
        [Buffer.from(expiredId, 'base64url')],
      );
      await db.query(
        `UPDATE box_queues SET "claimBy" = now() - interval '1 second' WHERE rid = $1`,
        [Buffer.from(unclaimed.rid, 'base64url')],
      );
      await db.query(
        `UPDATE box_queues SET "touchedDay" = (now() AT TIME ZONE 'utc')::date - 91
          WHERE rid = $1`,
        [Buffer.from(idle.rid, 'base64url')],
      );
      await db.query(
        `UPDATE box_queues SET "touchedDay" = (now() AT TIME ZONE 'utc')::date - 90
          WHERE rid = $1`,
        [Buffer.from(boundary.rid, 'base64url')],
      );
      await db.query(
        `UPDATE box_media SET "expiresAt" = now() - interval '1 second'
          WHERE id = $1`,
        [Buffer.from(expiring.id, 'base64url')],
      );

      await app.get(BoxReaper).sweep();

      expect(await storedIds(live.rid)).toHaveLength(1);
      expect((await queueRow(live.rid)).msgCount).toBe(1);
      expect(await queueRow(unclaimed.rid)).toBeUndefined();
      expect(await queueRow(idle.rid)).toBeUndefined();
      expect(await storedIds(idle.rid)).toEqual([]);
      expect(await queueRow(boundary.rid)).toBeDefined();
      expect(await pathOf(expiring.id)).toBeUndefined();
      expect(await pathOf(kept.id)).toBe(keptPath);
      const onDisk = readdirSync(join(mediaDir, 'box'));
      expect(onDisk).not.toContain(expiringPath);
      expect(onDisk).toContain(keptPath);
      expect((await fetch(`${base}/box/media/${expiring.id}`)).status).toBe(
        404,
      );
    });
  });
});
