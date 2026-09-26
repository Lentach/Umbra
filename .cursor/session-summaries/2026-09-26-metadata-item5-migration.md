# Item 5: existing friendships move onto the box, with a composer notice until the friend is covered

**Date:** 2026-09-26 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only)

## What was done
- Owner answers: O15 → (a) handoffs over the friend's REQUEST queues, O16 → (a) one line above the composer (decisions 47–48; engineering E20a–g in `docs/plans/metadata-privacy-decisions.md` and `docs/plans/2026-09-25-metadata-pr31-remainder.md` § Item 5).
- Backend: `getDeviceLists {userIds 1..256}` (60/15 min, answered per user with `deviceList`, silence for a refused user); `friendsList` entries carry `devices:[{deviceId, requestSid, sealPub}]` from two batched queries (`DevicesService.firstContactDevicesFor`, `DeviceListService.pendingReplacementUserIds`).
- Frontend: new `BoxFriendHandoff` (`box_friend_handoff.dart`) runs one pass per connect after `ContactStore.settled`, handing our queue to every friend device with a target. `BoxSession` implements `BoxFriendLink` (`box_friends.dart`). `BoxInbox._intakeRequest` journals a friend's frame from our request queue (`viaRequestQueue`), and `messaging_provider.box.dart` reads it under anchor, liveness and replace-session checks.
- Re-key rules (second review): `rekeyFriend` asks `getFriends` once per device per session and gives up if the fresh list names no address (was an unbounded loop a stranger could drive). Only a session built where none existed opens the 10-min "asked" window (`friendSessionStarted`); a re-key's fresh session never does.
- A friend's box message on a chat this device has not linked yet is HELD in the journal, not dropped. `ConnectionProvider` drains the inbox once a `conversationsList` write settles (NOT driven: see Verification).
- Follow-up commit (advisor re-check): a handoff to a friend device that never acks goes again only 24 h after the last one (`ContactQueue.handedAt`; was one blob per reload). A pass's new queues are subscribed in ONE frame (was one per queue: past ~60 friends, over the box's subscribe limit). Closed with no change: an ack never uploads the contact backup (`toBackupJson` drops `queues`).
- Other changes: `EncryptionProvider.getVerifiedDeviceList(batched:)`, `QueueKeys.ensureInbound` (it replaces `createInbound`), and `siblingPreKeyWouldReplace` renamed to `preKeyWouldReplaceSession`. UI: `BoxFriendOlderAppNote` in `chat_detail_screen._buildComposerFooter`, with ARB key `boxFriendOlderAppNote` (EN and PL).
- Out-of-repo: the throwaway `%TEMP%/umbra-item5-befriend.cjs` and the Chrome drive profiles were deleted. Local drive accounts 319–329 remain in `fireplace-mp-db-1`. A temporary `git worktree` of HEAD was used for the lint baseline and then removed.

## Key files
- New: `frontend/lib/services/box/box_friend_handoff.dart`, `box_friends.dart`, `frontend/lib/widgets/box_friend_older_app_note.dart`, `frontend/test/services/box/box_session_friends_test.dart`, `frontend/test/providers/messaging_provider_box_friend_test.dart`.
- Edited (frontend): `box_session.dart`, `box_inbox.dart`, `queue_keys.dart`, `contact_record.dart`, `contact_store_inbox.dart`, `messaging_provider.box.dart`, `messaging_provider.dart`, `connection_provider.dart`, `encryption_provider.dart`, `encryption_service.dart`, `prekey_identity.dart`, `chat_detail_screen.dart`, l10n, and `test_e2e/box_roundtrip_test.dart` (case 3: migration).
- Edited (backend): `chat.gateway.ts`, `dto/device-list.dto.ts`, `chat-device-list.service(.spec).ts`, `chat-friend-request.service(.spec).ts`, `devices.service(.int-spec).ts`, `device-list.service(.spec).ts`.
- Docs: `docs/contracts/wire.md`, `frontend/docs/e2e-invariants.md`, decisions log, remainder plan, `traps.md`, root `CLAUDE.md` counts.

## Verification
- CI: 7/7 green on `bb8f6f17` (the item-5 commit). The follow-up commit's CI is recorded in LATEST once it reports.
- Backend on the final tree (re-run after restoring the `--fix` rewrites): jest 1217/68, int 39/2, `scripts/lint-ratchet.mjs` held at baseline.
- Flutter: full suite 2809 passed, 14 skipped at `bb8f6f17`; 2811/14 after the follow-up's 2 tests. Analyze showed 0 errors or warnings. `scripts/dart-lint-ratchet.mjs` PASS at 3160; the 8 new infos were fixed, found by diffing against a HEAD worktree.
- E2E: `box_roundtrip_test.dart` with `BOX_PROBE=true` passed 3/3 on the local stack.
- Mutants: all killed. Three first-round survivors were fixed by strengthening tests. Review-fix mutants RV-M1..3 and HOLD-M1 were killed, as were RR-A (drop the once-per-device guard) and RR-B (fresh re-key opens the window). Follow-up: A1–A3 (resend gate removed / not persisted / inverted) and C1–C2 (per-queue subscribe / new queue not batched) were killed.
- Live drive, release web, headless Chrome, local stack. Final build: F/G (324/325, conv 99), with G's request queue nulled to emulate an old app.
  - Notice shown on F; the old-path send went to `messages` (row 617).
  - G came back: handoff via request queue, then `REFUSED would_replace`, then re-key, then acked on both sides.
  - Box traffic both ways ("gus replies…", "second from gus", "fay over the box"); `messages` stayed at 1 row.
  - The note did NOT clear live: F refused both of G's handoffs (`would_replace`, `prekey_unasked`; see Notes), so it held no queue from G and the note was right. It was gone at a reopen a minute later with no handoff logged; unexplained.
  - Earlier build: 319–323; the three bugs found there (late store write, rekey with no address, `no_conversation` drop) were fixed test-first.
- Follow-up drive (release web of the fix, H/I 328/329, conv 101): I online once, then offline; befriended; H reloaded 4 times. I's request queue held 1 handoff blob throughout, and H's last connect looked up I's list and sent nothing. I returned: box both ways ("hal/ida over the box"), 0 `messages` rows, no note.
- NOT verified: the inbox drain after `conversationsList` (no way found to make a friend's chat link land late on demand); Android, iOS, prod (box OFF), a linked second device of a friend (E20g: waits for the next connect's pass), the 24 h resend and >60 friends on a device (tests only).

## Notes for next session
- Next action: owner call on the crossing re-key below, then slice (e), queue rotation, per the remainder plan.
- Open, owner-class: since review fix B (a re-key never opens the 10-min window), two devices that re-key each other at once refuse each other's re-key (`prekey_unasked`), and one side gets no queue until the next connect. Seen in the F/G drive; before fix B, the E/C drive converged in one round. Options: keep B (one extra connect, messages stay on the old path meanwhile) or restore decision 37's rule for friends (a re-key counts as asking; a revoked friend device could use that 10-min window).
- Open finding: on F the first box message from G was HELD (`no_conversation`) although that session's `conversationsList` named conv 99. The store held no link until the next connect, so the message showed only after a reload. Cause not pinned; trap added. Suspect: a `ContactStore.reconcile` dropped silently by a generation change.
- Review P3 left as a documented residual (wire.md): the normal-queue PreKey handoff guard runs after `decrypt`, so the replaced session is already gone. That predates item 5, and the address is not moved.
- Carried: `boxdel_v1` tombstone lost-write race; reactions not ordered by `ts`; `getMessages`/`markConversationRead` still name box chats; the chat-list preview after reload shows the last OLD-path message, not the last box message.
- Drive recipes (register past the bucket, old-app emulation, befriend script, blob count, serving): `.planning/metadata-item5/findings.md`. Backend lint = `node scripts/lint-ratchet.mjs` only; `npm run lint` is `eslint --fix` (it rewrote 41 files this session, restored).
- Traps: see `docs/agents/traps.md` lines citing this file (Tests / harness ×3, E2E / multi-device ×6).
