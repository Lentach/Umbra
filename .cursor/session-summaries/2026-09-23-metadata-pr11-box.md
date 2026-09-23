# The box (metadata-privacy PR1.1) exists on the branch, dark; recoverPassword never issues a dead token

**Date:** 2026-09-23 · **Version:** unchanged · **Tiers deployed:** none

## What was done
- `424283cd` fix(backend, unasked): `AuthService.recoverPassword` re-checks `Date.now()` after every wait. One `setTimeout` to the next second can fire ~1 ms early, so the JWT was signed in `passwordChangedAt`'s second and `JwtStrategy` refused it (CI flake on `917845eb`).
- `8ad7c04e` PR1.1 `backend/src/box/`: `/box` namespace with NO handshake auth. Six ack-answered verbs (`createQueue`, `send`, `subscribe`, `ack`, `deleteQueue`, `registerNotifier`), Ed25519 over bytes bound to the socket id, and one push `msg` (window 16, round-robin, newest subscriber wins, at-least-once). Also caps 128 / 50-drop-oldest, TTL + 24 h unclaimed + 90 d reaper, and a push-challenge notifier (`{type:'new_message'}` only, coalesced per nid).
- `POST/GET /box/media`: size decided from `Content-Length` after the throttle, body streamed to `MEDIA_DIR/box/`, 256 MiB/day per normal queue, request queues take no media, unknown sid → `201` never stored.
- `migrations/0022_box.sql` + 4 entities (named to match; the suite asserts `synchronize` would change nothing). No column names an account, device or sender (I2; the suite pins the exact column list).
- `scripts/verify-box-imports.mjs` (I1, TRANSITIVE + self-test). CI backend job gained a Postgres service, the I1 check and `npm run test:int` (fails, never skips, in CI without its DB).
- `buildCorsOrigin` → `common/socket-cors.ts`: both gateways share one engine.io server built from the FIRST-scanned gateway's options.
- `@types/web-push` added (ESLint floor 888 → 870). The sweep logs per-event throttle-refusal COUNTS (the nginx conf promised that metric).
- Decisions beyond the G3 text, recorded in `wire.md` "Box" and `task_plan.md` PR1.1 as-built:
  - `deleteQueue` on a gone rid answers `auth_failed`, NOT `ok`: `ok` would be an existence oracle;
  - `createQueue` is idempotent per `authPub`;
  - `claimBy` column for the 24 h rule;
  - Web Push endpoints allowlisted (the box POSTs to them: SSRF).

## Key files
- New: `backend/src/box/**` (14 source files + 4 entities, `box-wire.spec.ts`, `box-signature.spec.ts`, `box.int-spec.ts`), `backend/migrations/0022_box.sql`, `backend/jest.integration.config.json`, `backend/src/common/socket-cors.ts`, `scripts/verify-box-imports.mjs`.
- Edited: `app.module.ts`, `chat/chat.gateway.ts` (import only), `chat/guards/ws-throttler.guard.ts` + `common/client-ip.ts` (comments), `package.json` (+`socket.io-client`, `@types/web-push`, `test:int`), `knip.json`, `ci.yml`, `CLAUDE.md`, `backend/CLAUDE.md`, `docs/contracts/wire.md`, `scripts/lint-baseline.json`.
- Read only: `.planning/metadata-privacy/{g3-surface-designs,design-candidate,task_plan}.md`; Nest `io-adapter.js`, `socket-server-provider.js`; throttler 6.7.0 guard.

## Verification
- Race fix: red with the CI numbers (`1790127135` vs `1790127135`) on a virtual clock whose timer lands 1 ms short, green after; mutant `waitMs > 1` killed; jest 1166/66; CI 7/7 on `424283cd`.
- Box, `npm run test:int` against a fresh DB migrated 0001…0022 on the dev Postgres: 23/23 (real socket.io + HTTP, real module, only the push relay faked). Unit: jest 1181/68 (+15 wire/signature tests). tsc, ESLint 870 (held), knip, no-user-logs, I1 checker: all OK.
- Mutants: 22 killed, files byte-restored (sha256):
  - sid oracle, sockId binding, window 32, old owner keeps rid, cap off-by-one, request drops newest;
  - extra keys tolerated, no /64, code unchecked, 90-day boundary, ack keeps count, media 404 oracle;
  - unknown rid passes owner check, migration drift, unclaimed never reaped, request queue takes media;
  - throttle not acked, no-ack not disconnected, I1 checker (it printed two chains into `chat/`, `users/`), non-canonical b64;
  - ack without the queue lock, body read before the size check.
- Two defects found in review AFTER the first green run, fixed red-first:
  - an ack racing a flood on a full request queue deadlocked (40P01, 14 of 50 answers `internal`); now one lock order: queue rows (rid order) before msg rows;
  - `express.raw` read up to 16 MiB of any unauthenticated body before throttle/sid/budget (red: an off-rung `Content-Length` with no body never got an answer); now no parser.
- Live on the dev app (`main.ts` + `AppModule`, :3000):
  - chat `/` without a token → `io server disconnect`;
  - box createQueue → subscribe → send → `msg` intact → ack → deleteQueue;
  - media 201/200 `no-store`;
  - `/auth/login` 200 kB JSON → 413 (the 100 kb cap holds).
- `flutter test test_e2e` 46 passed / 14 skipped (chat path unchanged by the shared server).
- NOT verified: a real Flutter client (PR1.2), real FCM/Web Push delivery (dev has no Firebase), the ORDER BY rid multi-row locks (no deterministic repro), nginx/VM, prod.

## Notes for next session
- Next: PR1.2 (Flutter `BoxClient`), then PR1.3 → gate G4. Client facts: sign over the namespace socket's id; a repeated `deleteQueue` = gone; ack blobs you cannot open.
- Owner-owed:
  - OK the `deleteQueue` → `auth_failed` deviation from G3 §1;
  - the media budget number (256 MiB/day);
  - I2b in the transition: one push token in both `fcm_tokens` and `box_notifiers` during release N (`findings.md`).
- Deploy owed at the gate: nginx `location /box/` with `X-Real-IP`.
- **CI never ran on `8ad7c04e`**: another session pushed 3 docs commits to `master` at 01:57 (the `umbra-session-start` skill) and draft PR #184 conflicted on `LATEST.md`, so GitHub created no `pull_request` run. Owner's pick: the branch's `LATEST.md` is now master's VERBATIM (`git merge-tree` probe: clean; master + a new entry on top still conflicts), so **this session has NO LATEST entry** — this file and `NEXT.md` carry the handoff. The same commit carries master's other 7 docs files byte-identical (skill, `.gitignore` `NEXT.md`, AGENTS.md, …) plus its 2 trap lines. PR1.1's first CI run is the one on the handoff commit.
- Traps → `docs/agents/traps.md` (6 lines, this file).
