# Backend media, SSRF and Secret Notes reference

Detail relocated from `backend/CLAUDE.md` §8 (media), §10 (link previews and SSRF) and §11 (Secret Notes). The one-line rules stay in `backend/CLAUDE.md`; each points here for mechanism, rationale and history.

## Media storage (§8)

- Self-hosted storage is avatars only and is read-only now (decision 138): `LocalStorageService` only deletes `avatars/<uuid>.(jpg|png)` under `MEDIA_DIR` (account delete); no route uploads one. The files that remain are served by the public `GET /media/avatars/:filename` for the one-time client migration, and release B removes them.
- There is no `POST /media/upload` and no `msgs/` route, writer or sweep (removed in Phase 4 step 5): message attachments travel as E2E blobs through the box (`POST /box/media`). Old `msgs/` files stay on disk until the deploy's ops step archives and removes them; no code reads or serves them.

## Box media location (§8)

Box media (`POST /box/media`, capability `GET`) lives in `MEDIA_DIR/box/`; box files expire by `box_media.expiresAt` (14 d, `BoxReaper`).

## SSRF defence layers (§10)

The only user-URL fetch surface is `POST /messages/link-preview` (`src/link-preview/`, JWT-guarded, 30/min). Defence in `link-preview.service.ts` is two-layer:

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

Expired notes are lazy-deleted on reveal and swept every minute (`@Cron(EVERY_MINUTE)`). It was daily-at-03:00 until 2026-08-02, which left an UNREAD expired note's ciphertext in the table for up to ~24h past its TTL — the API refuses to serve it, but the AES key travels in the note URL and that URL was stored as ordinary plaintext message content, so DB access plus device access read a note the UI already called self-destructed. The cadence is pinned by a test.
