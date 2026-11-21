import { parsePurgeArgs } from './box-purge.cli';

const NOW = new Date('2026-11-21T12:00:00Z');

describe('parsePurgeArgs', () => {
  it('is a dry run unless --execute is given', () => {
    expect(parsePurgeArgs([], NOW)).toEqual({
      minMsgs: 32,
      olderThan: new Date('2026-11-18T12:00:00Z'),
      maxQueues: 500,
      dryRun: true,
    });
    expect(
      parsePurgeArgs(
        [
          '--min-msgs',
          '100',
          '--min-age-hours',
          '6',
          '--max-queues',
          '9',
          '--execute',
        ],
        NOW,
      ),
    ).toEqual({
      minMsgs: 100,
      olderThan: new Date('2026-11-21T06:00:00Z'),
      maxQueues: 9,
      dryRun: false,
    });
  });

  it('refuses a typo or a bad number instead of purging with a default', () => {
    expect(() => parsePurgeArgs(['--exeucte'], NOW)).toThrow(
      'unknown argument',
    );
    expect(() => parsePurgeArgs(['--min-msgs', '0'], NOW)).toThrow(
      'whole number',
    );
    expect(() => parsePurgeArgs(['--min-msgs'], NOW)).toThrow('whole number');
    expect(() => parsePurgeArgs(['--max-queues', '2.5'], NOW)).toThrow(
      'whole number',
    );
  });
});
