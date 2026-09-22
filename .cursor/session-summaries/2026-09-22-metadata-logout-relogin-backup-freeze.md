# A logout then login froze the contact backup until app restart — fixed, proven on the owner's iPhone

**Date:** 2026-09-22 · **Version:** unchanged (prod web `0.2.50`/`d37e2dcc`, backend `0.2.51`/`9e621f63`) · **Tiers deployed:** none

## What was done
- `connection_provider.dart:428` — `backup.attach(store)` now re-arms the store hook on EVERY session. `AuthProvider.logout` (`auth_provider.dart:434`) calls `ContactBackupService.clear`, which drops `_store` and nulls `store.onChanged`; re-login only calls `onSession`, and `attach` was reachable ONLY from `setProviders` (`:150`) at widget build. Any logout→login in one app instance left the service storeless: `uploadNow` bailed at `contact_backup_service.dart:411-413` and mutations notified nobody. Silent freeze until app restart. Shipped to `master` at G2.
- Placed OUTSIDE the `isOpen` gate on purpose: `attach` never reads the store, so gating it would re-freeze any session whose open overshot `kContactStoreOpenBudget` (4 s) — the same bug twice.
- `contact_backup_service_test.dart` — 3 tests: re-login-after-logout (regression, asserts through `onChanged`, not a hand `uploadNow()` call), token-resumed session (no password) publishes, local-graph-ahead republished on login (characterisation, green on first run).
- `_ios_drive/nginx.conf` + `api_proxy.conf` (OUTSIDE the repo) — rig fixes: upstream pinned to the compose-network service name `backend:3000` (IPv4-only), and `proxy_set_header Origin "";`.
- Reverted a `dart format --line-length 80` mistake that reflowed 184 lines of unrelated pre-existing code; re-applied by hand (56 insertions, 0 deletions).

## Key files
- Edited: `frontend/lib/providers/connection_provider.dart` (1 line + comment), `frontend/test/services/contacts/contact_backup_service_test.dart` (+56), `scripts/smoke/post-deploy-smoke.mjs` (`/notes` probe, `2ab9265c`).
- New: none in-repo. `C:/Users/Lentach/Desktop/_ios_drive/{nginx.conf,api_proxy.conf}` (rig, untracked by design).
- Read only (load-bearing): `contact_backup_service.dart` (`:165-170` idempotent `attach`, `:377-385` debounce, `:410-465` upload guards, `:619-668` `_adopt`), `auth_provider.dart:101-142` (`classifyAuthFailure`), `conversations_provider.dart:96-112,673-705`, `backend/src/main.ts:78-101` (dev CORS), `.planning/metadata-privacy/task_plan.md:37-38`.

## Verification
- `flutter test` full suite at `177e8032`: **2297 passed / 14 skipped**. Backup suite at `12d9ec3d`: **28/28**. `dart analyze` on both edited files: 0 issues inside the edited ranges, 0 errors/warnings.
- Mutant: deleted only `backup.attach(store);` → `a re-login after logout still publishes later changes` fails `Expected: true, Actual: <false>`; file restored byte-identical. First red was for the WRONG reason (the second `connect()` was swallowed by the cooldown at `:310-319`) — re-established with `immediate: true` before trusting it.
- **Live drive, owner's iPhone PWA on build `177e8032`** (rig tunnel, same-origin): logout `16:01:56` → login `16:02:04` → mute via avatar→user tile (`chat_detail_screen.dart:533`) → `PUT /backup/contacts` ×2, **`contact_backups.rev` 16 → 18**, and `conversation_notification_preferences` row (viewer 114, conv 35, 8 h). The `PUT` at `16:11:31`, before the mute, was the session republishing drift — the characterisation test's path, observed live.
- Restore re-proven on hardware: `CONTACT_BACKUP_RESTORED {count: 2}` with `BOOT_MARKERS {ls/idb/cache: absent}`, landing before `IDENTITY_MINTED`. `STORAGE_PERSIST {supported: true, granted: true, quota: 41231686042}` — `persist()` IS granted on the iOS PWA.
- **NOT verified:** CI never ran (`12d9ec3d` has **0 check-runs**; no open PR). Run C (phrase restore, keys match) never driven. Android, prod, and the 15-commit frontend deploy surface (incl. the whole update-banner feature) all untouched.

## Notes for next session
- **Owner parked the deploy**: keep everything local until the programme is finished. `master` stays `2ab9265c`; the fix is branch-only on `feat/metadata-privacy` (`12d9ec3d`).
- **Owner-owed:** close Phase 2a (decide S1/S2, route `storage_loss_screen.dart:73` to the phrase restore — it offers only the file restore today, so the loss screen never reaches the one path that preserves keys — and drive Run C) **or** take PR0.2 and carry 2a's deferrals as debt. Plan order is `PR0.2 → PR1.0 → G3 → PR1.1…` (`task_plan.md:37-38`); PR1.0 is NOT next.
- Wrong theories, do not re-investigate: dead tunnel; "every 304 GET session is broken" (a 304-resolved session published fine); "a dead debounce timer strands the change forever" (the test written to prove it passed immediately); "the owner used a non-emitting mute control".
- Traps (each appended to `traps.md`): `ci.yml` fires only on `push: master`/`pull_request`, so a branch push with no open PR yields 0 check-runs; `frontend/build/web` can hold a rig bundle with a tunnel `BASE_URL` baked in; `deploy-web.config.ps1` is gitignored/per-checkout and absent here, and a missing `GIPHY_API_KEY` silently ships GIF search disabled; a hand `uploadNow()` call in a test cannot see a dead `onChanged`; `connect()` swallows a second call inside the reconnect cooldown, so a two-session test proves nothing; `host.docker.internal` resolves IPv6-first and nginx 500s on the unroutable record; browsers send `Origin` on same-origin POST so the dev CORS allowlist 500s any tunnel host while curl-style probes pass; never `dart format` a shared file; `verify-context-budget.mjs --worktree` false-blocks on Windows CRLF — re-run it staged.
