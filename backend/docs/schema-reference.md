# Backend schema and messaging reference

Detail relocated from `backend/CLAUDE.md` §4 (database, schema, migrations) and §7 (messages, edit, reactions). The one-line rules stay in `backend/CLAUDE.md`; each points here for the runner contract, per-table facts, incident history and wire detail.

## Migration runner contract (§4)

Entities in `backend/src/**/*.entity.ts` define the dev schema (TypeORM `synchronize` in dev only). Production schema changes go through SQL migrations in `backend/migrations/*.sql`, applied automatically at every backend boot by `src/database/migration-runner.ts` (runs in `main.ts` BEFORE Nest creates the app, all environments).

- Files apply in lexical order, exactly once, tracked by filename in `schema_migrations`; each file runs in one transaction with `lock_timeout=10s` under an advisory lock. A failed migration aborts boot — the container never goes healthy and `deploy-backend.sh` fails loudly.
- `0001_baseline.sql` is the full pre-migration schema. It EXECUTES only on an empty database; on any DB that already has tables (live prod, existing dev DBs) the runner STAMPS it as applied without executing. Only the baseline is ever stamped — every later file runs everywhere.
- No `CREATE INDEX CONCURRENTLY` inside a migration (cannot run in a transaction); that stays manual DBA work.
- Schema-qualify names (`public.messages`) because the baseline clears `search_path` when it executes first on a fresh DB.

## Message index (§4)

The message index exists in the entity as `@Index('idx_messages_conv_created', ['conversation', 'createdAt'])`. If prod needs a descending concurrent index, treat `CREATE INDEX CONCURRENTLY ... "createdAt" DESC` as manual DBA/perf work, not generated entity truth.

## Column casing incident (§4)

Column casing is PER ENTITY — `secret_notes` is camelCase but `refresh_tokens` uses snake_case `user_id`. Unquoted `expires_at` silently broke secret-note reveal with 42703 for weeks; the mocked `repo.query` spec could not catch it.

## repo.query() result shape incidents (§4)

`repo.query()` on Postgres returns `[rows, rowCount]` for DELETE/UPDATE (even with `RETURNING`), plain `rows` only for SELECT. Bit twice:

- Secret-note reveal.
- `key-bundles.service.ts` `fetchPreKeyBundle` OTP claim (2026-07-08): `const [otp]` read the rows ARRAY, so every bundle ever served had `oneTimePreKeyId: null` while still burning the OTP `used=true`. The test_e2e wire harness is what caught it; mocked specs had not, because they did not mock the `[rows, rowCount]` tuple.

## Foreign keys and cascades (§4)

- FKs to `users` with `ON DELETE CASCADE` exist on `key_bundles.userId`, `one_time_pre_keys.userId`, `fcm_token.userId`, `web_push_subscription.userId` (migration `0002_user_foreign_keys.sql`; entities carry matching `@ManyToOne` relations, scalar `userId` columns stay the API).
- `secret_notes.creatorId` and its FK were dropped by `0020_drop_secret_notes_creator.sql` (metadata privacy step 0), reversing 0002's "a note must not outlive its creator" rationale: a note is token + ciphertext + expiry, owned by nobody the server knows, bounded by its ≤24h TTL instead.
- Account-delete service cleanup remains for media files and non-cascading tables; the FKs are the backstop against orphan rows.
- Cascades present: friend request sender/receiver FKs, blocked blocker/blocked FKs, refresh token `user_id`. Conversations/messages do not cascade from users in entities.

## messages.reactions (§4)

Nullable text containing JSON string `{ key: [userId] }`, not a JSON column. Since migration `0018_reaction_keys.sql` the KEY is a blinded 22-char token, not the emoji (`docs/design/reaction-privacy.md`); that migration also NULLed every pre-existing row, so old messages serve `reactions: {}`.

## reaction_keys (§4)

`reaction_keys(conversationId, userId, deviceId, epoch, senderUserId, senderDeviceId, ciphertext, createdAt)`, PK on the first four, FK to `conversations` `ON DELETE CASCADE`, plus `conversations.reactionKeyEpoch int NOT NULL DEFAULT 0`. One Signal-ciphertext copy of the conversation's reaction key per participant device per epoch; clients PULL their own row.

The epoch is SERVER-assigned — `ReactionKeysService.upload` locks the conversation row and accepts only `reactionKeyEpoch + 1`, or the current epoch from the same uploader (top-up); anything else is `stale_epoch` and writes nothing. `senderUserId`/`senderDeviceId` are taken from the authenticated socket, never the payload.

## devices request queue (§4)

`devices."requestSid"` / `"requestSealPub"` (migration `0023`, metadata-privacy PR3.2) hold a device's box REQUEST queue: written only by `setRequestQueue` on the session's own LIVE row, served by `searchUsers` beside one CLAIMED bundle per device (`ChatSearchService` → `ChatKeyExchangeService.claimBundle`, the one door that spends an OTP and fires `preKeysLow`). Contract: `docs/contracts/wire.md` "First contact".

## messages.hiddenByUserIds (§4)

Comma-separated text for delete-for-me. Since 2026-08-03 it is also a DESTRUCTION trigger: `hideMessageForUser` hard-deletes the row (media before row, replies detached first — the `reply_to_message_id` self-FK has no ON DELETE) once EVERY participant id from the conversation relation appears in it. The append is one atomic `UPDATE … RETURNING`; the guard fails closed (missing relation/empty set = never delete) and a one-participant hide must NEVER delete — falsified tests pin all of this in `messages.service.spec.ts`.

## Edit refusal reasons (§7)

`editMessageFailed` reasons: `not_sender`, `window_expired`, `not_text`, `not_found`, or an envelope/device-list refusal (`duplicate_envelope_device`, `self_envelope_for_origin_device`, `unknown_recipient_device`, owed-replacement bounce).

## Reaction DTOs (§7)

WS `addReaction` / `removeReaction` `{ messageId, emoji }`; DTOs accept EITHER one emoji grapheme (basic emoji, VS16, skin tones, ZWJ sequences, flags, keycaps; 32-code-unit cap) OR a 22-char blinded token `^[A-Za-z0-9_-]{22}$` — one explicit compat window, and removing the emoji branch is what closes D10. Participant-checked in `ChatReactionService`; `MessagesService` JSON-parse/stringifies the text column; emits `reactionUpdated` to both sides.

## Reaction key events (§7)

WS `uploadReactionKey` (30/15min) → `reactionKeyUploaded { success, epoch?, error? }`, `fetchReactionKey` (120/15min) → `reactionKeyResponse { conversationId, epoch, senderUserId, senderDeviceId, ciphertext }`, both in `ChatReactionKeyService`. Refusals are `success:false` + a stable code (`invalid_payload`, `unauthorized` — used for a non-participant AND a blocked pair so the block never leaks, `duplicate_envelope_device`, `foreign_recipient`, `stale_epoch`, `rate_limited`), never a bare `error`. Contract in `docs/contracts/wire.md`.
