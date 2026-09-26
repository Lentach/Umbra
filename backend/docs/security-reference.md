# Backend media, SSRF and Secret Notes reference

Detail relocated from `backend/CLAUDE.md` §8 (media), §10 (link previews and SSRF) and §11 (Secret Notes). The one-line rules stay in `backend/CLAUDE.md`; each points here for mechanism, rationale and history.

## Media upload and storage (§8)

- `POST /media/upload`: JWT-guarded, 20/min, 21 MiB limit; handles `image`, `voice`, `gif`, `file`, `video`, `avatar`. Voice returns `mediaDuration`; file returns `fileName`; video takes the same opaque `msgs/` path as `file` and echoes `mediaDuration`; avatar validates magic bytes.
- `LocalStorageService` writes avatars to `avatars/<uuid>.(jpg|png)` and encrypted message blobs to `msgs/<uuid>.bin` under `MEDIA_DIR`.
- `MEDIA_URL_REGEX` allows either legacy Cloudinary HTTPS upload URLs or exact self-hosted `${MEDIA_BASE_URL}/media/(avatars|msgs)/<filename>.<ext>` with one path segment. This prevents SSRF/path traversal because URLs later become unlink targets.

## Box media location (§8)

Box media (`POST /box/media`, capability `GET`) lives in `MEDIA_DIR/box/`, never `msgs/`: the orphan cleanup deletes every `msgs/` file no `messages` row references, which is every box file. Box files expire by `box_media.expiresAt` (14 d, `BoxReaper`).

## Orphan cleanup (§8)

Orphan/expired cleanup runs daily at 03:00. It scans `msgs`, compares non-expired references vs all references, skips files newer than `MEDIA_CLEANUP_GRACE_MS` (default 15 min), logs `scanned/deleted/orphan/expired/graceSkipped`.

## SSRF defence layers (§10)

The only user-URL fetch surface is `POST /messages/link-preview` (JWT-guarded) plus the async fire-and-forget path for legacy plaintext messages. Defence in `link-preview.service.ts` is two-layer:

1. URL-literal — `isPrivateIp` byte-parses the WHATWG-normalized hostname, so decimal/hex/octal IPv4, IPv4-mapped/NAT64 IPv6, `0.0.0.0`, CGNAT, ULA, and link-local literals are all rejected (replaced the old `PRIVATE_IP_RE`, which missed those and false-matched any `fd*` host).
2. DNS resolve-and-pin — every outbound request goes through an undici `Agent` whose `connect.lookup` (`ssrfSafeLookup`) resolves all A/AAAA records and refuses the connection if ANY is private; the socket dials only those validated addresses, so DNS-rebinding cannot bypass it. Swapping `fetchImpl` back to global `fetch` drops the pin.

Redirects are manual (`redirect:'manual'`, max 5); every hop is re-validated at the literal layer before the next fetch and re-pinned at the DNS layer on connect.

`undici` is a direct dependency specifically for the pinned-DNS agent; its `connect.lookup` wiring is proven end-to-end by a test in `link-preview.service.unit.spec.ts` (drives a live loopback server; a fail-open would serve a request).

## Secret Notes endpoints (§11)

- `POST /notes` (JWT) stores ciphertext and returns a random 16-byte hex token. `expiresIn` is whitelisted to 1h/6h/12h/24h (any other value → 6h default). Ciphertext max 65536 chars.
- `GET /note/:token` is public server-rendered HTML. AES-GCM key is in URL fragment (`#key`), never sent to server.
- `POST /note/:token/reveal` is public read-once: atomic `DELETE ... WHERE token AND "expiresAt" > NOW() RETURNING ciphertext`.
- `GET /note/:token/status` (JWT, 120/min) returns `{ alive }` for the in-chat banner: the client flips the card to "burned — it was read" when the note is gone before its `e=` fragment clock ran out. Legacy links without `e=` cannot distinguish read-vs-expired and keep the generic destroyed state; after the clock passes, read-vs-expired is indistinguishable by design (the row is deleted on reveal).

## Secret Notes sweep cadence (§11)

Expired notes are lazy-deleted on reveal and swept every minute (`@Cron(EVERY_MINUTE)`, matching `MessageCleanupService`). It was daily-at-03:00 until 2026-08-02, which left an UNREAD expired note's ciphertext in the table for up to ~24h past its TTL — the API refuses to serve it, but the AES key travels in the note URL and that URL is stored as ordinary plaintext message content, so DB access plus device access read a note the UI already called self-destructed. The cadence is pinned by a test.
