# Phase 4 step 1 (revised): box chats no longer named to the server, no server list deletes a contact, pre-box friends end and time out over the box

**Date:** 2026-10-21 · **Version:** unchanged (0.2.67; this is unreleased client + backend code) · **Tiers deployed:** none

## What was done
- Whole-plan review of Phase 4 (two read-only agents + prod `SELECT`s). The owner picked "revised step 1" and recorded decisions 107–110 in `docs/plans/metadata-privacy-decisions.md`:
  - 107: revised scope;
  - 108: no app version at connect;
  - 109: purge the prod backend logs after deploy;
  - 110: count PWA users before the PWA delete.
  - Plan rewritten in `2026-10-08-friend-row-gap-check.md` steps 1, 2, rehearsal, §"Review 10-21".
- Leak fix (`afdfc1a6`): `ConnectionProvider._refetchActiveChat` skips local chat ids on `socketReady` and resume. `ChatMessageService.handleGetMessages` drops ids above int4 with no reply and no log. Before this, prod logged `2^48 + peer`, which names the friend.
- No deletion on absence:
  - `ContactRecord.onBoxRoute`: a `boxOrigin`, or queues or outbound held.
  - `FriendsProvider._storeList` never sweeps such a record, and hides any other as `former` instead of deleting it.
  - An empty `blockedList` after a real one is ignored.
  - `ConversationsProvider._storeConversationsList` keeps a box-route chat id and `timerAt`.
- Pre-box friends with a box route get box behaviour:
  - `FriendsProvider._end` ends them over the box, then emits the server event; a failed box end sends nothing.
  - The box-origin gates now use `onBoxRoute`: `endBoxFriendship`, `_takeGoodbye`, `sendBoxChatTimer`, `_takeBoxTimer`, `applyLocalChatTimer` (keyed by `chatId`). `BoxSession.endBoxFriendship` handles a record with no `boxOrigin`.
  - `setDisappearingTimer` sends both over the box and to the server.
  - Either end drops the friend from the RAM `_friends` list.
- Contact backup carries `legacy.conversationId` only (`ContactRecord.toBackupJson`); request ids still stay out.
- Found on the drive and fixed: unblocking the last blocked account left it listed, because the guard swallowed the server's empty list. `unblockUser` now applies its own unblock locally.
- Out-of-repo: dev DB only.
  - Users 261 `p4alpha` and 262 `p4bravo` (password `Test123123`).
  - Rows inserted by hand: `friend_requests` 93 and 94, `conversations` 77 and 78, `blocked_users` 2 (later unblocked).
  - Dev backend restarted, which reset the box throttle.
  - Nothing left running; Chrome profile `%TEMP%/d101drive/prof`.

## Key files
- Edited:
  - `frontend/lib/providers/{connection,friends,conversations}_provider.dart`
  - `frontend/lib/providers/messaging/messaging_provider.first_contact.dart`
  - `frontend/lib/services/box/box_session.dart`
  - `frontend/lib/services/contacts/contact_{record,backup}.dart`
  - `backend/src/chat/services/chat-message.service{,.spec}.ts`
- Tests:
  - `connection_provider_socket_ready_test.dart`
  - `contact_store_hydration_test.dart`
  - `friends_provider_test.dart`
  - `messaging_provider_box_first_contact_test.dart`
  - `contact_backup_test.dart`
- Docs:
  - decisions log, plan doc, `docs/contracts/wire.md:142`;
  - `frontend/docs/e2e-invariants.md` lines 51, 52, 103–105;
- CI: green on `7f28d0ee` (all six jobs). `2dd35da3` had Backend tests RED on the backend ESLint ratchet, 850 → 853: an `any` read in the guard, and `unbound-method` from `expect(mock.method)` in the spec. Fixed by `7f28d0ee`.
- Read only: `box_inbox.dart:211-217` (a non-friend's frames are dropped unread).

## Verification
- CI: see the handoff commit's Notes. The last code commit of this session is the step-1 commit after `afdfc1a6`.
- Every new test was red first with the exact symptom:
  - `getMessages` emitted `281474976710693`;
  - a box-route friend swept to `former`;
  - the chat id stripped;
  - an empty blocked list unblocking;
  - goodbye and timer refused for pre-box friends;
  - the RAM friend kept;
  - the last unblock kept.
- Flutter 3203 passed, 14 skipped. Backend 1242/70 (`verify-claude-backend-test-counts` OK). Dart lint ratchet held at 3146. Before the ratchet was fixed, one `prefer_if_elements_to_conditional_expressions` in a test.
- Web drive, release builds `p4s1`, `p4s1b`, `p4s1c` (footer checked):
  - Leak: a box chat was open while the backend was paused 35 s. `socketReady` fired again (count 2), no `getMessages` left the page, 0 out-of-range lines in the backend log.
  - Pre-box pair made in the dev DB plus an item-5 handoff; the box route was proven by the `messages` row count staying flat.
  - Timer set on p4alpha reached p4bravo with `disappearingTimerUpdated` dropped.
  - Unfriend ended p4bravo's chat and friend with `unfriended`/`friendsList`/`conversationsList` dropped. The server row was gone too.
  - Block: p4bravo lost the contact with `youWereBlocked` dropped; p4alpha's blocked list and the server block row were correct.
  - Unblock of the last block cleared the list and stayed cleared after a reload.
- NOT verified: Android/native (shared Dart logic, no native storage change), iOS, prod. The partial-list sweep is unit-tested only; a server cannot be made to send a partial list on demand.

## Notes for next session
- Next action: release step 1 (0.2.68), with decision 104 riding along:
  - version bump, CI green, staging rehearsal per the runbook, then deploy backend first, then web and APK;
  - then purge the prod backend container logs (decision 109).
- Step 2 after that: measure accounts with no backup (Ketokeczup now has a temp password; jarekk and qwerty are still open) and devices with no request queue (0/24 on 10-21). Step 3 only after that.
- Owner-owed before step 4: account delete sends goodbyes and retires queues; device-list entitlement without friend rows; profiles freeze (decision 55); R78 push table vs decision 81; shred or export old-path text.
- Android release prep (decision 105): `flutter_secure_storage` writes with `apply()` and loses writes silently on a full disk (`ENOSPC` seen on the emulator 10-20). Fix before native is "the product"; do not just bump to 10.x.
- PrezydentKarol (ruchens69's new account) is stuck on "Ponów". Emulator repro at 0 bytes free: `BOX_SEND_NO_LOCAL_ID`. His own log is still owed.
- Drive recipe:
  - launch Chrome from bash (`launch.ps1`), never from an eval cell: it dies with the cell;
  - add the drop hook with `tab.addInitScript` after `browser.open`, then reload;
  - the CDP offline switch does not cut a websocket; `docker pause` the backend for 35 s does;
  - more than ~10 reloads across 4 tabs trips the box `subscribe` throttle (`BoxThrottlerGuard refused event=subscribe`): restart the dev backend;
  - a fresh server pair needs two reload rounds before the handoffs give it a box route.
- Residual (documented): an old build that unfriends a box-route friend over the server while we are offline leaves the friendship standing here.
