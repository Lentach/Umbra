# G4 passed with the box OFF on prod: Phase 1 is on master and the backend is live at 14c1f22d (0022 applied, /box unregistered)

**Date:** 2026-09-23 · **Version:** backend `0.2.51 / 9e621f63` → `0.2.51 / 14c1f22d`; web unchanged `0.2.50 / d37e2dcc` · **Tiers deployed:** backend

## What was done
- Gate review of `2ab9265c..43cf55a8` (46 commits, 125 files), run by 4 parallel agents: standards, spec, box security and deploy compatibility.
  - BLOCKER (security): the box has no GLOBAL storage ceiling. Every limit is per IP or per queue, and anyone can mint a queue. At 300 × 16 MiB per 15 min, one IPv4 could write ~4.7 GiB to `/box/media` per window. Prod had 7.9 GB free (`df -h`), on the same disk as Postgres.
  - Deploy compat: safe with the old clients (web 0.2.50, APK 0.2.51). MAJOR: PR0.2 visibly changes push behaviour.
  - Standards and spec: no blockers.
- Owner decisions:
  - **Box OFF on prod, rehearse, deploy.**
  - **PR0.2 signed off:** while the app is visible, a message in another chat gets only an unread badge. A closed or backgrounded app gets pushes as before (verified in `chat-message.service.ts:1279-1286` and in the old client's `main_shell.dart:220-228` at `d37e2dcc`).
- `27ec3421`: `AppModule` registers `BoxModule` through `ConditionalModule.registerWhen(…, env.BOX_ENABLED === 'true')`.
  - `env.validation.ts` accepts only `'true'`/`'false'`.
  - `docker-compose.prod.yml` PINS `BOX_ENABLED: 'false'`, so enabling it takes a reviewed change, never a `.env` edit.
  - The dev `docker-compose.yml` defaults it to true, and so do CI's e2e stacks.
- Folded in the same commit:
  - `messaging_provider.send.dart` `_refreshRecipientDeviceListAfterDeadAddress` uses `.ignore()` (frontend/CLAUDE.md §8).
  - `backend/CLAUDE.md` §2 names the box's strict parsers as the `validateDto` exception.
  - The wire.md box bullet lists the PR3.1 prerequisites.
- `14c1f22d`: merged `origin/master` (3 docs commits, clean), then pushed `HEAD:master` + the branch (`git ls-remote`: both at `14c1f22d`).
- Deployed: backup `chatdb-20260923T190351Z.dump.gpg` first, then `./deploy-backend.sh`. `0022_box.sql` applied at boot. `.planning/metadata-privacy/task_plan.md` §5 has the G4 block with the 5 PR3.1 prerequisites.
- **Owner, after the deploy: BRANCH UNTIL RELEASE N.** PR2.1/PR3.2/PR3.1 stay on the branch until the box cutover works end to end. G4 failed the plan's own standalone test for the box (dark, no user value) and used a merge commit against §5's linear-history rule. Owner kept the deploy.

## Key files
- Edited: `backend/src/app.module.ts`, `backend/src/config/env.validation.ts`, `docker-compose.prod.yml`, `docker-compose.yml`, `backend/CLAUDE.md`, `docs/contracts/wire.md`, `frontend/lib/providers/messaging/messaging_provider.send.dart`
- New: this summary. Gitignored: the G4 block in `.planning/metadata-privacy/task_plan.md`.
- Read only (load-bearing): `backend/src/box/box.constants.ts` (limits, budget), `backend/src/chat/services/chat-message.service.ts:1279` (push predicate), `staging.ps1`, `infra/nginx/fireplace.conf` (server-level `client_max_body_size 21m`; no `/box/` block, on purpose)

## Verification
- CI, before and after:
  - `43cf55a8`, re-checked this session: 7/7 success.
  - Tip `14c1f22d` on master: 6/6 success (Backend tests, Flutter analyze+tests, E2E wire harness, E2E isolated probes incl. the box round trip, Web Lock probe, Analyze actions). CodeQL did not report on the push.
- Local checks:
  - `tsc --noEmit` clean.
  - Both ratchets held: ESLint 870, dart infos 3163.
  - `messaging_provider_fanout_test.dart`: 11/11, including the dead-address refetch.
- Dev stack, raw engine.io probe:
  - `BOX_ENABLED` unset → `POST /box/media` 404 and `/box` "Invalid namespace".
  - `true` → 201 and the namespace connects.
- Staging (`staging.ps1`, prod image `14c1f22d`, its own volume at `0021`):
  - `applied 0022_box.sql` at boot.
  - `sql 0022` replay: every statement "already exists, skipping".
  - Box off: 404 / Invalid namespace.
  - `harness`: +46 ~16, All tests passed.
  - `down` afterwards, no `-v`.
- Prod:
  - Backup `chatdb-20260923T190351Z.dump.gpg` (+ media, env) taken BEFORE the deploy.
  - `/version` `0.2.51 / 14c1f22d`, `/health` ok.
  - `schema_migrations` top row `0022_box.sql`; the 4 `box_*` tables exist.
  - Container `BOX_ENABLED=false`; log line "Skipping the registration of BoxModule".
  - `wss …/socket.io` `40/box,` → `44/box {"Invalid namespace"}`. `POST /box/media` → nginx 405 (never reaches Nest).
  - 0 error lines since boot. Disk: 9.4 GB free.
  - Smoke 8/8 PASS with `--commit d37e2dcc`, run from the `fireplace` checkout, because mp has no playwright.
- **Old client (what users run) vs the new backend, after the deploy.** Throwaway worktree at `d37e2dcc` (web 0.2.50) against staging with the prod image (`ec69e7a5`, same code as `14c1f22d`):
  - The old client's own `test_e2e`: 44 passed, 14 skipped, 2 failed. Both failures are its "legacy plaintext emoji reaction" test and the error event that test causes. The server has refused plain emoji since `84d9608d` (2026-09-19, D10), which was already on prod in `9e621f63`. `chat.dto.ts` and the reaction service are identical between the two, so this is not from today.
  - Browser: the old web build served on :8090/:8091, two accounts. A message went through, decrypted and got a reply, with ✓✓ read receipts. 0 server errors during the drive.
  - PR0.2 push behaviour with a real Web Push subscription (FCM endpoint, staging VAPID):
    - App visible on the chat list: badge only, no notification.
    - App closed (page left): notification "g4alice | 4 new messages".
    - App backgrounded (`visibilitychange` → hidden): notification "5 new messages".
    - Control: a direct `web-push` send from the container showed up in the SW.
- NOT verified: a real message push on PROD (needs the owner's device); Android push (dev/staging have no FCM service account, and the APK is built for prod only); the FCM box notifier; iOS.

## Notes for next session
- **Owner-owed:**
  - Send one message to a backgrounded or closed app, to confirm the push still arrives on prod.
  - The next `deploy-web.ps1` from master ships ALL the undeployed frontend work (Phase 2a + storage-loss Part A + PR0.2 client + dark box client). It needs its own gate and the ordinary-login device re-drive (task_plan G2 note).
  - Still open: the 16 MiB box file cap; `deleteQueue` → `auth_failed` meaning "gone"; I2b.
- **PR3.1 prerequisites before `BOX_ENABLED` flips on prod** (task_plan §5 G4 block):
  1. A global byte/row ceiling.
  2. A per-socket rid cap.
  3. Media refusals counted in the abuse counters.
  4. nginx `location /box/`, tracked conf first.
  5. A decision on the media-quota liveness oracle.
- Review items left as judgement calls: the e2e user-id row check skips `box_media`/`box_notifiers`; duplicated `BoxResult` re-typing; the copied throttler adapter; the module-global refusal map; the `'no key bundle'` string match.
- Traps → `docs/agents/traps.md` (8 lines, this file).
