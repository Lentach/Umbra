#!/usr/bin/env node
/**
 * Invariant I1 of the metadata-privacy design: no account credential on the
 * message path. Nothing under `backend/src/box/` may reach `auth/`, `users/`
 * or `chat/` — not directly and not through anything it imports.
 *
 * TRANSITIVE on purpose: the obvious leak is one hop away. `box/` importing
 * `push-notifications/` looks harmless, but that module resolves tokens
 * through `fcm-tokens/`, whose entity imports `users/user.entity`. A direct-
 * imports grep passes that; this walk fails it and prints the chain.
 *
 * Follows every relative specifier (`import … from`, `export … from`,
 * `import type`, `import()`, `require()`); package imports are outside the
 * tree and not followed.
 *
 * Usage:  node scripts/verify-box-imports.mjs [--self-test]
 */
import { existsSync, readdirSync, readFileSync, statSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join, relative, resolve, sep } from 'path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const srcRoot = join(root, 'backend', 'src');
const FORBIDDEN = ['auth', 'users', 'chat'];

const SPECIFIER =
  /(?:\bfrom\s*|\bimport\s*\(\s*|\brequire\s*\(\s*|\bimport\s+)['"]([^'"]+)['"]/g;

/** Relative specifiers of one source file. */
function relativeImports(source) {
  const found = [];
  for (const match of source.matchAll(SPECIFIER)) {
    if (match[1].startsWith('.')) found.push(match[1]);
  }
  return found;
}

/** The .ts file a relative specifier names, or null (json, missing). */
function resolveTs(fromFile, specifier, exists) {
  const base = resolve(dirname(fromFile), specifier);
  for (const candidate of [`${base}.ts`, join(base, 'index.ts'), base]) {
    if (candidate.endsWith('.ts') && exists(candidate)) return candidate;
  }
  return null;
}

/**
 * Every chain from an entry file to a file under a forbidden top-level
 * directory of `src`. Breadth-first, so each reported chain is a shortest one.
 */
function forbiddenChains({ entries, src, read, exists }) {
  const parent = new Map(entries.map((file) => [file, null]));
  const queue = [...entries];
  const chains = [];
  while (queue.length > 0) {
    const file = queue.shift();
    const top = relative(src, file).split(sep)[0];
    if (FORBIDDEN.includes(top)) {
      const chain = [];
      for (let at = file; at !== null; at = parent.get(at)) {
        chain.unshift(relative(src, at).split(sep).join('/'));
      }
      chains.push(chain);
      continue;
    }
    for (const specifier of relativeImports(read(file))) {
      const target = resolveTs(file, specifier, exists);
      if (target && !parent.has(target)) {
        parent.set(target, file);
        queue.push(target);
      }
    }
  }
  return chains;
}

function listTs(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...listTs(full));
    else if (name.endsWith('.ts')) out.push(full);
  }
  return out;
}

function selfTest() {
  const src = resolve('/virtual/src');
  const files = {
    [join(src, 'box', 'a.ts')]: "import { x } from '../common/x';\n",
    [join(src, 'box', 'b.ts')]: "import type { C } from './c';\n",
    [join(src, 'box', 'c.ts')]: "export { P } from '../push/p';\n",
    [join(src, 'push', 'p.ts')]: "import { U } from '../users/user.entity';\n",
    [join(src, 'users', 'user.entity.ts')]: 'export class U {}\n',
    [join(src, 'common', 'x.ts')]: "import { json } from 'express';\n",
  };
  const chains = forbiddenChains({
    entries: [join(src, 'box', 'a.ts'), join(src, 'box', 'b.ts')],
    src,
    read: (f) => files[f],
    exists: (f) => f in files,
  });
  const expected = [['box/b.ts', 'box/c.ts', 'push/p.ts', 'users/user.entity.ts']];
  if (JSON.stringify(chains) !== JSON.stringify(expected)) {
    console.error(`self-test FAILED: ${JSON.stringify(chains)}`);
    process.exit(1);
  }
  console.log('self-test OK: a transitive users/ import is caught, common/ passes');
}

if (process.argv.includes('--self-test')) {
  selfTest();
} else {
  const boxRoot = join(srcRoot, 'box');
  if (!existsSync(boxRoot)) {
    console.error(`missing ${boxRoot}`);
    process.exit(1);
  }
  const chains = forbiddenChains({
    entries: listTs(boxRoot),
    src: srcRoot,
    read: (f) => readFileSync(f, 'utf8'),
    exists: existsSync,
  });
  if (chains.length > 0) {
    console.error(
      `I1 violated: box/ reaches ${FORBIDDEN.join('/, ')}/ (design §3):`,
    );
    for (const chain of chains) console.error(`  ${chain.join(' -> ')}`);
    process.exit(1);
  }
  console.log('OK: backend/src/box imports nothing from auth/, users/ or chat/');
}
