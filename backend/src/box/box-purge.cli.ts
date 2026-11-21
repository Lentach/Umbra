/**
 * Operator purge of attacker-shaped box queues during a flood incident (plan
 * D2 O2, decision 145; runbook: production-vm-deploy rule, "Box flood").
 *
 *   docker compose -f docker-compose.prod.yml exec -T backend \
 *     node dist/box/box-purge.cli.js [--min-msgs 32] [--min-age-hours 24]
 *       [--max-queues 500] [--execute]
 *
 * Without `--execute` it only counts. It prints counts, never an address. It
 * opens its own connection from the backend's `DB_*` environment and needs
 * no running app: `BoxService` is the one place that writes the box tables.
 */
import { DataSource } from 'typeorm';
import {
  BOX_GLOBAL_MEDIA_CEILING_BYTES,
  BOX_GLOBAL_MSG_CEILING,
  BOX_OPEN_MEDIA_CEILING_BYTES,
  BOX_OPEN_MSG_CEILING,
} from './box.constants';
import { BoxService, type PurgeCriteria } from './box.service';

const HOUR_MS = 60 * 60 * 1000;

/** The command line as criteria; throws on anything it does not know. */
export function parsePurgeArgs(argv: string[], now: Date): PurgeCriteria {
  const options = new Map<string, number>([
    ['--min-msgs', 32],
    ['--min-age-hours', 24],
    ['--max-queues', 500],
  ]);
  let dryRun = true;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--execute') {
      dryRun = false;
      continue;
    }
    if (!options.has(arg)) throw new Error(`unknown argument ${arg}`);
    const value = Number(argv[++i]);
    if (!Number.isInteger(value) || value < 1) {
      throw new Error(`${arg} needs a whole number of at least 1`);
    }
    options.set(arg, value);
  }
  return {
    minMsgs: options.get('--min-msgs')!,
    olderThan: new Date(
      now.getTime() - options.get('--min-age-hours')! * HOUR_MS,
    ),
    maxQueues: options.get('--max-queues')!,
    dryRun,
  };
}

async function main(): Promise<void> {
  const criteria = parsePurgeArgs(process.argv.slice(2), new Date());
  const db = new DataSource({
    type: 'postgres',
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT ?? 5432),
    username: process.env.DB_USER,
    password: process.env.DB_PASS,
    database: process.env.DB_NAME,
  });
  await db.initialize();
  try {
    const box = new BoxService(db, {
      msgs: BOX_GLOBAL_MSG_CEILING,
      mediaBytes: BOX_GLOBAL_MEDIA_CEILING_BYTES,
      openMsgs: BOX_OPEN_MSG_CEILING,
      openMediaBytes: BOX_OPEN_MEDIA_CEILING_BYTES,
    });
    const before = await box.totals();
    const result = await box.purgeStaleBacklogs(criteria);
    const after = await box.totals();
    const verb = criteria.dryRun ? 'would purge' : 'purged';
    console.log(
      `[box] purge ${verb} normalQueues=${result.normalQueues} ` +
        `requestQueues=${result.requestQueues} msgs=${result.msgs} ` +
        `(min-msgs=${criteria.minMsgs} older-than=${criteria.olderThan.toISOString()} ` +
        `max-queues=${criteria.maxQueues})`,
    );
    console.log(
      `[box] totals msgCount ${before?.msgCount ?? 'missing'} -> ` +
        `${after?.msgCount ?? 'missing'} of ${BOX_GLOBAL_MSG_CEILING} ` +
        `(open band ${BOX_OPEN_MSG_CEILING})`,
    );
    if (criteria.dryRun) console.log('[box] dry run: add --execute to delete');
  } finally {
    await db.destroy();
  }
}

if (require.main === module) {
  main().catch((err: unknown) => {
    console.error(`[box] purge failed: ${String(err)}`);
    process.exitCode = 1;
  });
}
