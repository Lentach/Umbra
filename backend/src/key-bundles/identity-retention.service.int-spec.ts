import { randomBytes } from 'crypto';
import { join } from 'path';
import { Client } from 'pg';
import { DataSource } from 'typeorm';
import { runMigrations } from '../database/migration-runner';
import { IdentityRetentionService } from './identity-retention.service';

/**
 * BE-29 / decision 150 on a FRESH Postgres database built by the real
 * migration runner: which rows the daily sweep deletes is SQL a mocked
 * connection cannot judge. Same database switch as the other int suites.
 */
const ADMIN_URL = process.env.BOX_IT_DATABASE_URL;
if (!ADMIN_URL && process.env.CI) {
  throw new Error(
    'BOX_IT_DATABASE_URL is not set: in CI the integration suites must run, never skip',
  );
}
const describeWithDb = ADMIN_URL ? describe : describe.skip;

describeWithDb('identity retention sweep on real Postgres', () => {
  let admin: Client;
  let dbName: string;
  let db: DataSource;
  let service: IdentityRetentionService;

  async function seedUser(): Promise<number> {
    const rows: { id: number }[] = await db.query(
      `INSERT INTO public.users (username, tag, password)
       VALUES ($1, '0001', 'x') RETURNING id`,
      [`u${randomBytes(6).toString('hex')}`],
    );
    return rows[0].id;
  }

  /** An audit row `daysAgo` days old; returns its id. */
  async function audit(userId: number, daysAgo: number): Promise<number> {
    const rows: { id: number }[] = await db.query(
      `INSERT INTO public.identity_change_audit
         ("userId", "previousIdentityPublicKey", "newIdentityPublicKey", "createdAt")
       VALUES ($1, 'a', 'b', now() - make_interval(days => $2)) RETURNING id`,
      [userId, daysAgo],
    );
    return rows[0].id;
  }

  /** A reset row in `status` whose ending moment is `daysAgo` days old. */
  async function reset(
    userId: number,
    status: 'pending' | 'cancelled' | 'completed',
    daysAgo: number,
  ): Promise<number> {
    const rows: { id: number }[] = await db.query(
      `INSERT INTO public.identity_reset_requests
         ("userId", status, "requestedAt", "deadlineAt", "cancelledAt", "completedAt")
       VALUES ($1, $2, now() - make_interval(days => $3),
               now() - make_interval(days => $3),
               CASE WHEN $2 = 'cancelled' THEN now() - make_interval(days => $3) END,
               CASE WHEN $2 = 'completed' THEN now() - make_interval(days => $3) END)
       RETURNING id`,
      [userId, status, daysAgo],
    );
    return rows[0].id;
  }

  async function ids(table: string, userId: number): Promise<number[]> {
    const rows: { id: number }[] = await db.query(
      `SELECT id FROM public.${table} WHERE "userId" = $1 ORDER BY id`,
      [userId],
    );
    return rows.map((row) => row.id);
  }

  beforeAll(async () => {
    const url = new URL(ADMIN_URL as string);
    admin = new Client({ connectionString: ADMIN_URL });
    await admin.connect();
    dbName = `retention_it_${randomBytes(6).toString('hex')}`;
    await admin.query(`CREATE DATABASE ${dbName}`);
    const connection = {
      host: url.hostname,
      port: Number(url.port || 5432),
      username: decodeURIComponent(url.username),
      password: decodeURIComponent(url.password),
      database: dbName,
    };
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
    db = new DataSource({ type: 'postgres', ...connection, entities: [] });
    await db.initialize();
    service = new IdentityRetentionService(db);
  });

  afterAll(async () => {
    if (db?.isInitialized) await db.destroy();
    if (admin) {
      await admin.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`);
      await admin.end();
    }
  });

  it('audit: keeps the newest row per account however old, deletes older rows past 30 days, keeps recent ones', async () => {
    const lone = await seedUser();
    const loneRow = await audit(lone, 400);

    const busy = await seedUser();
    await audit(busy, 200);
    await audit(busy, 100);
    const recentOld = await audit(busy, 20);
    const newest = await audit(busy, 1);

    await service.sweep();

    expect(await ids('identity_change_audit', lone)).toEqual([loneRow]);
    expect(await ids('identity_change_audit', busy)).toEqual([
      recentOld,
      newest,
    ]);
  });

  it('audit: of two rows with one timestamp exactly one survives', async () => {
    const userId = await seedUser();
    await db.query(
      `INSERT INTO public.identity_change_audit
         ("userId", "previousIdentityPublicKey", "newIdentityPublicKey", "createdAt")
       SELECT $1, 'a', 'b', now() - interval '90 days' FROM generate_series(1, 2)`,
      [userId],
    );

    await service.sweep();

    expect(await ids('identity_change_audit', userId)).toHaveLength(1);
  });

  it('resets: deletes completed and cancelled rows past 30 days, never a pending one, keeps recent ones', async () => {
    const oldDone = await seedUser();
    await reset(oldDone, 'completed', 45);
    const oldCancelled = await seedUser();
    await reset(oldCancelled, 'cancelled', 45);
    const oldPending = await seedUser();
    const pendingRow = await reset(oldPending, 'pending', 400);
    const recent = await seedUser();
    const recentRow = await reset(recent, 'completed', 5);

    await service.sweep();

    expect(await ids('identity_reset_requests', oldDone)).toEqual([]);
    expect(await ids('identity_reset_requests', oldCancelled)).toEqual([]);
    expect(await ids('identity_reset_requests', oldPending)).toEqual([
      pendingRow,
    ]);
    expect(await ids('identity_reset_requests', recent)).toEqual([recentRow]);
  });
});
