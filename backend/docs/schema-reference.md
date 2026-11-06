# Backend schema reference

Detail relocated from `backend/CLAUDE.md` §4 (database, schema, migrations). The one-line rules stay in `backend/CLAUDE.md`; each points here for the runner contract, per-table facts, incident history and wire detail.

## Migration runner contract (§4)

Entities in `backend/src/**/*.entity.ts` define the dev schema (TypeORM `synchronize` in dev only). Production schema changes go through SQL migrations in `backend/migrations/*.sql`, applied automatically at every backend boot by `src/database/migration-runner.ts` (runs in `main.ts` BEFORE Nest creates the app, all environments).

- Files apply in lexical order, exactly once, tracked by filename in `schema_migrations`; each file runs in one transaction with `lock_timeout=10s` under an advisory lock. A failed migration aborts boot — the container never goes healthy and `deploy-backend.sh` fails loudly.
- `0001_baseline.sql` is the full pre-migration schema. It EXECUTES only on an empty database; on any DB that already has tables (live prod, existing dev DBs) the runner STAMPS it as applied without executing. Only the baseline is ever stamped — every later file runs everywhere.
- No `CREATE INDEX CONCURRENTLY` inside a migration (cannot run in a transaction); that stays manual DBA work.
- Schema-qualify names (`public.devices`) because the baseline clears `search_path` when it executes first on a fresh DB.

## Column casing incident (§4)

Column casing is PER ENTITY — `secret_notes` is camelCase but `refresh_tokens` uses snake_case `user_id`. Unquoted `expires_at` silently broke secret-note reveal with 42703 for weeks; the mocked `repo.query` spec could not catch it.

## repo.query() result shape incidents (§4)

`repo.query()` on Postgres returns `[rows, rowCount]` for DELETE/UPDATE (even with `RETURNING`), plain `rows` only for SELECT. Bit twice:

- Secret-note reveal.
- `key-bundles.service.ts` `fetchPreKeyBundle` OTP claim (2026-07-08): `const [otp]` read the rows ARRAY, so every bundle ever served had `oneTimePreKeyId: null` while still burning the OTP `used=true`. The test_e2e wire harness is what caught it; mocked specs had not, because they did not mock the `[rows, rowCount]` tuple.

## Foreign keys and cascades (§4)

- FKs to `users` with `ON DELETE CASCADE` exist on `key_bundles.userId` and `one_time_pre_keys.userId` (migration `0002_user_foreign_keys.sql`; entities carry matching `@ManyToOne` relations, scalar `userId` columns stay the API).
- `secret_notes.creatorId` and its FK were dropped by `0020_drop_secret_notes_creator.sql` (metadata privacy step 0), reversing 0002's "a note must not outlive its creator" rationale: a note is token + ciphertext + expiry, owned by nobody the server knows, bounded by its ≤24h TTL instead.
- `DELETE /users/account` (`UsersService.deleteAccount`) revokes refresh tokens first, removes the user row (the rest cascades by FK, e.g. refresh token `user_id`), then purges key bundles and unlinks avatar files; the FKs are the backstop against orphan rows.

## devices request queue (§4)

`devices."requestSid"` / `"requestSealPub"` (migration `0023`, metadata-privacy PR3.2) hold a device's box REQUEST queue: written only by `setRequestQueue` on the session's own LIVE row, served by `searchUsers` beside one CLAIMED bundle per device (`ChatSearchService` → `ChatKeyExchangeService.claimBundle`, the one door that spends an OTP and fires `preKeysLow`). Contract: `docs/contracts/wire.md` "First contact".

## Phase 4 step 5 drop (migration 0027)

`0027_phase4_step5_drop_old_tables.sql` drops, WITHOUT `CASCADE`: `message_envelopes`, `reaction_keys`, `conversation_notification_preferences`, `messages`, `conversations`, `friend_requests`, `blocked_users`, `web_push_subscription`, `fcm_token`, and the enum types `messages_messagetype_enum`, `messages_deliverystatus_enum`, `friend_requests_status_enum`. Nothing references them (no entity, no FK from a kept table); the entities and the code that used them went in the same release. It is NOT reversible by DDL: restore means loading rows from the offline gpg archive (decision 128), never an inverse `CREATE TABLE`.
