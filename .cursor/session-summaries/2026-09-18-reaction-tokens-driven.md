# Driving `feat/reaction-tokens` for the first time broke it twice — a relaunch could not name its own chips

**Date:** 2026-09-18 · **Version:** unchanged (prod stays `0.2.48 / eefc44b0`) · **Tiers deployed:** none

## What was done
- `messaging_provider.history.dart`: re-resolve reactions after BOTH snapshot installs (`_reRenderReactions(convIdForMerge)` and the pagination path). The key acquisition kicked off at ingest reads the LOCAL store, so on a cold entry it completes during `await hydration` — before the rows reach `_messages` — and burned its one latched attempt on an empty list.
- `messaging_provider.decrypt.dart`: `_withRenderableReactions` now wraps the decrypt-pass merge. `_mergeMessagePreferNewer` returns `server.copyWith(...)`, so the RAM decryption cache's stale reactions map won and reverted an already-named chip. This is why INBOUND rows stayed placeholders while the reader's own rows resolved.
- `staging.ps1` `harness`: exports `E2E_DB_CONTAINER = fireplace-staging-db-1`. It only exported `E2E_BASE_URL`, so `e2eSql` hit its `fireplace-db-1` default — the DEV stack.
- `frontend/test/providers/messaging_provider_events_test.dart`: new test "a relaunch names its chips from the LOCAL key, with no round trip". One added test was DELETED instead of kept — see Verification.
- `CLAUDE.md` §3: 2196 → 2197 tests; harness re-measured 2026-09-18; documented the `E2E_DB_CONTAINER` trap inline.
- No merge to `master` and no deploy: the owner stopped the merge. `origin/master` is still `cf14afc4`; the branch is 9 (now 10) ahead / 5 behind and the ONE conflict is `docs/design/reaction-privacy.md` §4 rows 5-7 (master's `f70f1ca3` vs the branch's implemented owner ruling — row 6's "self-heal by re-keying" is what the epoch-0 rule forbids).

## Key files
- Edited: `frontend/lib/providers/messaging/messaging_provider.{history,decrypt}.dart`, `frontend/test/providers/messaging_provider_events_test.dart`, `staging.ps1`, `CLAUDE.md`.
- Read only (load-bearing): `services/reactions/reaction_{token_codec,display,key_service}.dart`, `messaging_provider.dart` `_renderableReactions`/`_reRenderReactions`/`_fetchReactionKeyOnce`, `decrypt.dart` `_hydrateSnapshotFromCaches`, `backend/migrations/0018_reaction_keys.sql`, `docs/contracts/wire.md` (Reactions).

## Verification
- Isolated staging stack (`staging.ps1`, `:3100` / db `:5533`, prod-mode image at `ac2a155c`, own volumes) — the dev stack `:3000`/`:5433` was another session's and stayed untouched. `0018` applied by the migration runner at boot; the manual `staging.ps1 sql` replay was a no-op, so the migration's legacy-wipe GUARD works.
- **Chrome, two accounts on two origins:** register → invite → accept → E2E message → react → peer render → relaunch. `messages.reactions` held `{"iztFf2sjk_f7WS5z1XbSng":[12]}` — 22-char base64url, never an emoji; one `reaction_keys` row (conv 4, user 11 device 1, epoch 1, sender 12); `conversations."reactionKeyEpoch"` = 1. Tokens verified against an independent HMAC computation (👍/❤️/😂/🔥 all matched).
- **The bug:** after reload both chips rendered `• 1` while `flutter.e2e_11_rkey_v1_4` sat in localStorage and live reactions resolved fine. Falsification R7 failing in practice. Fix 1 resolved own rows; inbound rows needed fix 2 — proven by browser A/B (reverting `decrypt.dart` alone puts the placeholder back).
- **Mutant:** without the `history.dart` fix the new test fails `Expected: [2] / Actual: <null>`. A second test for the decrypt clobber PASSED with the fix reverted (the harness's hydration consumes the RAM cache one pass earlier, so no test can reach that branch) — it was deleted rather than kept as decoration. Fix 2's only evidence is the browser A/B.
- **Android emulator (Pixel_7, cold boot, `adb reverse tcp:3100`):** registered `carol175509`, accepted an invite, decrypted a real message, reacted 👍 → `{"h1XobPsvlX1bfVqClYz_Dw":[13]}` + a new mailbox row (conv 5, epoch 1, sender = the Android device). Peer render confirmed in Chrome. `am force-stop` + relaunch still rendered 👍 — R7 holds on secure storage.
- Gates at `0ea536ca`: `flutter test` **2197 passed / 14 skipped**; backend `npx jest` **1159 / 64 suites**; staging `flutter test test_e2e` **46 passed / 14 skipped**; `flutter analyze --no-fatal-infos lib test test_e2e` zero errors/warnings; `dart-lint-ratchet` PASS at 3166; backend `lint-ratchet` PASS (898→897); both count verifiers OK.
- **NOT verified:** iOS, prod, physical phone, push, and reaction REMOVAL by an agent (the owner removed one manually and reports it correct; my pixel taps kept missing the chip — ADD/replace was driven successfully on both surfaces).

## Notes for next session
- Owner-owed: the `master` merge (conflict above), the same-epoch top-up (a device linked after distribution shows placeholders indefinitely), the D10-closing commit that drops the plaintext branch, local fonts to drop `fonts.gstatic.com` from CSP `connect-src`.
- Reported, NOT fixed: `envelopeRefusal` validates envelope shape but never COVERAGE — a crafted client can advance the epoch with envelopes reaching nobody and blind the peer. Needs an `incomplete_fanout` refusal.
- Two statements from the mis-targeted harness ran against the dev DB before the fix; both matched ZERO rows (no `pending` resets; `recovery_keys` starts at `userId 113`) — nothing of the owner's was destroyed.
- Traps (also in `docs/agents/traps.md`): `E2E_DB_CONTAINER` defaults to the dev stack; machine-level env vars override `--env-file` in compose; PowerShell `>` corrupts `adb exec-out` PNGs; a resolved reaction map must survive every post-install merge.
