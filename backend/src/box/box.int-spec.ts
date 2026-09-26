import type { INestApplication } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { APP_GUARD } from '@nestjs/core';
import { Test } from '@nestjs/testing';
import { ThrottlerModule } from '@nestjs/throttler';
import { TypeOrmModule } from '@nestjs/typeorm';
import { generateKeyPairSync, randomBytes, sign, type KeyObject } from 'crypto';
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'fs';
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
  type BoxSignedVerb,
} from './box-signature';
import { takeRefusalCounts } from './box-throttler.guard';
import {
  BOX_GLOBAL_MEDIA_CEILING_BYTES,
  BOX_GLOBAL_MSG_CEILING,
  BOX_MEDIA_DAILY_BUDGET_BYTES,
  BOX_MEDIA_LADDER,
  BOX_SOCKET_RID_CAP,
} from './box.constants';
import { BOX_ENTITIES, BoxModule } from './box.module';
import { BOX_CEILING, type BoxCeiling } from './box.service';

/**
 * The box end to end: real socket.io connections and HTTP against the real
 * module, on a FRESH Postgres database built by the real migration runner
 * (0001 baseline … the latest). Nothing is mocked but the push relay.
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
  refused?: { rid?: string; nid?: string; code: string }[];
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
  /**
   * The global ceiling the app runs with: the real numbers, which a test
   * lowers to just above the running totals instead of writing 2 GiB
   * (restored after every test).
   */
  const ceiling: BoxCeiling = {
    msgs: BOX_GLOBAL_MSG_CEILING,
    mediaBytes: BOX_GLOBAL_MEDIA_CEILING_BYTES,
  };

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

  /** Step 1: the box pushes a code to `token`; answers with that code. */
  async function challengeToken(
    socket: ClientSocket,
    token: string,
  ): Promise<Buffer> {
    const before = pushes.length;
    const answer = await call(socket, 'registerNotifier', {
      v: 1,
      platform: 'fcm',
      token,
    });
    if (answer.state !== 'challenged') throw new Error('not challenged');
    return Buffer.from(pushes[before].data.code, 'base64url');
  }

  /** Step 2: `code` activates every queue in `queues`, each signing for itself. */
  function activateWith(socket: ClientSocket, code: Buffer, queues: Queue[]) {
    return call(socket, 'registerNotifier', {
      v: 1,
      code: code.toString('base64url'),
      queues: queues.map((q) => ({
        nid: q.nid,
        sig: signFor(
          socket,
          q.key,
          'registerNotifier',
          notifierActivateFields(Buffer.from(q.nid, 'base64url'), code),
        ),
      })),
    });
  }

  /** Registers and activates `token` as the queue's notifier, the two steps. */
  async function activateNotifier(
    socket: ClientSocket,
    queue: Queue,
    token: string,
  ): Promise<void> {
    const code = await challengeToken(socket, token);
    const answer = await activateWith(socket, code, [queue]);
    if (!answer.ok || answer.refused?.length !== 0) {
      throw new Error('notifier not active');
    }
  }

  async function notifierRows(queues: Queue[]): Promise<string[]> {
    const rows: { nid: Buffer; token: string }[] = await db.query(
      `SELECT nid, token FROM box_notifiers WHERE nid = ANY($1::bytea[])`,
      [queues.map((q) => Buffer.from(q.nid, 'base64url'))],
    );
    return rows.map((r) => `${r.nid.toString('base64url')}:${r.token}`).sort();
  }

  /** The running totals the global ceiling is checked against (decision 30). */
  async function totals(): Promise<{ msgs: number; mediaBytes: number }> {
    const rows: { msgCount: number; mediaBytes: string }[] = await db.query(
      `SELECT "msgCount", "mediaBytes" FROM box_totals`,
    );
    return { msgs: rows[0].msgCount, mediaBytes: Number(rows[0].mediaBytes) };
  }

  /** Bytes per stored medium, at its rung size. */
  function mediaBytesOf(media: { sizeBucket: string }[]): number {
    const rungBytes = new Map(BOX_MEDIA_LADDER.map((r) => [r.bucket, r.bytes]));
    return media.reduce(
      (sum, m) => sum + (rungBytes.get(m.sizeBucket) ?? Number.NaN),
      0,
    );
  }

  /** What the tables actually hold, media at their rung sizes. */
  async function stored(): Promise<{ msgs: number; mediaBytes: number }> {
    const msgs: { n: number }[] = await db.query(
      `SELECT count(*)::int AS n FROM box_msgs`,
    );
    const media: { sizeBucket: string }[] = await db.query(
      `SELECT "sizeBucket" FROM box_media`,
    );
    return { msgs: msgs[0].n, mediaBytes: mediaBytesOf(media) };
  }

  /**
   * `n` normal queues written straight to the table, with real keys: the rid
   * cap needs more queues than createQueue's throttle gives one address.
   */
  async function mintQueues(n: number): Promise<Queue[]> {
    const minted = Array.from({ length: n }, () => ({
      key: mintKey(),
      rid: randomBytes(32),
      sid: randomBytes(32),
      nid: randomBytes(16),
    }));
    await db.query(
      `INSERT INTO box_queues (rid, sid, nid, "recipientAuthPub", kind, "claimBy")
       SELECT r, s, n, k, 'normal', now() + interval '1 day'
         FROM unnest($1::bytea[], $2::bytea[], $3::bytea[], $4::bytea[])
           AS t(r, s, n, k)`,
      [
        minted.map((q) => q.rid),
        minted.map((q) => q.sid),
        minted.map((q) => q.nid),
        minted.map((q) => q.key.pub),
      ],
    );
    return minted.map((q) => ({
      key: q.key,
      rid: q.rid.toString('base64url'),
      sid: q.sid.toString('base64url'),
      nid: q.nid.toString('base64url'),
    }));
  }

  /** True once a subscribe claimed the queue (`claimBy` cleared). */
  async function claimed(queue: Queue): Promise<boolean> {
    const rows: { claimed: boolean }[] = await db.query(
      `SELECT "claimBy" IS NULL AS claimed FROM box_queues WHERE rid = $1`,
      [Buffer.from(queue.rid, 'base64url')],
    );
    return rows[0].claimed;
  }

  /**
   * POSTs an upload's HEADERS only — not one body byte is ever sent — and
   * resolves with the status, or 0 when the server waits for the body.
   */
  async function statusBeforeBody(
    sid: string,
    contentLength: number,
  ): Promise<number> {
    const url = new URL(`${base}/box/media`);
    const req = httpRequest({
      host: url.hostname,
      port: url.port,
      path: url.pathname,
      method: 'POST',
      headers: {
        'content-type': 'application/octet-stream',
        'content-length': String(contentLength),
        'box-sid': sid,
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
    return status;
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
      .overrideProvider(BOX_CEILING)
      .useValue(ceiling)
      .compile();
    app = moduleRef.createNestApplication();
    await app.listen(0, '127.0.0.1');
    base = await app.getUrl();
    db = app.get(DataSource);
  });

  afterEach(() => {
    for (const socket of sockets.splice(0)) socket.disconnect();
    pushes.length = 0;
    ceiling.msgs = BOX_GLOBAL_MSG_CEILING;
    ceiling.mediaBytes = BOX_GLOBAL_MEDIA_CEILING_BYTES;
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
    it('the box migrations and the entities agree: dev synchronize would change nothing', async () => {
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
        box_totals: ['id', 'msgCount', 'mediaBytes'],
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

    it('migration 0024 seeds the totals from what is already stored, every rung at its ladder size', async () => {
      const runner = db.createQueryRunner();
      await runner.startTransaction();
      try {
        const rid = randomBytes(32);
        await runner.query(
          `INSERT INTO box_queues (rid, sid, nid, "recipientAuthPub", kind)
           VALUES ($1, $2, $3, $4, 'normal')`,
          [rid, randomBytes(32), randomBytes(16), randomBytes(32)],
        );
        for (let i = 0; i < 2; i++) {
          await runner.query(
            `INSERT INTO box_msgs (id, rid, blob, "createdAt", "expiresAt")
             VALUES ($1, $2, $3, now(), now() + interval '1 day')`,
            [randomBytes(16), rid, randomBytes(16)],
          );
        }
        for (const rung of BOX_MEDIA_LADDER) {
          await runner.query(
            `INSERT INTO box_media (id, path, "sizeBucket", "expiresAt")
             VALUES ($1, 'seed.bin', $2, now() + interval '1 day')`,
            [randomBytes(32), rung.bucket],
          );
        }
        const msgs: { n: number }[] = await runner.manager.query(
          `SELECT count(*)::int AS n FROM box_msgs`,
        );
        const media: { sizeBucket: string }[] = await runner.manager.query(
          `SELECT "sizeBucket" FROM box_media`,
        );
        await runner.query(`DELETE FROM box_totals`);
        await runner.query(
          readFileSync(
            join(__dirname, '..', '..', 'migrations', '0024_box_totals.sql'),
            'utf8',
          ),
        );
        const seeded: { msgCount: number; mediaBytes: string }[] =
          await runner.manager.query(
            `SELECT "msgCount", "mediaBytes" FROM box_totals`,
          );
        expect(msgs[0].n).toBeGreaterThanOrEqual(2);
        expect(seeded).toEqual([
          { msgCount: msgs[0].n, mediaBytes: String(mediaBytesOf(media)) },
        ]);
      } finally {
        await runner.rollbackTransaction();
        await runner.release();
      }
    });
  });

  describe('messages', () => {
    it('delivers a sent blob to the subscribed recipient, and ack deletes it for good', async () => {
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

      // The ack frees the window slot and pumps the queue; that pass (and
      // the next send's) must never push the acked id again.
      const next = blob();
      await call(alice, 'send', { v: 1, sid: queue.sid, blob: next });
      await until(() => got.length >= 2);
      await sleep(300);
      expect(got.map((m) => m.blob)).toEqual([payload, next]);
      expect(got[1].id).not.toBe(delivered.id);
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

  describe('per-socket rid cap (E10)', () => {
    it('holds at most 1024 rids per socket: an entry past it is refused alone with limit and claims nothing; a rid it holds costs nothing; a bad signature stays auth_failed', async () => {
      const bob = await connect();
      const alice = await connect();
      const queues = await mintQueues(BOX_SOCKET_RID_CAP + 2);
      const held = queues.slice(0, BOX_SOCKET_RID_CAP);
      for (let i = 0; i < held.length; i += 256) {
        expect(await subscribe(bob, held.slice(i, i + 256))).toEqual({
          ok: true,
          refused: [],
        });
      }
      const [extra, other] = queues.slice(BOX_SOCKET_RID_CAP);
      const forged = { ...other, key: mintKey() };
      expect(await subscribe(bob, [held[0], extra, forged])).toEqual({
        ok: true,
        refused: [
          { rid: extra.rid, code: 'limit' },
          { rid: other.rid, code: 'auth_failed' },
        ],
      });
      // Refused means untouched: not claimed, and never delivered here.
      expect(await claimed(extra)).toBe(false);
      expect(await claimed(held[0])).toBe(true);
      const got = collect(bob);
      await call(alice, 'send', { v: 1, sid: extra.sid, blob: blob() });
      await sleep(300);
      expect(got).toEqual([]);

      // A rid a newer socket takes frees its slot on the old one.
      const fresh = await connect();
      expect(await subscribe(fresh, [held[0]])).toEqual({
        ok: true,
        refused: [],
      });
      expect(await subscribe(bob, [extra])).toEqual({ ok: true, refused: [] });
      await until(() => got.length === 1);
      expect(got[0].rid).toBe(extra.rid);
      await ackMessage(bob, extra, got[0].id);
    });

    it('never lets concurrent subscribe frames on one socket past the cap', async () => {
      const bob = await connect();
      const queues = await mintQueues(BOX_SOCKET_RID_CAP + 256);
      const frames: Queue[][] = [];
      for (let i = 0; i < queues.length; i += 256) {
        frames.push(queues.slice(i, i + 256));
      }
      const answers = await Promise.all(frames.map((f) => subscribe(bob, f)));
      expect(answers.every((a) => a.ok)).toBe(true);
      const refused = answers.flatMap((a) => a.refused ?? []);
      expect(refused).toHaveLength(256);
      expect(refused.every((r) => r.code === 'limit')).toBe(true);
    });
  });

  describe('rate limits and broken clients', () => {
    it('answers a throttled event on its ACK, one bucket per IPv6 /64, while another address proceeds', async () => {
      const first = await connect('2001:db8:77:1::1');
      takeRefusalCounts();
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
    it('proves the token with ONE pushed code, then activates a batch of queues, each signed by its own key; then wakes the device once per burst', async () => {
      const bob = await connect();
      const alice = await connect();
      const one = await createQueue(bob);
      const two = await createQueue(bob);
      const stranger = await createQueue(alice);
      const token = 'fcm-token_box:1';

      // Step 1 names no queue and signs nothing: it only makes the box push
      // a code to the token, which only the token's holder can read.
      expect(
        await call(bob, 'registerNotifier', { v: 1, platform: 'fcm', token }),
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

      // A code the box never pushed refuses the WHOLE frame, one answer.
      expect(await activateWith(bob, randomBytes(16), [one, two])).toEqual({
        ok: false,
        code: 'auth_failed',
      });
      expect(await notifierRows([one, two])).toEqual([]);

      // The right code: every entry stands on its own signature. An entry
      // signed by another queue's key (a sid holder has no nid, but test
      // the bytes) is refused alone, like a subscribe entry.
      const forged = { ...stranger, key: one.key };
      expect(await activateWith(bob, code, [one, two, forged])).toEqual({
        ok: true,
        refused: [{ nid: stranger.nid, code: 'auth_failed' }],
      });
      expect(await notifierRows([one, two, stranger])).toEqual(
        [`${one.nid}:${token}`, `${two.nid}:${token}`].sort(),
      );
      // Idempotent: a repeat answers the same and rewrites nothing.
      expect(await activateWith(bob, code, [one, two])).toEqual({
        ok: true,
        refused: [],
      });
      expect(pushes).toHaveLength(1);

      pushes.length = 0;
      await call(alice, 'send', { v: 1, sid: one.sid, blob: blob() });
      await call(alice, 'send', { v: 1, sid: one.sid, blob: blob() });
      await until(() => pushes.length === 1, 8000);
      await sleep(500);
      expect(pushes).toEqual([
        { platform: 'fcm', token, data: { type: 'new_message' } },
      ]);
    });

    it('a pushed code survives a reconnect between the steps and a stranger challenging the same token', async () => {
      const first = await connect();
      const queue = await createQueue(first);
      const token = 'fcm-token_box:5';
      const code = await challengeToken(first, token);
      // Someone else asks for a code to the same token: the box pushes a
      // second one, and the first stays good — no one can void it.
      const stranger = await connect();
      const second = await challengeToken(stranger, token);
      expect(second.equals(code)).toBe(false);
      first.disconnect();

      // The code is the proof; the signatures bind the NEW connection.
      const again = await connect();
      expect(await activateWith(again, code, [queue])).toEqual({
        ok: true,
        refused: [],
      });
      expect(await notifierRows([queue])).toEqual([`${queue.nid}:${token}`]);
    });

    it('wakes the device for what a socket that went away never acked; one that acked everything leaves nothing to wake', async () => {
      const bob = await connect();
      const alice = await connect();
      const queue = await createQueue(bob);
      const token = 'fcm-token_box:2';
      await activateNotifier(bob, queue, token);
      const got = collect(bob);
      expect(await subscribe(bob, [queue])).toMatchObject({ ok: true });
      pushes.length = 0;

      // Handed to a live socket, never acked: the device may not have read
      // it. A socket dies silently (a phone put the app away) and the box
      // learns it only at the ping timeout — every message in between went
      // to that socket instead of to a push.
      await call(alice, 'send', { v: 1, sid: queue.sid, blob: blob() });
      await until(() => got.length === 1, 4000);
      await sleep(3000);
      expect(pushes).toEqual([]);
      bob.disconnect();
      await until(() => pushes.length === 1, 8000);
      expect(pushes).toEqual([
        { platform: 'fcm', token, data: { type: 'new_message' } },
      ]);

      const carol = await connect();
      const again = collect(carol);
      await subscribe(carol, [queue]);
      await until(() => again.length === 1, 4000);
      expect(await ackMessage(carol, queue, again[0].id)).toMatchObject({
        ok: true,
      });
      pushes.length = 0;
      carol.disconnect();
      await sleep(3500);
      expect(pushes).toEqual([]);
    });

    it('a socket whose queue a newer socket took wakes nobody when it goes', async () => {
      const stale = await connect();
      const alice = await connect();
      const queue = await createQueue(stale);
      const token = 'fcm-token_box:3';
      await activateNotifier(stale, queue, token);
      await subscribe(stale, [queue]);
      const fresh = await connect();
      const got = collect(fresh);
      await subscribe(fresh, [queue]);
      await call(alice, 'send', { v: 1, sid: queue.sid, blob: blob() });
      await until(() => got.length === 1, 4000);
      pushes.length = 0;

      // The unacked message sits with the live socket, which owns the queue.
      stale.disconnect();
      await sleep(3500);
      expect(pushes).toEqual([]);
      // Nothing left for the suite's disconnect to wake in the next test.
      await ackMessage(fresh, queue, got[0].id);
    });

    it('an expired message the reaper has not swept yet wakes nobody: delivery would never hand it out', async () => {
      const bob = await connect();
      const queue = await createQueue(bob);
      await activateNotifier(bob, queue, 'fcm-token_box:4');
      await subscribe(bob, [queue]);
      // Stored as `enqueue` would have: the counters follow the row.
      await db.query(
        `WITH m AS (
           INSERT INTO box_msgs (id, rid, blob, "createdAt", "expiresAt")
           VALUES ($1, $2, $3, now() - interval '31 days', now() - interval '1 day')
           RETURNING rid),
         q AS (
           UPDATE box_queues SET "msgCount" = "msgCount" + 1
            WHERE rid IN (SELECT rid FROM m))
         UPDATE box_totals SET "msgCount" = "msgCount" + 1`,
        [randomBytes(16), Buffer.from(queue.rid, 'base64url'), randomBytes(16)],
      );
      pushes.length = 0;

      bob.disconnect();
      await sleep(3500);
      expect(pushes).toEqual([]);
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

    it('stores the 32 MiB top rung, so a 20 MiB file of today still sends once padded', async () => {
      const bob = await connect();
      const queue = await createQueue(bob);
      const posted = await upload(queue.sid, randomBytes(32 * 1024 * 1024));
      expect(posted.status).toBe(201);
      const answer = await readJson<{ id: string; bucket: string }>(posted);
      expect(answer.bucket).toBe('32m');
      expect((await queueRow(queue.rid)).mediaBytesToday).toBe(
        32 * 1024 * 1024,
      );
      const fetched = await fetch(`${base}/box/media/${answer.id}`);
      expect(fetched.status).toBe(200);
      expect((await fetched.arrayBuffer()).byteLength).toBe(32 * 1024 * 1024);
    });

    it('refuses an off-ladder body, and one over the top rung, with 413 bad_size', async () => {
      const bob = await connect();
      const queue = await createQueue(bob);
      for (const size of [5000, 32 * 1024 * 1024 + 1]) {
        const res = await upload(queue.sid, randomBytes(size));
        expect(res.status).toBe(413);
        expect(await res.json()).toEqual({ error: 'bad_size' });
      }
      expect((await queueRow(queue.rid)).mediaBytesToday).toBe(0);
    });

    it('refuses an off-ladder Content-Length before reading one byte of the unauthenticated body', async () => {
      const bob = await connect();
      const queue = await createQueue(bob);
      // Headers only: not one body byte is ever sent. A server that read
      // the body first would never answer.
      expect(await statusBeforeBody(queue.sid, 16 * 1024 * 1024 - 1)).toBe(413);
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
      takeRefusalCounts();
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
      // Counters only, never an address (E11).
      expect(takeRefusalCounts()).toEqual(new Map([['mediaUpload:budget', 2]]));
    });
  });

  describe('global ceiling (decision 30)', () => {
    const QUOTA = { ok: false, code: 'quota_exceeded' };

    it('refuses a send past the global message ceiling with quota_exceeded — a live sid and an unknown one alike — while a full request queue still rotates; an ack gives the room back', async () => {
      const bob = await connect();
      const alice = await connect();
      const normal = await createQueue(bob);
      const request = await createQueue(bob, 'request');
      for (let i = 0; i < 50; i++) {
        await call(alice, 'send', { v: 1, sid: request.sid, blob: blob() });
      }
      takeRefusalCounts();
      const before = await totals();
      ceiling.msgs = before.msgs + 1;

      expect(
        await call(alice, 'send', { v: 1, sid: normal.sid, blob: blob() }),
      ).toEqual({ ok: true });
      expect(await totals()).toEqual({ ...before, msgs: before.msgs + 1 });
      expect(
        await call(alice, 'send', { v: 1, sid: normal.sid, blob: blob() }),
      ).toEqual(QUOTA);
      // No oracle: a dead sid reads exactly like a live one past the ceiling.
      expect(
        await call(alice, 'send', {
          v: 1,
          sid: randomBytes(32).toString('base64url'),
          blob: blob(),
        }),
      ).toEqual(QUOTA);
      expect(await storedIds(normal.rid)).toHaveLength(1);
      expect((await queueRow(normal.rid)).msgCount).toBe(1);

      // Evicting the oldest replaces a message: the total does not grow.
      const [oldest] = await storedIds(request.rid);
      expect(
        await call(alice, 'send', { v: 1, sid: request.sid, blob: blob() }),
      ).toEqual({ ok: true });
      expect(await storedIds(request.rid)).not.toContain(oldest);
      expect((await totals()).msgs).toBe(before.msgs + 1);
      // Counted, never traced (E11).
      expect(takeRefusalCounts()).toEqual(new Map([['send:ceiling', 2]]));

      const [id] = await storedIds(normal.rid);
      expect(await ackMessage(bob, normal, id)).toEqual({ ok: true });
      expect((await totals()).msgs).toBe(before.msgs);
      expect(
        await call(alice, 'send', { v: 1, sid: normal.sid, blob: blob() }),
      ).toEqual({ ok: true });
    });

    it('gives the room back on every other path that removes messages: the TTL sweep, deleteQueue and the reaper', async () => {
      const bob = await connect();
      const alice = await connect();
      const expiring = await createQueue(bob);
      const deleted = await createQueue(bob);
      const unclaimed = await createQueue(bob);
      for (const queue of [expiring, deleted, deleted, unclaimed, unclaimed]) {
        await call(alice, 'send', { v: 1, sid: queue.sid, blob: blob() });
      }
      // Whatever earlier tests left expired goes first, so each step below
      // moves the total by its own messages only.
      await app.get(BoxReaper).sweep();
      const before = (await totals()).msgs;

      await db.query(
        `UPDATE box_msgs SET "expiresAt" = now() - interval '1 second'
          WHERE rid = $1`,
        [Buffer.from(expiring.rid, 'base64url')],
      );
      await app.get(BoxReaper).sweep();
      expect((await totals()).msgs).toBe(before - 1);

      expect(
        await call(bob, 'deleteQueue', {
          v: 1,
          rid: deleted.rid,
          sig: signFor(
            bob,
            deleted.key,
            'deleteQueue',
            Buffer.from(deleted.rid, 'base64url'),
          ),
        }),
      ).toEqual({ ok: true });
      expect((await totals()).msgs).toBe(before - 3);

      await db.query(
        `UPDATE box_queues SET "claimBy" = now() - interval '1 second'
          WHERE rid = $1`,
        [Buffer.from(unclaimed.rid, 'base64url')],
      );
      await app.get(BoxReaper).sweep();
      expect(await queueRow(unclaimed.rid)).toBeUndefined();
      expect((await totals()).msgs).toBe(before - 5);
    });

    it('refuses an upload past the global media ceiling with 429 quota_exceeded before reading its body — a live sid and an unknown one alike; expired media gives the room back', async () => {
      const bob = await connect();
      const queue = await createQueue(bob);
      takeRefusalCounts();
      const before = await totals();
      ceiling.mediaBytes = before.mediaBytes + 16 * 1024;

      const first = await upload(queue.sid, randomBytes(16 * 1024));
      expect(first.status).toBe(201);
      const { id } = await readJson<{ id: string }>(first);
      expect(await totals()).toEqual({
        ...before,
        mediaBytes: before.mediaBytes + 16 * 1024,
      });

      expect(await statusBeforeBody(queue.sid, 4096)).toBe(429);
      for (const sid of [queue.sid, randomBytes(32).toString('base64url')]) {
        const res = await upload(sid, randomBytes(4096));
        expect(res.status).toBe(429);
        expect(await res.json()).toEqual({ error: 'quota_exceeded' });
      }
      // A refused upload charges nothing, the queue's budget included.
      expect((await queueRow(queue.rid)).mediaBytesToday).toBe(16 * 1024);
      expect((await totals()).mediaBytes).toBe(before.mediaBytes + 16 * 1024);
      expect(takeRefusalCounts()).toEqual(
        new Map([['mediaUpload:ceiling', 3]]),
      );

      await db.query(
        `UPDATE box_media SET "expiresAt" = now() - interval '1 second'
          WHERE id = $1`,
        [Buffer.from(id, 'base64url')],
      );
      await app.get(BoxReaper).sweep();
      expect((await totals()).mediaBytes).toBe(before.mediaBytes);
      expect((await upload(queue.sid, randomBytes(4096))).status).toBe(201);
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

  describe('running totals (decision 30)', () => {
    it('equal what the tables hold after every path above: sends, evictions, acks, deletes, sweeps, reaps, uploads and refusals', async () => {
      const held = await stored();
      // Positive control: the suite left messages and media behind.
      expect(held.msgs).toBeGreaterThan(0);
      expect(held.mediaBytes).toBeGreaterThan(0);
      expect(await totals()).toEqual(held);
    });
  });
});
