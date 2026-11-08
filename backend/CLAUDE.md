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

- `AppModule` imports Config, Schedule, Throttler, TypeORM, and the domain modules: auth, media (avatars only), users, key bundles, backup (contact backups), chat, link preview, secret notes, health, version, and the **box** (`src/box/`).
- **The old server chat path is gone (Phase 4 step 5, migration `0027`).** There are no conversations, messages, friend requests, blocks, reaction keys, mute preferences or account push tables, no modules or services for them, no `msgs/` attachment routes or sweep, and no `LEGACY_*` env flags. Friends, chats, history and blocks live on devices and travel over the box. Contract: `docs/contracts/wire.md` "Step 5: the old path is gone".
- **The box is registered only when `BOX_ENABLED=true`** and imports nothing from `auth/`, `users/`, `chat/`, even transitively (I1, `scripts/verify-box-imports.mjs`, CI); contract `docs/contracts/wire.md` "Box"; suite `npm run test:int` (→ rt "Box module").
- `main.ts` sets trust proxy, helmet, global `ValidationPipe({ whitelist:true })`, CORS, and listens on `PORT || 3000` at `0.0.0.0`.
- Production logger omits debug/verbose. Production CORS is restricted to `ALLOWED_ORIGINS`; dev allows localhost/127.0.0.1/192.168/10.*.
- `ChatGateway` authenticates Socket.IO with `handshake.auth.token`, rejects stale JWTs after password change, joins `user:<id>` AND `device:<userId>:<deviceId>` rooms, emits `socketReady`, and delegates event handlers. Presence is room occupancy; the `onlineUsers` map is retired. It handles ONLY key/device/identity/provisioning/revocation events, `searchUsers`, the request-queue events, `typing`/`recordingVoice`, `requestSessionRebuild` and `getServerTime`; an old-path event is simply unanswered.
- Chat logic is split across `chat-*` services (full map → rt "Chat service map").
- DTO validation uses `validateDto()` and class-validator decorators. Do not bypass it with ad hoc object checks. Exception: `src/box/` parses its frames with the strict exact-key parsers in `box-wire.ts` (`validateDto` keeps extras; I1).

## 3. Docker and environment

- Dev `docker-compose.yml` (auto-sync, Postgres on host `5433`) vs prod `docker-compose.prod.yml` (localhost-bound, log rotation, `/health` healthcheck) → rt "Docker".
- Keep per-message, push, and key-refresh logs at `debug` (prod-silent); container logs must not expose recipient IDs, online rosters, or push timing (→ rt "Docker").
- The prod image runs as non-root `USER node` (uid 1000); the media volume must be node-owned (→ rt "Docker").
- `deploy.sh` is legacy/all-in-one; do not use it as backend production deploy path.
- `JWT_SECRET` (≥ 32 chars) is generated once and persisted; never regenerate it on deploy/recreate (rotation procedure → rt "Environment variables").
- `ALLOWED_ORIGINS` is required in prod; the Web Push VAPID public key must match the frontend build. `FIREBASE_SERVICE_ACCOUNT` and `WEB_PUSH_VAPID_*` now feed the box wake-up push only. Full env table → rt "Environment variables".

## 4. Database, schema, and migrations

Entities in `backend/src/**/*.entity.ts` define the dev schema (TypeORM `synchronize` in dev only). **Production schema changes go through SQL migrations in `backend/migrations/*.sql`**, applied exactly once at every backend boot by `src/database/migration-runner.ts`; a failed migration aborts boot (runner contract, baseline stamping → schema "Migration runner contract").

- Applied migration files are IMMUTABLE — never edit one, add the next numbered file. No `CREATE INDEX CONCURRENTLY` inside a migration; that stays manual DBA work.
- Schema-qualify names (`public.devices`) in migration SQL.
- New schema change = entity update (dev shape) + numbered migration file (prod truth). Dev auto-DDL does not mean prod is done. Rehearse on the staging stack (root `CLAUDE.md` §6) before deploying.
- Raw SQL must quote camelCase: `"requestSid"`, `"expiresAt"`, `"createdAt"`. Column casing is PER ENTITY; check the entity, never guess (→ schema "Column casing incident").
- `repo.query()` on Postgres returns `[rows, rowCount]` for DELETE/UPDATE (even with `RETURNING`), plain `rows` only for SELECT — destructure `const [rows] = ...`; mocked `repo.query` specs MUST mock the `[rows, rowCount]` tuple (→ schema "repo.query() result shape incidents").
- `users` unique key is `(username, tag)`, not username alone.
- **`0027_phase4_step5_drop_old_tables.sql` dropped `message_envelopes`, `reaction_keys`, `conversation_notification_preferences`, `messages`, `conversations`, `friend_requests`, `blocked_users`, `web_push_subscription` and `fcm_token`** (no cascade). It is NOT reversible by DDL: restore means loading rows from the offline gpg archive (decision 128), and no code reads them (→ schema "Phase 4 step 5 drop (migration 0027)").
- Account deletion relies on `ON DELETE CASCADE` FKs to `users` as the orphan backstop (→ schema "Foreign keys and cascades").
- `devices."requestSid"` / `"requestSealPub"` are written only by `setRequestQueue` on the session's own LIVE row (→ schema "devices request queue").

## 5. Auth and sessions

- JWT TTL is 24h. Refresh tokens are stable opaque 365-day sliding sessions: `/auth/refresh` extends the existing row and returns the same refresh token value; do **not** reintroduce single-use rotation because a lost refresh response would strand the client on login. SHA-256 only is stored in `refresh_tokens`.
- `POST /auth/logout` revokes the current refresh token. Password reset sets `passwordChangedAt`, revokes all refresh tokens, and `JwtStrategy.validate()` rejects old tokens with `iat <= passwordChangedAt`.
- Register/login use username#tag model; tag is a 4-digit string.
- Delete account revokes all refresh tokens FIRST, then removes the user row (key bundles/OTPs, devices, profile photos, recovery rows and the contact backup fall away by FK cascade). Only after that does it run the idempotent key-bundle purge and the avatar-file unlinks. Friends are told over the box by the client BEFORE this call (decision 113); the server tells nobody.

## 6. Socket.IO contracts and rate limits

- Disconnect needs no presence bookkeeping: Socket.IO drops the socket from `user:<id>` itself, so the room empties only when the LAST tab goes (→ rt "Presence on disconnect").
- `typing` / `recordingVoice` (`ChatPresenceService`) relay to a recipient that has a live socket after DTO validation, with no friend or block check and no database access (decision 126: a block is device-only).
- `getDeviceList` / `getDeviceLists` answer ONLY the caller's own user id; any other id is silence (`[device-list] REFUSED reason=not_entitled`), with no friendship or conversation lookup.
- `searchUsers` and `fetchPreKeyBundle` stay by-id/handle oracles for any authenticated caller (rate-limited); with `BOX_ENABLED` off `searchUsers` serves no device or list.
- Gateway throttles are source-truth in `chat.gateway.ts` (summary → rt "Gateway throttles"). `typing`, `recordingVoice` and several others are not throttled.
- Throttle trackers: user id on an authenticated socket, else the nginx `X-Real-IP` (`common/client-ip.ts`), else `handshake.address` — never `handshake.address` first, never X-Forwarded-For. `/box` uses its own `BoxThrottlerGuard` (→ rt "WsThrottlerGuard tracker").
- **`@nestjs/throttler` must stay ≥ 6.7.0**; pinned by `ws-throttler.guard.spec.ts` (→ rt "@nestjs/throttler version floor").

## 7. Security alerts and key events

- A key-bundle upload that REPLACES the stored identity emits `ownIdentityReplaced` to the account's OTHER live sockets only; reset ceremony and recovery-key events (`identityResetPending`, `identityResetCancelled`, `recoveryKeyEnrolled`) go to the account's live sockets. There is NO account push and NO `peerIdentityChanged` (decisions 115, 116): a closed app learns at its next open from `ownKeyBundleStatus` (`identityReset`, `identityReplacedAt`, `hasRecoveryPhrase`).
- The server never sees plaintext and keeps no message, friend or chat row; ciphertext lives only in the box queues until delivered (decision 86).

## 8. Media and cleanup

- Avatars are the only account-keyed files, and nothing writes them any more (decision 138): `POST /users/profile-picture` and every `/users/profile-photos/*` route are gone (404), and `searchUsers` answers carry no photo field. `GET /media/avatars/:filename` (public, basename only; types and layout → sec "Media storage") and `GET /users/me` `profilePictureUrl` stay for the one-time client migration; account delete still unlinks the files. Release B deletes the rest.
- There is no `POST /media/upload`, no `GET /media/msgs/*` and no media sweep. Old `msgs/` files that survive on a volume are read, served and swept by nothing; the deploy that applied `0027` archives and removes them.
- Box media lives in `MEDIA_DIR/box/` (→ sec "Box media location").
- `LocalStorageService.deleteFile()` has a resolved-path containment check against `MEDIA_DIR`. Keep it even if DTO validation looks strict.
- `MEDIA_X_ACCEL_REDIRECT=true` only works with nginx internal `/internal/media/`; otherwise media responses can become empty 200s.

## 9. Push notifications

- The only push the server sends is the BOX wake-up (`src/box/box-push.transport.ts`, its own firebase-admin + web-push sender; payloads and notifier challenge → wire.md "Box"). There are no account push tables and no account push service: `POST|DELETE /users/fcm-token` and `/users/web-push-subscription` are gone.
  - **FCM** `data` transits Google READABLE: content-free wake-up, ONLY `type: 'new_message'` (or the one-off notifier challenge code). NEVER `n`/`c`, names, counts, message text, or keys.
  - **Web Push** body is E2E-encrypted (RFC 8291) and may carry the queue `n`/`c`, but sends NO `topic` header (cleartext to the relay). Never message text or keys.
- FCM initializes from `FIREBASE_SERVICE_ACCOUNT`; absent means disabled. Web Push initializes from VAPID env; absent means disabled.
- `web-push-sw.spec.ts` (in `src/box/`) loads the real `frontend/web/web-push-sw.js`; it pins what the PWA push worker must do with a box wake-up.
- Keep the `overrides.firebase-admin.uuid` override scoped and firebase-admin on 13.x (→ rt "firebase-admin and the uuid override").

## 10. Link previews and SSRF

- `POST /messages/link-preview` lives in `src/link-preview/` (`LinkPreviewModule`; the path predates the module and stays, nginx `location /messages/`). Box sends use it.
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
- Any destructive path involving media must delete self-hosted files before row deletion.
