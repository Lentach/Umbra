# 0.2.88 on master: refresh tokens rotate, reuse of an old one ends the session (plan B4)

**Date:** 2026-11-17 · **Version:** 0.2.87 → 0.2.88 on master (PR #258, merged `aa45e290`) · **Tiers deployed:** none (the owner chose "merge, no deploy yet")

## What was done
- `backend/src/auth/refresh-tokens.service.ts` `redeem` replaces `consumeAndSlide`:
  - Tokens are `<sessionId>.<secret>`. `rotate: true` swaps the current token for `HMAC-SHA384(key from JWT_SECRET, token)`, deterministic, so a lost response's retry and racing refreshes get the same successor.
  - Reuse deletes the row (`reason=refresh_reuse`): an older token naming the session, or the replaced token sent without `rotate`.
  - Conditional UPDATEs on both the current-token and replaced-token paths; both slide the expiry. `Device revoked` comes first and keeps the row.
- Migration `0028_refresh_token_rotation.sql` adds `prev_token_hash` and its index. One row per session, no per-refresh history.
- `jwt-secret.ts` holds `resolveJwtSecret`, shared by `auth.module.ts` and the rotation key. `RefreshBodyDto.rotate` is optional (an older server strips it). `createToken` mints prefixed tokens.
- Client:
  - `AuthProvider._rotateRefreshTokens = !kIsWeb`; the flag is decided once per `_silentRefresh`.
  - `_refreshPersisted`: `AuthTokenStore.write` now returns `bool`, and the client does not rotate after a refused write.
  - `_endRefusedSession` compares sessions via `AuthTokenStore.refreshSessionOf`.
  - The wake-up probe sends `rotate: true`, and `sessionKey` hashes the session prefix.
- Docs: `backend/CLAUDE.md` §5, `wire.md` (new REST bullet, decision 130 bullet), `METADATA.md` sessions row, `runtime-reference.md` `JWT_SECRET`, `e2e-invariants.md`, `testing-and-ci.md` (integration suite 71), plan row B4 ✅, the traps Auth line, root `CLAUDE.md` counts.
- Out-of-repo: the `fireplace-staging` volumes were left in place (prod image, 0.2.88 schema, two `stg*` users). Worktree `fireplace-b4` removed; branch deleted locally and remotely; `dmed` and `b4pg` downed; emulator killed.

## Key files
- Edited: `backend/src/auth/{refresh-tokens.service,refresh-token.entity,auth.service,auth.controller,auth.module}.ts`, `dto/refresh-body.dto.ts`, `frontend/lib/providers/auth_provider.dart`, `lib/services/{api_service,auth_token_store,wake_up_revocation_check}.dart`, `test_e2e/auth_token_fault_injection_test.dart`.
- New: `backend/migrations/0028_refresh_token_rotation.sql`, `backend/src/auth/jwt-secret.ts`, `refresh-tokens.service.int-spec.ts` (13), `frontend/test/providers/auth_provider_rotation_test.dart` (4).
- Read only (load-bearing): `web-push-sw.js` (web never rotates, unchanged), `2026-07-04-session-sticky-sessions.md` (why single-use rotation was removed).

## Verification
- CI: PR 13/13 green on `a703bef3`; master 12/12 green on `aa45e290`.
- Backend: `npm test` 774/43; `npm run test:int` 71/3 (box 55, devices 3, refresh 13); backend ESLint ratchet 253 → 252 (`--update`); knip clean; no-user-logs OK.
- Frontend: `flutter test` 3299 passed, 14 skipped; Dart lint ratchet held at 2478; `test_e2e/auth_token_fault_injection_test.dart` green against a live local backend.
- Mutants, all killed:
  - Server: race read as reuse, no idempotent retry, no session delete, the replaced token accepted without rotate, no re-key, unconditional rotation UPDATE, unconditional replaced-token UPDATE, no slide on retry.
  - Client: no `_refreshPersisted`, whole-token `sessionKey`, string compare in `_endRefusedSession`.
  - The first race test passed vacuously, so it was replaced by a gated Proxy repo that forces both reads before either update.
- Reviews: B4Correctness (correct; 2 P3 nits fixed: replaced-token path conditional, session compare) and B4Contracts (9 drift items fixed, including the e2e test that would have failed CI).
- Device (local stack, debug APK on emulator-5556 through a response-dropping proxy on :3101):
  - Every cold boot rotated the token (one row, 10+ boots, two builds) and the app stayed logged in.
  - First response dropped: the retry got the same successor. All 3 attempts dropped: still logged in; the next boot re-presented the replaced token and got the same successor.
  - `searchUsers` answered after the rotations.
  - Web (Chromium): the token stayed the same across reloads. When an "attacker" rotated the stolen web token via curl, the tab's next start was refused (`refresh_invalid`) and the attacker got 401.
- Staging rehearsal (prod image):
  - At master: a legacy token was issued, and the old server ignored `rotate`.
  - At the branch: 0028 applied over existing data. The legacy token slid, then rotated into its row id, retried the same, and its reuse ended the session. Harness 33 passed (17 skipped).
- NOT verified: the Android wake-up probe on a real FCM wake (no FCM locally); prod; iOS; the owner's phone.

## Notes for next session
- Next action: when the owner says "release", run the recipe with versionCode 20088 (0.2.88). The backend deploy applies 0028.
  - After deploy, check `refresh_tokens.prev_token_hash` exists. Release-APK drive: cold boots rotate, the app stays signed in. Then close the app, send from web, and read logcat `[wake-up] revoked-device check: notRevoked`; reopen and confirm still signed in.
  - Watch `reason=refresh_reuse` in backend logs for a few days: legit clients should never produce it.
- Owner-owed: confirm the footer `0.2.87 · c04eac31`; store decision, privacy policy, ToS.
- Next plan items: D3 (box attachment delete route), C1 (link-preview image fetched by the sender), A4 rest (R2 lifecycle doc).
- Recipe, lost response on a device: build the debug APK with `BASE_URL=http://10.0.2.2:3101`; run a Node proxy :3101 → :3100 that, while `drops.txt` > 0, lets `/auth/refresh` reach the backend but destroys the client socket (WebSocket upgrades piped raw).
- Trap: native refresh tokens rotate (traps.md Auth, added in the PR).
