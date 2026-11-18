import { BoxReaper } from './box-reaper.service';

function setup(totals: Array<{ msgCount: number; mediaBytes: number } | null>) {
  const box = {
    deleteExpiredMessages: jest.fn().mockResolvedValue(undefined),
    expiredMedia: jest.fn().mockResolvedValue([]),
    deleteMedia: jest.fn(),
    reapQueues: jest.fn().mockResolvedValue([]),
    totals: jest.fn(),
  };
  for (const t of totals) box.totals.mockResolvedValueOnce(t);
  const reaper = new BoxReaper(box as never, {} as never, {} as never);
  const logger = reaper['logger'] as unknown as Record<string, jest.Mock>;
  const error = jest.spyOn(logger as never, 'error').mockImplementation();
  const warn = jest.spyOn(logger as never, 'warn').mockImplementation();
  jest.spyOn(logger as never, 'log').mockImplementation();
  return { reaper, error, warn };
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
});
