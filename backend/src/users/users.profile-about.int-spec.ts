import { readFileSync } from 'fs';
import { randomBytes } from 'crypto';
import { join } from 'path';
import {
  ExecutionContext,
  INestApplication,
  ValidationPipe,
} from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import { Client } from 'pg';
import { DataSource } from 'typeorm';
import { JwtAuthGuard } from '../auth-core/jwt-auth.guard';
import { runMigrations } from '../database/migration-runner';
import { LocalStorageService } from '../media/local-storage.service';
import { RefreshTokensService } from '../refresh-tokens/refresh-tokens.service';
import { ProfilePhoto } from './profile-photo.entity';
import { User } from './user.entity';
import { UsersController } from './users.controller';
import { UsersService } from './users.service';

/**
 * R12-BE-01 on a FRESH Postgres database built by the real migration runner:
 * `PATCH /users/profile-about` through the real pipe, controller and service.
 * `users.about` is varchar(80) and Postgres counts code points; whatever the
 * DTO lets through must fit, or the save is a 500. Same database switch as
 * the other int suites.
 */
const ADMIN_URL = process.env.BOX_IT_DATABASE_URL;
if (!ADMIN_URL && process.env.CI) {
  throw new Error(
    'BOX_IT_DATABASE_URL is not set: in CI the integration suites must run, never skip',
  );
}
const describeWithDb = ADMIN_URL ? describe : describe.skip;

describeWithDb('PATCH /users/profile-about on real Postgres', () => {
  let admin: Client;
  let dbName: string;
  let db: DataSource;
  let app: INestApplication;
  let base: string;
  let userId: number;

  const patchAbout = (about: string) =>
    fetch(`${base}/users/profile-about`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ about }),
    });

  const storedAbout = async (): Promise<string | null> => {
    const rows: Array<{ about: string | null }> = await db.query(
      `SELECT about FROM public.users WHERE id = $1`,
      [userId],
    );
    return rows[0].about;
  };

  beforeAll(async () => {
    const url = new URL(ADMIN_URL as string);
    admin = new Client({ connectionString: ADMIN_URL });
    await admin.connect();
    dbName = `users_about_it_${randomBytes(6).toString('hex')}`;
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
    const inserted: Array<{ id: number }> = await db.query(
      `INSERT INTO public.users (username, tag, password) VALUES ('alice', '1111', 'x') RETURNING id`,
    );
    userId = inserted[0].id;

    const moduleRef = await Test.createTestingModule({
      controllers: [UsersController],
      providers: [
        UsersService,
        { provide: getRepositoryToken(User), useValue: db.getRepository(User) },
        {
          provide: getRepositoryToken(ProfilePhoto),
          useValue: db.getRepository(ProfilePhoto),
        },
        { provide: LocalStorageService, useValue: {} },
        { provide: RefreshTokensService, useValue: {} },
      ],
    })
      .overrideGuard(JwtAuthGuard)
      .useValue({
        canActivate: (ctx: ExecutionContext) => {
          ctx.switchToHttp().getRequest<{ user?: { id: number } }>().user = {
            id: userId,
          };
          return true;
        },
      })
      .compile();
    app = moduleRef.createNestApplication({ logger: false });
    app.useGlobalPipes(new ValidationPipe({ whitelist: true }));
    await app.listen(0, '127.0.0.1');
    base = await app.getUrl();
  });

  afterAll(async () => {
    if (app) await app.close();
    if (db?.isInitialized) await db.destroy();
    if (admin) {
      await admin.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`);
      await admin.end();
    }
  });

  it.each([
    ['80 hearts with a variation selector', '\u2764\uFE0F'.repeat(80)],
    [
      '80 family emoji',
      '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}'.repeat(80),
    ],
  ])(
    'saves %s and reads it back identical (was a 500)',
    async (_name, about) => {
      const saved = await patchAbout(about);
      expect(saved.status).toBe(200);
      expect(await saved.json()).toEqual({ about });
      expect(await storedAbout()).toBe(about);
    },
  );

  it('answers 400, not 500, to 81 characters and keeps the stored text', async () => {
    const kept = '\u2764\uFE0F'.repeat(80);
    expect((await patchAbout(kept)).status).toBe(200);

    const refused = await patchAbout('\u2764\uFE0F'.repeat(81));
    expect(refused.status).toBe(400);
    expect(await refused.json()).toMatchObject({
      message: ['about must be at most 80 characters'],
    });
    expect(await storedAbout()).toBe(kept);
  });

  it('answers 400, not 500, to one cluster of 700 code points', async () => {
    const refused = await patchAbout('a' + '\u0301'.repeat(700));
    expect(refused.status).toBe(400);
  });

  it('the column CHECK refuses 641 code points even past the DTO', async () => {
    await expect(
      db.query(
        `UPDATE public.users SET about = repeat('x', 641) WHERE id = $1`,
        [userId],
      ),
    ).rejects.toMatchObject({ code: '23514' });
  });

  describe('migration 0032 down and up', () => {
    const migrationsDir = join(__dirname, '..', '..', 'migrations');
    const up = readFileSync(
      join(migrationsDir, '0032_users_about_text.sql'),
      'utf8',
    );
    const down = readFileSync(
      join(migrationsDir, 'down', '0032_users_about_text.down.sql'),
      'utf8',
    );

    const column = async (): Promise<string> => {
      const rows: Array<{ type: string }> = await db.query(
        `SELECT data_type || coalesce('(' || character_maximum_length || ')', '') AS type
           FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'about'`,
      );
      return rows[0].type;
    };
    const hasCheck = async (): Promise<boolean> => {
      const rows: unknown[] = await db.query(
        `SELECT 1 FROM pg_constraint WHERE conname = 'CHK_users_about_max_code_points'`,
      );
      return rows.length === 1;
    };

    it('round-trips on an empty table', async () => {
      await db.query(`DELETE FROM public.users`);
      expect(await column()).toBe('text');
      expect(await hasCheck()).toBe(true);

      await db.query(down);
      expect(await column()).toBe('character varying(80)');
      expect(await hasCheck()).toBe(false);

      await db.query(up);
      expect(await column()).toBe('text');
      expect(await hasCheck()).toBe(true);
    });

    it('down refuses, and changes nothing, when a row has 100 code points', async () => {
      await db.query(
        `INSERT INTO public.users (username, tag, password, about) VALUES ('bob', '2222', 'x', repeat('x', 100))`,
      );
      await expect(db.query(down)).rejects.toThrow(
        /cannot restore users\.about to varchar\(80\): 1 row\(s\) hold more than 80 code points/,
      );
      expect(await column()).toBe('text');
      expect(await hasCheck()).toBe(true);
      const rows: Array<{ length: number }> = await db.query(
        `SELECT char_length(about) AS length FROM public.users WHERE tag = '2222'`,
      );
      expect(rows[0].length).toBe(100);
    });
  });
});
