# 0.2.77 backend: old clients' server-id chats opened empty after step 5; getMessages answers an empty page again

**Date:** 2026-11-06 · **Version:** backend 0.2.76 → 0.2.77 (`e3a44237`); web 0.2.76 and APK 0.2.76 unchanged · **Tiers deployed:** backend

## What was done
- Report (owner, ~16:40Z, about an hour after 0.2.76): in old-friendship chats the user reads and replies (✓), goes back, re-opens → zero messages while the chat-list preview still shows the last one; "all users".
- Cause: step 5 deleted the server's `getMessages` handler. A 0.2.75 web page (not reloaded since the deploy) or the 0.2.74 APK, opening a chat with a SERVER conversation id, emits `getMessages` and merges the chat's stored box messages only inside its `messageHistory` handler (`37187b90` `messaging_provider.history.dart:493,533`); with no answer the chat opens empty, live arrivals still show, re-open is empty again. Box-made chats (local ids) skip the server and were fine; 0.2.76 never asks the server and was fine.
- Fix (PR #218, owner: "Yes, ship the shim"): `ChatGateway.handleGetMessages` answers a positive int32 `conversationId` from an authenticated socket with `messageHistory {conversationId, messages: []}` (the reply the old server gave for a chat the caller was not in); anything else is silent. Reads and writes nothing; `getServedMessageIds` stays gone.
- `docs/contracts/wire.md` step 5 bullet: `getMessages` moved to "still served", `messageHistory` out of "never emits". Version 0.2.77 (backend only; web stays 0.2.76).
- Out of repo: repro fixture `%TEMP%/upgrepro` kept (pre-upgrade dump, Chrome profiles, `rerun-upgrade.mjs`); its worktrees, containers and `upg-backend:*` images removed, so a rerun rebuilds them first.

## Key files
- Edited: `backend/src/chat/chat.gateway.ts` (`handleGetMessages`), `backend/src/chat/chat.gateway.spec.ts`, `docs/contracts/wire.md`, `frontend/pubspec.yaml`, `CLAUDE.md` (792 tests).
- Read only: `37187b90:frontend/lib/providers/messaging/messaging_provider.history.dart`, `f3bdc1c9:backend/src/chat/services/chat-message.service.ts:602-638`.

## Verification
- CI: 7/7 on `193d9718` (PR #218); master merge `e3a44237`: Backend, Flutter, E2E wire, isolated probes, Web Lock probe, Analyze all success.
- Local: jest 792/47; build clean; backend lint ratchet at baseline 269.
- Upgrade-path repro on a dev stack (subagent): old-path friendships on `f3bdc1c9` + 0.2.75 web, box on, timers 1 d and 2 d 6 h, upgraded to `8b240388`. 0.2.75 tab: open / re-open → "Brak wiadomości" (with or without a timer; socket shows `getMessages` OUT, no `messageHistory` IN; diag `HISTORY_REQ` without `HISTORY_RESP`). 0.2.76 tab: green incl. reload and forced reconnect. 0.2.75 tab against `193d9718`: green on open, back → re-open, and the full sequence.
- Owner's own PWA (footer 0.2.76, diag log without `HISTORY_REQ`) shows bob210's messages on re-open.
- Prod: `/version` 0.2.77 / `e3a44237`, healthy, 0 error lines 17:19–17:24Z; backup `chatdb-20261106T171824Z.dump.gpg` before the deploy.
- Ruled out on the way: record deletion (owner log `PLAINTEXT_SWEEP {expired: 0, retired: 0}`), store failures (no `DECRYPT_PERSIST_FAILED` / `BOX_SENT_STORE_UNPROVEN`), timers, `_cid` mismatch.
- NOT verified: a real prod user on a 0.2.75 tab or the 0.2.74 APK after the shim (owner relay).

## Notes for next session
- Next action: owner relays one user still on an old tab or the 0.2.74 APK (e.g. ol321654) opening an old-friendship chat.
- The shim stays until no pre-0.2.76 client remains; remove it then (and the wire.md line).
- Traps: removing a server handler breaks every client still on an older bundle (`docs/agents/traps.md`, Deploy).
