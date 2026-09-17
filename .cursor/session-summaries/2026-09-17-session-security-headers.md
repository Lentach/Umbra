# The app document has security headers, the prod vhost is tracked, and two unmerged branches are in master

**Date:** 2026-09-17 · **Version:** unchanged (0.2.48) · **Tiers deployed:** none (nginx config only — no bundle, no image)

## What was done
- Merged `feat/unreadable-reason` (clean) and `proof/e2e-encryption` (3 doc conflicts) into `master`; composed the `CLAUDE.md` Tests line once from both deltas (unit count from the verifier, `test_e2e` 46 → 46+5 as prose), rotated `LATEST.md` back to 5 entries.
- Fixed the 13 info-lints the two branches added (ratchet 3168 → 3181 would have failed CI); floor re-lowered to 3168.
- `infra/nginx/fireplace.conf` + `infra/nginx/security-headers.conf`: the live host vhost is TRACKED, and `location /` + `^~ /welcome/` now send HSTS, nosniff, `X-Frame-Options: DENY`, `Referrer-Policy`, COOP, `Permissions-Policy` (camera/mic kept at `self`) and a Report-Only CSP. Applied on the VM, `nginx -t` + reload.
- Normalized the VM layout: `sites-enabled/fireplace` was a REGULAR FILE and `sites-available/fireplace` a stale copy (`client_max_body_size 11m`, no `/contact`, no `no-cache`) — now available + symlink, both backed up.
- `scripts/verify-csp-inline-hashes.mjs` (new): fails when `web/index.html`'s inline blocks and the CSP `script-src` disagree. `post-deploy-smoke.mjs` gained check 5: the static set present, and `/health` still carrying helmet's alone.
- `connection_provider.dart`: `_reenrollInFlight` latch taken BEFORE the mint — `(lxxxv)`, closing `(lxiv)` residual 8, whose recorded price was too low (the two passes destroyed each other's ack channel, so NEITHER promoted).
- `docs/design/reaction-privacy.md` (new): the owner-picked blinded-token design for D10, with work breakdown, 6 falsifications, and the three leaks it does not fix.

## Key files
- Edited: `CLAUDE.md`, `docs/agents/traps.md`, `docs/design/multi-device.md` (`(lxxxv)` + residual 8 closure), `.omp/rules/production-vm-deploy.md`, `scripts/smoke/post-deploy-smoke.mjs`, `scripts/dart-lint-baseline.json`, `frontend/lib/providers/connection_provider.dart`, `frontend/test/providers/connection_provider_reset_rebind_test.dart`, `frontend/test_e2e/encryption_proof_test.dart` (lint only).
- New: `infra/nginx/fireplace.conf`, `infra/nginx/security-headers.conf`, `scripts/verify-csp-inline-hashes.mjs`, `docs/design/reaction-privacy.md`, this summary.
- Read only (load-bearing): `docs/contracts/wire.md` §reset/REBIND, `frontend/web/index.html`, `backend/src/main.ts:30` (helmet), `frontend/lib/services/encryption/signal_stores.dart:27-52`.

## Verification
- `flutter test` 2149 / 14 skipped, matches `CLAUDE.md` via `verify-claude-frontend-test-counts.mjs`. `flutter analyze` 0 errors / 0 warnings. `dart-lint-ratchet.mjs` PASS at 3168.
- Latch is red-first: with the guard stashed the new test fails `Expected: length of <1>, Actual: [2 enrollments]`; with it, 15/15 and the diag prints `RESET_REENROLL_INFLIGHT` then `RESET_REENROLL_PROMOTED`. F51–F53 recorded in `(lxxxv)`.
- Headers measured live with `curl -D -`: `/`, `/index.html`, `/flutter.js`, `/version.json`, `/welcome/` carry the 7-header set **and** keep `Cache-Control: no-cache`; `/health` + `/version` still carry helmet's set only, `X-Frame-Options: SAMEORIGIN`, no duplicates. `Server: nginx` (tokens off).
- `post-deploy-smoke.mjs --commit eefc44b0` → 7/7 PASS including both new checks.
- Headless Chromium against prod: **zero CSP violations** after the fix; app boots, fonts load, login screen renders, footer `eefc44b0`. The pass caught two real defects first — `base-uri 'none'` rejects Flutter's own `<base href="/">`, and the inline-script hashes were CRLF digests (the HTML parser normalizes newlines first; Chrome named the LF digests verbatim). Enforced, that second one would have killed the pre-paint theme sync and the passcode privacy curtain.
- NOT verified: the logged-in surface (chat, GIF picker, voice, media, QR scan) under the Report-Only CSP — needs one desktop-Chrome pass by the owner; Android/iOS PWA untouched by this change; no bundle or backend image was built or deployed.

## Notes for next session
- **Owner-owed:** (1) the logged-in desktop-Chrome CSP pass, after which enforcing needs `frame-ancestors 'none'` added and the two inline blocks moved to a blocking same-origin `web/boot.js` (kills the hashes; touches the passcode curtain, so re-verify it — emulator + real phone are available); (2) whether the reaction migration nulls existing plaintext rows; (3) bundling Inter/Archivo/PressStart2P locally to drop `fonts.gstatic.com` (privacy + a simpler enforcing policy).
- Still open from the original four: D10 itself (designed, not built) and the web key-custody hole (`signal_stores.dart:27-52` — the unwrapping key sits beside the ciphertext in localStorage; only a non-extractable IndexedDB `CryptoKey` closes it; CSP narrows blast radius, it is not a fix).
- Traps appended to `docs/agents/traps.md`: `frontend/nginx.conf` is not prod; static headers only in the two document blocks; CSP hashes must be LF; `sites-available` was stale; a `keyBundleUploaded` handler can run twice; backticks in `git commit -m` from bash are command substitution (it silently ate two words of `f86a43de`'s message).
