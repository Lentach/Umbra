#!/usr/bin/env node
/**
 * Fails when backend source can log an account identifier.
 *
 * Metadata privacy step 0 (2026-09-20): container stdout is the one server
 * record that survives the transient-queue cutover, so a log line carrying
 * `userId=`, `username=` or `identifier=` is a per-account activity trail
 * (who logged in, who provisioned, who was refused, when). Event names and
 * outcomes stay; the identifier goes.
 *
 * The rule is on the STRING, not the logger call: a line-based regex over
 * `this.logger.warn(` saw 8 of the first 23 sites (the literal usually sits
 * on its own line), and two more built the line in a variable first
 * (`ws-throttler.guard.ts`, `chat-message.service.ts`). Every `'…'`, `"…"`
 * and `` `…` `` literal in a non-spec file is matched instead, `debug` lines
 * included — prod-silent today is one `main.ts` edit away from a leak.
 *
 * Usage:  node scripts/verify-no-user-logs.mjs
 */
import { readdirSync, readFileSync, statSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join, relative } from 'path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const srcRoot = join(root, 'backend', 'src');
const IDENTIFYING = /\b(userId|username|identifier)=/;

function* tsFiles(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* tsFiles(p);
    else if (name.endsWith('.ts') && !name.endsWith('.spec.ts')) yield p;
  }
}

/** Yields [startIndex, text] for every string/template literal; comments skipped. */
function* literals(text) {
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '/' && text[i + 1] === '/') {
      i = text.indexOf('\n', i);
      if (i < 0) return;
    } else if (c === '/' && text[i + 1] === '*') {
      i = text.indexOf('*/', i + 2) + 1;
    } else if (c === "'" || c === '"' || c === '`') {
      const start = i;
      for (i++; i < text.length && text[i] !== c; i++) {
        if (text[i] === '\\') i++;
      }
      yield [start, text.slice(start, i + 1)];
    }
  }
}

const violations = [];
for (const file of tsFiles(srcRoot)) {
  const text = readFileSync(file, 'utf8');
  for (const [start, literal] of literals(text)) {
    const hit = literal.match(IDENTIFYING);
    if (!hit) continue;
    const line = text.slice(0, start).split('\n').length;
    violations.push(
      `${relative(root, file).replaceAll('\\', '/')}:${line} ${hit[1]}=`,
    );
  }
}

if (violations.length > 0) {
  console.error(
    `${violations.length} backend string(s) name an account (strip the id, keep the event):`,
  );
  for (const v of violations) console.error(`  ${v}`);
  process.exit(1);
}
console.log('OK: no backend source string names an account');
