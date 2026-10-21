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

Owner decisions 97–100 (10-08) apply. Phase 4 stays the owner's call (decision 86).

## Review 10-21 (whole-plan review; decision 107)

Read-only review of the plan against HEAD plus prod `SELECT`s (10-21: 24 live devices, 0 without a request queue; 25 accepted pairs, all pre-box; 8 old-path messages in 14 days; 23 accounts with Web Push, 2 FCM tokens).

- **HIGH, fixed in step 1: `getMessages` leaks box friendships.** `connection_provider.dart` re-asserts the active chat on `socketReady` and on resume without the local-id guard; a box chat id is `2^48 + peer`, so the server learns the pair and logs it (`QueryFailedError … out of range for type integer`, prod 10-20). Breaks `wire.md` "every chat-keyed emit is skipped for a local id". Logs purged after deploy (decision 109).
- **HIGH, fixed in step 1: pre-box friends still end and time out through the server.** `unfriend`/`blockUser` go over the box only for `boxOrigin` friends (`friends_provider.dart` `_endsOverBox`), the timer goes over the box only for local chat ids (`conversations_provider.dart` `setDisappearingTimer`), and a goodbye from a pre-box friend is ignored (`messaging_provider.first_contact.dart` `_takeGoodbye`). After step 4 a block on such a chat would do nothing.
- **HIGH, Android release prep (not Phase 4; PARKED by the owner 10-21: "save it for later"):** `flutter_secure_storage` 9.2.4 writes with `SharedPreferences.apply()` (silent loss on a full disk or crash; its own AES key too, and a failed unwrap mints a new key). Identity, pre-keys and sessions ride it. Do not just upgrade to 10.x (`resetOnError` defaults to true). Seen on the emulator 10-20: `ENOSPC` on these writes with 0 bytes free. A fix cannot free space; it can only make the failure visible ("phone full") instead of silent.
- **Before step 4 (open):** account delete leaves friends sending ✓ into dead queues (send a goodbye and retire queues first); device-list entitlement without friend rows (answer any authenticated caller; `searchUsers` already serves it); friends' profiles freeze (decision 55 deferred a profile frame); R78's security push table would keep decision 81's queue↔account link alive; after step 5 old-path text sits on devices with nothing to show or delete it (shred or export). Found 10-21: the resume probe (`connection_provider.dart:1115-1136`) forces a full reconnect unless `_serverResponseCounter` moves within 6 s, and only `conversationsList` and `messageHistory` move it (`:1646`, `:1713`; a box chat sends no `getMessages`). Silencing `conversationsList` therefore makes every resume reconnect on EVERY build, 0.2.68 included: the probe needs another answered emit (e.g. `getServerTime`) in a release that reaches users before the silence.
- **Asked 10-21 as O31–O36** (decisions log, with evidence and recommendations). Correction to the line above: `searchUsers` is NOT a drop-in for the device list (box-flag-gated, spends one one-time pre-key per device), and answering any caller by id reopens the amendment (xliii) oracle; every prod friendship is pre-box and fetches lists by id (`messaging_provider.box.dart:308-311`), so O32 is the step's critical path.
- **Dropped from step 1:** see decision 107; the version at connect, decision 108.
