# A refresh answered `Device revoked` now signs out with the revoked notice and deletes the install's queues (#234)

**Date:** 2026-11-10 · **Version:** unchanged (0.2.81 live; fix on PR #238, not released) · **Tiers deployed:** none

## What was done
- `ApiService.refreshSession`: `401 {message: 'Device revoked'}` throws `SessionRefreshInvalidException.revokedDevice()` (`deviceRevoked: true`); every other refusal is unchanged.
- `AuthProvider._endRefusedSession`, used by both boot phases and `ensureSessionReady`:
  - a revoked refusal signs out with reason `device_revoked` and `AuthStatusCode.deviceRevoked`, mapped to `deviceRevokedNotice` in `auth_status_text.dart`;
  - it hands the account over through `takeRevokedDeviceAccount()`, but only while the stored refresh token is still the refused one.
- `AuthGate` (`main.dart`) takes the account and calls `ConnectionProvider.retireRevokedInstall`:
  - if this launch holds that account's box, it uses #205's `_retireOwnQueues`;
  - otherwise it opens its own `ContactStore` on `enc.encryptionService.contentKv` and an unstarted `BoxSession` that runs `retireRevokedDevice` (it deletes and subscribes nothing), then closes the store;
  - `connect` waits for it before it opens its own store.
- Docs: `wire.md` revoked-device bullet; E29a clause (4) and its residuals; `CLAUDE.md` test count 3268.
- Owner's question "are we done with metadata?" was answered in chat: close the series after release B (≥ 12-08); move decisions 90, 105/110 and 124 to the ordinary backlog. The owner has not answered yet.
- Out-of-repo: Docker Desktop started; the local stack `d234` was brought up and removed with `down -v`; the emulator was started and stopped, and the debug APK uninstalled. Nothing is left running.

## Key files
- Edited: `frontend/lib/services/api_service.dart`, `frontend/lib/services/session_refresh_exception.dart`, `frontend/lib/providers/auth_provider.dart`, `frontend/lib/providers/connection_provider.dart`, `frontend/lib/main.dart`, `frontend/lib/l10n/auth_status_text.dart`.
- Tests: `frontend/test/providers/auth_boot_test.dart` (3 new), `frontend/test/providers/connection_provider_box_test.dart` (1 new), `frontend/test/screens/auth_screen_theme_test.dart` (new code mapped).
- Docs: `docs/contracts/wire.md`, `docs/plans/metadata-privacy-decisions.md`, `CLAUDE.md`.

## Verification
- CI: success 7/7 on `2fefa038` (PR #238 head; the code commit `7f2503d3`'s run was cancelled by that docs push).
- Red first: both revoked-boot tests failed on `statusCode` null before the change. Mutants killed:
  - the retire dropped from `retireRevokedInstall`;
  - `_namesDeviceRevoked` → false;
  - the hand-over dropped.
- flutter 3268 passed / 14 skipped (count gate OK); analyze 0 warnings/errors; dart ratchet at baseline 2494 (one new `directives_ordering` fixed).
- Web drive (release build `fix234`, local stack, two origins `localhost:8080` / `127.0.0.1:8080`):
  - setup: A and B friends, one message each way; A's tab to `about:blank`; `devices."revokedAt"` stamped for A; B sent one more;
  - A reopened: login screen with "To urządzenie usunięto z konta. Zaloguj się i połącz je ponownie.", footer `wylogowano: device_revoked`;
  - `box_queues` 6 → 3, `box_msgs` 1 → 0; Postgres statement log showed 3 `WITH gone` deletes. It also showed 2 `SELECT rid, id FROM (` (pendingHeads, run on a subscribe/delivery), whose rids were not checked before the stack was removed, so "A subscribed nothing" rests on the unit test (`subscribe` frames 0), not on this drive.
- Android drive (debug APK, Pixel_7, `10.0.2.2:3000`): C (app) and B (web) friends; C force-stopped, revoked; B sent one more; C started → same notice and footer; `box_queues` 7 → 4, `box_msgs` 1 → 0, 3 deletes (the log filter used would not have shown a pendingHeads query, so subscribes are unchecked here too).
- NOT verified: a passcode-locked web vault (expected: `BOX_REVOKED_RETIRE_SKIPPED`, queues left to #208), iOS PWA, prod.

## Notes for next session
- Next action: once CI on #238 is green, the owner decides whether to merge and ship it as 0.2.82 (web + APK; backend unchanged).
- Owner-owed: the metadata close-out proposal above; release B ≥ 12-08; do83rman's iPhone log; throwaway prod accounts (list in `NEXT.md`).
- Drive recipe: two web accounts in one managed Chromium need two origins (`localhost` vs `127.0.0.1`, both allowed by dev CORS); "closed" = `goto('about:blank')`; revoke = `update devices set "revokedAt"=now() where "userId"=N`; box traffic shows only with `alter system set log_statement='all'` — TypeORM statements are `execute <unnamed>:` lines, and a queue delete is `WITH gone AS (`.
