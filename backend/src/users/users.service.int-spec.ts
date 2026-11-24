import { randomBytes } from 'crypto';
import { join } from 'path';
import { Client } from 'pg';
import { DataSource, QueryFailedError } from 'typeorm';
import { runMigrations } from '../database/migration-runner';
import { ProfilePhoto } from './profile-photo.entity';
import { User } from './user.entity';

/**
 * BE-05 on a FRESH Postgres database built by the real migration runner: two
 * names that differ only by case cannot both be stored, and the violation
 * carries the constraint name `UsersService.create` tells apart from a
 * (username, tag) collision. Same database switch as the other int suites.
 */
const ADMIN_URL = process.env.BOX_IT_DATABASE_URL;
if (!ADMIN_URL && process.env.CI) {
  throw new Error(
    'BOX_IT_DATABASE_URL is not set: in CI the integration suites must run, never skip',
  );
}
const describeWithDb = ADMIN_URL ? describe : describe.skip;

describeWithDb('users: case-insensitive unique name on real Postgres', () => {
  let admin: Client;
  let dbName: string;
  let db: DataSource;

  const insert = (username: string, tag: string) =>
    db.query(
      `INSERT INTO public.users (username, tag, password) VALUES ($1, $2, 'x')`,
      [username, tag],
    );

  async function violatedConstraint(
    promise: Promise<unknown>,
  ): Promise<string> {
    const error: unknown = await promise.then(
      () => {
        throw new Error('expected a unique violation');
      },
      (e: unknown) => e,
    );
    expect(error).toBeInstanceOf(QueryFailedError);
    const driverError = (error as QueryFailedError).driverError as {
      code: string;
      constraint: string;
    };
    expect(driverError.code).toBe('23505');
    return driverError.constraint;
  }

  beforeAll(async () => {
    const url = new URL(ADMIN_URL as string);
    admin = new Client({ connectionString: ADMIN_URL });
    await admin.connect();
    dbName = `users_it_${randomBytes(6).toString('hex')}`;
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
    db = new DataSource({
      type: 'postgres',
      ...connection,
      entities: [User, ProfilePhoto],
      synchronize: false,
    });
    await db.initialize();
  });

  afterAll(async () => {
    if (db?.isInitialized) await db.destroy();
    if (admin) {
      await admin.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`);
      await admin.end();
    }
  });

  it('refuses a name differing only by case, under the index create() recognises', async () => {
    await insert('Alice', '1111');
    expect(await violatedConstraint(insert('alice', '2222'))).toBe(
      'UQ_users_lower_username',
    );
  });

  it('still reports a (username, tag) collision under the old constraint', async () => {
    await insert('bob', '3333');
    // Same name AND tag: the name index and the pair constraint both apply;
    // Postgres names the first one it checks, so only assert it is a 23505
    // on one of the two.
    expect([
      'UQ_users_lower_username',
      'UQ_82ed9e04d0b61a87074cf8a8d39',
    ]).toContain(await violatedConstraint(insert('bob', '3333')));
  });

  it('the inverse (drop the index) restores the old behaviour', async () => {
    await db.query('DROP INDEX public."UQ_users_lower_username"');
    await insert('Carol', '4444');
    await insert('carol', '5555');
    // Put it back so the test order cannot matter: remove the offender first.
    await db.query(`DELETE FROM public.users WHERE username = 'carol'`);
    await db.query(
      'CREATE UNIQUE INDEX "UQ_users_lower_username" ON public.users USING btree (LOWER(username))',
    );
  });
});
