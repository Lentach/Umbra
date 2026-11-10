# No box subscribe before the session is confirmed: a device revoked while away takes nothing from its queues (#206)

**Date:** 2026-11-10 · **Version:** unchanged (0.2.80 live; fix on PR #233 `8d806391`, not released) · **Tiers deployed:** none

## What was done
- New PC (`C:/Users/olek2`): `gh auth login` redone; Android SDK in `F:\Android\Sdk`; AVD `Pixel_7` in `F:\Android\avd`; Docker Desktop theme dark (`ThemeSource`, `%APPDATA%\Docker\settings-store.json`); stale worktrees pruned; `fireplace-hotfix` re-added as a worktree (copy kept as `fireplace-hotfix.old-pc`).
- #206 cause: every box (re)connection re-signs its whole subscribe set at once — its own backoff, `connect()`'s `resume()`, `onE2EReady` → `start()` at a cold start, `checkAlive`'s replacement on a resume — before the account socket's connect gate can answer `deviceRevoked`.
- Fix (`box_client.dart`): `holdSubscribes`/`releaseSubscribes` — while held no `subscribe` frame goes out; a connection that comes up waits (`_heldConnection`) and asks `onHeldConnection`; a new `subscribe` answers offline and, on a connection that stayed ready, goes out at the release; `holdOnLoss` holds at every lost connection; `forget`/`forgetAll` drop held queues. Transport and backoff unchanged.
- Wiring: `ConnectionProvider` holds a new `BoxSession` and `confirmSessionWith(_confirmSessionForBox)`; `accountLost` holds; `accountReady` and `accountAnswered` (`_onServerTime`) release; `_confirmSessionForBox` runs the liveness probe (`_probeAccountLiveness`, extracted from the resume resync) when the account socket claims ready; `retireRevokedDevice` `forgetAll`s, stops holding on loss, releases.
- Iterations the same day: close-on-account-loss (`27cb82ab`, replaced: cycled live box connections, decision 76) → subscribe hold (`268e08cd`) → review fixes (`14990453`: resume gap, `forgetAll`) → hold on every lost box connection (`8d806391`, Android drive found a backoff reconnect under a silent-dead account socket).
- Code review skill run (standards + spec in parallel); findings fixed red-first.
- Docs: `wire.md` #206 bullet + corrected revoked-while-closed sentence, E29a (3) and residuals, trap line on box tests, `CLAUDE.md` 3264.
- Out-of-repo: PC setup above only; local stacks `d206w`/`d206a` were throwaway and are down.

## Key files
- Edited: `frontend/lib/services/box/box_client.dart`, `frontend/lib/services/box/box_session.dart`, `frontend/lib/providers/connection_provider.dart`, `frontend/test/providers/connection_provider_box_test.dart`, `frontend/test/services/box/box_client_test.dart`, `docs/contracts/wire.md`, `docs/plans/metadata-privacy-decisions.md`, `docs/agents/traps.md`, `CLAUDE.md`.
- Read only: `backend/src/chat/chat.gateway.ts` (connect gate), `box_friend_handoff.dart`, `queue_keys.dart` (subscribe callers).

## Verification
- CI: 7/7 success on `8d806391` (PR #233).
- Red first on master (reconnect and cold start subscribed before the gate); 17 mutants killed across the commits. flutter 3264 passed / 14 skipped (count gate OK); analyze 0 warnings/errors; dart ratchet at baseline 2494.
- Web (release builds, own stack, CDP frames, revoke by Postgres `revokedAt`; slow gate = 12 s `LOCK TABLE devices`): master subscribed 3 rids 12 s before `deviceRevoked` on reconnect and cold start; fix none, 3 `deleteQueue`, notice; resume with silenced sockets: `268e08cd` subscribed 4 s early, `14990453` none; live paths render; an account-only drop keeps the box connection with no new subscribe. Final round on `8d806391`: box lost under a silent-dead account socket — revoked: probe unanswered, no subscribe, `deviceRevoked`, 3 deletes, notice; live: subscribe right after `serverTime`, messages render; resume W4/W5 and the slow gate pass.
- Android (debug APK, `Pixel_7`, own stack, TCP proxy to cut/delay/silence; ring via `flutter attach`; deliveries via Postgres statement log): master consumed and rendered the waiting messages with the gate held 8 s; on `8d806391` the silent-dead-account box reconnect subscribed nothing, probe timed out, `deviceRevoked`, `{held: 3, owed: 0}`, notice; live box reset subscribed 12 ms after `serverTime`; 60 s background + resume and the 8 s gate pass.
- NOT verified: a real revoke from the Devices screen; iOS PWA; a real page freeze / phone background freezer.

## Notes for next session
- Next action: owner's go to merge PR #233 and ship it (web + APK) as 0.2.81, or hold it for the next release.
- Found, not #206 (same on master): a revoked device that cold-starts ONLINE signs out over REST (`GET /users/me` 401, refresh `Device revoked`) before any socket — no revoked notice, queues kept until that install signs in again (#208). Owner call whether to act on the refresh's `Device revoked` at boot.
- Left (wire.md, E29a): a box connection that stayed up while the account socket was down keeps taking deliveries until `deviceRevoked`; the retire's one pass owes (`boxgone_v1`) a delete whose connection drops (Android R2c).
- `_confirmSessionForBox` writes no diag line: a probe after a box reconnect shows only as `RESUME_PROBE_TIMEOUT` when it times out.
- Observed on web: after an account-only drop the app opened a second account connection ~100 ms after `socketReady`; not investigated.
- Drive recipes: slow gate = `LOCK TABLE devices IN ACCESS EXCLUSIVE MODE` ~12 s; Android `svc wifi/data disable` does not cut an `adb reverse` app — use a TCP proxy that drops/delays/silences; the debug APK prints no `[E2E-FLOW]` to logcat (read the ring via `flutter attach`); box traffic is visible only in Postgres statement logs (server logs no queue ids).
- Leftovers: `fireplace-hotfix.old-pc` (nothing unique), `fireplace-062`/`fireplace-p4s5` (old batons), `fireplace-mp` (unique `.planning/` dirs + `.env.staging`: copy before deleting).
- Traps: the box-test line in `docs/agents/traps.md` now says tests must serve `socketReady`.
