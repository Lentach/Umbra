# Metadata Stored by Fireplace

This document describes what metadata the Fireplace server stores and why. It is intended for transparency and user trust.

## What the Server CANNOT See

- **Message content** — End-to-end encrypted (Signal Protocol). Server stores only ciphertext and `[encrypted]` placeholder.
- **Reply-to content** — For encrypted messages, server stores `Encrypted message` placeholder only.

## What the Server CAN See (Metadata)

The server needs certain metadata to deliver messages and manage conversations.

| Data | Stored in | Purpose | Retention / cleanup |
|------|-----------|---------|---------------------|
| User identity | `users` | Account (username, tag, profile picture) | Until account deletion |
| Conversation membership | `conversations` | Who is in each chat (user_one_id, user_two_id) | Until conversation delete, unfriend, block, or account deletion |
| Message routing | `messages` | sender_id, conversation_id — who sent what, to which conversation | Until message/conversation deletion, disappearing-message expiry, or account deletion |
| Timestamps | `messages`, `conversations` | createdAt — when messages/conversations were created | Same lifecycle as the row that owns the timestamp |
| Delivery status | `messages` | SENT, DELIVERED, READ — for read receipts and unread counts | Same lifecycle as message row |
| Friend graph | `friend_requests` | Who is friends with whom | Until unfriend, account deletion, or request cleanup path |
| Block graph | `blocked_users` | Who blocked whom | Until unblock or account deletion |
| Key bundles | `key_bundles`, `one_time_pre_keys` | Public keys for E2E (no private keys) | Until account deletion; used pre-keys are kept for protocol bookkeeping |
| Push tokens | `fcm_tokens` | Push delivery token and platform | Until logout/token removal, invalid token response, or account deletion |
| Secret notes | `secret_notes` | Random token, ciphertext, expiry — no creator id (dropped 2026-09-20) | Deleted on reveal, on expired access, or by the per-minute expired-note cleanup |
| Message media blobs | disk `msgs/*.bin` | Encrypted image/voice/GIF/file payloads | Deleted on destructive chat paths where possible; orphan/expired blobs are swept daily |

## Why This Metadata Is Needed

- **Routing:** The server must know the recipient to deliver a message.
- **Display:** The recipient needs to know who sent each message (sender_id).
- **Access control:** Only conversation participants can read messages.
- **Offline/history:** Messages are stored so users can fetch them when they reconnect.

## Retention & Logging

- **Disappearing messages:** Expired rows are checked every minute. If they reference self-hosted media, the media file is deleted before the message row is removed.
- **Secret notes:** Notes are one-shot. Expired unread notes are also purged daily so ciphertext is not retained indefinitely.
- **Media cleanup:** Conversation deletion, clear history, unfriend, block, and account deletion delete known self-hosted message media where possible. A daily media cleanup removes orphaned or expired `msgs/*.bin` files that remain after crashes or legacy paths.
- **Local plaintext cache:** The client may cache decrypted message fields locally for recovery/performance. The cache is capped per user and can be cleared from Privacy & Safety without deleting Signal keys or server history.
- **Data retention:** General metadata is stored only while the account, relationship, conversation, or message exists. `METADATA_RETENTION_DAYS` is still reserved for a future global auto-purge policy and is not a broad server-side deletion switch today.
- **Logging:** Production logs should avoid raw tokens, keys, ciphertext, message content, and unnecessary user/conversation/message identifiers. Use operational error messages and narrow identifiers only when needed for debugging or security investigation.

## Key Storage (E2E)

- **Mobile:** Keys in Keychain (iOS) / Keystore (Android) — hardware-backed when available.
- **Web:** Keys in browser storage, encrypted with WebCrypto. Uses app-specific db (`FireplaceE2E`). Someone with device access could potentially extract them. Privacy & Safety screen shows a web-specific warning; mobile app recommended for maximum security.

## Future Improvements

See `docs/plans/2026-03-11-metadata-privacy-design.md` for options to reduce metadata visibility (e.g. Sealed Sender).
