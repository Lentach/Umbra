# Backend runtime reference

Detail relocated from `backend/CLAUDE.md` §1, §2, §3, §6 and §9. The one-line rules stay in `backend/CLAUDE.md`; each points here for commands, tables, rationale and history. Read the matching section before editing that area.

## Deploy script (§1)

Production backend deploy runs on the VM only (`cd ~/fireplace && ./deploy-backend.sh`).

`deploy-backend.sh` does `git pull --ff-only`, derives `APP_VERSION` from `frontend/pubspec.yaml`, validates `.env`, builds/up's `docker-compose.prod.yml`, waits for Docker health, curls local `/version` and `/health`.

## Box module (§2)

The **box** (`src/box/`: `/box` namespace + `/box/media`, metadata-privacy PR1.1) is dark until a client speaks it. It is registered only when `BOX_ENABLED=true` (`ConditionalModule`); dev compose sets it, prod does not until a global storage ceiling lands.

The box has NO account on its path: it imports nothing from `auth/`, `users/`, `chat/`, even transitively (invariant I1, enforced by `scripts/verify-box-imports.mjs` in CI). Contract: `docs/contracts/wire.md` "Box". Suite: `npm run test:int` (real sockets + Postgres, `BOX_IT_DATABASE_URL`).

## Chat service map (§2)

`chat-message`, `chat-friend-request`, `chat-conversation`, `chat-key-exchange`, `chat-presence`, `chat-block`, `chat-search`, `chat-reaction`, `chat-reaction-key`, `chat-link-preview`, `chat-device-list`, `chat-device-revocation`, `chat-provisioning`; shared `ChatValidationService` lives in `ChatValidationModule`.

`ChatGateway` presence is room occupancy (`isUserOnline` in `chat/utils/user-room.ts`); the old `onlineUsers: Map<userId, socketId>` is retired.

## Docker (§3)

- Local `docker-compose.yml`: dev only, Node 22 bind mount, `NODE_ENV=development`, command `npm install && npm run start:dev`, Postgres 16 exposed at host `5433`, TypeORM auto-sync enabled by source.
- Prod `docker-compose.prod.yml`: built image from `backend/Dockerfile`, backend and DB bound to localhost only, `NODE_ENV=production`, persistent `pgdata` and `media_storage`, healthcheck on `http://127.0.0.1:3000/health`, and json-file log rotation capped per service (`max-size: 10m`, `max-file: 3`) so stdout logs cannot grow unbounded on disk.
- Prod logger is `error/warn/log` only; per-message, push, and key-refresh logs are `debug` (prod-silent) so container-log breach/seizure does not expose recipient IDs, online rosters, or push timing.
- `backend/Dockerfile`: multi-stage build, runtime installs prod deps only, copies `dist` + `migrations/`, sets `NODE_ENV=production`, runs `node dist/main.js` as non-root `USER node` (uid 1000). The media volume must be node-owned: fresh volumes inherit it from the image; volumes created by older root images are chown'd idempotently by `deploy-backend.sh` / `staging.ps1`.

## Environment variables (§3)

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
| `BOX_ENABLED` | `true` registers the box module (dev compose only for now). |

## Presence on disconnect (§6)

Disconnect needs no presence bookkeeping: Socket.IO drops the socket from `user:<id>` itself, so the room empties only when the LAST tab goes. This retired the old guarded delete of `onlineUsers[userId]`, which an iOS resume (new socket connected before the old one times out) could get wrong.

## Gateway throttles (§6)

Source of truth is `chat.gateway.ts`; this is an orientation summary.

- `sendMessage`, `getMessages`, list fetches: high-volume 300/15min where annotated.
- Mutating chat actions like clear/delete/edit/pin/timer/start are mostly 60/15min.
- Reactions: 120/15min. Search/friend/block/key-rebuild actions have lower limits.
- `messageDelivered`, `markConversationRead`, typing, voice-recording, upload key bundle, accept/reject friend request, and unblock are not all throttled.

## WsThrottlerGuard tracker (§6)

`WsThrottlerGuard` adapts Nest throttler to sockets with a no-op `res.header()` mock.

Tracker: the user id on an authenticated socket, from any IP; on a TOKENLESS one (only an event racing `handleConnection`'s JWT check) the client IP nginx wrote into `X-Real-IP` (`common/client-ip.ts`, shared with `HttpThrottlerGuard`; a blank first hop counts as absent, never as one `''` bucket), else `handshake.address`.

Never `handshake.address` first — behind nginx it is the proxy's address for EVERY client, one bucket that one flood empties for all (metadata-privacy PR1.0) — and never X-Forwarded-For: nginx appends to it, so its first hop is the caller's choice.

The `/box` gateway has its own `BoxThrottlerGuard` (I1 bars `chat/`): same IP source, IPv6 widened to /64, the refusal answered on the event's ack.

## @nestjs/throttler version floor (§6)

Bumped from 6.5.0 to ≥ 6.7.0 on 2026-09-22. 6.5.0's in-memory storage kept ONE expiry-timer list per throttler NAME, so any tracker whose block lapsed cancelled every other tracker's pending expiries — every `@Throttle({ default })` here shares that name and one storage, HTTP and WS — and other clients were refused inside limits they never exceeded; it also never evicted a record (one permanent entry per distinct tracker). Pinned by `ws-throttler.guard.spec.ts` "a lapsed block on one client never freezes the window of another".

6.7.0's IPv6 /64 masking lives in the BUILT-IN tracker only; ours override it, so `proxiedClientIp` keys a full IPv6 address.

## Push payloads (§9)

Payloads differ per channel by design (metadata-privacy contract — verify in `push-notifications.service.ts`):

- **FCM** `data` transits Google READABLE, so it is a content-free wake-up: ONLY `type: 'new_message'` + `conversationId` (opaque int, for notification tap-routing/dedup). NEVER `senderName`, unread counts, message text, or keys. The app wakes on the signal and fetches real state over its own socket. (Android handler already renders a generic title/body and ignores senderName, so this is a pure server-side win.)
- **Web Push** body is E2E-encrypted to the browser, so it may carry richer metadata (`type`, `conversationId`, `unreadCount`, `unreadTotal`, `unreadConversationIds`, `senderName`) — but sends NO `topic` header: a `conv-<id>` topic is cleartext to the relay (Mozilla/Apple/Google) and would leak per-conversation cadence. Never message text or keys.

## Push coalescer and visibility (§9)

- Coalescer buckets by `(recipientUserId, conversationId)`, debounce 2500 ms, max wait 10000 ms, latest `senderName` wins, and suppresses identical count repeat within 10000 ms.
- Push scheduling is skipped only when EVERY delivered recipient device's newest socket reports `clientVisible` (any chat, or the list). The client never reports WHICH conversation is open (metadata privacy PR0.2); an older client's `activeConversationId` is dropped by `handlePushClientState`, never stored.
- `pushClientState` is set by WS event and stored on `client.data`; frontend should set `clientVisible=false` on inactive/background.
- Endpoints: Web Push `POST`/`DELETE /users/web-push-subscription`; FCM `POST`/`DELETE /users/fcm-token`.

## firebase-admin and the uuid override (§9)

`package.json` pins a scoped `overrides.firebase-admin.uuid = ^11.1.1`: `uuid < 11.1.1` is vulnerable (GHSA-w5hq-g745-h8pq) and 11.1.1 is the only patched line, but the sole consumer is firebase-admin's transitive google-cloud chain (`gaxios`/`teeny-request`), which only calls `uuid.v4()` — stable across the major.

Keep it scoped (not top-level) and keep firebase-admin on 13.x: v14 moved to the modular SDK and drops the `admin.apps`/`admin.credential`/`admin.messaging()` namespace this service uses, so a 14 bump needs a code migration + a live FCM smoke test, not just a version change.
