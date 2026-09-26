# CLAUDE.md — Fireplace Backend (NestJS)

Root rules, production safety, shared wire contracts, version policy, and env overview live in `../CLAUDE.md`. This file is for NestJS/PostgreSQL/server-specific facts only.

Detail lives on demand in `backend/docs/`: **rt** = `runtime-reference.md`, **schema** = `schema-reference.md`, **sec** = `security-reference.md`. `→ rt "X"` means: read heading "X" there before editing that area.

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

Production backend deploy runs on the VM only: `cd ~/fireplace && ./deploy-backend.sh` (what it does → rt "Deploy script").

## 2. Runtime architecture

- `AppModule` imports Config, Schedule, Throttler, TypeORM, and domain modules: auth, media, users, conversations, messages, friends, blocked, FCM tokens, web push subscriptions, key bundles, push notifications, chat, conversation notification preferences, secret notes, health, version, and the **box** (`src/box/`).
- **The box is registered only when `BOX_ENABLED=true`** and imports nothing from `auth/`, `users/`, `chat/`, even transitively (I1, `scripts/verify-box-imports.mjs`, CI); contract `docs/contracts/wire.md` "Box"; suite `npm run test:int` (→ rt "Box module").
- `main.ts` sets trust proxy, helmet, global `ValidationPipe({ whitelist:true })`, CORS, and listens on `PORT || 3000` at `0.0.0.0`.
- Production logger omits debug/verbose. Production CORS is restricted to `ALLOWED_ORIGINS`; dev allows localhost/127.0.0.1/192.168/10.*.
- `ChatGateway` authenticates Socket.IO with `handshake.auth.token`, rejects stale JWTs after password change, joins `user:<id>` AND `device:<userId>:<deviceId>` rooms, emits `socketReady`, and delegates event handlers. Presence is room occupancy; the `onlineUsers` map is retired.
- Chat logic is split across `chat-*` services; shared `ChatValidationService` lives in `ChatValidationModule` (full map → rt "Chat service map").
- DTO validation uses `validateDto()` and class-validator decorators. Do not bypass it with ad hoc object checks. Exception: `src/box/` parses its frames with the strict exact-key parsers in `box-wire.ts` (`validateDto` keeps extras; I1).

## 3. Docker and environment

- Dev `docker-compose.yml` (auto-sync, Postgres on host `5433`) vs prod `docker-compose.prod.yml` (localhost-bound, log rotation, `/health` healthcheck) → rt "Docker".
- Keep per-message, push, and key-refresh logs at `debug` (prod-silent); container logs must not expose recipient IDs, online rosters, or push timing (→ rt "Docker").
- The prod image runs as non-root `USER node` (uid 1000); the media volume must be node-owned (→ rt "Docker").
- `deploy.sh` is legacy/all-in-one; do not use it as backend production deploy path.
- `JWT_SECRET` (≥ 32 chars) is generated once and persisted; never regenerate it on deploy/recreate (rotation procedure → rt "Environment variables").
- `ALLOWED_ORIGINS` is required in prod; the Web Push VAPID public key must match the frontend build. Full env table → rt "Environment variables".

## 4. Database, schema, and migrations

Entities in `backend/src/**/*.entity.ts` define the dev schema (TypeORM `synchronize` in dev only). **Production schema changes go through SQL migrations in `backend/migrations/*.sql`**, applied exactly once at every backend boot by `src/database/migration-runner.ts`; a failed migration aborts boot (runner contract, baseline stamping → schema "Migration runner contract").

- Applied migration files are IMMUTABLE — never edit one, add the next numbered file. No `CREATE INDEX CONCURRENTLY` inside a migration; that stays manual DBA work (incl. a descending messages index → schema "Message index").
- Schema-qualify names (`public.messages`) in migration SQL.
- New schema change = entity update (dev shape) + numbered migration file (prod truth). Dev auto-DDL does not mean prod is done. Rehearse on the staging stack (root `CLAUDE.md` §6) before deploying.
- Raw SQL must quote camelCase: `"deliveryStatus"`, `"hiddenByUserIds"`, `"expiresAt"`, `"createdAt"`. Column casing is PER ENTITY; check the entity, never guess (→ schema "Column casing incident").
- `repo.query()` on Postgres returns `[rows, rowCount]` for DELETE/UPDATE (even with `RETURNING`), plain `rows` only for SELECT — destructure `const [rows] = ...`; mocked `repo.query` specs MUST mock the `[rows, rowCount]` tuple (→ schema "repo.query() result shape incidents").
- `users` unique key is `(username, tag)`, not username alone.
- `friend_requests.status` stores lowercase values (`pending`, `accepted`, `rejected`), unlike uppercase message enums.
- Account deletion relies on `ON DELETE CASCADE` FKs to `users` as the orphan backstop; conversations/messages do not cascade from users (→ schema "Foreign keys and cascades").
- `messages.reactions` is nullable JSON-in-text `{ key: [userId] }` whose key is a blinded 22-char token since `0018` (→ schema "messages.reactions").
- `reaction_keys` epochs are SERVER-assigned; sender ids come from the authenticated socket, never the payload (→ schema "reaction_keys").
- `devices."requestSid"` / `"requestSealPub"` are written only by `setRequestQueue` on the session's own LIVE row (→ schema "devices request queue").
- `messages.hiddenByUserIds` (delete-for-me) hard-deletes the row once EVERY participant hid it; the guard fails closed and a one-participant hide must NEVER delete (→ schema "messages.hiddenByUserIds").

## 5. Auth and sessions

- JWT TTL is 24h. Refresh tokens are stable opaque 365-day sliding sessions: `/auth/refresh` extends the existing row and returns the same refresh token value; do **not** reintroduce single-use rotation because a lost refresh response would strand the client on login. SHA-256 only is stored in `refresh_tokens`.
- `POST /auth/logout` revokes the current refresh token. Password reset sets `passwordChangedAt`, revokes all refresh tokens, and `JwtStrategy.validate()` rejects old tokens with `iat <= passwordChangedAt`.
- Register/login use username#tag model; tag is a 4-digit string.
- Delete account revokes all refresh tokens FIRST, then deletes messages/conversations/friend requests and the user row in one transaction (FCM tokens, Web Push subscriptions, key bundles/OTPs and secret notes fall away by FK cascade). Only after that commit does it run the idempotent side-table purge plus profile-avatar and conversation-media unlinks.

## 6. Socket.IO contracts and rate limits

- Disconnect needs no presence bookkeeping: Socket.IO drops the socket from `user:<id>` itself, so the room empties only when the LAST tab goes (→ rt "Presence on disconnect").
- `ChatValidationService.validateCanMessage(senderId, recipientId)` is the shared blocked+friendship gate for messaging/start conversation.
- `handleStartConversation` requires friendship; emits `openConversation` only to caller and `conversationsList` updates as needed.
- `handleGetMessages` must load the conversation and verify caller membership before querying history. Non-members receive empty `messageHistory`.
- `handleMessageDelivered` must verify caller is the recipient, not sender.
- `handleMarkConversationRead` verifies membership, marks peer-sent messages read, stamps read-based disappearing expiry, and emits `messageDelivered` to sender and reader.
- `conversationsWithUnread` batches unread, last message, and pinned-message reads; do not reintroduce N+1 list queries.
- Gateway throttles are source-truth in `chat.gateway.ts` (summary → rt "Gateway throttles"). `messageDelivered`, `markConversationRead`, typing, voice-recording and several others are not throttled — do not document a blanket "read events throttled" rule.
- Throttle trackers: user id on an authenticated socket, else the nginx `X-Real-IP` (`common/client-ip.ts`), else `handshake.address` — never `handshake.address` first, never X-Forwarded-For. `/box` uses its own `BoxThrottlerGuard` (→ rt "WsThrottlerGuard tracker").
- **`@nestjs/throttler` must stay ≥ 6.7.0**; pinned by `ws-throttler.guard.spec.ts` (→ rt "@nestjs/throttler version floor").

## 7. Messages, disappearing, edit, pin, reactions

- Server never sees plaintext for encrypted messages. Stored `content` is `[encrypted]`; `encryptedContent` holds Signal ciphertext.
- E2E envelope metadata (`messageType`, `mediaUrl`, `mediaDuration`, `mediaKey`, `mediaIv`) is needed for media cleanup and client display; do not strip it because “server is blind”.
- Read-based disappearing messages: send stores `disappearAfterSeconds`, leaves `expiresAt=null`; `markConversationRead` sets `expiresAt = now + disappearAfterSeconds`. Never-read fallback expires at `createdAt + DISAPPEARING_MAX_UNREAD_SECONDS`.
- Expired-message cleanup runs every minute and deletes media files before removing rows.
- Delivery status never downgrades; enforced via `DELIVERY_STATUS_ORDER`.
- Delete-for-everyone deletes media before row removal and clears pin if the deleted message was pinned.
- Edit message: sender-only, TEXT-only, 15-minute window from `createdAt`; stores new ciphertext, stamps `editedAt`, leaves expiry/status untouched; refusals emit `editMessageFailed` with a reason (→ schema "Edit refusal reasons").
- Reactions: WS `addReaction` / `removeReaction`, participant-checked in `ChatReactionService`; DTOs accept an emoji grapheme OR a 22-char blinded token — removing the emoji branch closes D10 (→ schema "Reaction DTOs").
- Reaction keys (`ChatReactionKeyService`): refusals are `success:false` + a stable code, `unauthorized` for a non-participant AND a blocked pair so the block never leaks, never a bare `error` (→ schema "Reaction key events", `docs/contracts/wire.md`).
- Pin/unpin validates conversation membership and message state; delete-for-everyone clears the pin.

## 8. Media and cleanup

- `POST /media/upload` is JWT-guarded, 20/min, 21 MiB; avatars validate magic bytes (types and storage layout → sec "Media upload and storage").
- Avatars are public. `GET /media/msgs/:filename` is JWT-guarded. Filename must be a basename; no path traversal.
- Box media lives in `MEDIA_DIR/box/`, never `msgs/` — the orphan cleanup would delete it (→ sec "Box media location").
- Keep `MEDIA_URL_REGEX` strict to exact self-hosted (or legacy Cloudinary) URLs: URLs later become unlink targets (→ sec "Media upload and storage").
- `LocalStorageService.deleteFile()` has a resolved-path containment check against `MEDIA_DIR`. Keep it even if DTO validation looks strict.
- `MEDIA_X_ACCEL_REDIRECT=true` only works with nginx internal `/internal/media/`; otherwise media responses can become empty 200s.
- Orphan/expired cleanup runs daily at 03:00 and honours `MEDIA_CLEANUP_GRACE_MS` (→ sec "Orphan cleanup").
- Block user / delete conversation / clear history delete self-hosted media before deleting DB rows; do not rely on daily cleanup for user-visible destructive actions.

## 9. Push notifications

- Push is dual-channel: FCM for native android/ios tokens, Web Push for PWA subscriptions. Payloads differ per channel by design (→ rt "Push payloads"):
  - **FCM** `data` transits Google READABLE: content-free wake-up, ONLY `type: 'new_message'` + `conversationId`. NEVER `senderName`, unread counts, message text, or keys.
  - **Web Push** body is E2E-encrypted and may carry richer metadata, but sends NO `topic` header (cleartext to the relay). Never message text or keys.
- FCM initializes from `FIREBASE_SERVICE_ACCOUNT`; absent means disabled. Web Push initializes from VAPID env; absent means disabled.
- Coalescer timings, the `clientVisible` skip rule, and endpoints → rt "Push coalescer and visibility". The client never reports WHICH conversation is open; never store `activeConversationId`.
- Keep the `overrides.firebase-admin.uuid` override scoped and firebase-admin on 13.x (→ rt "firebase-admin and the uuid override").

## 10. Link previews and SSRF

- `ChatLinkPreviewService` skips encrypted messages and non-TEXT messages.
- SSRF defence in `link-preview.service.ts` is two-layer (URL-literal `isPrivateIp` + undici DNS resolve-and-pin) and both layers must stay; do not swap `fetchImpl` back to global `fetch` (→ sec "SSRF defence layers").
- Redirects are manual (max 5), each hop re-validated; do not switch to default fetch follow.
- `og:image` must be HTTPS and non-private; relative image URLs are resolved against page URL.
- Keep the live-loopback pinned-agent test in `link-preview.service.unit.spec.ts` if you touch the agent.

## 11. Secret Notes

- Secret Notes (“Anti-Quantum Note”) are separate from chat E2E. Endpoints → sec "Secret Notes endpoints".
- The AES-GCM key is in the URL fragment, never sent to the server; reveal is an atomic read-once `DELETE ... RETURNING`.
- Expired notes are swept **every minute**; the cadence is pinned by a test — do not relax it (→ sec "Secret Notes sweep cadence").

## 12. REST/media/auth additions checklist

- New REST endpoint: DTO if input is non-trivial, service method, controller route, `JwtAuthGuard` unless deliberately public, throttle if user-triggered, frontend `ApiService` update.
- New WS event: DTO + service handler + gateway `@SubscribeMessage`, throttle decision, frontend socket emit/listener, provider state update, regression test.
- New DB field: entity + mapper payload + frontend model + numbered migration in `backend/migrations/` + test-count update if backend tests change.
- Any destructive path involving media must delete self-hosted files before row deletion or explicitly rely on the orphan cleanup grace logic.
