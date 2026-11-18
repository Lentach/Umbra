import {
  BACKOFF_BASE_MS,
  BACKOFF_FORGET_MS,
  BACKOFF_FREE_FAILURES,
  BACKOFF_MAX_ENTRIES,
  BACKOFF_MAX_MS,
  LoginBackoffException,
  LoginBackoffService,
  clientBucket,
} from './login-backoff.service';

describe('LoginBackoffService', () => {
  let svc: LoginBackoffService;
  const T0 = 1_000_000;
  const A = '203.0.113.1';
  const B = '203.0.113.2';

  /** Spends n attempts (each is reserved, none succeeds). */
  const spend = (acct: string, ip: string, n: number, at = T0) => {
    for (let i = 0; i < n; i++) svc.reserve(acct, ip, at);
  };
  /** 0 when the next attempt is admitted (and counted), else the wait. */
  const waitMs = (acct: string, ip: string, at = T0): number => {
    try {
      svc.reserve(acct, ip, at);
      return 0;
    } catch (e) {
      return (
        (e as LoginBackoffException).getResponse() as { retryAfterMs: number }
      ).retryAfterMs;
    }
  };

  beforeEach(() => {
    svc = new LoginBackoffService();
  });

  it('admits the free attempts, then waits 15 s, doubling with each further attempt', () => {
    spend('u:1', A, BACKOFF_FREE_FAILURES);
    expect(waitMs('u:1', A)).toBe(BACKOFF_BASE_MS);
    // Wait it out: the next attempt is admitted and the wait doubles.
    expect(waitMs('u:1', A, T0 + BACKOFF_BASE_MS)).toBe(0);
    expect(waitMs('u:1', A, T0 + BACKOFF_BASE_MS)).toBe(2 * BACKOFF_BASE_MS);
  });

  it('never waits longer than the cap', () => {
    for (let i = 0; i < 60; i++) {
      svc.reserve('u:1', A, T0 + i * BACKOFF_MAX_MS);
    }
    expect(waitMs('u:1', A, T0 + 60 * BACKOFF_MAX_MS)).toBe(0);
    expect(waitMs('u:1', A, T0 + 60 * BACKOFF_MAX_MS)).toBe(BACKOFF_MAX_MS);
  });

  it('answers 429 { error: rate_limited, retryAfterMs } and a refused attempt does not lengthen the wait', () => {
    spend('u:1', A, BACKOFF_FREE_FAILURES);
    let err: LoginBackoffException | undefined;
    try {
      svc.reserve('u:1', A, T0 + 1000);
    } catch (e) {
      err = e as LoginBackoffException;
    }
    expect(err?.getStatus()).toBe(429);
    expect(err?.getResponse()).toEqual({
      error: 'rate_limited',
      retryAfterMs: BACKOFF_BASE_MS - 1000,
    });
    expect(waitMs('u:1', A, T0 + BACKOFF_BASE_MS)).toBe(0);
  });

  it("one client's lock leaves the same account open to another client", () => {
    spend('u:1', A, BACKOFF_FREE_FAILURES);
    expect(waitMs('u:1', A)).toBeGreaterThan(0);
    expect(waitMs('u:1', B)).toBe(0);
  });

  it('succeed() resets the pair', () => {
    const key = svc.reserve('u:1', A, T0);
    spend('u:1', A, 3);
    svc.succeed(key);
    spend('u:1', A, BACKOFF_FREE_FAILURES - 1);
    expect(waitMs('u:1', A)).toBe(0);
  });

  it('refund() gives back one reserved attempt, and the lock with it', () => {
    spend('u:1', A, BACKOFF_FREE_FAILURES - 1);
    const key = svc.reserve('u:1', A, T0); // 5th: locks
    svc.refund(key);
    expect(waitMs('u:1', A)).toBe(0);
  });

  it('clearAccount() forgets every client of that account only', () => {
    spend('u:1', A, BACKOFF_FREE_FAILURES);
    spend('u:1', B, BACKOFF_FREE_FAILURES);
    spend('u:10', A, BACKOFF_FREE_FAILURES);
    svc.clearAccount('u:1');
    expect(waitMs('u:1', A)).toBe(0);
    expect(waitMs('u:1', B)).toBe(0);
    expect(waitMs('u:10', A)).toBeGreaterThan(0); // u:1 is not a prefix of u:10's key
  });

  it('forgets a quiet pair after the forget window', () => {
    spend('u:1', A, BACKOFF_FREE_FAILURES);
    expect(waitMs('u:1', A, T0 + BACKOFF_FORGET_MS + 1)).toBe(0);
    // Its count restarted: one more attempt right away is again a first one.
    expect(waitMs('u:1', A, T0 + BACKOFF_FORGET_MS + 1)).toBe(0);
  });

  it('bounds memory: a spray of distinct names evicts the oldest entry', () => {
    spend('u:victim', A, BACKOFF_FREE_FAILURES);
    for (let i = 0; i < BACKOFF_MAX_ENTRIES; i++) svc.reserve(`n:${i}`, A, T0);
    expect(waitMs('u:victim', A)).toBe(0);
  });

  describe('clientBucket', () => {
    it('keeps IPv4, unwraps IPv4-mapped IPv6', () => {
      expect(clientBucket('203.0.113.5')).toBe('203.0.113.5');
      expect(clientBucket('::ffff:203.0.113.5')).toBe('203.0.113.5');
    });
    it('widens IPv6 to its /64, however it is spelled', () => {
      const same = [
        '2001:db8:1:2:aaaa:bbbb:cccc:dddd',
        '2001:0DB8:0001:0002::1',
        '2001:db8:1:2::',
      ].map(clientBucket);
      expect(new Set(same).size).toBe(1);
      expect(clientBucket('2001:db8:1:3::1')).not.toBe(same[0]);
      expect(clientBucket('2001:db8::1')).toBe('2001:db8:0:0::/64');
    });
    it('no address shares one bucket', () => {
      expect(clientBucket(undefined)).toBe('unknown');
      expect(clientBucket('  ')).toBe('unknown');
    });
  });
});
