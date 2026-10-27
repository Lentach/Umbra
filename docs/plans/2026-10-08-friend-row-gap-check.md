# Phase 4 safety audit: what still needs the server's old tables (2026-10-08, read-only)

Question: can Phase 4 (decision 86: drop `friend_requests`, `conversations`, `messages`, the account push tables, old attachments) run on prod without users losing data? Answer: **no, not as one step, and not in the order first assumed.** Two paths destroy data on devices for good, several features break, and the server cannot see who is ready. Checked on `merge/0.2.62` (`9b686f6e`) by four independent read-only audits plus prod `SELECT`s; each row below was traced in code.

## The two rules every Phase 4 step must keep

1. **Never empty a table while the code that reads it still answers clients.** An EMPTY answer is what devices act on; a dropped table or a removed handler makes the server SILENT, and silence is safe on every app version.
2. **Never let a device delete anything because the server stopped naming it.** No app version has a minimum-version gate (nothing in `backend/src` checks a client version; `ApkUpdateService` is a dismissible banner), so old installs obey whatever the server sends.

## Paths that destroy data on devices

| # | Path | Where | Versions | Trigger | Lost | Recoverable |
|---|---|---|---|---|---|---|
| A | Plaintext reconcile: every 6 h at most, the device asks which of its stored SERVER message ids are still served and purges the decrypted text of the rest | `encryption_provider.dart:1411-1456`; backend `messages.service.ts:356-368` (joins `conversations`) | every build since 0.0.140 | `messages` or `conversations` rows deleted/truncated while `getServedMessageIds` still answers, or a stub that answers `[]` | the text of every old-path message on every device that reconnects (box messages are spared since 0.2.52) | **no**: the ratchet keys are spent, the server ciphertext cannot be read again |
| B | Friends sweep on a NON-EMPTY `friendsList` that leaves people out | `friends_provider.dart:183-199, 655` | 0.2.52–0.2.62 (identical) | rows emptied while old handlers can still create one row (an old-path accept sends a 1-entry list to both sides) | old-path friends holding no box queues are deleted; ones with queues become `former` (hidden); the pruned store then replaces the contact backup (`uploadNow` is a full replacement) | **no** once the upload lands |

Not destructive, but visible: an EMPTY `friendsList` deletes nothing on disk (`friends_provider.dart:639, 655`), yet the old-path friends vanish from the screen for that session; `conversationsList` the same for chats (`conversations_provider.dart:481`); old-path history is rendered ONLY from server history (`messaging_provider.history.dart:195-238`), so it looks gone even while its text is still on disk. An emptied `blocked_users` sweeps local blocks (`friends_provider.dart:686-696`).

Correction to this note's first version (same day): it said an empty list deletes old-path friends; it does not (only a partial list does), and it missed path A entirely.

## Backend dependencies (what breaks if the rows go)

| Dependency | Where | Effect | Severity |
|---|---|---|---|
| `getServedMessageIds` | `chat-message.service.ts:712-761` | path A | BLOCKER: remove the handler (silence) BEFORE any row goes |
| `friendsList` from `friend_requests` | `chat-friend-request.service.ts:733-745`; `friends.service.ts:321-359` | path B; it is also the only server source of friends' profiles (avatar, about) and of request-queue addresses for old-path friends (`box_friend_handoff.dart:239-251`) | BLOCKER |
| Device-list reads entitled by `areFriends` or a conversation row | `chat-device-list.service.ts:221-224, 275-293` | E50a/E50c fallbacks refused silently; sends to a friend whose key changed fail | HIGH |
| Account push tables | `push-notifications.service.ts:94-174`, called from `chat-key-exchange.service.ts:389-398, 499, 734, 763, 865` | security alerts (reset pending/cancelled, recovery key, identity changed) never reach a closed app; R78's security-only table must exist first | HIGH |
| `deleteAccount` | `users.service.ts:371, 386-426` | with the tables dropped and this code left: tokens revoked, then the delete throws: user logged out, account NOT deleted | HIGH (cut over in the same release) |
| Block, unfriend | `blocked.service.ts:67`; `chat-friend-request.service.ts:747-838` | throw after a partial write | MEDIUM (cut over) |
| `peerIdentityChanged` fan-out | `chat-key-exchange.service.ts:501-512` | no server-side takeover warning to peers | MEDIUM |
| Media sweep keeps `msgs/` files a `messages` row names | `media-cleanup.service.ts:69-121` | old attachments unlinked at 03:00, as R79 intends | intended |
| `POST /messages/link-preview` lives in `MessagesModule` | `messages.module.ts:7` | deleting the module wholesale kills web link previews (box sends too) | LOW |
| FK cascades | prod `pg_constraint` | only old side tables cascade (`reaction_keys`, `message_envelopes`, notification prefs); nothing from `box_*`, `contact_backups`, `devices`, `key_bundles`, `users` points at the old tables | none |

Independent of the old tables (checked): pre-key fetch, box module and box push, `contact_backups`, devices, key bundles, identity-reset cron, avatars (`GET /media/avatars` is public), search with the box on, throttlers.

## Prod numbers (2026-10-08, `SELECT` only)

- 65 accepted friend pairs, 75 users in them; all made before the box launch. The server **cannot** tell which pairs also exist on the box: only devices know.
- Accounts with friends and NO `contact_backups` row (decision 86's number): 23 of 26 active in 30 days, 42 of 45 in 90 days, 72 of 75 overall. Only 5 accounts have a backup.
- 118 active devices, 95 without a request queue; every device seen in the last 7 days has one (21), 6 of 29 seen in 30 days do not. App versions are not recorded server-side.
- The old path is still used: 13 `messages` rows since the box launch (2 senders), newest 2026-10-07.
- Builds 0.2.40–0.2.51 keep no contact store: for an account that never ran 0.2.52+, `friend_requests` is the ONLY copy of its friends.

## Safer plan: staged, every step reversible until the last

0. **Cull inactive and test accounts first** (decision 100). DONE 10-08: 93 accounts deleted in two owner-picked rounds (no live session, last seen before 06-24, test accounts; then 14 unused ones last seen before 09-10), 26 remain; SQL transactions mirroring `UsersService.deleteAccount`, since no password exists for an admin delete (`2026-10-08-account-cull.md`). Their friends' devices drop them as contacts and lose the text of those chats (intended for a deleted account).
1. **Client hardening release** — RELEASED 10-21 as 0.2.68 (`655e7f0b`, web + backend + APK). (No server data touched; revised 10-21 by decision 107, see §"Review 10-21"): fix the `getMessages` local-id leak; no deletion on absence anywhere (friends prune, blocked prune, chat list); every friend with a box route gets box behaviour whoever made the friendship (unfriend, block, timer and goodbye over the box; chat id kept in the backup); decision 104. Old-path history is NOT rendered locally: it may go (decision 99). Dropped: the 409 merge, the all-orphan reconcile guard, the app version at connect (decision 108), queue addresses and device lists in the backup.
2. **Measure**: accounts with friends and no backup; devices without a request queue (0 of 24 on 10-21). 10-21: Ketokeczup's backup landed; jarekk and qwerty still have none and gate step 4, not step 3 (decision 111).
3. **Freeze behind an env flag** (rows untouched): no new rows in the old tables (old-path sends and requests refused; only the existing disappearing-message expiry still deletes), versions below step 1 told to update. The list handlers keep serving the frozen rows: a complete frozen list cannot trigger the partial-list sweep, and silencing `conversationsList` would force a reconnect on every resume (`connection_provider.dart:1118-1126`). Watch 1–2 weeks. Undo = flip the flag. BUILT 10-21 (`LEGACY_WRITES_FROZEN`, scope and calls E111a–c) and DEPLOYED 10-21 with the flag `'false'` (backend `0b03d64f`); not yet rehearsed (owner: later). Flip only after a POSITIVE check (E111c): bob208 → R0yb3r and the reply both arrive on 0.2.68 while `max("createdAt")` of `messages` stays at 2026-10-11 20:40Z; a quiet week alone is not enough.
4. **Cut over** account delete, block, unfriend, device-list entitlement, security push (R78), profiles; then the list handlers and `getServedMessageIds` are removed (silence, never `[]`).
5. **Archive, then DROP** (never `DELETE` rows under live code): an encrypted dump kept offline, then `DROP TABLE` with the code removal in the same release.

Before steps 3 and 5: a rehearsal on a restored copy of the prod backup with an old APK (0.2.61), a PWA and the new build. Pass = every pair sends and receives both ways; a timer change, an unfriend and a block on a pre-box chat take effect on both sides; a wiped native device restores and receives (decision 105); account delete runs. A matching contact count alone proves too little. Before step 4: every build still able to connect reads a missing `servedMessageIds` reply as "no answer" — CHECKED 10-21: `getServedMessageIds` arrived in `4fa1ab7a` (07-28) and `git log -L` shows `_askServedMessageIds`/`_onServedMessageIds` and the `served == null → return false` in `reconcileStoredPlaintext` unchanged since; builds older than 07-28 never ask. Silence costs one 20 s wait per connect and purges nothing. Decision 99 accepts losing old-path text, but users are told first.

**Also on the restored copy, before the freeze flips (E111c, added 10-27):** list every pair that wrote an old-path row since the box went on (09-30, decision 75). Live prod cannot answer it: 58 rows were deleted since 10-21 (E111c-r) and the 49 left end 09-22. Use the OLDEST backup kept, `chatdb-20261013T040001Z.dump.gpg`: no `messages` row is newer than 10-11 20:40:55 and rows are only ever deleted, so it holds every row any later backup holds. Run `select conversation_id, min("createdAt"), max("createdAt"), count(*) from messages where "createdAt" >= '2026-09-30' group by 1` and map each `conversation_id` to its pair through `conversations.user_one_id` / `user_two_id`. Every pair other than bob208 ↔ R0yb3r (done 10-23, E111c-r) then needs the same send-both-ways check on its current build with `max("createdAt")` of live `messages` not moving; pairs with a deleted account drop out. The flag flips only when that list is done. Residual, not recoverable: a pair whose disappearing rows from 09-30 to 10-11 expired before 10-13 is in no backup; against it stands live `messages` gaining no row since 10-11 20:40:55 while 18 of the 23 friendship accounts were active (reach check 10-27).

Owner decisions 97–100 (10-08) apply. Phase 4 stays the owner's call (decision 86).

## Review 10-21 (whole-plan review; decision 107)

Read-only review of the plan against HEAD plus prod `SELECT`s (10-21: 24 live devices, 0 without a request queue; 25 accepted pairs, all pre-box; 8 old-path messages in 14 days; 23 accounts with Web Push, 2 FCM tokens).

- **HIGH, fixed in step 1: `getMessages` leaks box friendships.** `connection_provider.dart` re-asserts the active chat on `socketReady` and on resume without the local-id guard; a box chat id is `2^48 + peer`, so the server learns the pair and logs it (`QueryFailedError … out of range for type integer`, prod 10-20). Breaks `wire.md` "every chat-keyed emit is skipped for a local id". Logs purged after deploy (decision 109).
- **HIGH, fixed in step 1: pre-box friends still end and time out through the server.** `unfriend`/`blockUser` go over the box only for `boxOrigin` friends (`friends_provider.dart` `_endsOverBox`), the timer goes over the box only for local chat ids (`conversations_provider.dart` `setDisappearingTimer`), and a goodbye from a pre-box friend is ignored (`messaging_provider.first_contact.dart` `_takeGoodbye`). After step 4 a block on such a chat would do nothing.
- **HIGH, Android release prep (not Phase 4; PARKED by the owner 10-21: "save it for later"):** `flutter_secure_storage` 9.2.4 writes with `SharedPreferences.apply()` (silent loss on a full disk or crash; its own AES key too, and a failed unwrap mints a new key). Identity, pre-keys and sessions ride it. Do not just upgrade to 10.x (`resetOnError` defaults to true). Seen on the emulator 10-20: `ENOSPC` on these writes with 0 bytes free. A fix cannot free space; it can only make the failure visible ("phone full") instead of silent.
- **Before step 4 (open):** account delete leaves friends sending ✓ into dead queues (send a goodbye and retire queues first); device-list entitlement without friend rows (answer any authenticated caller; `searchUsers` already serves it); friends' profiles freeze (decision 55 deferred a profile frame); R78's security push table would keep decision 81's queue↔account link alive; after step 5 old-path text sits on devices with nothing to show or delete it (shred or export). Found 10-21: the resume probe (`connection_provider.dart:1115-1136`) forces a full reconnect unless `_serverResponseCounter` moves within 6 s, and only `conversationsList` and `messageHistory` move it (`:1646`, `:1713`; a box chat sends no `getMessages`). Silencing `conversationsList` therefore makes every resume reconnect on EVERY build, 0.2.68 included: the probe needs another answered emit (e.g. `getServerTime`) in a release that reaches users before the silence.
- **Asked 10-21 as O31–O36** (decisions log, with evidence and recommendations). Correction to the line above: `searchUsers` is NOT a drop-in for the device list (box-flag-gated, spends one one-time pre-key per device), and answering any caller by id reopens the amendment (xliii) oracle; every prod friendship is pre-box and fetches lists by id (`messaging_provider.box.dart:308-311`), so O32 is the step's critical path.
- **Answered 10-22 as decisions 113–118** (all as recommended): 113 goodbye and queue retire before account delete; 114 pre-box friends move to the box (device lists and queue addresses over the box and by handle lookup; the release must reach users before `friendsList` and the rows go); 115 R78 reversed, account push tables drop at step 5; 116 key-change alarm accepted gone; 117 names and photos freeze when `friendsList` stops; 118 old-path text left to 30-day retention. Next: the step 4 design pass, 114 first (size it; include the resume-probe replacement and `MediaCleanupService`).
- **Dropped from step 1:** see decision 107; the version at connect, decision 108.

## Step 4 design (2026-10-22; decisions 113, 114 and the resume probe)

The client release that must reach users before step 4's server half. Backend untouched. Spec: decisions 113–122 (120–122 are the owner's answers to the questions this pass raised, 10-22). Engineering calls: E114a–E114p (decisions log; E114m–E114o come from the reviews and the drive of the build, E114p from the second review). Line numbers are as of `7e34495e`.

### What the client asks the server today

**Peer device lists.** Every peer-list emit goes through ONE function, `EncryptionProvider._fetchDeviceListAnswer` (`encryption_provider.dart:1020-1050`). It emits `getDeviceList`, or `getDeviceLists` when batched (`:1076-1090`), unless `isBoxOnlyPeer(peer)` is true, which sends it to `lookupBoxPeerList` (one `searchUsers` of the handle, once per account per process). `isBoxOnlyPeer` is `ContactRecord.boxOrigin != null` (`connection_provider.dart:519`): a friendship MADE over the box. A pre-box friend has no `boxOrigin`, so every row below names its id to the server.

| Caller (file:line) | Trigger | After this release |
|---|---|---|
| `_boxLists.fetch`, peers (`messaging_provider.dart:343-347`) | connect refresh: list not held, or a >30-d gap (E50c) | handle lookup (E114a) |
| `friendLiveDevices` (`messaging_provider.box.dart:561`) | the handoff pass, each connect and friend-list change | held list, else handle lookup (E114a) |
| `_friendDeviceIsLive` (`messaging_provider.box.dart:311`) | a friend's handoff read off a queue | held list only, never a lookup on a frame read (E114e) |
| `adoptCarriedDeviceList`, unpinned DAK (`encryption_provider.dart:919`) | a carried list under a DAK the server never served | handle lookup, one per account per process of its OWN: it does not share the first-sight lookup's budget (E114l, found on the drive) |
| accept gate, sender-list check (`messaging_provider.decrypt.dart:120, 152, 274`) | old-path rows only | handle lookup; dies with the rows |
| old-path send, edit, resend, failed-send refresh (`messaging_provider.send.dart:1052, 1125, 2020`; `messaging_provider.dart:1062`) | old-path sends only | handle lookup; dies with the old path |
| the OWN list (`messaging_provider.dart:331`; `messaging_provider.box.dart:371, 975, 1012`; `messaging_provider.decrypt.dart:255`; `link_ceremony_controller.dart:265`; the devices screen) | connect, link ceremony, handoff carry | UNCHANGED, by id: it names only the caller. The server half must keep answering `userId == caller` |
| **missed by the first pass (review F2, 10-22):** the verify dialog's served-key fetch, `loadPeerIdentityVerification` → `_fetchServedAccountIdentity` → `_servedDeviceIdHints` (`encryption_provider.dart`) | a standing key-change warning with no candidate (amendment (xlvii) clause 3), a person opening the dialog | by id before; now the key the friend's handle lookup served (kept in RAM from the lookup that raised the warning, a lookup of its own only when that is older than the floor), and no by-id bundle fetch for a friend (E114m) |
| **invalidate-then-refetch (review F2):** `invalidateDeviceList` from `onSessionRebuildNeeded` (`encryption_provider.dart`), a peer's newer-list claim (`messaging_provider.decrypt.dart`, `refreshPeerList`) and `acknowledgePeerIdentity` | a rebuild request, an old-path row claiming a newer list, a person acknowledging a new key | by id before; a peer- or server-driven event drops the held list only when a lookup is owed and may be made: one per event, floored (1 min, set by every lookup) and capped (6 per friend per process), else the held list stands (E114m, E114o); acknowledging a new key is a person's act, neither floored nor capped, and drops the list whatever the budget says (E114o); a lookup nobody answers is asked again up to three times in a row (E114p) |

**`friendsList` `devices`** (`[{deviceId, requestSid, sealPub}]`, built by `chat-friend-request.service.ts:51-76`). Consumers:

| Consumer | Use | After this release |
|---|---|---|
| `BoxFriendHandoff.takeFriendsList` → `_requestQueues` (`box_friend_handoff.dart:144-172`), read by `targetOf` (`:239-251`) | where a handoff goes when that device has handed us nothing | `targetOf` = held `outbound`, else the addresses of this process's handle lookup (E114b) |
| `BoxFriendHandoff._pass` (`:329-336`) | a friend with no known address is not visited at all | every friend is visited; one with nothing to hand to is looked up once (E114c) |
| `BoxSession.rekeyFriend` (`box_session.dart:812-828`) | no target: one `getFriends` per device per session, re-key when the list arrives | an awaited handle lookup (E114d) |

Nothing else reads `devices`: `FriendsProvider.onFriendsList` takes names and photos only, and the contact store keeps no request address of a pre-box friend.

### What the handle lookup gives, and what it does not

With the box on, `searchUsers` answers "stranger or friend alike" (`chat-search.service.ts:32-37`): per live device a bundle (its next one-time pre-key spent), the request queue it published, and the account's DAK-signed list. So ONE call supplies a list AND every address; the server learns "A looked up B", once, and does not log it (`:39`). It is the one lookup design §4.2 keeps (E15h), and decision 114 names it.

- **`boxOrigin` is NOT set for a pre-box friend.** It means "made over the box" and drives the chat id, which lists show the friend, hidden chats, request lifetime and the unfriend path (40+ sites). The lookup's addresses live in RAM beside the friends list they replace (E114b); the list is kept on disk like any box peer's (E114a).
- **Bundles stay by id** (E114f). `fetchPreKeyBundle` answers any authenticated caller today (`chat-key-exchange.service.ts:876-915`, no friend check, rate-limited per requester and target) and reads `key_bundles` only, so it is no friend-row dependency. It still names the pair when used; it is not part of 114's wording.
- A re-minted friend stays a human's call: `adoptServedAccount` throws on a different pinned key, and the caller's check under the held anchor decides, as by id.

### Pairs with no route, and the reach of the release (the two gaps)

Prod, read-only, 10-22: 25 accepted pairs, 23 accounts, exactly 1 live device each, **0 of 23 without a published request queue** (the 10-20 "device 1 without a queue" is stale), 22 of 23 refreshed a session within 14 days (16 within 2). `messages` is untouched since 10-11. Which pairs hold queues both ways is known only to the devices (the box cannot link a queue to an account by design), so "no route" cannot be counted on the server.

- **A pair with no route gets one from this release, without `friendsList` (decision 120).** Both devices run the pass at every connect. A friend with a live device it holds no address for, and a handoff to it due, is looked up once per process; the answer carries the request queues, the handoff goes there, the friend hands its queue back on receipt. All 23 devices are lookup-reachable. The cost is bounded (E114c): per looking device at most one lookup per friend per process and one per 24 h per friend still waiting, zero in steady state. **One-time pre-keys:** a lookup spends one per live device of the friend. Moving prod's 25 pairs costs about two lookups per pair, about 50 pre-keys fleet-wide once; replenishment keeps up because the server signals `preKeysLow` to the claimed device's room below 10 left and a connected device mints 100 (`encryption_service.dart:116`), a device that is offline is topped up by the first claim after it returns, and an empty pool serves the bundle WITHOUT a one-time pre-key (the prod `OTP exhausted` line: a weaker first message, never a failure).
- **Stranded whatever we do:** a friend whose build ignores a goodbye (before 0.2.68, `BOX_GOODBYE_IGNORED`), a friend with no device that published a request queue (0 on prod), a wiped device with no contact backup (decision 119).
- **Reach has no server signal and is not given one** (decisions 108 and 122; E114j). The check that can be run:
  1. Before the silence, read-only on prod: every accepted-pair account refreshed a session after the release deploy time (`refresh_tokens`: `expires_at - interval '365 days'`), and `devices` still shows 0 live devices without `requestSid`. PWA users (23 of 24 hold Web Push; decision 110) load the new bundle at their next open (`no-cache` on `/`), so "opened since the deploy" is the best server-visible proxy; a tab left open for days keeps old code.
  2. The 2 native accounts (FCM tokens) are on the new APK: the owner's attestation, there is no signal.
  3. On each device the durable log gains `BOX_ROUTES {friends, routed, owed}` after every pass (no server effect); the owner reads it on his own devices, and a user can read it in hacker mode.
  4. No server counter (decision 122): the one option that reverses nothing in 108 is an anonymous count of by-id peer-list answers, and it is weak (a build holding kept lists never asks).

### Release order

1. This client release (web at the next open of each page, APK by hand). 2. Reach check above. 3. Server half: silence `friendsList`, `conversationsList`, `getServedMessageIds`; `getDeviceList(s)` answers only `userId == caller`. 4. Step 5: archive, drop, `MediaCleanupService`, push tables.

### The resume probe (item 3)

`_serverResponseCounter` moved only on `conversationsList` and `messageHistory`. The probe now also emits `getServerTime` and counts `serverTime` (E114g); `getConversations` stays until the silence. Old builds (≤ 0.2.69) reconnect on every resume once `conversationsList` is silent: accepted, they must update anyway.

### Account delete (113)

Order: verify the password (`POST /users/verify-password`, no side effect) → goodbye to every friend's devices over the box and retire every own queue → `DELETE /users/account` → the existing teardown. A wrong password must not tell friends goodbye (E114h). Best effort inside a 10 s budget (the delete shows no progress of its own); the delete is never held hostage by a down box or a friend that cannot be reached (E114i).

### The client under silence (decision 121)

Besides the probe, a client whose `conversationsList` never arrives was still wrong: the chat list kept its skeleton for an account with no chat (`conversations_screen.dart:603`), a notification tap never navigated (`main_shell.dart:279`: it waits for the first list) and the unread badge never flushed (`unread_badge_sync.dart:60`). Nothing was destroyed (`served == null` purges nothing; `_storeList` prunes only on a received list). Now `ConnectionProvider` arms an 8 s timer at each `socketReady` that asks for the list, and when it fires `ConversationsProvider.releaseFirstSnapshotWait()` flips a flag of its own that those three consumers read through `hasLoadedConversationsOnce`. It runs no list handler and no reconcile, prune or sweep (an empty `friendsList` blanks the friends screen, `friends_provider.dart:631-643`), local contacts and chats stay as held, and a list that arrives later finds the real flag unset and is applied as a first snapshot (E114k). A transport disconnect cancels the timer (the next `socketReady` arms it again), and the 500 ms `getConversations` re-ask in `_onSocketReady` reads the REAL flag (`conversationsListReceived`), so a release never stops a later reconnect from asking again (review 10-22, F3 and F4). A fresh install still shows no friends without a contact backup (decision 119).

### What remains for step 4's server half

1. Silence (never `[]`) `friendsList`, `conversationsList`, `getServedMessageIds`; the list payload's `devices` (`chat-friend-request.service.ts:51-76`) goes with it. A new client reads none of it for routing.
2. `getDeviceList` / `getDeviceLists`: answer only `userId == caller` (the own list: connect, link ceremony, devices screen, handoff carry) and drop the `areFriends` / `conversations` entitlement (`chat-device-list.service.ts:275-293`); silence for every other id.
3. `searchUsers` and `fetchPreKeyBundle` stay as they are. Note for the owner: `fetchPreKeyBundle` answers any authenticated caller and claims a pre-key (`chat-key-exchange.service.ts:876-915`), an existing by-id oracle outside 114's wording (E114f).
4. The reach check above, then the owner's go. Old builds (≤ 0.2.69) reconnect on every resume once `conversationsList` is silent, cannot read a friend's list they do not hold, and never learn a new device of a friend: they must update.
5. Step 5 as before (archive, drop, `MediaCleanupService`, push tables).

### Size (as built)

See the dated summary `2026-10-22-phase4-step4-client.md` for the file list and counts. No backend, no migration, no wire change. Test seams (all existing): `ConnectionProvider.ensureReconnectIfNeeded` and `socketReady`, `BoxSession` (`box_session_friends_test.dart`), `EncryptionProvider.getVerifiedDeviceList` with a captured emit, `MessagingProvider` (`messaging_provider_box_first_contact_test.dart`), `AuthProvider.deleteAccount`, `ConversationsProvider`.
