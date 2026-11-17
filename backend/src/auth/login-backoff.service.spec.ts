import {
  BACKOFF_BASE_MS,
  BACKOFF_FORGET_MS,
  BACKOFF_FREE_FAILURES,
  BACKOFF_MAX_ENTRIES,
  BACKOFF_MAX_MS,
  LoginBackoffException,
  LoginBackoffService,
} from './login-backoff.service';

describe('LoginBackoffService', () => {
  let svc: LoginBackoffService;
  const T0 = 1_000_000;
  const failTimes = (key: string, n: number, at = T0) => {
    for (let i = 0; i < n; i++) svc.recordFailure(key, at);
  };
  const waitMs = (key: string, at = T0): number => {
    try {
      svc.assertAllowed(key, at);
      return 0;
    } catch (e) {
      return (e as LoginBackoffException).getResponse()['retryAfterMs'];
    }
  };

  beforeEach(() => {
    svc = new LoginBackoffService();
  });

  it('allows the free failures, then waits 15 s, doubling each failure', () => {
    failTimes('a', BACKOFF_FREE_FAILURES - 1);
    expect(waitMs('a')).toBe(0);
    failTimes('a', 1);
    expect(waitMs('a')).toBe(BACKOFF_BASE_MS);
    // Wait it out, fail again: the next wait doubles.
    svc.recordFailure('a', T0 + BACKOFF_BASE_MS);
    expect(waitMs('a', T0 + BACKOFF_BASE_MS)).toBe(2 * BACKOFF_BASE_MS);
  });

  it('never waits longer than the cap', () => {
    failTimes('a', 60);
    expect(waitMs('a')).toBe(BACKOFF_MAX_MS);
  });

  it('answers 429 { error: rate_limited, retryAfterMs } and a refused attempt does not lengthen the wait', () => {
    failTimes('a', BACKOFF_FREE_FAILURES);
    let err: LoginBackoffException | undefined;
    try {
      svc.assertAllowed('a', T0 + 1000);
    } catch (e) {
      err = e as LoginBackoffException;
    }
    expect(err?.getStatus()).toBe(429);
    expect(err?.getResponse()).toEqual({
      error: 'rate_limited',
      retryAfterMs: BACKOFF_BASE_MS - 1000,
    });
    // assertAllowed records nothing: the lock still ends on schedule.
    expect(waitMs('a', T0 + BACKOFF_BASE_MS)).toBe(0);
  });

  it('a success resets the account to a clean slate', () => {
    failTimes('a', 10);
    svc.recordSuccess('a');
    expect(waitMs('a')).toBe(0);
    failTimes('a', BACKOFF_FREE_FAILURES - 1);
    expect(waitMs('a')).toBe(0);
  });

  it('keeps accounts apart', () => {
    failTimes('a', 10);
    expect(waitMs('b')).toBe(0);
  });

  it('forgets a quiet account after the forget window', () => {
    failTimes('a', 10);
    expect(waitMs('a', T0 + BACKOFF_FORGET_MS + 1)).toBe(0);
    // And its count restarts: one more failure is within the free tries.
    svc.recordFailure('a', T0 + BACKOFF_FORGET_MS + 1);
    expect(waitMs('a', T0 + BACKOFF_FORGET_MS + 1)).toBe(0);
  });

  it('bounds memory: a spray of distinct names evicts the oldest entry', () => {
    failTimes('victim', 10);
    for (let i = 0; i < BACKOFF_MAX_ENTRIES; i++)
      svc.recordFailure(`n${i}`, T0);
    expect(waitMs('victim')).toBe(0);
    expect(waitMs(`n${BACKOFF_MAX_ENTRIES - 1}`)).toBe(0);
  });
});
