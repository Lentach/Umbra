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

  it('answers 400, not 500, to 80 two-code-point emoji and keeps the stored text', async () => {
    const kept = '\u{1F600}'.repeat(80);
    const saved = await patchAbout(kept);
    expect(saved.status).toBe(200);
    expect(await storedAbout()).toBe(kept);

    const refused = await patchAbout('\u2764\uFE0F'.repeat(80));
    expect(refused.status).toBe(400);
    expect(await refused.json()).toMatchObject({
      message: ['about must be at most 80 characters'],
    });
    expect(await storedAbout()).toBe(kept);
  });
});
