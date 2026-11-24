import { randomBytes } from 'crypto';
import { join } from 'path';
import { Client } from 'pg';
import { DataSource } from 'typeorm';
import { runMigrations } from '../database/migration-runner';
import { ProfilePhoto } from '../users/profile-photo.entity';
import { User } from '../users/user.entity';
import { Device } from './device.entity';
import { DevicesService } from './devices.service';

/**
 * First-contact addressing (metadata-privacy PR3.2) on a FRESH Postgres
 * database built by the real migration runner (0001 … latest). The privacy
 * properties live in SQL a mocked repository cannot run: a revoked device is
 * never served to a stranger nor re-publishable, and a pre-Phase-1 device 1
 * with a bundle but no `devices` row is still reachable. Moving the
 * `revokedAt` predicate into the JOIN, or making the JOIN inner, breaks one of
 * them.
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
  'DevicesService first-contact addressing on real Postgres',
  () => {
    let admin: Client;
    let dbName: string;
    let db: DataSource;
    let service: DevicesService;
    const sid = randomBytes(32).toString('base64url');
    const sealPub = randomBytes(32).toString('base64url');

    /** A user with a key bundle for each of [bundleDevices]; returns its id. */
    async function seedUser(bundleDevices: number[]): Promise<number> {
      const rows: { id: number }[] = await db.query(
        `INSERT INTO public.users (username, tag, password)
       VALUES ($1, '0001', 'x') RETURNING id`,
        [`u${randomBytes(6).toString('hex')}`],
      );
      const userId = rows[0].id;
      for (const deviceId of bundleDevices) {
        await db.query(
          `INSERT INTO public.key_bundles ("userId", "deviceId", "registrationId",
           "identityPublicKey", "signedPreKeyId", "signedPreKeyPublic",
           "signedPreKeySignature")
         VALUES ($1, $2, 1, 'ik', 1, 'spk', 'sig')`,
          [userId, deviceId],
        );
      }
      return userId;
    }

    async function addDevice(
      userId: number,
      deviceId: number,
      revoked: boolean,
    ): Promise<void> {
      await db.query(
        `INSERT INTO public.devices ("userId", "deviceId", "isPrimary", "revokedAt")
       VALUES ($1, $2, $3, $4)`,
        [userId, deviceId, deviceId === 1, revoked ? new Date() : null],
      );
    }

    beforeAll(async () => {
      const url = new URL(ADMIN_URL as string);
      admin = new Client({ connectionString: ADMIN_URL });
      await admin.connect();
      dbName = `devices_it_${randomBytes(6).toString('hex')}`;
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
        entities: [Device, User, ProfilePhoto],
        synchronize: false,
      });
      await db.initialize();
      service = new DevicesService(db.getRepository(Device));
    });

    afterAll(async () => {
      if (db?.isInitialized) await db.destroy();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`);
        await admin.end();
      }
    });

    it('migration 0023 and the Device entity agree on the request-queue columns', async () => {
      // Scoped to the two columns this migration owns: `devices` already carries
      // an unrelated FK-name drift from 0015 that synchronize would rename.
      const log = await db.driver.createSchemaBuilder().log();
      expect(
        log.upQueries
          .map((q) => q.query)
          .filter((query) => /"request(Sid|SealPub)"/.test(query)),
      ).toEqual([]);
    });

    it('serves live devices and a row-less legacy device 1, never a revoked one, with what each published', async () => {
      const userId = await seedUser([1, 2, 3]);
      // Device 1 predates the devices table: a bundle, no row.
      await addDevice(userId, 2, false);
      await addDevice(userId, 3, true);
      expect(await service.setRequestQueue(userId, 2, sid, sealPub)).toBe(true);

      expect(await service.firstContactDevices(userId)).toEqual([
        { deviceId: 1, requestSid: null, requestSealPub: null },
        { deviceId: 2, requestSid: sid, requestSealPub: sealPub },
      ]);
    });

    it('never lets a revoked device, or one without a row, publish a request queue', async () => {
      const userId = await seedUser([1, 2]);
      await addDevice(userId, 2, true);

      expect(await service.setRequestQueue(userId, 2, sid, sealPub)).toBe(
        false,
      );
      expect(await service.setRequestQueue(userId, 1, sid, sealPub)).toBe(
        false,
      );
      const rows: { requestSid: string | null }[] = await db.query(
        `SELECT "requestSid" FROM public.devices WHERE "userId" = $1`,
        [userId],
      );
      expect(rows).toEqual([{ requestSid: null }]);
    });
  },
);
