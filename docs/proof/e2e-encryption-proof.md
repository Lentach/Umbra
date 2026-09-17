# Proof that Umbra messages are end-to-end encrypted

**Date:** 2026-09-14 · **Commit:** `de59540a` · **Branch:** `proof/e2e-encryption`

This document is evidence, not assurance. Every number below came from a command
run against a real system on the date above, and every command is written out so
anyone can run it again and get the same answer.

## What is being claimed

**Claimed:** the server stores message content it cannot read. Anyone who owns
the server — or steals the database, or steals a backup — gets ciphertext and
cannot turn it back into your messages, because the keys that would open it are
not there.

**NOT claimed:** that the server is blind. It knows *who* talks to *whom*, *when*,
*how often*, message *type* (text / image / voice / video), media *file size*,
and it holds the opaque media blobs. That is metadata and it is listed honestly
in §6. E2E hides content, not the existence of the conversation.

---

## 1. Production census — every message that exists

Read-only, against the live production database (`fireplace-db-1` on the VM).
Script: [`sql/prod-census.sql`](sql/prod-census.sql).

```bash
ssh ubuntu@51.68.138.13 \
  'docker exec -i fireplace-db-1 psql -U postgres -d chatdb -At -F "|" -f -' \
  < docs/proof/sql/prod-census.sql
```

| Measure | Result |
|---|---|
| Messages in the database | **230** |
| …spanning | 2026-05-17 → 2026-09-14 (the whole life of the deployment) |
| `content = '[encrypted]'` | **230** |
| `content` = anything readable | **0** |
| Legacy-column ciphertexts (`encryptedContent`) | 81 — **81 of 81** match the Signal wire format |
| Per-device envelopes (`message_envelopes.ciphertext`) | 273 across 156 messages — **273 of 273** Signal-shaped |
| Messages carrying **no** ciphertext in either channel | **0** |
| Messages carrying **both** (legacy send normalised at ingest, contract §8) | 7 |

`230 = 156 + 81 − 7`. Every single message row in production is backed by a
Signal ciphertext. Not one holds readable text.

## 2. Production, swept for anything that reads like a sentence

The census only looks at `messages`. This sweep looks **everywhere**: every
text-typed column of every table, counting rows that look like human prose
(longer than 25 characters, containing a space, not base64-shaped). It reports
counts and column names only — never row contents.

Script: [`sql/prod-prose-sweep.sql`](sql/prod-prose-sweep.sql).

```
columns scanned .................... 52
pg_stat_statements.query ........... 405 rows   <- Postgres' own SQL text cache
web_push_subscription.userAgent .... 35 rows    <- browser UA strings
```

Those are the only two, and both were then ruled out rather than assumed:

- **`pg_stat_statements.query`** is the one column that could plausibly have
  captured message bytes, so it was checked directly: of 417 rows, **0** mention
  `[encrypted]`, **0** match a ciphertext shape (`[0-9]+:[A-Za-z0-9+/]{40,}`),
  and 328 carry `$1` placeholders — it holds *normalised* SQL text, not data.
- **`web_push_subscription.userAgent`** is browser UA strings.

**No table in production holds message prose.** Not a cache, not a log, not a
preview, not a search index.

### Where the 230 rows live, exactly

| shape | rows | span | note |
|---|---|---|---|
| per-device envelopes only | 149 | | the current model |
| legacy `encryptedContent` only | 74 | 2026-05-17 → 09-02 | 65 TEXT, 6 PING, 2 IMAGE, 1 GIF — the pre-envelope era |
| **both** channels | 7 | 2026-09-05 | all VIDEO, all `content = '[encrypted]'`, all 7 legacy values Signal-shaped — the §8 ingest normalisation during the envelope rollout |
| **neither** | **0** | | |

$149 + 74 + 7 = 230$. The overlap is explained, not hand-waved: it is one day of
video sends written under both models.

## 3. Real messages from a real phone, on production

Seven messages sent by the owner from the production Android app
(`com.fireplace.app`) to a second account of his own at 04:25–04:26 UTC, then
read straight out of the production database. Account names, user ids and the
device serial are deliberately omitted — this file is public.


| id | type | what the server stored in `content` |
|---|---|---|
| 24404 | PING | `[encrypted]` |
| 24403 | PING | `[encrypted]` |
| 24402 | VIDEO | `[encrypted]` |
| 24401 | VIDEO | `[encrypted]` |
| 24400 | GIF | `[encrypted]` |
| 24399 | VOICE | `[encrypted]` |
| 24398 | TEXT | `[encrypted]` |

`encryptedContent` is NULL on all seven — they are new-model sends, so the
ciphertext lives per-device. Message 24398 (the text one) fanned out to exactly
three envelopes:

```
24398 | recipient <sender's own account>  device 1 | 242 chars | 2:<ciphertext>
24398 | recipient <sender's own account>  device 5 | 350 chars | 3:<ciphertext>
24398 | recipient <the peer account>      device 1 | 242 chars | 2:<ciphertext>
```

One ciphertext for the peer, one for each of the sender's own other devices
(that is how your own message appears on your other phone). `2:` is a Double
Ratchet message, `3:` a PreKey message opening a new session. Three *different*
ciphertexts of the same sentence — because each is encrypted to a different
device's key. The server made none of them and can open none of them.

### The media, as the server sees it

Those messages carried a GIF, two videos and a voice note. Taking the strongest
possible adversary — **root on the production VM, reading the file off disk**:

```bash
ssh ubuntu@51.68.138.13 \
  'docker exec fireplace-backend-1 head -c 32 /app/media/msgs/<uuid>.bin | od -A d -t x1'
```

```
GIF   (292 KB) : 05 a1 b1 92 80 d6 0d e8 5a 8d 94 bd ba 1d 25 bb …
VIDEO (17 MB)  : 6f 04 18 ee 6d 4e 40 20 1a 3d 44 66 b1 c6 f7 e8 …
VOICE (24 KB)  : 8d 03 79 e2 92 86 07 b4 77 8e db b7 51 6d 77 a5 …
```

A GIF starts `47 49 46 38` (`GIF8`). An MP4 has `66 74 79 70` (`ftyp`) at byte 4.
An Ogg voice note starts `4f 67 67 53` (`OggS`). None of them do. Scanning the
**entire** files for every container signature — `ftyp`, `OggS`, `GIF8`, `JFIF`,
`PNG`, `moov`, `mdat`, `RIFF`, `webm` — returns **0 hits each**, and all three
files use **256 of 256 possible byte values**, which is what encrypted data looks
like and what a media container never looks like.

Fetching the media URL without credentials returns **HTTP 401**.

## 4. A reproducible proof anyone can run

Everything above is observation of a live system. This is the part you can
re-run from scratch: [`frontend/test_e2e/encryption_proof_test.dart`](../../frontend/test_e2e/encryption_proof_test.dart).

It drives the **real** client stack — the app's own `ApiService`, `SocketService`
and `EncryptionService` on real `libsignal_protocol_dart 0.8.2` — against a real
NestJS backend and a real Postgres, on an isolated stack that cannot touch
anything else:

```bash
docker compose -p fpproof -f docker-compose.yml -f docker-compose.proof.yml up -d
cd frontend
E2E_BASE_URL=http://localhost:3100 E2E_DB_CONTAINER=fpproof-db-1 \
  flutter test test_e2e/encryption_proof_test.dart --reporter expanded
```

Result on 2026-09-14: **5 of 5 passed in 10 s.** What each one establishes:

**1 — one message, fully disclosed.** Alice types a unique sentence; the test
prints the plaintext envelope the app builds, the ciphertext libsignal produces,
and then the exact database row:

```
Alice types              : UMBRA-PROOF-…-MEET-ME-AT-THE-DOCKS-AT-MIDNIGHT
App builds envelope      : {"content":"UMBRA-PROOF-…-MEET-ME-AT-THE-DOCKS-AT-MIDNIGHT"}
libsignal produces       : 3:MwgAEiEFfck4zQuRgHjVzCadmGKvGLJd8Qf5IcpZhnCeErv3awAa…
messages.content         : [encrypted]
messages.encryptedContent: 3:MwgAEiEFfck4zQuRgHjVzCadmGKvGLJd8Qf5IcpZhnCeErv3awAa…
Bob decrypts it back to  : UMBRA-PROOF-…-MEET-ME-AT-THE-DOCKS-AT-MIDNIGHT
```

Base64-decoding the ciphertext gives 211 bytes that do not contain the sentence.
Bob recovers it exactly — so this is encryption, not deletion.

**2 — the plaintext is in zero columns of the entire database**, in any
encoding. A literal-only search would miss plaintext sitting verbatim inside a
base64 or hex blob, so the sweep runs three times over **all 52 text columns of
all tables**:

```
as literal UTF-8 -> NOT FOUND (58 chars,  52 columns scanned)
as base64        -> NOT FOUND (80 chars,  52 columns scanned)
as hex           -> NOT FOUND (116 chars, 52 columns scanned)

CONTROL — a run of Alice's username : HIT users.username x1
```

The control makes the negative real: the same query finds a string that *is*
there. A sweep that scanned nothing would prove nothing, so the test asserts on
the column count too.

**3 — the private keys are not on the server either.** LIKE's only
metacharacters are `%` and `_`, and base64 contains neither, so the key is
searched **in full** — not as a fragment:

```
stored identityPublicKey : BWSDcMDUdWMpOGEA…   (44-char base64, truncated here)
bob's real PUBLIC key    : BWSDcMDUdWMpOGEA…   byte-identical to the stored one
bob's PRIVATE key        : <44-char base64, never printed into a public file>
  → full-string sweep, 52 columns : NOT FOUND
CONTROL, the PUBLIC half, in full : HIT key_bundles.identityPublicKey x1
                                    HIT one_time_pre_keys.identityPublicKey x20
columns whose NAME suggests private material: none
```

The sweep demonstrably finds key material when it is there. It cannot find the
private half, because the private half was never sent.

**4 — census.** Every message row in the test database is a ciphertext row.

**5 — a picture.** An image is AES-256-GCM encrypted client-side and uploaded.
An unauthenticated GET is refused (401). An authenticated GET returns bytes
byte-identical to the ciphertext that was uploaded, containing none of the
original content. The row keeps `content = [encrypted]`, `messageType = IMAGE`,
`mediaUrl = …/msgs/<uuid>.bin` — and the AES key is in **no** column: it lives
only inside the Signal ciphertext of the message. The recipient decrypts the
envelope, takes key+IV out of it, and recovers the original bytes exactly.

> The harness encrypts the image with `pointycastle` AES-256-GCM rather than the
> app's `MediaCryptoService`, because that service reaches AES-GCM through
> `package:webcrypto`, whose BoringSSL backend cannot load under `flutter test`
> on this machine (`dart run webcrypto:setup` → `CMAKE_C_COMPILER not set`). The
> parameters are identical (32-byte key, 12-byte IV) and the claim under test is
> about the *server*. The app's own media path is evidenced by §3, on real files.

## 5. The server has no way to decrypt, by construction

| Probe | Finding |
|---|---|
| Any backend dependency that could decrypt a message | **None.** `backend/package.json` has no libsignal, no AES-GCM over message bodies. |
| `curve25519-js` — the one curve dependency | Used only as `verify(...)` for signature checking: `key-bundles/device-list-signature.util.ts:1`, `identity-signature.util.ts:1`. Never decryption. |
| Where the placeholder is written | `chat/services/chat-message.service.ts:443` — `data.encryptedContent \|\| isNewModel ? '[encrypted]' : data.content` |
| Link previews (would need plaintext) | Skipped for encrypted messages: `chat/services/chat-link-preview.service.ts:44` — `if (encryptedContent) return;`. E2E previews are built client-side and travel *inside* the envelope. |
| Push notifications | Content-free. FCM gets `data: { type: 'new_message', conversationId }` (`push-notifications.service.ts:195-202`, comment: "metadata only — no message body"). Web Push may add sender name and unread counts — never a message body. |
| Server-side message search / full-text index | None. `chat-search.service.ts` searches usernames. |
| Admin/debug endpoint that dumps content | None. |
| Private key material in any entity | None. `key_bundles` holds `identityPublicKey` / `signedPreKeyPublic` / signature; `one_time_pre_keys` holds `publicKey`; `account_authorizations` holds `dakPub` + signatures; `recovery_keys` holds an Argon2id `verifierHash` and a `backupBlob` sealed under a key derived from the phrase, which the server does not have. Confirmed against the live production schema in §1. |

Client side, the one place a message is turned into ciphertext:
`providers/messaging/messaging_provider.send.dart` builds the envelope and calls
`EncryptionService.encrypt`, which returns `"{type}:{base64}"`
(`encryption_service.dart:2032-2048`). `mediaKey` and `mediaIv` are placed
*inside* that envelope (`utils/e2e_envelope.dart:47-48`) before encryption, which
is why they can never become columns. There is no branch that emits a message
with readable `content`, and encryption failure aborts the send rather than
falling back.

## 6. What the server does see — stated honestly

- who sent it and to whom (`sender_id`, `conversation_id`), and your contact graph
- when (`createdAt`, `editedAt`, delivery/read timestamps)
- message type: TEXT / IMAGE / VOICE / VIDEO / GIF / FILE / PING
- media: the opaque encrypted blob, its size, and its URL; client-reported duration
- which of your devices sent it, and how many devices you have
- your public keys, your username, your password hash

A database dump is therefore sensitive — it exposes the social graph and
metadata — but it cannot decrypt a single message.

## 7. The honest limit

**E2E here is enforced by the client, not by the server.** The server writes
whatever `content` a client sends it; it does not refuse plaintext. Evidence: the
local dev database contains exactly one readable row, `DELPROOF-RECIPIENT-UNLINK`
(id 977), written by a test harness emitting a raw `sendMessage` that bypassed the
app's encrypt path. A modified client could do the same.

This is true of every end-to-end encrypted messenger — the guarantee is "the app
on your device encrypts before sending", never "the server rejects plaintext". The
relevant question is whether the real fleet ever does it, and §1 answers that
empirically: **230 of 230 production messages, over four months, are ciphertext.**

## Re-running everything

```bash
# 1. production census + prose sweep (read-only, safe)
ssh ubuntu@51.68.138.13 'docker exec -i fireplace-db-1 psql -U postgres -d chatdb -At -F "|" -f -' \
  < docs/proof/sql/prod-census.sql
ssh ubuntu@51.68.138.13 'docker exec -i fireplace-db-1 psql -U postgres -d chatdb -At -F "|" -f -' \
  < docs/proof/sql/prod-prose-sweep.sql

# 2. the reproducible harness on an isolated stack
docker compose -p fpproof -f docker-compose.yml -f docker-compose.proof.yml up -d
cd frontend && E2E_BASE_URL=http://localhost:3100 E2E_DB_CONTAINER=fpproof-db-1 \
  flutter test test_e2e/encryption_proof_test.dart --reporter expanded

# teardown (never `-v` on anything but this throwaway project)
docker compose -p fpproof -f docker-compose.yml -f docker-compose.proof.yml down -v
```
