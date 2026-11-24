import { BoxReaper } from './box-reaper.service';
import { BOX_OPEN_MSG_CEILING } from './box.constants';

function setup(totals: Array<{ msgCount: number; mediaBytes: number } | null>) {
  const box = {
    deleteExpiredMessages: jest.fn().mockResolvedValue(undefined),
    expiredMedia: jest.fn().mockResolvedValue([]),
    deleteMedia: jest.fn(),
    reapQueues: jest.fn().mockResolvedValue([]),
    totals: jest.fn(),
  };
  for (const t of totals) box.totals.mockResolvedValueOnce(t);
  const alert = { report: jest.fn().mockResolvedValue(undefined) };
  const reaper = new BoxReaper(
    box as never,
    {} as never,
    {} as never,
    alert as never,
  );
  const logger = reaper['logger'] as unknown as Record<string, jest.Mock>;
  const error = jest.spyOn(logger as never, 'error').mockImplementation();
  const warn = jest.spyOn(logger as never, 'warn').mockImplementation();
  jest.spyOn(logger as never, 'log').mockImplementation();
  return { reaper, error, warn, alert };
}

describe('BoxReaper ceiling check', () => {
  it('a missing box_totals row logs one ERROR per transition, not per sweep, and skips the monitor', async () => {
    const { reaper, error, warn } = setup([
      null,
      null,
      { msgCount: 0, mediaBytes: 0 },
      null,
    ]);
    for (let i = 0; i < 4; i++) await reaper.sweep();
    const missing = error.mock.calls.filter((c) =>
      String(c[0]).includes('box_totals row missing'),
    );
    expect(missing).toHaveLength(2);
    expect(String(missing[0][0])).toBe(
      '[box] ceiling box_totals row missing (box refusing all stores)',
    );
    expect(warn).not.toHaveBeenCalled();
  });

  it('pings the alarm with one bit per sweep: fail while missing or at 50 %, fine otherwise', async () => {
    const { reaper, alert } = setup([
      { msgCount: 0, mediaBytes: 0 },
      { msgCount: BOX_OPEN_MSG_CEILING / 2, mediaBytes: 0 },
      null,
      { msgCount: 10, mediaBytes: 0 },
    ]);
    for (let i = 0; i < 4; i++) await reaper.sweep();
    expect(alert.report.mock.calls).toEqual([[false], [true], [true], [false]]);
  });
});

/** BE-03: one failing step or file must not stop the rest of the sweep. */
function sweepSetup() {
  const box = {
    deleteExpiredMessages: jest.fn().mockResolvedValue(undefined),
    expiredMedia: jest.fn().mockResolvedValue([]),
    deleteMedia: jest.fn().mockResolvedValue(undefined),
    reapQueues: jest.fn().mockResolvedValue([]),
    totals: jest.fn().mockResolvedValue({ msgCount: 0, mediaBytes: 0 }),
  };
  const store = { remove: jest.fn().mockResolvedValue(undefined) };
  const delivery = { forget: jest.fn() };
  const alert = { report: jest.fn().mockResolvedValue(undefined) };
  const reaper = new BoxReaper(
    box as never,
    store as never,
    delivery as never,
    alert as never,
  );
  const logger = reaper['logger'] as unknown as Record<string, jest.Mock>;
  const logged: string[] = [];
  for (const level of ['error', 'warn', 'log', 'debug']) {
    jest.spyOn(logger as never, level as never).mockImplementation(((
      ...args: unknown[]
    ) => {
      logged.push(args.map(String).join(' '));
    }) as never);
  }
  return { reaper, box, store, delivery, alert, logged };
}

function errno(code: string, path: string): NodeJS.ErrnoException {
  const error: NodeJS.ErrnoException = new Error(
    `${code}: operation failed, unlink '${path}'`,
  );
  error.code = code;
  error.path = path;
  return error;
}

describe('BoxReaper sweep isolation (BE-03)', () => {
  it('one undeletable file keeps its row, and the other file, the queues and the alarm ping still go', async () => {
    const f = sweepSetup();
    f.box.expiredMedia.mockResolvedValue([
      { id: 'm1', path: 'stuck-file.bin' },
      { id: 'm2', path: 'fine-file.bin' },
    ]);
    f.store.remove.mockImplementation((path: string) =>
      path === 'stuck-file.bin'
        ? Promise.reject(errno('EACCES', '/app/media/box/stuck-file.bin'))
        : Promise.resolve(),
    );
    f.box.reapQueues.mockResolvedValue(['rid-1']);

    await f.reaper.sweep();

    expect(f.store.remove.mock.calls).toEqual([
      ['stuck-file.bin'],
      ['fine-file.bin'],
    ]);
    // File first, then row: the row of the file that stayed is kept.
    expect(f.box.deleteMedia.mock.calls).toEqual([[['m2']]]);
    expect(f.box.reapQueues.mock.calls).toHaveLength(1);
    expect(f.delivery.forget.mock.calls).toEqual([['rid-1']]);
    // A sweep that could not finish its work is an alarm, not a silent pass.
    expect(f.alert.report.mock.calls).toEqual([[true]]);
  });

  it('a failing step is logged by step name and errno code only, never a path or an id', async () => {
    const f = sweepSetup();
    f.box.expiredMedia.mockResolvedValue([
      { id: 'm1', path: 'stuck-file.bin' },
    ]);
    f.store.remove.mockRejectedValue(
      errno('EACCES', '/app/media/box/stuck-file.bin'),
    );

    await f.reaper.sweep();

    const all = f.logged.join('\n');
    expect(all).toContain('EACCES');
    expect(all).not.toContain('stuck-file');
    expect(all).not.toContain('m1');
  });

  it.each(['deleteExpiredMessages', 'expiredMedia', 'reapQueues', 'totals'])(
    'a rejecting %s does not stop the later steps or the alarm ping',
    async (step) => {
      const f = sweepSetup();
      f.box[step as keyof typeof f.box].mockRejectedValue(new Error('db down'));

      await f.reaper.sweep();

      for (const [name, fn] of Object.entries(f.box)) {
        if (name === step || name === 'deleteMedia') continue;
        expect([name, fn.mock.calls.length]).toEqual([name, 1]);
      }
      expect(f.alert.report.mock.calls).toEqual([[true]]);
    },
  );

  it('a rejecting alarm ping does not make the sweep reject', async () => {
    const f = sweepSetup();
    f.alert.report.mockRejectedValue(new Error('ping failed'));
    await expect(f.reaper.sweep()).resolves.toBeUndefined();
  });

  it('a sweep that starts while the previous one still runs does nothing; the next one runs again', async () => {
    const f = sweepSetup();
    let release!: () => void;
    f.box.deleteExpiredMessages.mockReturnValueOnce(
      new Promise<void>((resolve) => (release = resolve)),
    );

    const first = f.reaper.sweep();
    await f.reaper.sweep();
    expect(f.box.deleteExpiredMessages.mock.calls).toHaveLength(1);
    expect(f.box.expiredMedia.mock.calls).toHaveLength(0);
    expect(f.alert.report.mock.calls).toHaveLength(0);

    release();
    await first;
    expect(f.alert.report.mock.calls).toEqual([[false]]);

    await f.reaper.sweep();
    expect(f.box.deleteExpiredMessages.mock.calls).toHaveLength(2);
    expect(f.alert.report.mock.calls).toEqual([[false], [false]]);
  });
});

describe('BoxReaper synchronous throws (BE-03 review)', () => {
  it('a throwing delivery.forget or ceiling check still reaches the alarm ping', async () => {
    const f = sweepSetup();
    f.box.reapQueues.mockResolvedValue(['rid-1']);
    f.delivery.forget.mockImplementation(() => {
      throw new Error('boom');
    });
    f.box.totals.mockResolvedValue({ msgCount: 0, mediaBytes: 0 });
    jest.spyOn(f.reaper['ceiling'], 'check').mockImplementation(() => {
      throw new Error('boom');
    });

    await f.reaper.sweep();

    expect(f.alert.report.mock.calls).toEqual([[true]]);
  });
});
