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
- Re-drive with subscribe attribution (fresh local stack, Postgres `log_statement='all'`, every statement read through its `DETAIL` line). Signals:
  - `markSubscribed` (`UPDATE public.box_queues` + `touchedDay`) = a subscribe;
  - `SELECT rid, id FROM (` (pendingHeads) = a delivery pass for a live socket slot;
  - `SELECT q.nid` = `handleDisconnect` detaching a slot.
- Web (release build `fix234`):
  - D on `localhost:8081`, B on `127.0.0.1:8080`, friends with one message each way;
  - D's tab truly closed: `SELECT q.nid` on its 3 rids, so the slot detached; D revoked; B sent one more, with no pendingHeads (no owner);
  - D reopened in a new tab: notice and `wylogowano: device_revoked`; 3 ownership checks plus 3 `WITH gone` on exactly D's 3 rids; **0 `markSubscribed`, 0 pendingHeads**; `box_queues` 7 → 4, `box_msgs` 1 → 0.
- Android (debug APK, Pixel_7):
  - C and B friends; C force-stopped: `SELECT q.nid`, the slot detached; C revoked; B sent one more, with no pendingHeads;
  - C started: same notice and footer; 3 deletes; **0 `markSubscribed`, 0 pendingHeads**; `box_queues` 8 → 5, `box_msgs` 1 → 0.
- The first drives' 2 pendingHeads are explained. "Closing" with `goto('about:blank')` left A's old page alive (bfcache), still connected:
  - B's send handed it the message (pendingHeads at 23:01:15, before A reopened);
  - the new boot's `deleteQueue` → `delivery.forget` → `release` → `pump` on that old slot ran the pendingHeads;
  - the new boot itself sent no `markSubscribed`.
  - So `about:blank` is not a closed device: close the tab.
- NOT verified: a passcode-locked web vault (expected: `BOX_REVOKED_RETIRE_SKIPPED`, queues left to #208), iOS PWA, prod.

## Notes for next session
- Next action: released as 0.2.82; see `2026-11-10-release-0282.md`.
- Owner-owed: the metadata close-out proposal above; release B ≥ 12-08; do83rman's iPhone log; throwaway prod accounts (list in `NEXT.md`).
- Drive recipe: two web accounts in one managed Chromium need two origins (`localhost` vs `127.0.0.1`, or another port), both allowed by dev CORS. "Closed" = close the tab (`goto('about:blank')` keeps the page alive in bfcache with its sockets connected). Revoke = `update devices set "revokedAt"=now() where "userId"=N`; a revoked device cannot log in again on the same install. Box traffic shows only with `alter system set log_statement='all'`: read each statement through its `DETAIL` (`awk '/LOG:  execute/{p=1} p; /DETAIL/{p=0}'`). Queue delete = `WITH gone AS (`, subscribe = `markSubscribed` `UPDATE public.box_queues` + `touchedDay`, delivery = `SELECT rid, id FROM (`, detach = `SELECT q.nid`.
