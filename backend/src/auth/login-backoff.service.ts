import { HttpException, HttpStatus, Injectable } from '@nestjs/common';

/** Failures a (account, client) pair takes before its first wait. */
export const BACKOFF_FREE_FAILURES = 5;
/** The first wait; it doubles with every further failure. */
export const BACKOFF_BASE_MS = 15_000;
/** No wait is longer than this. */
export const BACKOFF_MAX_MS = 15 * 60_000;
/** A quiet pair forgets its failures after this long. */
export const BACKOFF_FORGET_MS = 60 * 60_000;
/** Tracked pairs at most; the oldest entry goes first. Bounds memory under a spray. */
export const BACKOFF_MAX_ENTRIES = 20_000;

interface Entry {
  failures: number;
  lockedUntil: number;
  lastFailureAt: number;
}

/** `429 { error: 'rate_limited', retryAfterMs }`, the answer every other throttle gives. */
export class LoginBackoffException extends HttpException {
  constructor(retryAfterMs: number) {
    super(
      { error: 'rate_limited', retryAfterMs },
      HttpStatus.TOO_MANY_REQUESTS,
    );
  }
}

/**
 * The part of a client address that identifies one client for backoff: an IPv4
 * address as is (an IPv4-mapped IPv6 one unwrapped), an IPv6 address as its
 * /64 (one subscriber owns a whole /64, so per-address keys would be free to
 * rotate). No address at all shares one `unknown` bucket.
 */
export function clientBucket(ip: string | undefined): string {
  const addr = (ip ?? '').trim().toLowerCase();
  if (!addr) return 'unknown';
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(addr);
  if (mapped) return mapped[1];
  if (!addr.includes(':')) return addr;
  const [head, tail = ''] = addr.split('::');
  const headGroups = head ? head.split(':') : [];
  const tailGroups = addr.includes('::') && tail ? tail.split(':') : [];
  const missing = 8 - headGroups.length - tailGroups.length;
  const groups = addr.includes('::')
    ? [
        ...headGroups,
        ...Array<string>(Math.max(missing, 0)).fill('0'),
        ...tailGroups,
      ]
    : headGroups;
  return `${groups
    .slice(0, 4)
    .map((g) => (g || '0').replace(/^0+(?=.)/, ''))
    .join(':')}::/64`;
}

/**
 * Login backoff (plan D4), keyed on (ACCOUNT, CLIENT), never on the account
 * alone. A per-account lock would let anyone who knows a name keep its owner out
 * with 5 requests per 15 min; keyed on the pair, an attacker's lock stops only
 * the attacker, and the owner on another address logs in untouched. No
 * account→address memory is kept beyond these counters (they expire after
 * {@link BACKOFF_FORGET_MS}, and a success erases the pair), as the privacy
 * decisions want.
 *
 * After {@link BACKOFF_FREE_FAILURES} failures the pair waits 15 s, 30 s, 1 min
 * … up to 15 min before the next attempt is even CHECKED (no hash runs). Residual:
 * guessing spread over many addresses gets about 5 tries per address per hour
 * per account (each address then waits up to 15 min), on top of the per-IP
 * throttle; a global per-account cap would close that and reopen the lockout.
 *
 * In memory: the backend is ONE instance, and a restart only hands an attacker
 * a fresh set of free tries. Unknown identifiers use the same counters as real
 * accounts, so the answer never tells them apart.
 */
@Injectable()
export class LoginBackoffService {
  private readonly entries = new Map<string, Entry>();

  /**
   * Admits one attempt or throws {@link LoginBackoffException}. The attempt is
   * counted as a failure RIGHT HERE, in the same synchronous step as the check,
   * so parallel requests cannot all pass before the first one's verdict. Call
   * {@link succeed} when the password was right, {@link refund} when the attempt
   * failed for a reason that is not the caller's fault. Returns the key to pass.
   */
  reserve(account: string, ip: string | undefined, now = Date.now()): string {
    const key = `${account}|${clientBucket(ip)}`;
    const entry = this.entries.get(key);
    if (entry && now - entry.lastFailureAt > BACKOFF_FORGET_MS) {
      this.entries.delete(key);
    } else if (entry && entry.lockedUntil > now) {
      throw new LoginBackoffException(entry.lockedUntil - now);
    }
    this.count(key, now);
    return key;
  }

  /** The password was right: the pair starts clean. */
  succeed(key: string): void {
    this.entries.delete(key);
  }

  /** Takes back one reserved attempt (the server, not the caller, failed). */
  refund(key: string): void {
    const entry = this.entries.get(key);
    if (!entry) return;
    if (entry.failures <= 1) {
      this.entries.delete(key);
      return;
    }
    entry.failures -= 1;
    entry.lockedUntil = entry.lastFailureAt + waitFor(entry.failures);
  }

  /** The owner proved themselves another way (a recovery phrase): forget every client's count. */
  clearAccount(account: string): void {
    const prefix = `${account}|`;
    for (const key of [...this.entries.keys()]) {
      if (key.startsWith(prefix)) this.entries.delete(key);
    }
  }

  private count(key: string, now: number): void {
    const failures = (this.entries.get(key)?.failures ?? 0) + 1;
    // Re-insert so Map order stays oldest-failure-first for eviction.
    this.entries.delete(key);
    this.entries.set(key, {
      failures,
      lockedUntil: now + waitFor(failures),
      lastFailureAt: now,
    });
    if (this.entries.size > BACKOFF_MAX_ENTRIES) {
      for (const oldest of this.entries.keys()) {
        this.entries.delete(oldest);
        break;
      }
    }
  }
}

function waitFor(failures: number): number {
  const over = failures - BACKOFF_FREE_FAILURES;
  return over < 0 ? 0 : Math.min(BACKOFF_MAX_MS, BACKOFF_BASE_MS * 2 ** over);
}
