import * as argon2 from 'argon2';

// Wrapped so the concurrency test can watch calls; real behaviour otherwise.
jest.mock('argon2', () => {
  const actual = jest.requireActual('argon2');
  return { ...actual, verify: jest.fn(actual.verify) };
});
import * as bcrypt from 'bcrypt';
import {
  MAX_CONCURRENT_PASSWORD_HASHES,
  PASSWORD_ARGON2_OPTIONS,
  TIMING_SAFE_DUMMY_PASSWORD_HASH,
  hashPassword,
  verifyDummyPassword,
  verifyPassword,
} from './password-hash';

describe('password-hash', () => {
  it('hashes as Argon2id with the pinned OWASP parameters (m=19 MiB, t=2, p=1)', async () => {
    expect(PASSWORD_ARGON2_OPTIONS).toMatchObject({
      memoryCost: 19456,
      timeCost: 2,
      parallelism: 1,
    });
    const hash = await hashPassword('CorrectHorse1');
    expect(hash).toMatch(/^\$argon2id\$v=19\$m=19456,p=1,t=2\$/);
    // Salted: the same password never hashes the same twice.
    expect(await hashPassword('CorrectHorse1')).not.toBe(hash);
  });

  it('verifies a fresh Argon2id hash and needs no rehash', async () => {
    const hash = await hashPassword('CorrectHorse1');
    await expect(verifyPassword('CorrectHorse1', hash)).resolves.toEqual({
      valid: true,
      needsRehash: false,
    });
    await expect(verifyPassword('wrong', hash)).resolves.toEqual({
      valid: false,
      needsRehash: false,
    });
  });

  it('verifies a legacy bcrypt hash (cost 10) and asks for a rehash only when valid', async () => {
    const legacy = await bcrypt.hash('CorrectHorse1', 10);
    expect(legacy).toMatch(/^\$2[aby]\$10\$/);
    await expect(verifyPassword('CorrectHorse1', legacy)).resolves.toEqual({
      valid: true,
      needsRehash: true,
    });
    await expect(verifyPassword('wrong', legacy)).resolves.toEqual({
      valid: false,
      needsRehash: false,
    });
  });

  it('asks for a rehash when an Argon2id hash was made with weaker parameters', async () => {
    const weak = await argon2.hash('CorrectHorse1', {
      type: argon2.argon2id,
      memoryCost: 8192,
      timeCost: 1,
      parallelism: 1,
    });
    await expect(verifyPassword('CorrectHorse1', weak)).resolves.toEqual({
      valid: true,
      needsRehash: true,
    });
  });

  it('treats an unknown or malformed stored value as a wrong password, never an error', async () => {
    for (const stored of [
      '',
      'plaintext',
      '$argon2id$garbage',
      '$2b$10$short',
    ]) {
      await expect(verifyPassword('x', stored)).resolves.toEqual({
        valid: false,
        needsRehash: false,
      });
    }
  });

  it('the dummy hash is a real Argon2id hash under the current parameters (same cost as a real verify)', async () => {
    expect(TIMING_SAFE_DUMMY_PASSWORD_HASH).toMatch(
      /^\$argon2id\$v=19\$m=19456,p=1,t=2\$/,
    );
    expect(
      argon2.needsRehash(
        TIMING_SAFE_DUMMY_PASSWORD_HASH,
        PASSWORD_ARGON2_OPTIONS,
      ),
    ).toBe(false);
    await expect(verifyDummyPassword('anything')).resolves.toBeUndefined();
  });

  it('runs at most MAX_CONCURRENT_PASSWORD_HASHES Argon2 operations at once, and finishes them all', async () => {
    const hash = await hashPassword('CorrectHorse1');
    let inFlight = 0;
    let peak = 0;
    const verifyMock = argon2.verify as jest.Mock;
    const realVerify = jest.requireActual('argon2').verify;
    verifyMock.mockImplementation(async (h: string, p: string) => {
      inFlight++;
      peak = Math.max(peak, inFlight);
      await new Promise((r) => setTimeout(r, 15));
      inFlight--;
      return realVerify(h, p);
    });
    try {
      const verdicts = await Promise.all(
        Array.from({ length: 8 }, () => verifyPassword('CorrectHorse1', hash)),
      );
      expect(verdicts.every((v) => v.valid)).toBe(true);
      expect(peak).toBe(MAX_CONCURRENT_PASSWORD_HASHES);
    } finally {
      verifyMock.mockImplementation(realVerify);
    }
  });
});
