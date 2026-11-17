# Metadata Stored by Fireplace

This document describes what the Fireplace (Umbra) server stores and can observe, and why. It is meant for transparency and user trust. It reflects the code since 0.2.76, the release that removed the old message path (Phase 4 step 5). Every accepted residual is recorded in `docs/plans/metadata-privacy-decisions.md`, which is the authority.

## What the server cannot see

- **Message content.** Messages, reactions, edits, deletes, pins, receipts, typing and profile updates are all end-to-end encrypted (Signal Protocol) inside fixed-size 16 KiB box blobs.
- **Who sends to whom.** A message goes into an anonymous box queue. The queue row names no account, device, sender or peer (`box_queues`, invariant I2), and a `send` is unsigned and carries no sender key (`box_msgs` has no sender column).
- **Your friends, chats and blocks.** These live only on your devices. The server keeps no friendship, request, conversation, message or block table: `friend_requests`, `conversations`, `messages`, `message_envelopes` and `blocked_users` were dropped in 0.2.76. A block is device-only (decision 126).
- **Read and delivery state.** Receipts travel inside the encryption. The server only learns that a blob was taken (`ack` deletes it).
- **Profile photos.** Since 0.2.79 a photo travels as encrypted box media, and search returns no photo (decision 138). Old server copies are deleted in release B (see below).

## What the server stores

| Data | Stored in | Purpose | Retention / cleanup |
|------|-----------|---------|---------------------|
| Account | `users` | Username, tag, password hash, created and password-changed times | Until account deletion |
| Devices | `devices` | Which devices an account has (added/revoked times) and each device's public request-queue address (`requestSid`) | Until account deletion |
| Public keys | `key_bundles`, `one_time_pre_keys`, `account_authorizations` | Public E2E key material and the signed device list; no private keys | Until account deletion |
| Sessions | `refresh_tokens` | Login sessions, one row each. `expires_at` slides on every refresh, so it shows last activity to about a day. A native session's token rotates on every refresh (plan B4); the row keeps only the hashes of the current token and the one it replaced, so no per-refresh history | Until logout, revoke, reuse of an old token, expiry or account deletion |
| Recovery and identity resets | `recovery_keys`, `identity_reset_requests`, `identity_change_audit` | The recovery-phrase verifier and the reset ceremony | Until account deletion |
| Box queues | `box_queues` | Random ids (`rid`, `sid`, `nid`) and the queue's auth key; no account. `touchedDay` is the UTC day of the last subscribe and feeds only the 90-day reaper | Deleted by the owner (unfriend, revoke, #234), or reaped after 90 idle days |
| Undelivered blobs | `box_msgs` | 16 KiB ciphertext waiting for its recipient | Deleted on `ack`, else after 30 days |
| Box media | `box_media` + disk | Encrypted attachments that fill a size rung (4 KiB … 32 MiB), linked to no queue. Since 0.2.83 the file's length is padded and sealed inside the encryption, so the server sees the rung only; a file from an older sender still shows its exact size (plan A1) | Until `expiresAt` (14 days) |
| Push notifiers | `box_notifiers` | One verified push endpoint (FCM token or Web Push subscription) per inbound queue | Deleted with its queue |
| Contact backup | `contact_backups` | One opaque encrypted blob per account (see below) | Until account deletion |
| Secret notes | `secret_notes` | Random token, ciphertext and expiry; no creator id | Deleted on reveal, on expired access, or by the per-minute cleanup |
| Old profile photos | `user_profile_photos`, `users.profilePictureUrl` | Pre-0.2.79 server photos, kept only for migration | Deleted by release B, about 30 days after 0.2.79 (decision 138) |

`contact_messages` and `contact_push_subscriptions` (migrations 0009 and 0010) are dormant tables from an old contact form: no backend code reads or writes them, and both held 0 rows on prod on 2026-11-11.

## What the server can still learn (accepted residuals)

- **Internet addresses and timing.** Every connection shows an IP address and a time; box throttles are per IP. Someone running the server could try to correlate one person's send with another person's receive by time. Hiding that needs an anonymity network, which was dropped (decision R82).
- **Handle lookups.** "A looked up B": at an invite accept (decisions 53, 56), and at most once per 24 h for a friend who has no delivery address yet (decision 120).
- **A device's request queue is tied to its account.** `devices.requestSid` is the same bytes as that queue's `sid` (the I2b exception, decision 1). The address is public by design: anyone who searches the handle gets it.
- **One device's queues can be grouped.** Each normal inbound queue on a device registers a notifier on that device's single push token (E9). The server can therefore group one device's queues, which shows how many contacts it has and when each one receives a message, though not whose device it is. Request queues get no notifier (decision 2).
- **A shared attachment links its receivers.** An attachment is uploaded once and every addressed device downloads the same id, which links the queues that received it (decision 44).
- **Revoked-device check.** A closed device's revoked check follows a push wake-up by about a second, so the server could link "queue X woke" with "this session refreshed", at most once per device per 24 h (decision 131).
- **Push providers.** Google (FCM) and Apple/Mozilla/Microsoft (Web Push) see that a device was woken. FCM wake-ups carry only `{type:'new_message'}`; Web Push payloads are encrypted (RFC 8291).

**Known gaps, not accepted, being fixed** (`docs/plans/2026-11-16-security-hardening.md`): on web, link-preview URLs reach the server with the user's session (C4); a receiver loads a link preview's image from the sender's chosen host (C1). The app's own fonts are bundled since 0.2.86 (C3); on web only, Flutter's CanvasKit renderer still downloads its default font (Roboto) from Google's font server on every page load, and Noto/emoji fallback fonts when a glyph is missing.

**GIF search (Giphy)** is off by default since 0.2.87 (C2, decision 141): only a user who turns it on talks to Giphy, which then sees that user's searches, the previews they load, the GIF they pick and their IP address. A GIF they send travels as encrypted media; its receiver never contacts Giphy.

**Camera metadata:** since 0.2.83 a photo (JPEG, PNG, WebP) or video (MP4/MOV) loses its GPS position, capture time, device model and embedded thumbnail on the sending device, before encryption (plan A2); a JPEG keeps only its orientation. A file sent as a document, a GIF, a HEIC photo or a WebM video goes as it is.

## Why this metadata is needed

- **Delivery:** a queue must exist and hold a blob until its recipient takes it.
- **Wake-ups:** a closed phone can only be woken through its push token.
- **Accounts and keys:** login, device linking and session setup need public keys and a device list.
- **Abuse limits:** per-IP throttles and size rungs keep an unauthenticated box from filling the disk.

## Retention and logging

- **Box:** a blob lives until it is acked or 30 days pass; a queue lives until its owner deletes it or 90 idle days pass; media lives until its `expiresAt`.
- **Secret notes:** one-shot; expired unread notes are purged every minute.
- **Backups:** a nightly `backup-db.sh` dump (database plus media volume, GPG-encrypted) is kept 14 days on the VM. A copy goes to Cloudflare R2, pruned by a lifecycle rule set in the Cloudflare dashboard, not in this repo (on 2026-11-17 the oldest copy was from 2026-10-17: about 31-32 days). Deleted data, undelivered blobs and deleted accounts therefore survive in backups for that long. The pre-box tables dropped in 0.2.76 were kept in an encrypted archive (`step5-archive-20261106T153338Z`, on the VM and the owner's PC) until 2026-11-16, when both copies were deleted (decision 140). Offsite copies of the nightly backups taken before the drop expire under the Cloudflare rule (about 32 days, so by about 2026-12-08).
- **Logging:** backend log strings carry no account ids or usernames (CI-guarded by `scripts/verify-no-user-logs.mjs`); no raw tokens, keys, ciphertext or message content. Docker keeps each service's log to 3 files of 10 MB (`docker-compose.prod.yml`).
- **Web server logs:** nginx's access log is off for the app's host since 2026-09-20, and its error log records only `crit` faults (`infra/nginx/fireplace.conf`). Rotated access logs from 6–19 September 2026 (IP addresses and paths) had stayed on the VM because logrotate's `notifempty` never rotated the now-empty log; they were deleted on 2026-11-17 with the owner's OK, and the VM's `/etc/logrotate.d/nginx` now says `ifempty`, so rotated nginx logs (the error log's older `client:` lines too) age out after 14 days.
- **Closed activity clocks (2026-09-20):** `devices.lastSeenAt`, `secret_notes.creatorId` and the every-connect re-stamp of `key_bundles.updatedAt` are gone. Still present and not presence-free: `refresh_tokens.expires_at`/`created_at`, `one_time_pre_keys.createdAt/used`, `devices.addedAt/revokedAt`, `users.createdAt/passwordChangedAt`, `box_notifiers.verifiedAt`, `box_queues.touchedDay` (day granularity), and the identity-reset and recovery timestamps.
- **Contact backup, what it does and does not leak (PR2.4):** the row's `blob` is AES-256-GCM under a content key the server never receives. That key is wrapped under PBKDF2-HMAC-SHA256 (600 000) of the account password and, when the user has enrolled one, of the recovery phrase. The login sends that same password to the server, so a malicious server operator could unwrap the backup (plan B3).
  - The server learns three things and no more: that an account has a backup, its size **rounded up to a 4 KiB bucket**, and when it last CHANGED.
  - The bucketing matters: AES-GCM is length-preserving, so an unpadded blob's length would estimate the contact count from a `pg_dump` with no key. The plaintext is padded to `kContactBackupPadBlock` before sealing, so one contact and ten look the same.
  - `updatedAt` does NOT move for an unchanged graph. The client decides that on the PLAINTEXT before sealing, because a fresh GCM IV makes every re-seal different bytes. An idle reconnect therefore leaves no trace.
  - The blob excludes this device's queue private keys.
  - **Web caveat:** on web the cached content key sits in cleartext `localStorage` next to the session tokens, so a browser profile plus a database dump reads the contact graph. On Android it is Keystore-backed. This is the accepted price of a PWA that survives its own eviction.
- **History backup (PR2.3) never reaches the server.** Decrypted history has no server copy, so its backup is a FILE the user holds, sealed under a passphrase only they choose (PBKDF2-HMAC-SHA256 600 000 + AES-256-GCM). Export works on every platform; import is Android-only. Signal key material is not in that file; the identity has its own phrase-sealed backup.
  - **Storage-loss notice, accepted residual on web (owner decision 2026-09-22):** the "this device lost its local store" notice fires only where destruction is PROVEN (the native opener recreating an unreadable SQLCipher file). A PWA that loses IndexedDB while its tokens survive has its contacts restored silently and loses decrypted history with no notice.

## Key storage (E2E)

- **Android:** keys in the Keystore (hardware-backed when available); messages in SQLCipher. If SQLCipher fails to open, the session runs without its content store and writes no content in plaintext (plan A3, 0.2.84). There is no native iOS app yet.
- **Web:** Signal keys, sealing keys and session tokens sit in `localStorage`, together with the key that unwraps them (`signal_stores.dart:29-49`). That is obfuscation, not encryption: anyone who can read the browser profile, or a script injected into the page, can read them. Privacy & Safety shows a web-specific warning; the native app is recommended.
