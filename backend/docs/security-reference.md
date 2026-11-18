# Backend media, SSRF and Secret Notes reference

Detail relocated from `backend/CLAUDE.md` §8 (media), §10 (link previews and SSRF) and §11 (Secret Notes). The one-line rules stay in `backend/CLAUDE.md`; each points here for mechanism, rationale and history.

## Media storage (§8)

- Self-hosted storage is avatars only and is read-only now (decision 138): `LocalStorageService` only deletes `avatars/<uuid>.(jpg|png)` under `MEDIA_DIR` (account delete); no route uploads one. The files that remain are served by the public `GET /media/avatars/:filename` for the one-time client migration, and release B removes them.
- There is no `POST /media/upload` and no `msgs/` route, writer or sweep (removed in Phase 4 step 5): message attachments travel as E2E blobs through the box (`POST /box/media`). Old `msgs/` files stay on disk until the deploy's ops step archives and removes them; no code reads or serves them.

## Box media location (§8)

Box media (`POST /box/media`, capability `GET`) lives in `MEDIA_DIR/box/`; box files expire by `box_media.expiresAt` (14 d, `BoxReaper`). The uploader can remove one earlier: `DELETE /box/media/:id` with the secret whose SHA-256 the upload stored in `box_media.deleteHash` (plan D3; constant-time compare, file before row, every failure a `404`; no stored hash = reaper-only). The box learns no account from it.

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

## Password hashing and login backoff (§5, plan D4)

- **Hash.** New and changed passwords are Argon2id with the OWASP Password Storage profile m = 19 MiB, t = 2, p = 1 (`PASSWORD_ARGON2_OPTIONS`, the same as the recovery-phrase verifier); about 20 ms and 19 MiB per hash on the VM. The PHC string carries its parameters, so raising them later needs no migration: `needsRehash` upgrades the old ones at the next login. `users.password` is an unbounded `varchar`: no migration.
- **Verify** takes both formats (`$2…` bcrypt, `$argon2id$`); anything else is a wrong password. A correct bcrypt password at **login only** is rehashed in place: `UPDATE users SET password = <argon2id> WHERE id = $1 AND password = <the hash just read>` (a concurrent change wins), `passwordChangedAt` untouched, no session dropped. Other doors never write: `verify-password` (R76), delete-account, the old password of a change (it stores a new hash anyway). Accounts that never log in again keep a bcrypt hash; that is the same strength as before. Register, `setPassword` (change and `/auth/recover`) always write Argon2id.
- **Memory.** Argon2 ops share a 2-slot gate (`MAX_CONCURRENT_PASSWORD_HASHES`): at most 2 × 19 MiB in flight on the 2 GB VM. At most 64 more wait (`MAX_WAITING_PASSWORD_HASHES`); past that a call is refused at once `503 { error: 'busy' }` (the client shows its "server could not handle that right now" message), so the queue is bounded. A refusal is refunded to the backoff counter. bcrypt runs outside the gate (4 KiB). The login IP throttle (30 / 15 min) and the backoff (refused before any hash) keep the queue short in practice; `/auth/recover` keeps its 5 / 15 min IP throttle and its own Argon2 (recovery verifier) outside the gate.
- **Timing parity.** A wrong password costs about 43 ms on a bcrypt row and 16 ms on an Argon2id row; the gap would tell which names exist. So every failed login pays BOTH formats: the real verify covers the row's own, and `verifyDummyPasswords` runs the other format's dummy (`$2b$10$` bcrypt dummy for Argon2 rows, Argon2id dummy for bcrypt rows, both for an unknown name or an ambiguous bare name).
- **Other secrets.** The recovery-phrase verifier was already Argon2id. Refresh tokens are SHA-256 / HMAC of 256-bit random secrets (a slow hash adds nothing to a high-entropy secret). No other `bcrypt` or `argon2` call exists in `backend/src` (checked with grep) besides the legacy-row verify here; device-link material was not changed.
- **Login backoff** (`LoginBackoffService`, in memory: one backend instance; a restart forgets the counters, which only hands an attacker a fresh 5 tries). Key = (name, client), never the name alone: the name is the parsed, trimmed, lower-cased NAME part of the identifier for everyone, resolved or not (`-` when the parse fails), so a refusal never says whether the account or its tag exists (keyed on the account id, a locked `alice` would answer 429 to a real `alice#1234` and 401 to `alice#1111`). Accounts sharing a name share the budget; the client is `proxiedClientIp` (X-Real-IP, the throttlers' identity), IPv4 as is, IPv6 widened to its /64. After 5 attempts from a client the pair waits 15 s, 30 s, 1 min … capped at 15 min, checked BEFORE the password, so even the right one is refused with `429 { error: 'rate_limited', retryAfterMs }`. The attempt is reserved synchronously with the check (parallel requests cannot slip past) and erased by a success. An attacker's lock stops only the attacker's address: the owner on another address logs in untouched, and no account→address memory exists beyond these counters (forgotten after 1 h of quiet; at most 20 000 pairs, oldest evicted). A successful `/auth/recover` clears every client's count for the account. The client maps 429 to `AuthStatusCode.tooManyAttempts` ("Too many attempts. Wait a while and try again.").
- **Residual (distributed guessing).** Spread over many addresses, an attacker gets about 13 tries per /64 per account in the first hour, then about 4 per hour (the waits double to 15 min), on top of the per-IP throttle (30 / 15 min on `/auth/login`). A global per-account cap would close that, and would reopen the lockout of the owner by anyone who knows the name; not built (owner question).
