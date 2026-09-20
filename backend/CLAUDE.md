# CLAUDE.md — Fireplace Backend (NestJS)

Root rules, production safety, shared wire contracts, version policy, and env overview live in `../CLAUDE.md`. This file is for NestJS/PostgreSQL/server-specific facts only.

## 1. Commands

```bash
cd backend
npm ci
npm run build        # nest build
npm run start:dev    # nest start --watch
npm run start:prod   # node dist/main
npm test             # jest --config jest.config.json
```

Other scripts: `npm run test:watch`, `npm run test:cov`, `npm run test:debug`, `npm run lint` (fixing), `npm run format`.

Backend test count is documented in root `CLAUDE.md`, not here. CI captures backend Jest output and runs `node scripts/verify-claude-backend-test-counts.mjs --log backend/test-output.txt`.

Production backend deploy, on VM only:

```bash
cd ~/fireplace
./deploy-backend.sh
```

`deploy-backend.sh` does `git pull --ff-only`, derives `APP_VERSION` from `frontend/pubspec.yaml`, validates `.env`, builds/up's `docker-compose.prod.yml`, waits for Docker health, curls local `/version` and `/health`.

## 2. Runtime architecture

- `AppModule` imports Config, Schedule, Throttler, TypeORM, and domain modules: auth, media, users, conversations, messages, friends, blocked, FCM tokens, web push subscriptions, key bundles, push notifications, chat, conversation notification preferences, secret notes, health, version.
- `main.ts` sets trust proxy, helmet, global `ValidationPipe({ whitelist:true })`, CORS, and listens on `PORT || 3000` at `0.0.0.0`.
- Production logger omits debug/verbose. Production CORS is restricted to `ALLOWED_ORIGINS`; dev allows localhost/127.0.0.1/192.168/10.*.
- `ChatGateway` authenticates Socket.IO with `handshake.auth.token`, rejects stale JWTs after password change, joins `user:<id>` AND `device:<userId>:<deviceId>` rooms, emits `socketReady`, and delegates event handlers. Presence is room occupancy (`isUserOnline` in `chat/utils/user-room.ts`); the old `onlineUsers: Map<userId, socketId>` is retired.
- Chat service map: `chat-message`, `chat-friend-request`, `chat-conversation`, `chat-key-exchange`, `chat-presence`, `chat-block`, `chat-search`, `chat-reaction`, `chat-reaction-key`, `chat-link-preview`, `chat-device-list`, `chat-device-revocation`, `chat-provisioning`; shared `ChatValidationService` lives in `ChatValidationModule`.
- DTO validation uses `validateDto()` and class-validator decorators. Do not bypass it with ad hoc object checks.

## 3. Docker and environment

- Local `docker-compose.yml`: dev only, Node 22 bind mount, `NODE_ENV=development`, command `npm install && npm run start:dev`, Postgres 16 exposed at host `5433`, TypeORM auto-sync enabled by source.
- Prod `docker-compose.prod.yml`: built image from `backend/Dockerfile`, backend and DB bound to localhost only, `NODE_ENV=production`, persistent `pgdata` and `media_storage`, healthcheck on `http://127.0.0.1:3000/health`, and json-file log rotation capped per service (`max-size: 10m`, `max-file: 3`) so stdout logs cannot grow unbounded on disk. Prod logger is `error/warn/log` only; per-message, push, and key-refresh logs are `debug` (prod-silent) so container-log breach/seizure does not expose recipient IDs, online rosters, or push timing.
- `backend/Dockerfile`: multi-stage build, runtime installs prod deps only, copies `dist` + `migrations/`, sets `NODE_ENV=production`, runs `node dist/main.js` as non-root `USER node` (uid 1000). The media volume must be node-owned: fresh volumes inherit it from the image; volumes created by older root images are chown'd idempotently by `deploy-backend.sh` / `staging.ps1`.
- `deploy.sh` is legacy/all-in-one; do not use it as backend production deploy path.

Backend env source:

| Var | Notes |
|---|---|
| `NODE_ENV`, `PORT` | `production` changes logger, CORS, TypeORM sync. |
| `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASS`, `DB_NAME` | Postgres; prod DB name is `chatdb`. |
| `JWT_SECRET` | Required; validation requires at least 32 chars. Generate once, persist in the VM `.env` and encrypted backups, and copy the current valid value during host moves. Do not regenerate on normal deploy/recreate. If exposed, rotate after sticky-session refresh is deployed: `/auth/refresh` uses the opaque refresh-token hash, not the old access JWT signature, so valid sessions can silently obtain new access JWTs. |
| `ALLOWED_ORIGINS` | Required in prod. |
| `MEDIA_BASE_URL`, `MEDIA_DIR` | Self-hosted media URLs and filesystem root. |
| `MEDIA_CLEANUP_GRACE_MS` | Used by orphan cleanup; default 15 min. Not class-validator validated. |
| `MEDIA_X_ACCEL_REDIRECT` | Use only when nginx has matching internal media route. |
| `FIREBASE_SERVICE_ACCOUNT` | Optional FCM; absent means FCM disabled. |
| `WEB_PUSH_VAPID_PUBLIC_KEY`, `WEB_PUSH_VAPID_PRIVATE_KEY`, `WEB_PUSH_VAPID_SUBJECT` | Web Push. Public key must match frontend build. |
| `APP_VERSION`, `GIT_COMMIT`, `BUILD_TIME` | `/version`; set by deploy script. |

## 4. Database, schema, and migrations

Entities in `backend/src/**/*.entity.ts` define the dev schema (TypeORM `synchronize` in dev only). **Production schema changes go through SQL migrations in `backend/migrations/*.sql`**, applied automatically at every backend boot by `src/database/migration-runner.ts` (runs in `main.ts` BEFORE Nest creates the app, all environments).

- Runner contract: files apply in lexical order, exactly once, tracked by filename in `schema_migrations`; each file runs in one transaction with `lock_timeout=10s` under an advisory lock. A failed migration aborts boot — the container never goes healthy and `deploy-backend.sh` fails loudly.
- `0001_baseline.sql` is the full pre-migration schema. It EXECUTES only on an empty database; on any DB that already has tables (live prod, existing dev DBs) the runner STAMPS it as applied without executing. Only the baseline is ever stamped — every later file runs everywhere.
- Applied migration files are IMMUTABLE — never edit one, add the next numbered file. No `CREATE INDEX CONCURRENTLY` inside a migration (cannot run in a transaction); that stays manual DBA work.
- Schema-qualify names (`public.messages`) in migration SQL — the baseline clears `search_path` when it executes first on a fresh DB.
- New schema change = entity update (dev shape) + numbered migration file (prod truth). Dev auto-DDL does not mean prod is done. Rehearse on the staging stack (root `CLAUDE.md` §6) before deploying.
- Message index exists in entity as `@Index('idx_messages_conv_created', ['conversation', 'createdAt'])`; if prod needs a descending concurrent index, treat `CREATE INDEX CONCURRENTLY ... "createdAt" DESC` as manual DBA/perf work, not generated entity truth.
- Raw SQL must quote camelCase: `"deliveryStatus"`, `"hiddenByUserIds"`, `"expiresAt"`, `"createdAt"`. Column casing is PER ENTITY — `secret_notes` is camelCase but `refresh_tokens` uses snake_case `user_id`; check the entity, never guess (unquoted `expires_at` silently broke secret-note reveal with 42703 for weeks; the mocked `repo.query` spec could not catch it).
- `repo.query()` on Postgres returns `[rows, rowCount]` for DELETE/UPDATE (even with `RETURNING`), plain `rows` only for SELECT — destructure `const [rows] = ...` or you read the wrong shape. Bit twice: secret-note reveal, and `key-bundles.service.ts` `fetchPreKeyBundle` OTP claim (2026-07-08: `const [otp]` read the rows ARRAY → every bundle ever served had `oneTimePreKeyId: null` while still burning the OTP `used=true`; mocked `repo.query` specs MUST mock the `[rows, rowCount]` tuple, and the test_e2e wire harness is what caught it).
- `users` unique key is `(username, tag)`, not username alone.
- `friend_requests.status` stores lowercase values (`pending`, `accepted`, `rejected`), unlike uppercase message enums.
- FKs to `users` with `ON DELETE CASCADE` exist on `key_bundles.userId`, `one_time_pre_keys.userId`, `fcm_token.userId`, `web_push_subscription.userId` (migration `0002_user_foreign_keys.sql`; entities carry matching `@ManyToOne` relations, scalar `userId` columns stay the API). `secret_notes.creatorId` and its FK were dropped by `0020_drop_secret_notes_creator.sql` (metadata privacy step 0), reversing 0002's "a note must not outlive its creator" rationale: a note is token + ciphertext + expiry, owned by nobody the server knows, bounded by its ≤24h TTL instead. Account-delete service cleanup remains for media files and non-cascading tables; the FKs are the backstop against orphan rows.
- Cascades present: friend request sender/receiver FKs, blocked blocker/blocked FKs, refresh token `user_id`. Conversations/messages do not cascade from users in entities.
- `messages.reactions` is nullable text containing JSON string `{ key: [userId] }`, not a JSON column. Since migration `0018_reaction_keys.sql` the KEY is a blinded 22-char token, not the emoji (`docs/design/reaction-privacy.md`); that migration also NULLed every pre-existing row, so old messages serve `reactions: {}`.
- `reaction_keys(conversationId, userId, deviceId, epoch, senderUserId, senderDeviceId, ciphertext, createdAt)`, PK on the first four, FK to `conversations` `ON DELETE CASCADE`, plus `conversations.reactionKeyEpoch int NOT NULL DEFAULT 0`. One Signal-ciphertext copy of the conversation's reaction key per participant device per epoch; clients PULL their own row. The epoch is SERVER-assigned — `ReactionKeysService.upload` locks the conversation row and accepts only `reactionKeyEpoch + 1`, or the current epoch from the same uploader (top-up); anything else is `stale_epoch` and writes nothing. `senderUserId`/`senderDeviceId` are taken from the authenticated socket, never the payload.
- `messages.hiddenByUserIds` is comma-separated text for delete-for-me. Since 2026-08-03 it is also a DESTRUCTION trigger: `hideMessageForUser` hard-deletes the row (media before row, replies detached first — the `reply_to_message_id` self-FK has no ON DELETE) once EVERY participant id from the conversation relation appears in it. The append is one atomic `UPDATE … RETURNING`; the guard fails closed (missing relation/empty set = never delete) and a one-participant hide must NEVER delete — falsified tests pin all of this in `messages.service.spec.ts`.

## 5. Auth and sessions

- JWT TTL is 24h. Refresh tokens are stable opaque 365-day sliding sessions: `/auth/refresh` extends the existing row and returns the same refresh token value; do **not** reintroduce single-use rotation because a lost refresh response would strand the client on login. SHA-256 only is stored in `refresh_tokens`.
- `POST /auth/logout` revokes the current refresh token. Password reset sets `passwordChangedAt`, revokes all refresh tokens, and `JwtStrategy.validate()` rejects old tokens with `iat <= passwordChangedAt`.
- Register/login use username#tag model; tag is a 4-digit string.
- Delete account revokes all refresh tokens FIRST, then deletes messages/conversations/friend requests and the user row in one transaction (FCM tokens, Web Push subscriptions, key bundles/OTPs and secret notes fall away by FK cascade). Only after that commit does it run the idempotent side-table purge plus profile-avatar and conversation-media unlinks.

## 6. Socket.IO contracts and rate limits

- Disconnect needs no presence bookkeeping: Socket.IO drops the socket from `user:<id>` itself, so the room empties only when the LAST tab goes. This retired the old guarded delete of `onlineUsers[userId]`, which an iOS resume (new socket connected before the old one times out) could get wrong.
- `ChatValidationService.validateCanMessage(senderId, recipientId)` is the shared blocked+friendship gate for messaging/start conversation.
- `handleStartConversation` requires friendship; emits `openConversation` only to caller and `conversationsList` updates as needed.
- `handleGetMessages` must load the conversation and verify caller membership before querying history. Non-members receive empty `messageHistory`.
- `handleMessageDelivered` must verify caller is the recipient, not sender.
- `handleMarkConversationRead` verifies membership, marks peer-sent messages read, stamps read-based disappearing expiry, and emits `messageDelivered` to sender and reader.
- `conversationsWithUnread` batches unread, last message, and pinned-message reads; do not reintroduce N+1 list queries.

Gateway throttles are source-truth in `chat.gateway.ts`:

- `sendMessage`, `getMessages`, list fetches: high-volume 300/15min where annotated.
- Mutating chat actions like clear/delete/edit/pin/timer/start are mostly 60/15min.
- Reactions: 120/15min. Search/friend/block/key-rebuild actions have lower limits.
- `messageDelivered`, `markConversationRead`, typing, voice-recording, upload key bundle, accept/reject friend request, and unblock are not all throttled. Do not document a blanket “read events throttled” rule.
- `WsThrottlerGuard` adapts Nest throttler to sockets with a no-op `res.header()` mock and user-id tracker.

## 7. Messages, disappearing, edit, pin, reactions

- Server never sees plaintext for encrypted messages. Stored `content` is `[encrypted]`; `encryptedContent` holds Signal ciphertext.
- E2E envelope metadata (`messageType`, `mediaUrl`, `mediaDuration`, `mediaKey`, `mediaIv`) is needed for media cleanup and client display; do not strip it because “server is blind”.
- Read-based disappearing messages: send stores `disappearAfterSeconds`, leaves `expiresAt=null`; `markConversationRead` sets `expiresAt = now + disappearAfterSeconds`. Never-read fallback expires at `createdAt + DISAPPEARING_MAX_UNREAD_SECONDS`.
- Expired-message cleanup runs every minute and deletes media files before removing rows.
- Delivery status never downgrades; enforced via `DELIVERY_STATUS_ORDER`.
- Delete-for-everyone deletes media before row removal and clears pin if the deleted message was pinned.
- Edit message: sender-only, TEXT-only, 15-minute window from `createdAt`; stores new ciphertext, stamps `editedAt`, leaves expiry/status untouched; rejects with `editMessageFailed` reason `not_sender`, `window_expired`, `not_text`, `not_found`, or an envelope/device-list refusal (`duplicate_envelope_device`, `self_envelope_for_origin_device`, `unknown_recipient_device`, owed-replacement bounce).
- Reactions: WS `addReaction` / `removeReaction` `{ messageId, emoji }`; DTOs accept EITHER one emoji grapheme (basic emoji, VS16, skin tones, ZWJ sequences, flags, keycaps; 32-code-unit cap) OR a 22-char blinded token `^[A-Za-z0-9_-]{22}$` — one explicit compat window, and removing the emoji branch is what closes D10. Participant-checked in `ChatReactionService`; `MessagesService` JSON-parse/stringifies the text column; emits `reactionUpdated` to both sides.
- Reaction keys: WS `uploadReactionKey` (30/15min) → `reactionKeyUploaded { success, epoch?, error? }`, `fetchReactionKey` (120/15min) → `reactionKeyResponse { conversationId, epoch, senderUserId, senderDeviceId, ciphertext }`, both in `ChatReactionKeyService`. Refusals are `success:false` + a stable code (`invalid_payload`, `unauthorized` — used for a non-participant AND a blocked pair so the block never leaks, `duplicate_envelope_device`, `foreign_recipient`, `stale_epoch`, `rate_limited`), never a bare `error`. Contract in `docs/contracts/wire.md`.
- Pin/unpin validates conversation membership and message state; delete-for-everyone clears the pin.

## 8. Media and cleanup

- `POST /media/upload`: JWT-guarded, 20/min, 21 MiB limit; handles `image`, `voice`, `gif`, `file`, `video`, `avatar`. Voice returns `mediaDuration`; file returns `fileName`; video takes the same opaque `msgs/` path as `file` and echoes `mediaDuration`; avatar validates magic bytes.
- Avatars are public. `GET /media/msgs/:filename` is JWT-guarded. Filename must be a basename; no path traversal.
- `LocalStorageService` writes avatars to `avatars/<uuid>.(jpg|png)` and encrypted message blobs to `msgs/<uuid>.bin` under `MEDIA_DIR`.
- `MEDIA_URL_REGEX` allows either legacy Cloudinary HTTPS upload URLs or exact self-hosted `${MEDIA_BASE_URL}/media/(avatars|msgs)/<filename>.<ext>` with one path segment. This prevents SSRF/path traversal because URLs later become unlink targets.
- `LocalStorageService.deleteFile()` has a resolved-path containment check against `MEDIA_DIR`. Keep it even if DTO validation looks strict.
- `MEDIA_X_ACCEL_REDIRECT=true` only works with nginx internal `/internal/media/`; otherwise media responses can become empty 200s.
- Orphan/expired cleanup runs daily at 03:00. It scans `msgs`, compares non-expired references vs all references, skips files newer than `MEDIA_CLEANUP_GRACE_MS` (default 15 min), logs `scanned/deleted/orphan/expired/graceSkipped`.
- Block user / delete conversation / clear history delete self-hosted media before deleting DB rows; do not rely on daily cleanup for user-visible destructive actions.

## 9. Push notifications

- Push is dual-channel: FCM for native android/ios tokens, Web Push for PWA subscriptions.
- Payloads differ per channel by design (metadata-privacy contract — verify in `push-notifications.service.ts`):
  - **FCM** `data` transits Google READABLE, so it is a content-free wake-up: ONLY `type: 'new_message'` + `conversationId` (opaque int, for notification tap-routing/dedup). NEVER `senderName`, unread counts, message text, or keys. The app wakes on the signal and fetches real state over its own socket. (Android handler already renders a generic title/body and ignores senderName, so this is a pure server-side win.)
  - **Web Push** body is E2E-encrypted to the browser, so it may carry richer metadata (`type`, `conversationId`, `unreadCount`, `unreadTotal`, `unreadConversationIds`, `senderName`) — but sends NO `topic` header: a `conv-<id>` topic is cleartext to the relay (Mozilla/Apple/Google) and would leak per-conversation cadence. Never message text or keys.
- FCM initializes from `FIREBASE_SERVICE_ACCOUNT`; absent means disabled. Web Push initializes from VAPID env; absent means disabled.
- Coalescer buckets by `(recipientUserId, conversationId)`, debounce 2500 ms, max wait 10000 ms, latest `senderName` wins, and suppresses identical count repeat within 10000 ms.
- Push scheduling is skipped only when recipient socket exists and `client.data.pushClientState` says client visible + active conversation matches.
- `pushClientState` is set by WS event and stored on `client.data`; frontend should set `clientVisible=false` on inactive/background.
- Web Push subscriptions: `POST /users/web-push-subscription`, `DELETE /users/web-push-subscription`.
- FCM token endpoints: `POST /users/fcm-token`, `DELETE /users/fcm-token`.
- `package.json` pins a scoped `overrides.firebase-admin.uuid = ^11.1.1`: `uuid < 11.1.1` is vulnerable (GHSA-w5hq-g745-h8pq) and 11.1.1 is the only patched line, but the sole consumer is firebase-admin's transitive google-cloud chain (`gaxios`/`teeny-request`), which only calls `uuid.v4()` — stable across the major. Keep it scoped (not top-level) and keep firebase-admin on 13.x: v14 moved to the modular SDK and drops the `admin.apps`/`admin.credential`/`admin.messaging()` namespace this service uses, so a 14 bump needs a code migration + a live FCM smoke test, not just a version change.

## 10. Link previews and SSRF

- `ChatLinkPreviewService` skips encrypted messages and non-TEXT messages. The only user-URL fetch surface is `POST /messages/link-preview` (JWT-guarded) plus the async fire-and-forget path for legacy plaintext messages.
- SSRF defence in `link-preview.service.ts` is two-layer and both layers must stay: (1) URL-literal — `isPrivateIp` byte-parses the WHATWG-normalized hostname, so decimal/hex/octal IPv4, IPv4-mapped/NAT64 IPv6, `0.0.0.0`, CGNAT, ULA, and link-local literals are all rejected (replaced the old `PRIVATE_IP_RE`, which missed those and false-matched any `fd*` host). (2) DNS resolve-and-pin — every outbound request goes through an undici `Agent` whose `connect.lookup` (`ssrfSafeLookup`) resolves all A/AAAA records and refuses the connection if ANY is private; the socket dials only those validated addresses, so DNS-rebinding cannot bypass it. Do not swap `fetchImpl` back to global `fetch` — that drops the pin.
- Redirects are manual (`redirect:'manual'`, max 5); every hop is re-validated at the literal layer before the next fetch and re-pinned at the DNS layer on connect. Do not switch to default fetch follow.
- `og:image` must be HTTPS and non-private; relative image URLs are resolved against page URL.
- `undici` is a direct dependency specifically for the pinned-DNS agent; its `connect.lookup` wiring is proven end-to-end by a test in `link-preview.service.unit.spec.ts` (drives a live loopback server; a fail-open would serve a request). Keep that test if you touch the agent.

## 11. Secret Notes

- Secret Notes (“Anti-Quantum Note”) are separate from chat E2E.
- `POST /notes` (JWT) stores ciphertext and returns a random 16-byte hex token. `expiresIn` is whitelisted to 1h/6h/12h/24h (any other value → 6h default). Ciphertext max 65536 chars.
- `GET /note/:token` is public server-rendered HTML. AES-GCM key is in URL fragment (`#key`), never sent to server.
- `POST /note/:token/reveal` is public read-once: atomic `DELETE ... WHERE token AND "expiresAt" > NOW() RETURNING ciphertext`.
- `GET /note/:token/status` (JWT, 120/min) returns `{ alive }` for the in-chat banner: the client flips the card to "burned — it was read" when the note is gone before its `e=` fragment clock ran out. Legacy links without `e=` cannot distinguish read-vs-expired and keep the generic destroyed state; after the clock passes, read-vs-expired is indistinguishable by design (the row is deleted on reveal).
- Expired notes are lazy-deleted on reveal and swept **every minute** (`@Cron(EVERY_MINUTE)`, matching `MessageCleanupService`). It was daily-at-03:00 until 2026-08-02, which left an UNREAD expired note's ciphertext in the table for up to ~24h past its TTL — the API refuses to serve it, but the AES key travels in the note URL and that URL is stored as ordinary plaintext message content, so DB access plus device access read a note the UI already called self-destructed. The cadence is pinned by a test; do not relax it.

## 12. REST/media/auth additions checklist

- New REST endpoint: DTO if input is non-trivial, service method, controller route, `JwtAuthGuard` unless deliberately public, throttle if user-triggered, frontend `ApiService` update.
- New WS event: DTO + service handler + gateway `@SubscribeMessage`, throttle decision, frontend socket emit/listener, provider state update, regression test.
- New DB field: entity + mapper payload + frontend model + numbered migration in `backend/migrations/` + test-count update if backend tests change.
- Any destructive path involving media must delete self-hosted files before row deletion or explicitly rely on the orphan cleanup grace logic.
