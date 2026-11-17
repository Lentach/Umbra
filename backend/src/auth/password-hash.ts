import * as argon2 from 'argon2';
import * as bcrypt from 'bcrypt';

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
    const valid = await limited(() => argon2.verify(stored, plain)).catch(
      () => false,
    );
    return {
      valid,
      needsRehash: valid && argon2.needsRehash(stored, PASSWORD_ARGON2_OPTIONS),
    };
  }
  return { valid: false, needsRehash: false };
}

/** The timing twin of a real verify, for an identifier that matches nobody. */
export async function verifyDummyPassword(plain: string): Promise<void> {
  await verifyPassword(plain, TIMING_SAFE_DUMMY_PASSWORD_HASH);
}
