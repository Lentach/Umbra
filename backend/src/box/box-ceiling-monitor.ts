import {
  BOX_OPEN_MEDIA_CEILING_BYTES,
  BOX_OPEN_MSG_CEILING,
} from './box.constants';

/** Fractions of the OPEN band (#204): WARN from the first, ERROR from the second. */
export const BOX_CEILING_WARN_FRACTION = 0.5;
export const BOX_CEILING_ERROR_FRACTION = 0.8;

export interface BoxTotals {
  msgCount: number;
  mediaBytes: number;
}

export interface CeilingLogger {
  log(message: string): void;
  warn(message: string): void;
  error(message: string): void;
}

type Level = 0 | 1 | 2;
const LEVEL_NAME = ['ok', 'warn', 'error'] as const;

const METRICS: ReadonlyArray<{ key: keyof BoxTotals; band: number }> = [
  { key: 'msgCount', band: BOX_OPEN_MSG_CEILING },
  { key: 'mediaBytes', band: BOX_OPEN_MEDIA_CEILING_BYTES },
];

/**
 * Early warning before the box's global ceiling (#204). Fed `box_totals` by
 * the reaper sweep, never on the request path. Logs only when a metric's
 * level CHANGES (per process), so a box sitting above a threshold logs once,
 * and once more when it recovers. Lines carry totals only — never an id.
 * The numbers are traffic metadata: log only, never on any route.
 */
export class BoxCeilingMonitor {
  private readonly levels = new Map<keyof BoxTotals, Level>();

  check(totals: BoxTotals, logger: CeilingLogger): void {
    for (const { key, band } of METRICS) {
      const value = totals[key];
      const level: Level =
        value >= band * BOX_CEILING_ERROR_FRACTION
          ? 2
          : value >= band * BOX_CEILING_WARN_FRACTION
            ? 1
            : 0;
      const previous = this.levels.get(key) ?? 0;
      if (level === previous) continue;
      this.levels.set(key, level);
      const pct = Math.round((value / band) * 100);
      const line =
        `[box] ceiling ${key}=${value} openBand=${band} (${pct}%) ` +
        `${LEVEL_NAME[previous]}->${LEVEL_NAME[level]}`;
      if (level === 2) logger.error(line);
      else if (level === 1 && previous === 0) logger.warn(line);
      else logger.log(line); // recovery: error->warn or ->ok
    }
  }
}
