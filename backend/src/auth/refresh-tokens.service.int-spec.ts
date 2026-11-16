import { randomBytes } from 'crypto';
import { join } from 'path';
import { ConfigService } from '@nestjs/config';
import { UnauthorizedException } from '@nestjs/common';
import { Client } from 'pg';
import { DataSource } from 'typeorm';
import { runMigrations } from '../database/migration-runner';
import { ProfilePhoto } from '../users/profile-photo.entity';
import { User } from '../users/user.entity';
import { RefreshToken } from './refresh-token.entity';
import { RefreshTokensService } from './refresh-tokens.service';

/**
 * Refresh-token rotation with reuse detection (plan B4) on a FRESH Postgres
 * database built by the real migration runner (0001 … latest). What has to
 * hold lives in SQL a mocked repository cannot run: the conditional UPDATE
 * that lets exactly one of two racing refreshes rotate (the other must get
 * the SAME successor, not a logout), the OR lookup of the current and the
 * replaced token, and the session row that ends on reuse.
 *
 * Same database switch as the box suite: `BOX_IT_DATABASE_URL`; a CI run
 * without it FAILS rather than skipping.
 */
const ADMIN_URL = process.env.BOX_IT_DATABASE_URL;
if (!ADMIN_URL && process.env.CI) {
  throw new Error(
    'BOX_IT_DATABASE_URL is not set: in CI the integration suites must run, never skip',
  );
}
const describeWithDb = ADMIN_URL ? describe : describe.skip;

const INVALID = new UnauthorizedException('Invalid refresh token');

describeWithDb('RefreshTokensService rotation on real Postgres', () => {
  let admin: Client;
  let dbName: string;
  let db: DataSource;
  let service: RefreshTokensService;
  const live = () => Promise.resolve(false);

  function serviceWithSecret(secret: string): RefreshTokensService {
    const config = {
      get: (key: string) => (key === 'JWT_SECRET' ? secret : undefined),
    } as unknown as ConfigService;
    return new RefreshTokensService(db.getRepository(RefreshToken), config);
  }

  async function seedUser(): Promise<number> {
    const rows: { id: number }[] = await db.query(
      `INSERT INTO public.users (username, tag, password)
       VALUES ($1, '0001', 'x') RETURNING id`,
      [`u${randomBytes(6).toString('hex')}`],
    );
    return rows[0].id;
  }

  async function sessionsOf(userId: number): Promise<RefreshToken[]> {
    return db.getRepository(RefreshToken).find({ where: { userId } });
  }

  const rotate = (token: string, s = service) =>
    s.redeem(token, live, { rotate: true }).then((r) => r.refreshToken);

  beforeAll(async () => {
    const url = new URL(ADMIN_URL as string);
    admin = new Client({ connectionString: ADMIN_URL });
    await admin.connect();
    dbName = `refresh_it_${randomBytes(6).toString('hex')}`;
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
    db = new DataSource({
      type: 'postgres',
      ...connection,
      entities: [RefreshToken, User, ProfilePhoto],
      synchronize: false,
    });
    await db.initialize();
    service = serviceWithSecret('integration-secret-one-0123456789abcdef');
  });

  afterAll(async () => {
    if (db?.isInitialized) await db.destroy();
    if (admin) {
      await admin.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`);
      await admin.end();
    }
  });

  it('migration 0028 and the RefreshToken entity agree on prev_token_hash', async () => {
    const log = await db.driver.createSchemaBuilder().log();
    expect(
      log.upQueries
        .map((q) => q.query)
        .filter((query) => /prev_token_hash/.test(query)),
    ).toEqual([]);
  });

  it('rotates on every refresh that asks, within one session row that keeps its device', async () => {
    const userId = await seedUser();
    const t0 = await service.createToken(userId, 3, 'Pixel');
    const t1 = await rotate(t0);
    const t2 = await rotate(t1);

    expect(new Set([t0, t1, t2]).size).toBe(3);
    const family = RefreshTokensService.familyOf(t0);
    expect(RefreshTokensService.familyOf(t1)).toBe(family);
    expect(RefreshTokensService.familyOf(t2)).toBe(family);
    const rows = await sessionsOf(userId);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      id: family,
      deviceId: 3,
      deviceName: 'Pixel',
      tokenHash: RefreshTokensService.hashToken(t2),
      prevTokenHash: RefreshTokensService.hashToken(t1),
    });
    await expect(
      service.redeem(t2, live, { rotate: true }),
    ).resolves.toMatchObject({ userId, deviceId: 3 });
  });

  it('a lost response is not a logout: the replaced token gets the same successor back', async () => {
    const userId = await seedUser();
    const t0 = await service.createToken(userId, 1);
    const t1 = await rotate(t0);

    // The client never saw t1 and retries with t0, as often as it takes; each
    // retry is a refresh like any other, so the session's expiry slides.
    await db.query(
      `UPDATE public.refresh_tokens SET expires_at = now() + interval '1 day'
        WHERE user_id = $1`,
      [userId],
    );
    expect(await rotate(t0)).toBe(t1);
    expect(await rotate(t0)).toBe(t1);
    const [row] = await sessionsOf(userId);
    expect(row.expiresAt.getTime()).toBeGreaterThan(
      Date.now() + 300 * 86400 * 1000,
    );
    // Then t1 works, and from that moment t0 is reuse.
    const t2 = await rotate(t1);
    expect(t2).not.toBe(t1);
    await expect(rotate(t0)).rejects.toThrow(INVALID);
  });

  /**
   * A service whose first [n] lookups each wait, after reading, for [gate]:
   * the requests that make them act on what they read before [gate] opens.
   */
  function heldService(n: number, gate: Promise<void>) {
    const repo = db.getRepository(RefreshToken);
    const held = { count: 0 };
    const racing = new Proxy(repo, {
      get(target, prop) {
        if (prop === 'findOne') {
          return async (...args: Parameters<typeof target.findOne>) => {
            const row = await target.findOne(...args);
            if (held.count < n) {
              held.count += 1;
              await gate;
            }
            return row;
          };
        }
        const value: unknown = Reflect.get(target, prop, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });
    const config = { get: () => undefined } as unknown as ConfigService;
    return { held, service: new RefreshTokensService(racing, config) };
  }

  function gate() {
    let open!: () => void;
    const opened = new Promise<void>((resolve) => (open = resolve));
    return { opened, open };
  }

  /** Resolves once [check] holds, polling the event loop. */
  async function until(check: () => boolean): Promise<void> {
    while (!check()) await new Promise((resolve) => setImmediate(resolve));
  }

  it('two refreshes that both read the token before either rotates: one rotates, the other gets the same successor', async () => {
    const userId = await seedUser();
    const t0 = await service.createToken(userId, 1);
    const g = gate();
    const { held, service: raced } = heldService(2, g.opened);

    const both = Promise.all([rotate(t0, raced), rotate(t0, raced)]);
    await until(() => held.count === 2);
    g.open();
    const answers = await both;

    expect(answers[0]).toBe(answers[1]);
    expect(answers[0]).not.toBe(t0);
    await expect(rotate(answers[0])).resolves.toEqual(expect.any(String));
    expect(await sessionsOf(userId)).toHaveLength(1);
  });

  it('a refresh that read its token before the session moved on twice is reuse, never a rollback of the session', async () => {
    const userId = await seedUser();
    const t0 = await service.createToken(userId, 1);
    const g = gate();
    const { held, service: stale } = heldService(1, g.opened);

    const late = rotate(t0, stale);
    await until(() => held.count === 1);
    const t2 = await rotate(await rotate(t0));
    g.open();

    await expect(late).rejects.toThrow(INVALID);
    // Rolled back to t1, the session would have orphaned t2 instead.
    expect(await sessionsOf(userId)).toEqual([]);
    await expect(rotate(t2)).rejects.toThrow(INVALID);
  });

  it('a retry of the replaced token that read before the session moved on is reuse, never a stale answer', async () => {
    const userId = await seedUser();
    const t0 = await service.createToken(userId, 1);
    const t1 = await rotate(t0);
    const g = gate();
    const { held, service: stale } = heldService(1, g.opened);

    const late = rotate(t0, stale);
    await until(() => held.count === 1);
    const t2 = await rotate(t1);
    g.open();

    await expect(late).rejects.toThrow(INVALID);
    expect(await sessionsOf(userId)).toEqual([]);
    await expect(rotate(t2)).rejects.toThrow(INVALID);
  });

  it('reuse of an older token ends the session for every holder', async () => {
    const userId = await seedUser();
    const t0 = await service.createToken(userId, 1);
    const t1 = await rotate(t0);
    const t2 = await rotate(t1);

    await expect(rotate(t0)).rejects.toThrow(INVALID);

    expect(await sessionsOf(userId)).toEqual([]);
    await expect(rotate(t2)).rejects.toThrow(INVALID);
  });

  it('a client that does not rotate presenting the replaced token is reuse: someone else rotated its session', async () => {
    const userId = await seedUser();
    const t0 = await service.createToken(userId, 1);
    // Whoever stole t0 rotates it; the web tab still holds t0.
    const stolen = await rotate(t0);

    await expect(service.redeem(t0, live, { rotate: false })).rejects.toThrow(
      INVALID,
    );

    await expect(rotate(stolen)).rejects.toThrow(INVALID);
  });

  it('a client that does not rotate keeps one token, and only the expiry slides', async () => {
    const userId = await seedUser();
    const t0 = await service.createToken(userId, 1);
    await db.query(
      `UPDATE public.refresh_tokens SET expires_at = now() + interval '1 day'
        WHERE user_id = $1`,
      [userId],
    );

    const answer = await service.redeem(t0, live, { rotate: false });

    expect(answer.refreshToken).toBe(t0);
    const [row] = await sessionsOf(userId);
    expect(row.tokenHash).toBe(RefreshTokensService.hashToken(t0));
    expect(row.prevTokenHash).toBeNull();
    expect(row.expiresAt.getTime()).toBeGreaterThan(
      Date.now() + 300 * 86400 * 1000,
    );
  });

  it('a session from before plan B4 (no family prefix) slides as it did, and rotates into its own row id', async () => {
    const userId = await seedUser();
    const legacy = randomBytes(48).toString('base64url');
    const [{ id }]: { id: string }[] = await db.query(
      `INSERT INTO public.refresh_tokens (user_id, token_hash, expires_at, device_id)
       VALUES ($1, $2, now() + interval '30 days', 1) RETURNING id`,
      [userId, RefreshTokensService.hashToken(legacy)],
    );

    expect(
      (await service.redeem(legacy, live, { rotate: false })).refreshToken,
    ).toBe(legacy);
    const t1 = await rotate(legacy);
    expect(RefreshTokensService.familyOf(t1)).toBe(id);
    expect(await rotate(legacy)).toBe(t1);
    await rotate(t1);
    // Its first token named no session, so once two steps old it is merely
    // unknown: nothing to end, nothing to issue.
    await expect(rotate(legacy)).rejects.toThrow(INVALID);
    expect(await sessionsOf(userId)).toHaveLength(1);
  });

  it('a JWT_SECRET change between a rotation and its retry re-derives the unseen successor instead of ending the session', async () => {
    const userId = await seedUser();
    const t0 = await service.createToken(userId, 1);
    const unseen = await rotate(t0);
    const rekeyed = serviceWithSecret(
      'integration-secret-two-0123456789abcdef',
    );

    const t1 = await rotate(t0, rekeyed);

    expect(t1).not.toBe(unseen);
    await expect(rotate(t1, rekeyed)).resolves.toEqual(expect.any(String));
    expect(await sessionsOf(userId)).toHaveLength(1);
  });

  // Decision 130 (E130a): the row is the revocation's proof, and the device
  // asks with whatever token it last stored — an old one included.
  it("a revoked device's older token is answered 'Device revoked' and the row stays", async () => {
    const userId = await seedUser();
    const t0 = await service.createToken(userId, 2);
    const t1 = await rotate(t0);
    await rotate(t1);
    const revoked = () => Promise.resolve(true);

    await expect(service.redeem(t0, revoked, { rotate: true })).rejects.toThrow(
      new UnauthorizedException('Device revoked'),
    );

    expect(await sessionsOf(userId)).toHaveLength(1);
  });

  it('logout with the just-replaced token (its response was lost) ends the session', async () => {
    const userId = await seedUser();
    const t0 = await service.createToken(userId, 1);
    const t1 = await rotate(t0);

    await service.revokeByPlain(t0);

    expect(await sessionsOf(userId)).toEqual([]);
    await expect(rotate(t1)).rejects.toThrow(INVALID);
  });
});
