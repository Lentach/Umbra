#!/usr/bin/env node
// Post-deploy smoke test for https://fireplace.ignorelist.com
//
// Run on the PC after `.\deploy-web.ps1` (and/or `./deploy-backend.sh` on the VPS):
//   cd scripts/smoke
//   npm install && npx playwright install chromium   # one-time
//   node post-deploy-smoke.mjs [--commit <shortSha>] [--url <base>]
//
// Checks (fails with exit 1 on any miss):
//   1. /health            -> {"status":"ok","db":"ok"}
//   2. /version.json      -> frontend semver present
//   3. /version           -> backend { version, gitCommit, buildTime } (not 0.0.1/0.0.2/dev/unknown)
//   4. main.dart.js       -> served bundle CONTAINS the expected git short-sha
//                            (the GIT_COMMIT dart-define is compiled into the JS; this is the
//                             definitive stale-build check — version.json alone can lie)
//   5. security headers -> HSTS/nosniff/DENY/Referrer-Policy/Permissions-Policy/CSP-RO on the
//                          STATIC document, and /health still carrying helmet's set ONLY
//   6. Playwright chromium boots the app (fresh profile = no stale SW) and the Flutter
//      view renders within 60 s. Screenshot saved next to this script.
//
// Expected commit defaults to `git rev-parse --short HEAD` of this repo; override with --commit.

import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const args = process.argv.slice(2);
const argVal = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};

const BASE = (argVal("--url") ?? "https://fireplace.ignorelist.com").replace(/\/$/, "");
const here = path.dirname(fileURLToPath(import.meta.url));
const expectedCommit =
  argVal("--commit") ??
  execSync("git rev-parse --short HEAD", { cwd: path.resolve(here, "..", "..") })
    .toString()
    .trim();

let failures = 0;
const ok = (name, detail = "") => console.log(`  PASS  ${name}${detail ? ` — ${detail}` : ""}`);
const fail = (name, detail) => {
  failures++;
  console.error(`  FAIL  ${name} — ${detail}`);
};

const getJson = async (p) => {
  const res = await fetch(`${BASE}${p}`, { cache: "no-store" });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
};

console.log(`Smoke: ${BASE} (expecting commit ${expectedCommit})\n`);

// 1. /health
try {
  const h = await getJson("/health");
  h.status === "ok" && h.db === "ok"
    ? ok("/health", JSON.stringify(h))
    : fail("/health", JSON.stringify(h));
} catch (e) {
  fail("/health", e.message);
}

// 2. /version.json (frontend)
let feVersion = "?";
try {
  const v = await getJson("/version.json");
  feVersion = v.version;
  /^\d+\.\d+\.\d+$/.test(feVersion ?? "")
    ? ok("/version.json", `frontend ${feVersion}`)
    : fail("/version.json", `bad semver: ${JSON.stringify(v)}`);
} catch (e) {
  fail("/version.json", e.message);
}

// 3. /version (backend)
try {
  const v = await getJson("/version");
  const stale =
    ["0.0.1", "0.0.2"].includes(v.version) || ["dev", "unknown", ""].includes(v.gitCommit ?? "");
  !stale && v.version && v.gitCommit
    ? ok("/version", `backend ${v.version}/${v.gitCommit}`)
    : fail("/version", `stale/default metadata: ${JSON.stringify(v)}`);
} catch (e) {
  fail("/version", e.message);
}

// 4. served bundle contains the expected commit (stale-build detector)
try {
  const res = await fetch(`${BASE}/main.dart.js?smoke=${Date.now()}`, { cache: "no-store" });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const js = await res.text();
  js.includes(expectedCommit)
    ? ok("bundle commit", `main.dart.js contains ${expectedCommit}`)
    : fail(
        "bundle commit",
        `served main.dart.js does NOT contain ${expectedCommit} — stale build ` +
          `(served frontend is ${feVersion}; rebuild with flutter clean + deploy-web.ps1, ` +
          `or pass --commit <deployed-sha> if checking an older deploy on purpose)`,
      );
} catch (e) {
  fail("bundle commit", e.message);
}

// 5. security headers on the STATIC document (nginx), and helmet's set left
//    alone on a PROXIED path. Regression guard: the app shell shipped with none
//    of these until 2026-09-17 because the vhost was untracked, and nginx
//    `add_header` in a location silently REPLACES an inherited set — so a
//    future edit can drop them without anything else failing.
try {
  const doc = await fetch(`${BASE}/?smoke=${Date.now()}`, { cache: "no-store" });
  const want = {
    "strict-transport-security": /max-age=\d{7,}/,
    "x-content-type-options": /^nosniff$/,
    "x-frame-options": /^DENY$/,
    "referrer-policy": /^no-referrer$/,
    "permissions-policy": /camera=\(self\)/,
    "content-security-policy-report-only": /script-src 'self' 'wasm-unsafe-eval'/,
    "cache-control": /no-cache/,
  };
  const missing = Object.entries(want)
    .filter(([h, re]) => !re.test((doc.headers.get(h) ?? "").trim()))
    .map(([h]) => h);
  missing.length === 0
    ? ok("static security headers", `${Object.keys(want).length} present on /`)
    : fail(
        "static security headers",
        `missing/wrong on /: ${missing.join(", ")} — re-apply infra/nginx/ ` +
          `(see .omp/rules/production-vm-deploy.md § Static security headers)`,
      );

  // The API half must keep exactly ONE set — helmet's. Two X-Frame-Options with
  // different values is an invalid response, not defence in depth.
  const api = await fetch(`${BASE}/health`, { cache: "no-store" });
  const xfo = api.headers.get("x-frame-options");
  xfo === "SAMEORIGIN"
    ? ok("proxied headers untouched", "/health still SAMEORIGIN from helmet")
    : fail(
        "proxied headers untouched",
        `/health X-Frame-Options is ${JSON.stringify(xfo)}; expected helmet's SAMEORIGIN ` +
          `(a server-level nginx add_header would duplicate/conflict here)`,
      );
} catch (e) {
  fail("static security headers", e.message);
}

// 5b. Every API route must actually REACH the backend. nginx answers an
// unproxied path with the Flutter index.html at HTTP 200 (never a 404), so a
// missing `location` block is invisible to status-code checks and to any
// container/DB-side verification. `/backup/contacts` shipped exactly that way
// on 2026-09-21: 200 text/html, so the client JSON-decoded a web page, parked
// in `unreachable`, and every password change would have been refused.
// Judge the CONTENT TYPE, and require the backend's own auth refusal.
try {
  // One probe per @Controller prefix. Not `/backup`-specific on purpose: the
  // defect is "new controller, forgot the nginx location", and Phase 1's box
  // endpoints are the next ones to hit it. A /backup-only assertion would
  // teach nothing the second time.
  //
  // `want` is what the BACKEND answers unauthenticated. Only the content type
  // is load-bearing: any `text/html` means the request never left nginx.
  //
  // `/notes` covers the secret-notes controller. `/note/<token>` is covered by
  // it and deliberately NOT probed on its own: that route legitimately RENDERS
  // HTML from the backend (the "Anti-Quantum Note" reveal page, 1114 bytes,
  // `text/html; charset=utf-8`), so the text/html rule would false-fail on a
  // perfectly healthy deploy. Measured 2026-09-21 — the SPA shell is 10724
  // bytes with no charset, which is why status+type alone cannot separate them.
  const probes = [
    { path: "/backup/contacts", want: [401] },
    { path: "/users/me", want: [401] },
    { path: "/messages/link-preview", want: [401, 404, 405] },
    { path: "/auth/refresh", want: [400, 401, 404, 405] },
    { path: "/media/msgs/probe.bin", want: [401, 404] },
    { path: "/notes", want: [401, 404] },
    { path: "/health", want: [200] },
    { path: "/version", want: [200] },
  ];
  const broken = [];
  for (const { path, want } of probes) {
    const res = await fetch(`${BASE}${path}`, { cache: "no-store" });
    const type = res.headers.get("content-type") ?? "";
    if (type.includes("text/html")) {
      broken.push(`${path} -> ${res.status} text/html (SPA fallthrough)`);
    } else if (!want.includes(res.status)) {
      broken.push(`${path} -> ${res.status} ${type || "(no type)"}`);
    }
  }
  broken.length === 0
    ? ok("api routes reach the backend", `${probes.length} controller prefixes proxied, none served by the SPA`)
    : fail(
        "api routes reach the backend",
        `served by the SPA instead of the API: ${broken.join(", ")} — add a ` +
          `location block to infra/nginx/fireplace.conf and reload nginx`,
      );
} catch (e) {
  fail("api routes reach the backend", e.message);
}

// 6. browser boot (fresh profile — no service worker cache involved)
try {
  const { chromium } = await import("playwright");
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const consoleErrors = [];
  page.on("pageerror", (err) => consoleErrors.push(String(err)));
  await page.goto(BASE, { waitUntil: "domcontentloaded", timeout: 60_000 });
  await page.waitForSelector("flutter-view, flt-glass-pane", { state: "attached", timeout: 60_000 });
  const shot = path.join(here, "smoke-latest.png");
  await page.screenshot({ path: shot });
  await browser.close();
  ok("app boot", `Flutter view rendered; screenshot ${path.basename(shot)}`);
  if (consoleErrors.length > 0)
    console.warn(`  WARN  page errors (not fatal): ${consoleErrors.slice(0, 3).join(" | ")}`);
} catch (e) {
  fail("app boot", e.message);
}

console.log(failures === 0 ? "\nSMOKE PASSED" : `\nSMOKE FAILED (${failures})`);
process.exit(failures === 0 ? 0 : 1);
