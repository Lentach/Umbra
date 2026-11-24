#!/usr/bin/env node
/**
 * Ensures CLAUDE.md frontend test counts match `flutter test` output.
 * Sibling of verify-claude-backend-test-counts.mjs — same idea, different parser:
 * Flutter reports a running "+passed ~skipped" counter, not Jest's summary block.
 *
 * Usage:
 *   node scripts/verify-claude-frontend-test-counts.mjs
 *   node scripts/verify-claude-frontend-test-counts.mjs --log frontend/test-output.txt
 */
import { readFileSync, existsSync } from 'fs';
import { spawnSync } from 'child_process';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const claudePath = join(root, 'CLAUDE.md');

function parseClaudeCounts(text) {
  const m = text.match(/(\d+)\s+Flutter tests,\s*(\d+)\s+skipped/);
  if (!m) {
    throw new Error(
      'CLAUDE.md: expected pattern like "903 Flutter tests, 4 skipped" in the Tests line',
    );
  }
  return { tests: Number(m[1]), skipped: Number(m[2]) };
}

/**
 * `flutter test` has TWO output shapes and CI uses the one a local run does not:
 *
 *   attached to a TTY -> per-test progress, last line wins ("All other tests
 *   passed!" when the run has skips):
 *       01:32 +903 ~4: All tests passed!
 *   non-interactive (GitHub Actions) -> a single summary line, no counters at all:
 *       🎉 903 tests passed, 4 skipped.
 *
 * Parsing only the first form passed locally and failed on CI. Handle both.
 */
function parseFlutterLog(text) {
  // Preferred: the non-interactive summary line, which is unambiguous.
  const summary = text.match(/(\d+)\s+tests?\s+passed(?:,\s*(\d+)\s+skipped)?/);
  if (summary) {
    return { tests: Number(summary[1]), skipped: Number(summary[2] ?? 0) };
  }

  // Fallback: the TTY progress counter, last occurrence wins.
  const counters = [...text.matchAll(/\+(\d+)(?:\s+~(\d+))?\s*:/g)];
  if (counters.length === 0) {
    throw new Error(
      'flutter test output: found neither an "N tests passed" summary nor a "+N:" progress counter — did the run fail before starting?',
    );
  }
  if (!/All (?:other )?tests passed!/.test(text)) {
    throw new Error(
      'flutter test output: "All tests passed!" not present — the suite did not pass, refusing to compare counts.',
    );
  }
  const last = counters[counters.length - 1];
  return { tests: Number(last[1]), skipped: Number(last[2] ?? 0) };
}

function runFrontendTests() {
  // flutter is a .bat shim on Windows, so it needs the shell there.
  const isWin = process.platform === 'win32';
  const command = isWin ? process.env.ComSpec || 'cmd.exe' : 'flutter';
  const args = isWin ? ['/d', '/s', '/c', 'flutter test'] : ['test'];
  const r = spawnSync(command, args, {
    cwd: join(root, 'frontend'),
    encoding: 'utf8',
    maxBuffer: 50 * 1024 * 1024,
  });
  const out = `${r.stdout ?? ''}${r.stderr ?? ''}`;
  if (r.error) {
    console.error(r.error);
    process.exit(1);
  }
  if (r.status !== 0) {
    console.error(out);
    process.exit(r.status ?? 1);
  }
  return out;
}

// `--log` may repeat: CI splits `flutter test` into directory legs, one log per leg; counts sum.
const logPaths = process.argv.flatMap((a, i) => (a === '--log' ? [process.argv[i + 1]] : []));
let actual;
if (logPaths.length > 0) {
  actual = { tests: 0, skipped: 0 };
  for (const logPath of logPaths) {
    if (!logPath || !existsSync(logPath)) {
      console.error(`Missing or invalid --log path: ${logPath}`);
      process.exit(1);
    }
    const shard = parseFlutterLog(readFileSync(logPath, 'utf8'));
    actual.tests += shard.tests;
    actual.skipped += shard.skipped;
  }
} else {
  actual = parseFlutterLog(runFrontendTests());
}

const expected = parseClaudeCounts(readFileSync(claudePath, 'utf8'));

if (expected.tests !== actual.tests || expected.skipped !== actual.skipped) {
  const noLibrary =
    actual.tests === expected.tests - 13 && actual.skipped === expected.skipped + 13;
  console.error(
    `CLAUDE.md drift: documented ${expected.tests} tests / ${expected.skipped} skipped, ` +
      `flutter has ${actual.tests} tests / ${actual.skipped} skipped.\n` +
      (noLibrary
        ? `This is not drift: do not edit CLAUDE.md. Without the native webcrypto library ` +
          `(\`dart run webcrypto:setup\`; CI builds it) 13 real-crypto tests skip, so a local ` +
          `run reports 13 fewer passed and 13 more skipped than CLAUDE.md.`
        : `Update the Tests line in CLAUDE.md (and re-run). The documented counts assume the ` +
          `native webcrypto library is present: without it a run reports 13 fewer passed and ` +
          `13 more skipped, and that difference is not drift.`),
  );
  process.exit(1);
}

console.log(
  `OK: CLAUDE.md matches flutter test (${actual.tests} tests, ${actual.skipped} skipped)`,
);
