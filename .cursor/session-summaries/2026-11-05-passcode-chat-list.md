# 2026-11-05 — Chat list empty after a passcode unlock; SaraLee checked

Branch `fix/passcode-chat-list` (off master `0f63fb75` = #211 merged). **Version:** 0.2.73 (web, rolled back) → 0.2.75 · **Tiers deployed:** web (owner: "Merge #212 and deploy web 0.2.75 now").

## What happened
- A web session that BOOTS with the passcode vault locked finds the contact store locked at `connect` (`CONTACT_STORE_UNAVAILABLE {stage: locked}`), so the lists never hydrate. The unlock (`PasscodeProvider.unlock` → `E2eLockRevoker.restore` → `EncryptionProvider.restoreAfterPasscodeUnlock` → `onPasscodeLockRestore`) re-opened the store but only called `rewriteStore`, a no-op without a server snapshot. Prod's lists are silent, so the Czaty list read "Brak czatów" for every web passcode user (0.2.73 too). Kontakty still showed box friends, because its getters read the store.
- Dev stack with `LEGACY_LISTS_SILENT=false` shows a second shape: an empty `conversationsList` lands while locked (`CONV_LIST {count: 0}`), `hydrateFromStore` then skips (`_conversationsListReceivedOnce`), and the box-made chats are missing because they only live in the store.

## What was done
- `ConnectionProvider` `onPasscodeLockRestore`: after `rewriteStore`, `hydrateFromStore` on both providers, `onBoxContactsChanged` and `refreshLocalChats`. All are no-ops after a mid-session re-lock (RAM lists already full).
- Tests: `contact_store_hydration_test.dart` group "a session that booted locked": silent lists (friends + chats from the store) and a server list landing while locked (box chat merged back). Both red without the fix (`[frank]` vs bob/carol/frank; `[10]` vs `[10, frank]`), green with it.
- Docs: `frontend/docs/e2e-invariants.md` (contact-store invariant, restore hydrates), `docs/agents/traps.md` (Auth).
- SaraLee (63), server read-only, 12:55Z: bob's queue `3b446aef…` `touchedDay` 2026-11-05, `msgCount` 0, no `box_msgs` (it was 10-31 with 3 msgs before). She has exactly ONE friend (`friend_requests` id 46, bob208, accepted 05-18) and one device, so `BOX_ROUTES {friends: 1}` is correct, not a lost graph. Drained = journaled and acked (`box_inbox.dart` acks after the journal write), not proof of decrypt. Quiet msgs at 12:02–12:41Z sit in two queues touched today (unattributable by design; consistent with her receipts to an offline bob).

## Key files
- `frontend/lib/providers/connection_provider.dart` (`onPasscodeLockRestore`)
- `frontend/lib/providers/conversations_provider.dart` (`hydrateFromStore`, `refreshLocalChats`, unchanged)
- `frontend/test/providers/contact_store_hydration_test.dart`

## Verification
- Before (0.2.73 build, dev, account `pca664` with 2 box friends, passcode 258036): reload + unlock → "Brak czatów" (screenshot), durable log `CONTACT_STORE_UNAVAILABLE {locked}`, `BOX_ROUTES {friends: 2, routed: 2}`.
- First fix (hydrate only), same account, lists not silent: still "Brak czatów". The live log showed `CONV_LIST {count: 0}` while locked, which found the second shape.
- Final fix, lists not silent: reload + unlock → Czaty lists pcc1747 and pcb664 with their last messages.
- Prod flags (`LEGACY_WRITES_FROZEN=true`, `LEGACY_LISTS_SILENT=true` on the dev backend): reload + unlock → live log `CONTACT_STORE_UNAVAILABLE {locked}`, no `CONV_LIST`, `E2E_RESTORE_UNLOCK` → `SIG_SEAL_OPEN` → `E2E_INIT_DONE`; Czaty lists both chats.
- Suites: `flutter test` 3346 passed / 14 skipped; `flutter analyze` 0 errors or warnings (3130 infos = baseline).
- CI: 7/7 success on `6fab94b9` (PR #212); master merge `37187b90` 6/6 success (CodeQL not run on the merge commit).
- Prod deploy: `deploy-web.ps1` from a throwaway worktree at `37187b90` → `PUBLISHED_OK`; `post-deploy-smoke.mjs --commit 37187b90` 8/8; `/version.json` 0.2.75/37187b90, `/version` 0.2.74/f3bdc1c9; backend logs 10 min after: 0 errors, `healthy`. Verified on prod after the deploy (owner relay): SaraLee, a web passcode user, sees the owner's messages and replies; her Settings footer reads `0.2.75 · 37187b90`.

## Notes for next session
- Sara RECOVERED on 0.2.73 (owner relay, 11-05 ~13:30Z): she sees bob208 (her only contact), can send messages and send invitations. Server agrees: her 12:02Z frames drained by ~13:25Z and three quiet frames (receipts) came back into her queue at 13:25:55Z.
- Next action: Phase 4 step 5 (PR #210, `fireplace-p4s5`) — merge master, bump to 0.2.76, CI, and the owner's go no sooner than 24 h after this release (decision 132).
- Cleanup done: dev stack `hotfix` down, worktrees `rb0273`/`b0274`/`d0275` removed, VM `~/frontend-build.0274` removed.
