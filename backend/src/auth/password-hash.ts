import * as argon2 from 'argon2';
import * as bcrypt from 'bcrypt';
import { HttpException, HttpStatus } from '@nestjs/common';

/**
 * Account-password hashing (plan D4). New hashes are Argon2id; bcrypt hashes
 * written before 0.2.89 still verify and are replaced on the next successful
 * login (`needsRehash`).
 *
 * Parameters: the OWASP Password Storage Cheat Sheet's first Argon2id profile
 * (m = 19 MiB, t = 2, p = 1), the same as the recovery-phrase verifier
 * (`RECOVERY_ARGON2_OPTIONS`). One verify costs ~20 ms of CPU and 19 MiB of RAM.
 * Raising them later stays compatible: the PHC string carries its own
 * parameters, and `needsRehash` upgrades old ones at the next login.
 */
export const PASSWORD_ARGON2_OPTIONS = {
  type: argon2.argon2id,
  memoryCost: 19456,
  timeCost: 2,
  parallelism: 1,
} as const satisfies argon2.HashOptions & { raw?: false };

/**
 * At most this many password Argon2 operations run at once, so their memory
 * stays below 2 × 19 MiB on the 2 GB VM whatever the request rate. The rest
 * wait in a queue that holds only closures. Two also leaves libuv's other two
 * default threads free for fs and DNS work.
 */
export const MAX_CONCURRENT_PASSWORD_HASHES = 2;

/**
 * Operations allowed to WAIT for a slot. Past it a call is refused at once with
 * `503 { error: 'busy' }`: the queue (and every pending HTTP request behind it)
 * stays bounded however fast requests arrive.
 */
export const MAX_WAITING_PASSWORD_HASHES = 64;

/**
 * An Argon2id hash of a random string nobody knows, made with
 * {@link PASSWORD_ARGON2_OPTIONS}. Login verifies against it when the identifier
 * matches no account, so "no such user" takes as long as a wrong password.
 */
export const TIMING_SAFE_DUMMY_PASSWORD_HASH =
  '$argon2id$v=19$m=19456,p=1,t=2$x+K1b1eocxuO+JqNo0bHxQ$7nrlxmy4ggFrlZEREqflSpu+rF8h9wDBKLyuiAsxCGc';

let running = 0;
const waiting: Array<() => void> = [];

async function limited<T>(op: () => Promise<T>): Promise<T> {
  if (running >= MAX_CONCURRENT_PASSWORD_HASHES) {
    if (waiting.length >= MAX_WAITING_PASSWORD_HASHES) {
      throw new HttpException(
        { error: 'busy' },
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }
    // Executor form: the backend's tsconfig lib (ES2023) has no Promise.withResolvers.
    await new Promise<void>((resolve) => waiting.push(resolve));
  } else {
    running++;
  }
  try {
    return await op();
  } finally {
    // Hand the slot straight to the next waiter; `running` stays the same.
    const next = waiting.shift();
    if (next) next();
    else running--;
  }
}

export function hashPassword(plain: string): Promise<string> {
  return limited(() => argon2.hash(plain, PASSWORD_ARGON2_OPTIONS));
}

export interface PasswordVerdict {
  valid: boolean;
  /** Valid, but stored as bcrypt or with old Argon2 parameters: store a new hash. */
  needsRehash: boolean;
}

/**
 * Checks `plain` against a stored hash in either format: bcrypt (`$2a$`, `$2b$`,
 * `$2y$`) or Argon2id. Anything else, including a malformed hash, is a wrong
 * password and never an error.
 */
export async function verifyPassword(
  plain: string,
  stored: string,
): Promise<PasswordVerdict> {
  if (stored.startsWith('$2')) {
    const valid = await bcrypt.compare(plain, stored).catch(() => false);
    return { valid, needsRehash: valid };
  }
  if (stored.startsWith('$argon2id$')) {
    // The catch sits INSIDE the gate: a malformed hash is a wrong password,
    // but a `busy` refusal must reach the caller.
    const valid = await limited(() =>
      argon2.verify(stored, plain).catch(() => false),
    );
    return {
      valid,
      needsRehash: valid && argon2.needsRehash(stored, PASSWORD_ARGON2_OPTIONS),
    };
  }
  return { valid: false, needsRehash: false };
}

/** A cost-10 bcrypt hash of a random string nobody knows. */
export const TIMING_SAFE_DUMMY_BCRYPT_HASH =
  '$2b$10$pwiFDkB3zcAu0PKQqI13b.fGqVMlVlB8aCB22BL/qyvTghAEiP2N2';

export type PasswordFormat = 'bcrypt' | 'argon2id';

/**
 * The cost of failing, for the formats a real verify did NOT pay. A bcrypt row
 * answers a wrong password in ~43 ms and an Argon2id row in ~16 ms; an unknown
 * name must not sit in either gap. So every failed login ends up paying BOTH
 * formats: the real verify covers one, this covers the other(s), and an unknown
 * name passes both.
 */
export async function verifyDummyPasswords(
  plain: string,
  formats: readonly PasswordFormat[],
): Promise<void> {
  for (const format of formats) {
    await verifyPassword(
      plain,
      format === 'bcrypt'
        ? TIMING_SAFE_DUMMY_BCRYPT_HASH
        : TIMING_SAFE_DUMMY_PASSWORD_HASH,
    );
  }
}

/** The format a stored hash is verified under. */
export function passwordFormatOf(stored: string): PasswordFormat {
  return stored.startsWith('$2') ? 'bcrypt' : 'argon2id';
}
