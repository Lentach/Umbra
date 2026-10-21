# Phase 4 step 3 built and deployed OFF: `LEGACY_WRITES_FROZEN` refuses new old-path messages, friend requests and chats

**Date:** 2026-10-21 · **Version:** unchanged (0.2.68; backend redeployed at `0b03d64f`, flag `'false'`) · **Tiers deployed:** backend

## What was done
- `backend/src/chat/utils/legacy-freeze.ts`: `legacyWritesFrozen(config)` (`=== 'true'`, unset = open) and `LEGACY_FROZEN = 'legacy_frozen'`. `env.validation.ts` takes only `'true'`/`'false'`.
- Frozen refusals:
  - `ChatMessageService.handleSendMessage`: `error legacy_frozen`, before any read.
  - `ChatFriendRequestService.handleSendFriendRequest` / `handleAcceptFriendRequest`: `friendRequestFailed reason legacy_frozen`, after DTO validation.
  - `ChatConversationService.handleStartConversation` and `handleEnsureInvitationChat`: `findByUsers` instead of `findOrCreate`, so an existing chat still opens and a missing one is refused.
- `docker-compose.prod.yml` pins `LEGACY_WRITES_FROZEN: 'false'` (the flip is a reviewed commit). Dev compose: `${LEGACY_WRITES_FROZEN:-false}`.
- Scope came from a read-only write-path inventory (agent `OldTableWriteMap`) and prod `SELECT`s:
  - only old-path messages are still written (bob208 ↔ R0yb3r, 13 rows 10-06…10-11);
  - reaction keys idle since 09-25, 0 mute rows, 0 `blocked_users` rows;
  - 0 friend requests since 08-24, 0 chats since 09-01.
  - So everything else stays open (E111a).
- Decisions log: E111a scope, E111b no update channel needed, E111c flip only after 7 days with no new `messages` row. Plan step 3 marked BUILT.
- Dev DB seeded for the drive and left in place:
  - `friend_requests` 95 (p4alpha 261 ↔ p4bravo 262) and 96 (d101a 253 ↔ d101g 255);
  - `conversations` 79 (261 ↔ 262);
  - `messages` 1045 (`frozen-ui-1`, sent after the flag went off).
- Out-of-repo: Chrome on CDP 9461 (profile `%TEMP%/d101drive/prof`), node static server `%TEMP%/d101drive/serve.mjs` serving `%TEMP%/p4s3` on 8091/8094/8095/8096, both left running. Dev backend restarted twice (flag `yes`, then `true`), now back to `false`.

## Key files
- New: `backend/src/chat/utils/legacy-freeze.ts`.
- Edited:
  - `chat-message.service.ts`, `chat-conversation.service.ts`, `chat-friend-request.service.ts` and their specs;
  - `config/env.validation.ts`, `docker-compose{,.prod}.yml`;
  - `docs/contracts/wire.md` ("Old-path freeze"), `backend/CLAUDE.md`, root `CLAUDE.md` counts;
  - decisions log, plan doc.

## Verification
- CI: green on `316fc600` (all six jobs, master push); tip `0b03d64f` is docs-only (CodeQL only, green).
- Prod (owner: "Deploy now, switch off"): `deploy-backend.sh` → `/version` 0.2.68 / `0b03d64f`, healthy, `LEGACY_WRITES_FROZEN=false` in the container; 0 error and 0 `legacy_frozen` lines in the first 2 min; newest `messages` row still 2026-10-11 20:40Z (107 rows).
- 7 new tests (send, start ×2, friend send, accept, ensure ×2), all red with the predicate mutated to never match, green with it. Backend 1249 tests, 70 suites (count verified). Backend ESLint ratchet 850 (the first run was 851: a redundant `as Message` in the new spec).
- Dev stack, release web build `p4s3` (HEAD 0.2.68):
  - `LEGACY_WRITES_FROZEN=yes`: boot refused ("must be one of the following values: true, false").
  - `=true`: p4alpha still got `friendsList` and `conversationsList` with the frozen rows.
  - A raw `sendMessage` on its own socket got `error legacy_frozen`; `startConversation` to p4bravo got `openConversation {79}` plus its history; d101a's `startConversation` to d101g (no chat) got `error legacy_frozen`. Messages stayed 590 and chats 76.
  - In the UI, p4alpha's chat shows "p4bravo ma starszą wersję aplikacji"; a typed send went red with "Ponów", no row stored.
  - Flag off again: tapping "Ponów" sent it (✓, row 1045).
- NOT verified: the rehearsal (prod dump, 0.2.61 APK, PWA), Android, the flag ON in prod.

## Notes for next session
- Next action: the step 3 rehearsal on staging, when the owner is ready ("Later", 10-21): `staging.ps1 up` → `restore chatdb-20261021T010125Z.dump.gpg` → backend with `LEGACY_WRITES_FROZEN=true` → APK 0.2.61 built against staging + a PWA + 0.2.68; pass criteria plan line 55. The restore needs the OWNER to type the backup passphrase (traps "Never pipe a plaintext prod pg_dump").
- Owner-owed:
  - the passphrase for the rehearsal;
  - the flip itself, only after a POSITIVE check (E111c): bob208 sends R0yb3r a message and R0yb3r replies on 0.2.68, both arrive, and `select max("createdAt") from messages` stays at 2026-10-11 20:40Z. A quiet week alone proves nothing (R0yb3r has only legacy device 1);
  - jarekk and qwerty backups before step 4 (decision 111);
  - the before-step-4 list.
- Trap (not new): a background tab in the drive Chrome does not boot the app; `page.bringToFront()` before reading it.
