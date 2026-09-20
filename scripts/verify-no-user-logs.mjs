#!/usr/bin/env node
/**
 * Fails when backend source can log an account identifier.
 *
 * Metadata privacy step 0 (2026-09-20): container stdout is the one server
 * record that survives the transient-queue cutover, so a log line carrying an
 * account id or username — alone, or worse, as a sender<->recipient pair — is
 * a per-account activity trail. Event names, outcomes, deviceId, versions and
 * reasons stay; the account goes.
 *
 * The rule is on the STRING, not the logger call: a line-based regex over
 * `this.logger.warn(` saw 8 of the first 23 sites, and lines are also built
 * in variables and thrown as Error messages that a catch re-logs. Every
 * '…', "…" and `…` literal in a non-spec file is matched, `debug` lines
 * included (prod-silent is one `main.ts` edit away from a leak). Regex
 * literals are skipped so a quote inside `/"/g` cannot flip the scan.
 *
 * A non-log literal (Map key, socket room, canonical wire format) opts out
 * with `// log-guard: key` on its line. Two forms are flagged (both
 * case-insensitive):
 *   1. a LABEL: `userId=`, `senderId:`, `targetUserId =`, `username=`,
 *      `identifier=`, `user 7`-style `user ${…}` / `users ${…}`
 *   2. an INTERPOLATION of an account field: `${userId}`, `${user.id}`,
 *      `${sender.username}`, `${recipientId}`, `${payload.sub}`, …
 *
 * Usage:  node scripts/verify-no-user-logs.mjs [--self-test]
 */
import { readdirSync, readFileSync, statSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join, relative } from 'path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const srcRoot = join(root, 'backend', 'src');

const ID_WORD =
  '(?:user|sender|recipient|requester|target|caller|blocker|blocked|other|peer|owner|member|creator|author|from|to)';
const LABEL = new RegExp(
  `\\b(?:[a-z]*${ID_WORD}(?![a-z]*device)[a-z]*id|username|identifier)\\s*[=:]|\\busers?\\s+\\$\\{`,
  'i',
);
const INTERPOLATION = new RegExp(
  `\\$\\{[^}]*\\b(?:[a-z]*${ID_WORD}(?![a-z]*device)[a-z]*id|username|identifier|${ID_WORD}[a-z]*\\.(?:id|username)|payload\\.sub|req\\.user\\.id)\\b[^}]*\\}`,
  'i',
);

function* tsFiles(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* tsFiles(p);
    else if (name.endsWith('.ts') && !name.endsWith('.spec.ts')) yield p;
  }
}

/** A `/` starts a regex literal when the previous token cannot end an expression. */
function startsRegex(text, i) {
  let j = i - 1;
  while (j >= 0 && /\s/.test(text[j])) j--;
  if (j < 0) return true;
  if ('(=,:!&|?[{;+-*%<>~^'.includes(text[j])) return true;
  const word = text.slice(Math.max(0, j - 6), j + 1).match(/[a-z]+$/i);
  return !!word && /^(return|typeof|case|throw|in|of|do|else)$/.test(word[0]);
}

/** Yields [startIndex, text] for every string/template literal; comments and regexes skipped. */
export function* literals(text) {
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '/' && text[i + 1] === '/') {
      i = text.indexOf('\n', i);
      if (i < 0) return;
    } else if (c === '/' && text[i + 1] === '*') {
      i = text.indexOf('*/', i + 2) + 1;
    } else if (c === '/' && startsRegex(text, i)) {
      let cls = false;
      for (i++; i < text.length && (cls || text[i] !== '/') && text[i] !== '\n'; i++) {
        if (text[i] === '\\') i++;
        else if (text[i] === '[') cls = true;
        else if (text[i] === ']') cls = false;
      }
    } else if (c === "'" || c === '"') {
      const start = i;
      for (i++; i < text.length && text[i] !== c && text[i] !== '\n'; i++) {
        if (text[i] === '\\') i++;
      }
      yield [start, text.slice(start, i + 1)];
    } else if (c === '`') {
      const start = i;
      let depth = 0;
      for (i++; i < text.length; i++) {
        const d = text[i];
        if (d === '\\') i++;
        else if (d === '$' && text[i + 1] === '{') depth++, i++;
        else if (d === '}' && depth > 0) depth--;
        else if (d === '`' && depth === 0) break;
      }
      yield [start, text.slice(start, i + 1)];
    }
  }
}

export function findViolations(text) {
  const out = [];
  for (const [start, literal] of literals(text)) {
    // A literal that is not a log line (Map key, room name, wire format)
    // opts out EXPLICITLY with `// log-guard: key` on its line; there is no
    // shape heuristic, so a bare `${userId}` in a log is still caught.
    const eol = text.indexOf('\n', start);
    const lineTail = text.slice(start, eol < 0 ? text.length : eol);
    const hit =
      literal.match(LABEL) ??
      (lineTail.includes('// log-guard: key') ? null : literal.match(INTERPOLATION));
    if (!hit) continue;
    out.push({ line: text.slice(0, start).split('\n').length, hit: hit[0] });
  }
  return out;
}

function selfTest() {
  const bad = [
    'logger.log(`login failed userId=${u.id}`)',
    'logger.warn(`REFUSED senderId=${a} recipientId=${b}`)',
    'logger.error(`for user ${userId}`)',
    'logger.log(`x ${user.username} y`)',
    'logger.log(`x (id=${sender.id})`)',
    'throw new Error(`allocateDeviceId: user ${userId} not found`)',
    "const l = 'targetUserId: ' + x",
    'logger.log(`${recipientId} online`)',
    'logger.warn(`${userId}`)',
    'const key = `${requesterId}:${recipientId}`; // a key without the marker',
    // a regex with quotes BEFORE the string must not hide it
    `s.replace(/"/g, '\\\\"'); logger.log(\`userId=\${id}\`)`,
  ];
  const good = [
    'logger.log(`[revoke] deviceId=${deviceId} version=${v}`)',
    'logger.log(`committed count=${rows.length}`)',
    "const re = /userId=/; // a regex, not a string",
    '// userId=${x} in a comment',
    'const key = `${requesterId}:${recipientId}:${deviceId}`; // log-guard: key',
    'return `user:${userId}`; // log-guard: key',
    'where(\'"userId" = :userId\', { userId })',
    'logger.log(`messageId=${messageId} conversationId=${c}`)',
    'logger.warn(`REFUSED callerDeviceId=${callerDeviceId} targetDeviceId=${d}`)',
  ];
  let ok = true;
  for (const s of bad)
    if (findViolations(s).length === 0) (ok = false), console.error(`MISSED: ${s}`);
  for (const s of good)
    if (findViolations(s).length > 0) (ok = false), console.error(`FALSE HIT: ${s}`);
  return ok;
}

if (process.argv.includes('--self-test')) {
  if (!selfTest()) process.exit(1);
  console.log('self-test OK');
} else {
  if (!selfTest()) {
    console.error('checker self-test failed; refusing to report');
    process.exit(2);
  }
  const violations = [];
  for (const file of tsFiles(srcRoot)) {
    const rel = relative(root, file).replaceAll('\\', '/');
    for (const v of findViolations(readFileSync(file, 'utf8')))
      violations.push(`${rel}:${v.line}  ${v.hit.trim()}`);
  }
  if (violations.length > 0) {
    console.error(
      `${violations.length} backend string(s) name an account (strip the id, keep the event):`,
    );
    for (const v of violations) console.error(`  ${v}`);
    process.exit(1);
  }
  console.log('OK: no backend source string names an account');
}
