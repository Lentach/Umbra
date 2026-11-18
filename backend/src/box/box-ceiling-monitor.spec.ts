import { BoxCeilingMonitor } from './box-ceiling-monitor';
import {
  BOX_OPEN_MEDIA_CEILING_BYTES as MEDIA,
  BOX_OPEN_MSG_CEILING as MSGS,
} from './box.constants';

function setup() {
  const lines: { level: string; text: string }[] = [];
  const logger = {
    log: (text: string) => lines.push({ level: 'log', text }),
    warn: (text: string) => lines.push({ level: 'warn', text }),
    error: (text: string) => lines.push({ level: 'error', text }),
  };
  const monitor = new BoxCeilingMonitor();
  const check = (msgCount: number, mediaBytes = 0) =>
    monitor.check({ msgCount, mediaBytes }, logger);
  return { lines, check };
}

describe('BoxCeilingMonitor', () => {
  it('stays silent below 50 % of the open band', () => {
    const { lines, check } = setup();
    check(0, 0);
    check(MSGS * 0.5 - 1, MEDIA * 0.5 - 1);
    expect(lines).toEqual([]);
  });

  it('warns once on crossing 50 % and not again while above', () => {
    const { lines, check } = setup();
    check(MSGS * 0.5);
    check(MSGS * 0.6);
    check(MSGS * 0.79);
    expect(lines.map((l) => l.level)).toEqual(['warn']);
    expect(lines[0].text).toContain('msgCount=');
  });

  it('errors once on crossing 80 %', () => {
    const { lines, check } = setup();
    check(MSGS * 0.5);
    check(MSGS * 0.8);
    check(MSGS * 0.95);
    expect(lines.map((l) => l.level)).toEqual(['warn', 'error']);
  });

  it('jumping straight past 80 % errors without a warn', () => {
    const { lines, check } = setup();
    check(MSGS * 0.9);
    expect(lines.map((l) => l.level)).toEqual(['error']);
  });

  it('logs recovery once, then re-warns on a new crossing', () => {
    const { lines, check } = setup();
    check(MSGS * 0.6);
    check(MSGS * 0.1);
    check(MSGS * 0.1);
    expect(lines.map((l) => l.level)).toEqual(['warn', 'log']);
    expect(lines[1].text).toContain('warn->ok');
    check(MSGS * 0.6);
    expect(lines.map((l) => l.level)).toEqual(['warn', 'log', 'warn']);
  });

  it('error falling back under 80 % is a recovery line, not a new warn', () => {
    const { lines, check } = setup();
    check(MSGS * 0.9);
    check(MSGS * 0.6);
    expect(lines.map((l) => l.level)).toEqual(['error', 'log']);
    expect(lines[1].text).toContain('error->warn');
  });

  it('mediaBytes alone triggers, tracked independently of msgCount', () => {
    const { lines, check } = setup();
    check(0, MEDIA * 0.5);
    expect(lines).toHaveLength(1);
    expect(lines[0].level).toBe('warn');
    expect(lines[0].text).toContain('mediaBytes=');
    check(MSGS * 0.5, MEDIA * 0.5);
    expect(lines.map((l) => l.level)).toEqual(['warn', 'warn']);
    expect(lines[1].text).toContain('msgCount=');
  });

  it('thresholds follow the constants and lines carry no ids', () => {
    const { lines, check } = setup();
    check(MSGS * 0.5);
    expect(lines[0].text).toBe(
      `[box] ceiling msgCount=${MSGS * 0.5} openBand=${MSGS} (50%) ok->warn`,
    );
  });
});
