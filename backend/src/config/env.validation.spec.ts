import 'reflect-metadata';
import { validate } from './env.validation';

/**
 * Phase 4 step 4: the list silence is only safe on a frozen old path. With
 * the old path open, an old-path send still answers `deviceListStale` with
 * the recipient's signed device list and can create a chat no client is told
 * about, so a silent-but-open server would serve by one door the roster it
 * refuses by another. Boot refuses that combination.
 */
describe('validate: LEGACY_LISTS_SILENT needs LEGACY_WRITES_FROZEN', () => {
  const base = { JWT_SECRET: 'x'.repeat(32) };

  it('refuses silent lists on an open old path', () => {
    expect(() => validate({ ...base, LEGACY_LISTS_SILENT: 'true' })).toThrow(
      /LEGACY_LISTS_SILENT/,
    );
    expect(() =>
      validate({
        ...base,
        LEGACY_LISTS_SILENT: 'true',
        LEGACY_WRITES_FROZEN: 'false',
      }),
    ).toThrow(/LEGACY_LISTS_SILENT/);
  });

  it('boots silent lists on a frozen old path', () => {
    expect(
      validate({
        ...base,
        LEGACY_LISTS_SILENT: 'true',
        LEGACY_WRITES_FROZEN: 'true',
      }).LEGACY_LISTS_SILENT,
    ).toBe('true');
  });

  it('boots served lists either way', () => {
    expect(() =>
      validate({ ...base, LEGACY_LISTS_SILENT: 'false' }),
    ).not.toThrow();
    expect(() =>
      validate({ ...base, LEGACY_WRITES_FROZEN: 'true' }),
    ).not.toThrow();
  });
});
