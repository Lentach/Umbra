# Item 5: existing friendships move onto the box, with a composer notice until the friend is covered

**Date:** 2026-09-26 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only)

## What was done
- Owner answers: O15 → (a) handoffs over the friend's REQUEST queues, O16 → (a) one line above the composer (decisions 47–48; engineering E20a–g in `docs/plans/metadata-privacy-decisions.md` and `docs/plans/2026-09-25-metadata-pr31-remainder.md` § Item 5).
- Backend: `getDeviceLists {userIds 1..256}` (60/15 min, answered per user with `deviceList`, silence for a refused user); `friendsList` entries carry `devices:[{deviceId, requestSid, sealPub}]` from two batched queries (`DevicesService.firstContactDevicesFor`, `DeviceListService.pendingReplacementUserIds`).
- Frontend: new `BoxFriendHandoff` (`box_friend_handoff.dart`) runs one pass per connect after `ContactStore.settled`, handing our queue to every friend device with a target. `BoxSession` implements `BoxFriendLink` (`box_friends.dart`). `BoxInbox._intakeRequest` journals a friend's frame from our request queue (`viaRequestQueue`), and `messaging_provider.box.dart` reads it under anchor, liveness and replace-session checks.
- Re-key rules (second review): `rekeyFriend` asks `getFriends` once per device per session and gives up if the fresh list names no address (was an unbounded loop a stranger could drive). Only a session built where none existed opens the 10-min "asked" window (`friendSessionStarted`); a re-key's fresh session never does.
- A friend's box message on a chat this device has not linked yet is HELD in the journal, not dropped. `ConnectionProvider` drains the inbox once a `conversationsList` write settles.
- Other changes: `EncryptionProvider.getVerifiedDeviceList(batched:)`, `QueueKeys.ensureInbound` (it replaces `createInbound`), and `siblingPreKeyWouldReplace` renamed to `preKeyWouldReplaceSession`. UI: `BoxFriendOlderAppNote` in `chat_detail_screen._buildComposerFooter`, with ARB key `boxFriendOlderAppNote` (EN and PL).
- Out-of-repo: throwaway `%TEMP%/umbra-item5-befriend.cjs` and the Chrome drive profiles were deleted. Local drive accounts 319–325 remain in `fireplace-mp-db-1`. A temporary `git worktree` of HEAD was used for the lint baseline and then removed.

## Key files
- New: `frontend/lib/services/box/box_friend_handoff.dart`, `box_friends.dart`, `frontend/lib/widgets/box_friend_older_app_note.dart`, `frontend/test/services/box/box_session_friends_test.dart`, `frontend/test/providers/messaging_provider_box_friend_test.dart`.
- Edited (frontend): `box_session.dart`, `box_inbox.dart`, `queue_keys.dart`, `contact_record.dart`, `contact_store_inbox.dart`, `messaging_provider.box.dart`, `messaging_provider.dart`, `connection_provider.dart`, `encryption_provider.dart`, `encryption_service.dart`, `prekey_identity.dart`, `chat_detail_screen.dart`, l10n, and `test_e2e/box_roundtrip_test.dart` (case 3: migration).
- Edited (backend): `chat.gateway.ts`, `dto/device-list.dto.ts`, `chat-device-list.service(.spec).ts`, `chat-friend-request.service(.spec).ts`, `devices.service(.int-spec).ts`, `device-list.service(.spec).ts`.
- Docs: `docs/contracts/wire.md`, `frontend/docs/e2e-invariants.md`, decisions log, remainder plan, `traps.md`, root `CLAUDE.md` counts.

## Verification
- CI: see the commit's check-runs (recorded in the LATEST entry after push); the previous head `137636dd` was 7/7.
- Backend: jest 1217/68, int 39, lint ratchet held, knip clean.
- Flutter: full suite 2809 passed, 14 skipped. Analyze showed 0 errors or warnings. `scripts/dart-lint-ratchet.mjs` PASS at 3160; the 8 new infos were fixed, found by diffing against a HEAD worktree.
- E2E: `box_roundtrip_test.dart` with `BOX_PROBE=true` passed 3/3 on the local stack.
- Mutants: all killed. Three first-round survivors were fixed by strengthening tests. Review-fix mutants RV-M1..3 and HOLD-M1 were killed, as were RR-A (drop the once-per-device guard) and RR-B (fresh re-key opens the window).
- Live drive, release web, headless Chrome, local stack. Final build: F/G (324/325, conv 99), with G's request queue nulled to emulate an old app.
  - Notice shown on F; the old-path send went to `messages` (row 617).
  - G came back: handoff via request queue, then `REFUSED would_replace`, then re-key, then acked on both sides.
  - Box traffic both ways ("gus replies…", "second from gus", "fay over the box"); `messages` stayed at 1 row; the notice cleared.
  - Earlier build: 319–323; the three bugs found there (late store write, rekey with no address, `no_conversation` drop) were fixed test-first.
- NOT verified: Android, iOS, prod (box OFF), a linked second device of a friend (E20g: waits for the next connect's pass).

## Notes for next session
- Next action: open PR-level review of item 5 on `feat/metadata-privacy` if the owner wants one. Otherwise start slice (e), queue rotation, per the remainder plan.
- Open finding: on F the first box message from G was HELD (`no_conversation`) although that session's `conversationsList` named conv 99. The store held no link until the next connect, so the message showed only after a reload. Cause not pinned; trap added. Suspect: a `ContactStore.reconcile` dropped silently by a generation change.
- Review P3 left as a documented residual (wire.md): the normal-queue PreKey handoff guard runs after `decrypt`, so the replaced session is already gone. That predates item 5, and the address is not moved.
- Carried: `boxdel_v1` tombstone lost-write race; reactions not ordered by `ts`; `getMessages`/`markConversationRead` still name box chats; the chat-list preview after reload shows the last OLD-path message, not the last box message.
- Drive recipe: register with `X-Real-IP: 10.x.x.x` (bypasses the 10/h bucket). Emulate an old app with `UPDATE devices SET "requestSid"=NULL,"requestSealPub"=NULL WHERE "userId"=…` while that account is offline. Befriend via two sockets (`friendRequest` then `acceptFriendRequest`). Serve `build/web` with `python -m http.server 8080 --bind ::`.
- Traps: see `docs/agents/traps.md` lines citing this file (Tests / harness ×3, E2E / multi-device ×5).
