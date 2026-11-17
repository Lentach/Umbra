import { HttpException, HttpStatus, Injectable } from '@nestjs/common';

/** Failures an account takes before its first wait. */
export const BACKOFF_FREE_FAILURES = 5;
/** The first wait; it doubles with every further failure. */
export const BACKOFF_BASE_MS = 15_000;
/** No wait is longer than this, so an attacker can never lock the owner out for longer. */
export const BACKOFF_MAX_MS = 15 * 60_000;
/** A quiet account forgets its failures after this long. */
export const BACKOFF_FORGET_MS = 60 * 60_000;
/** Tracked accounts at most; the oldest entry goes first. Bounds memory under a spray. */
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
 * Per-ACCOUNT login backoff (plan D4). The IP throttle on `/auth/login` stops
 * one address; this slows guessing spread over many. After
 * {@link BACKOFF_FREE_FAILURES} consecutive failures an account waits 15 s,
 * then 30 s, 1 min … up to 15 min before its next attempt is even CHECKED (no
 * hash is computed, so a refused attempt costs the server nothing). A success
 * resets it. A refused attempt is not a failure and does not lengthen the wait:
 * an attacker can hold the owner out for at most 15 min at a time, never longer.
 *
 * In memory: the backend is ONE instance, and a restart forgetting the counters
 * only gives an attacker a fresh set of free tries. The key is chosen by the
 * caller; unknown identifiers use the same counters as real accounts, so the
 * answer never tells them apart.
 */
@Injectable()
export class LoginBackoffService {
  private readonly entries = new Map<string, Entry>();

  /** Throws {@link LoginBackoffException} while `key` is waiting. */
  assertAllowed(key: string, now = Date.now()): void {
    const entry = this.entries.get(key);
    if (!entry) return;
    if (now - entry.lastFailureAt > BACKOFF_FORGET_MS) {
      this.entries.delete(key);
      return;
    }
    if (entry.lockedUntil > now) {
      throw new LoginBackoffException(entry.lockedUntil - now);
    }
  }

  recordFailure(key: string, now = Date.now()): void {
    const failures = (this.entries.get(key)?.failures ?? 0) + 1;
    const over = failures - BACKOFF_FREE_FAILURES;
    const wait =
      over < 0 ? 0 : Math.min(BACKOFF_MAX_MS, BACKOFF_BASE_MS * 2 ** over);
    // Re-insert so Map order stays oldest-failure-first for eviction.
    this.entries.delete(key);
    this.entries.set(key, {
      failures,
      lockedUntil: now + wait,
      lastFailureAt: now,
    });
    if (this.entries.size > BACKOFF_MAX_ENTRIES) {
      for (const oldest of this.entries.keys()) {
        this.entries.delete(oldest);
        break;
      }
    }
  }

  recordSuccess(key: string): void {
    this.entries.delete(key);
  }
}
