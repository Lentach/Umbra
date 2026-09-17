#!/usr/bin/env node
/**
 * Keeps the CSP `script-src` hashes in infra/nginx/security-headers.conf in sync
 * with the inline <script> blocks in frontend/web/index.html.
 *
 * WHY THIS EXISTS: those two blocks must run before first paint (theme-flash
 * killer + the passcode privacy curtain), so they cannot become `defer`red
 * files without a curtain re-verification. Until they do, the prod CSP names
 * them by sha256. Edit index.html, and the hash is stale — harmless while the
 * policy is Report-Only (a phantom violation report), FATAL the moment it is
 * enforced (no theme sync, no privacy curtain at boot).
 *
 * Usage:
 *   node scripts/verify-csp-inline-hashes.mjs          # verify, exit 1 on drift
 *   node scripts/verify-csp-inline-hashes.mjs --print  # print the current tokens
 */
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const indexPath = join(root, 'frontend/web/index.html');
const confPath = join(root, 'infra/nginx/security-headers.conf');

// Inline only: a block WITH src= is an external file and needs no hash.
const INLINE_SCRIPT = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g;

const html = readFileSync(indexPath, 'utf8');
const tokens = [...html.matchAll(INLINE_SCRIPT)].map(
  (m) => `'sha256-${createHash('sha256').update(m[1], 'utf8').digest('base64')}'`,
);

if (process.argv.includes('--print')) {
  console.log(tokens.join(' '));
  process.exit(0);
}

if (tokens.length === 0) {
  console.error(
    `BLOCKED: no inline <script> found in frontend/web/index.html. If the boot ` +
      `scripts moved to an external file, drop the sha256 tokens from ` +
      `infra/nginx/security-headers.conf (script-src 'self' 'wasm-unsafe-eval') ` +
      `and delete this check.`,
  );
  process.exit(1);
}

const conf = readFileSync(confPath, 'utf8');
const missing = tokens.filter((t) => !conf.includes(t));
const stale = [...conf.matchAll(/'sha256-[A-Za-z0-9+/=]+'/g)]
  .map((m) => m[0])
  .filter((t) => !tokens.includes(t));

if (missing.length || stale.length) {
  console.error('BLOCKED by scripts/verify-csp-inline-hashes.mjs:');
  if (missing.length)
    console.error(`  - index.html inline script(s) not named by the CSP: ${missing.join(' ')}`);
  if (stale.length)
    console.error(`  - CSP names hash(es) no inline script produces: ${stale.join(' ')}`);
  console.error(
    `  Fix: set script-src's sha256 tokens in infra/nginx/security-headers.conf to exactly:\n` +
      `    ${tokens.join(' ')}\n` +
      `  then re-apply the snippet on the VM (see .omp/rules/production-vm-deploy.md).`,
  );
  process.exit(1);
}

console.log(`OK: CSP names all ${tokens.length} inline index.html script(s)`);
