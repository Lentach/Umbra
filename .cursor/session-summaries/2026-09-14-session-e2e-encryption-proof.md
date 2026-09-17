# A runnable proof that every stored message is ciphertext — and an honest statement of what the server still sees

**Date:** 2026-09-14 · **Version:** unchanged (0.2.47) · **Tiers deployed:** none

## What was done
- New `frontend/test_e2e/encryption_proof_test.dart` (5 tests, all green): drives the real client stack against a real backend + Postgres, prints plaintext / ciphertext / the actual DB row, then dynamically sweeps **all 52 text columns of every table** for the plaintext it just sent. Each negative sweep carries a positive CONTROL sweep, so an empty result cannot be a broken query.
- New `docs/proof/e2e-encryption-proof.md` — the evidence write-up, with re-run commands; `docs/proof/sql/prod-census.sql` + `prod-prose-sweep.sql` are read-only production queries.
- New `docker-compose.proof.yml` — isolated stack (`-p fpproof`, backend :3100, db :5434) so the run cannot touch the dev stack another agent was using.
- Production census (read-only): **230 messages, 2026-05-17 → 2026-09-14, 230 `[encrypted]`, 0 readable**; 81 legacy ciphertexts + 273 per-device envelopes over 156 messages, all Signal-shaped, **0 messages with no ciphertext in either channel** (230 = 156 + 81 − 7 overlap).
- Production prose sweep: of 52 text columns, only `pg_stat_statements.query` and `web_push_subscription.userAgent` hold sentence-like text. No message content anywhere.
- Owner sent 7 live messages (TEXT/VOICE/GIF/VIDEO×2/PING×2) from his phone; all stored `[encrypted]` with per-device envelopes. Their media files read off the VM as root show **no container magic bytes anywhere in the file** and 256/256 distinct byte values; anonymous GET of a media URL is **401**.
- Documented the real limit: **E2E is client-enforced, not server-enforced** — the server writes whatever `content` it is given.

## Key files
- New: `frontend/test_e2e/encryption_proof_test.dart`, `docs/proof/e2e-encryption-proof.md`, `docs/proof/sql/{prod-census,prod-prose-sweep}.sql`, `docker-compose.proof.yml`
- Read only (load-bearing): `frontend/test_e2e/support/e2e_test_client.dart` (`e2eSql`, `E2eClient`), `backend/src/messages/{message,message-envelope}.entity.ts`, `backend/src/chat/services/chat-message.service.ts:443`, `chat-link-preview.service.ts:44`, `backend/src/push-notifications/push-notifications.service.ts:195-202`, `frontend/lib/utils/e2e_envelope.dart`

## Verification
- `flutter test test_e2e/encryption_proof_test.dart` against `E2E_BASE_URL=http://localhost:3100` / `E2E_DB_CONTAINER=fpproof-db-1` → **5/5 passed in 10 s** (three earlier runs were red; each failure was a harness bug, not a product finding — see Traps).
- `dart analyze test_e2e/encryption_proof_test.dart` → 0 errors, 0 warnings.
- Production: both SQL scripts run read-only over `fireplace-db-1` on the VM. No writes, no restarts, no compose commands.
- Backend blindness verified at source, not inherited: `grep` of `backend/package.json` finds no dependency able to decrypt; `curve25519-js` appears only as `verify(...)` in `device-list-signature.util.ts:1` and `identity-signature.util.ts:1`.
- NOT verified: iOS; the app's own `MediaCryptoService` under `flutter test` (webcrypto cannot load here — the harness uses pointycastle AES-GCM with identical parameters, and the app's real media path is evidenced by the production files instead).
- Committed `f0540c5e` on `proof/e2e-encryption`, pushed. **Not merged to master** — owner's call. CI not consulted (no master change).

## Notes for next session
- Owner-owed: whether `docs/proof/` should be linked from the README / landing page as user-facing assurance, and whether `proof/e2e-encryption` merges to master.
- The isolated stack is still up: `docker compose -p fpproof -f docker-compose.yml -f docker-compose.proof.yml down -v` to remove it (safe — throwaway volumes, and the `-p fpproof` project is the only thing `-v` can reach).
- Local dev DB `fireplace-db-1` holds one readable row (id 977, `DELPROOF-RECIPIENT-UNLINK`) written by another session's raw-emit harness. It is dev-only, and it is the proof that the server does not refuse plaintext.
- Traps below are also in `docs/agents/traps.md`.
