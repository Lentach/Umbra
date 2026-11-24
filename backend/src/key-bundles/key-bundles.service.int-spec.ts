import { randomBytes } from 'crypto';
import { setTimeout as sleep } from 'timers/promises';
import { join } from 'path';
import { Client } from 'pg';
import { DataSource } from 'typeorm';
import { runMigrations } from '../database/migration-runner';
import { ProfilePhoto } from '../users/profile-photo.entity';
import { User } from '../users/user.entity';
import { AccountAuthorization } from './account-authorization.entity';
import { IdentityChangeAudit } from './identity-change-audit.entity';
import { IdentityResetService } from './identity-reset.service';
import { KeyBundle } from './key-bundle.entity';
import { KeyBundlesService } from './key-bundles.service';
import { OneTimePreKey } from './one-time-pre-key.entity';

/**
 * The one-time pre-key claim on a FRESH Postgres database built by the real
 * migration runner (0001 … latest). "No key is ever served twice" is a
 * property of row locking under READ COMMITTED that a mocked repository
 * cannot run: two peers handed the same one-time pre-key both build a session
 * on it, and the second one's first message never decrypts.
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

describeWithDb(
  'KeyBundlesService one-time pre-key claim on real Postgres',
  () => {
    const IDENTITY = 'ik';
    let admin: Client;
    let dbName: string;
    let db: DataSource;
    let service: KeyBundlesService;

    /** A user whose device 1 holds a bundle and `keys` unused pre-keys. */
    async function seedUser(keys: number): Promise<number> {
      const rows: { id: number }[] = await db.query(
        `INSERT INTO public.users (username, tag, password)
       VALUES ($1, '0001', 'x') RETURNING id`,
        [`u${randomBytes(6).toString('hex')}`],
      );
      const userId = rows[0].id;
      await db.query(
        `INSERT INTO public.key_bundles ("userId", "deviceId", "registrationId",
         "identityPublicKey", "signedPreKeyId", "signedPreKeyPublic",
         "signedPreKeySignature")
       VALUES ($1, 1, 1, $2, 1, 'spk', 'sig')`,
        [userId, IDENTITY],
      );
      await db.query(
        `INSERT INTO public.one_time_pre_keys ("userId", "deviceId", "keyId",
         "publicKey", "identityPublicKey")
       SELECT $1, 1, k, 'otp-' || k, $2 FROM generate_series(1, $3::int) AS k`,
        [userId, IDENTITY, keys],
      );
      return userId;
    }

    async function usedKeyIds(userId: number): Promise<number[]> {
      const rows: { keyId: number }[] = await db.query(
        `SELECT "keyId" FROM public.one_time_pre_keys
       WHERE "userId" = $1 AND used = true ORDER BY "keyId"`,
        [userId],
      );
      return rows.map((row) => row.keyId);
    }

    beforeAll(async () => {
      const url = new URL(ADMIN_URL as string);
      admin = new Client({ connectionString: ADMIN_URL });
      await admin.connect();
      dbName = `otp_it_${randomBytes(6).toString('hex')}`;
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
        entities: [
          KeyBundle,
          OneTimePreKey,
          IdentityChangeAudit,
          AccountAuthorization,
          User,
          ProfilePhoto,
        ],
        synchronize: false,
      });
      await db.initialize();
      service = new KeyBundlesService(
        db.getRepository(KeyBundle),
        db.getRepository(OneTimePreKey),
        db.getRepository(IdentityChangeAudit),
        db.getRepository(AccountAuthorization),
        // The claim never reaches the reset ceremony.
        {} as IdentityResetService,
      );
    });

    afterAll(async () => {
      if (db?.isInitialized) await db.destroy();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`);
        await admin.end();
      }
    });

    it('concurrent fetches never serve one pre-key twice and claim every key there is', async () => {
      // More fetches than keys, each on its own pooled connection (pg's pool
      // holds 10); several rounds, because the overlap is a matter of timing.
      const FETCHES = 8;
      const KEYS = 5;
      for (let round = 0; round < 10; round++) {
        const userId = await seedUser(KEYS);

        const bundles = await Promise.all(
          Array.from({ length: FETCHES }, () =>
            service.fetchPreKeyBundle(userId),
          ),
        );

        const served = bundles
          .map((bundle) => bundle?.oneTimePreKeyId ?? null)
          .filter((keyId): keyId is number => keyId !== null)
          .sort((a, b) => a - b);
        expect(served).toEqual([1, 2, 3, 4, 5]);
        expect(await usedKeyIds(userId)).toEqual([1, 2, 3, 4, 5]);
      }
    });

    it('fetches queued behind one locked pre-key each get a different one', async () => {
      // The interleaving made certain: while another transaction holds the
      // oldest pre-key's row, every claim that picked that row waits on it.
      // Once it is released they must not all be handed that same key.
      const FETCHES = 4;
      const userId = await seedUser(FETCHES + 1);
      const holder = db.createQueryRunner();
      await holder.connect();
      await holder.startTransaction();
      let claims: Promise<(number | null)[]>;
      try {
        await holder.query(
          `SELECT id FROM public.one_time_pre_keys
         WHERE "userId" = $1 AND "keyId" = 1 FOR UPDATE`,
          [userId],
        );
        let settled = false;
        claims = Promise.all(
          Array.from({ length: FETCHES }, async () => {
            const bundle = await service.fetchPreKeyBundle(userId);
            return bundle?.oneTimePreKeyId ?? null;
          }),
        ).finally(() => {
          settled = true;
        });
        // Until every claim either waits on the held row or has been answered.
        const deadline = Date.now() + 10_000;
        while (!settled && Date.now() < deadline) {
          const waiting: { n: number }[] = await db.query(
            `SELECT count(*)::int AS n FROM pg_stat_activity
           WHERE datname = current_database() AND wait_event_type = 'Lock'`,
          );
          if (waiting[0].n === FETCHES) break;
          await sleep(20);
        }
      } finally {
        await holder.rollbackTransaction();
        await holder.release();
      }

      const served = (await claims).filter((keyId) => keyId !== null);
      expect(served).toHaveLength(FETCHES);
      expect(new Set(served).size).toBe(FETCHES);
      expect(await usedKeyIds(userId)).toEqual(
        [...served].sort((a, b) => a - b),
      );
    });

    it('a key served once stays served when the device uploads the same batch again', async () => {
      // The session that minted a batch uploads it again at every reconnect;
      // the device deleted the private half of the key that was served.
      const userId = await seedUser(2);
      const batch = [
        { keyId: 1, publicKey: 'otp-1' },
        { keyId: 2, publicKey: 'otp-2' },
      ];
      expect((await service.fetchPreKeyBundle(userId))?.oneTimePreKeyId).toBe(
        1,
      );

      await service.uploadOneTimePreKeys(userId, batch, IDENTITY);

      expect((await service.fetchPreKeyBundle(userId))?.oneTimePreKeyId).toBe(
        2,
      );
    });

    it('a new key under a new identity makes a served slot servable', async () => {
      // A regenerated identity reuses keyId slots with new key pairs.
      const userId = await seedUser(2);
      expect((await service.fetchPreKeyBundle(userId))?.oneTimePreKeyId).toBe(
        1,
      );
      await db.query(
        `UPDATE public.key_bundles SET "identityPublicKey" = 'ik-2'
       WHERE "userId" = $1`,
        [userId],
      );

      await service.uploadOneTimePreKeys(
        userId,
        [{ keyId: 1, publicKey: 'new-1' }],
        'ik-2',
      );

      expect(
        (await service.fetchPreKeyBundle(userId))?.oneTimePreKeyPublic,
      ).toBe('new-1');
    });
  },
);
