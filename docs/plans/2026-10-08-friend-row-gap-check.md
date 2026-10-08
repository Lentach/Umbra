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

0. **Cull inactive and test accounts first** (decision 100; the owner confirms the threshold and the list). Through the app's account-delete path, not raw SQL. Their friends' devices then drop them as contacts and lose the text of those chats (both intended for a deleted account). Prod 10-08, by last refresh: 20 seen in 7 d, 8 more in 30 d, 23 more in 90 d, 14 older, 54 with no live session.
1. **Client hardening release** (no server data touched): stop deleting on absence (friends removed only on `unfriended`/block/decline events; the reconcile refuses an answer that orphans every id it asked about); mark every current friend device-owned and carry its chat id, request-queue addresses and device list in the contact backup; merge the backup on a 409 instead of last-writer-wins; send the app version at connect. Old-path history is NOT rendered locally: it may go (decision 99).
2. **Measure**: devices by version, accounts with friends and no backup; owner decides when it is enough.
3. **Freeze behind an env flag** (rows untouched): no new rows in the old tables (old-path sends and requests refused; only the existing disappearing-message expiry still deletes), versions below step 1 told to update. The list handlers keep serving the frozen rows: a complete frozen list cannot trigger the partial-list sweep, and silencing `conversationsList` would force a reconnect on every resume (`connection_provider.dart:1118-1126`). Watch 1–2 weeks. Undo = flip the flag.
4. **Cut over** account delete, block, unfriend, device-list entitlement, security push (R78), profiles; then the list handlers and `getServedMessageIds` are removed (silence, never `[]`).
5. **Archive, then DROP** (never `DELETE` rows under live code): an encrypted dump kept offline, then `DROP TABLE` with the code removal in the same release.

Before steps 3 and 5: a rehearsal on a restored copy of the prod backup with an old APK (0.2.61), a PWA and the new build; each device's contact count must be identical before and after. Before step 4: confirm with `git log -L` that every build still able to connect reads a missing `servedMessageIds` reply as "no answer", not as an empty set (checked only at HEAD: `connection_provider.dart:962-965`). Decision 99 accepts losing old-path text, but users are told first.

Owner decisions 97–100 (10-08) apply. Phase 4 stays the owner's call (decision 86).
