#!/usr/bin/env node
// Frontend Dart lint RATCHET (very_good_analysis 10.3.0, frontend/analysis_options.yaml).
//
//   node scripts/dart-lint-ratchet.mjs            # fail if the info count grew
//   node scripts/dart-lint-ratchet.mjs --update   # accept the current count as the new floor
//
// Same contract as scripts/lint-ratchet.mjs (backend): errors and warnings are already
// fatal in CI's `flutter analyze --no-fatal-infos`; this script gates the INFO-level lint
// debt VGA surfaced on adoption (3 175 on 2026-09-12). Every commit holds the line or
// lowers it; pre-existing debt never turns the build red, new debt does.
//
// Counts are per rule so the log says WHICH rule grew. The total is what is enforced —
// a per-rule floor would let a change trade one rule's debt for another's.

import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const frontend = path.resolve(here, "..", "frontend");
const baselineFile = path.join(here, "dart-lint-baseline.json");
const update = process.argv.includes("--update");
// Windows: `flutter` is a .bat, which Node >= 20 refuses to spawn without a shell (EINVAL).
const shell = process.platform === "win32";

// flutter analyze exits 1 whenever it reports anything; infos are the normal case here.
// Findings go to stdout, the "N issues found" summary to stderr — read both.
const run = spawnSync("flutter", ["analyze", "--no-fatal-infos", "--no-fatal-warnings", "--no-pub"], {
  cwd: frontend,
  encoding: "utf8",
  shell,
  stdio: ["ignore", "pipe", "pipe"],
  maxBuffer: 64 * 1024 * 1024,
});
if (run.error || typeof run.stdout !== "string") {
  console.error("flutter analyze could not run:\n" + (run.error?.message ?? run.stderr));
  process.exit(2);
}
const raw = run.stdout + "\n" + run.stderr;

// flutter_tools picks the column separator by HOST: "-" on Windows, "•" everywhere else
// (packages/flutter_tools/lib/src/dart/analysis.dart, `_separator`). Accept both — a
// "-"-only pattern matched nothing on CI's Linux runner and "passed" at 0 for months.
const line = /^\s*(info|warning|error) [-•] .* [-•] ([a-z_0-9]+)\s*$/;
const byRule = new Map();
let infos = 0;
let others = 0;
for (const l of raw.split(/\r?\n/)) {
  const m = line.exec(l);
  if (!m) continue;
  if (m[1] !== "info") {
    others++;
    continue;
  }
  infos++;
  byRule.set(m[2], (byRule.get(m[2]) ?? 0) + 1);
}

// GUARD: "No issues found!" is a legitimate clean run, but an unparseable report is not.
const summary = /(\d+) issues? found|No issues found/.exec(raw);
if (!summary) {
  console.error("could not find the flutter analyze summary line — tooling error, not a pass:\n" + raw.slice(-2000));
  process.exit(2);
}
// GUARD: every finding flutter counted must have been parsed. A silent undercount (0 of
// 2 485 on Linux) reads as "PASS, IMPROVED" and switches the ratchet off.
const reported = Number(summary[1] ?? 0);
if (infos + others !== reported) {
  console.error(
    `PARSER ERROR — flutter analyze reported ${reported} issues but this script parsed ${infos + others}. ` +
      "The finding-line format changed; fix the `line` pattern. Not a pass.\n" +
      raw.split(/\r?\n/).filter((l) => l.trim()).slice(0, 5).join("\n"),
  );
  process.exit(2);
}

const top = [...byRule.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10);
console.log(`platform: ${process.platform}`);
console.log(`info-level lints (gated): ${infos}   errors+warnings (fatal in CI's own analyze step): ${others}`);
for (const [rule, n] of top) console.log(`  ${String(n).padStart(5)}  ${rule}`);

if (update) {
  writeFileSync(baselineFile, JSON.stringify({ infos, updated: new Date().toISOString().slice(0, 10) }, null, 2) + "\n");
  console.log(`\nbaseline updated: ${infos} infos -> ${path.relative(process.cwd(), baselineFile)}`);
  process.exit(0);
}

let baseline;
try {
  baseline = JSON.parse(readFileSync(baselineFile, "utf8"));
} catch {
  console.error(`no baseline at ${baselineFile}; run with --update once to create it`);
  process.exit(2);
}
if (typeof baseline.infos !== "number") {
  console.error("baseline file is malformed: expected { infos: number }");
  process.exit(2);
}

console.log(`\nbaseline: ${baseline.infos} infos`);
if (infos > baseline.infos) {
  console.error(`\nFAIL — info-level lint count rose ${baseline.infos} -> ${infos} (+${infos - baseline.infos}).`);
  console.error("Fix the new findings (see the rule table above); do not run a whole-tree dart fix.");
  process.exit(1);
}
if (infos < baseline.infos) {
  console.log(`\nPASS, IMPROVED — ${baseline.infos} -> ${infos}. Lower the floor: node scripts/dart-lint-ratchet.mjs --update`);
  process.exit(0);
}
console.log("\nPASS — info-level lint count held at the baseline.");
process.exit(0);
