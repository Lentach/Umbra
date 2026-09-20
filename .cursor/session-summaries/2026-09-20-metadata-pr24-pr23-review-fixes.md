# Two independent reviews turned PR2.4/PR2.3 from "green" into "correct": eight never-clobber holes and four privacy leaks closed

**Date:** 2026-09-20 · **Version:** unchanged (0.2.51 backend / 0.2.50 web on prod; branch only) · **Tiers deployed:** none

## What was done
- `reviewer` (`agent://Pr24Reviewer`) and `security-reviewer` (`agent://Pr24Security`) both returned REQUEST-CHANGES on `3915f4f8` — 13 and 10 findings. Every one was real; nothing was refuted. All folded in `1cfdc7f2`.
- **409 retry lost the wrap it was adding** (`contact_backup_service.dart:_rereadForRetry`): it overwrote `_wraps` with the server's set, so a password change racing another device's upload reported SUCCESS while publishing the old wraps — and `resetPassword` then destroyed the only password that opened them. The re-read now merges; a regression proves the new password opens the row after a forced 409.
- **Same retry republished a stale blob** — `_putWraps` captured `_blob` once, so attempt 2 wrote the pre-409 graph over the newer one. Blob is read per attempt; the re-read adopts the server's.
- **`applyRestore` ignored `reconcile`'s bool**, clearing `_pendingRestore` before knowing the rows landed — on exactly the storage-flaky device this PR exists for, that unblocked uploads of a reduced graph. Fails closed.
- **Backend rev guard was check-then-save**: two PUTs at one `baseRev` both won. Now `UPDATE … WHERE "userId" = :userId AND "rev" = :baseRev`, plus a 409 (not a 500) on a concurrent create.
- **`resetPassword` discarded `addWrap`'s refusal.** Now throws `ContactBackupRewrapRefused` — but ONLY when `holdsOpenableBackup`, because blocking a security action on a backup that does not exist is the worse bug. A server-refused change also `retractWrap()`s the stray wrap it staged (SEC-7: it was published before the old password was ever verified).
- **Blob length was a contact counter** — AES-GCM is length-preserving and nothing padded. Plaintext is now `uint32be(len) || json || zeros` to `kContactBackupPadBlock` (4 KiB); the entity and migration headers claimed "no count is visible", which was false.
- **The server's no-op guard could never fire**: a fresh GCM IV makes every re-seal different bytes, so `updatedAt` moved on every upload — the `key_bundles.updatedAt` presence clock rebuilt. Decision moved to the PLAINTEXT client-side; that also closes a leak where a `legacy`-only change (data deliberately excluded from the blob) re-stamped the row.
- **The 4 mb body limit was GLOBAL** (40x unauthenticated parse ceiling on `/auth/*`). Scoped to `/backup/contacts` — and the mount must wrap `json()` in a NAMED function or Nest skips its own global parser entirely.
- **History import accepted any `e2e_<uid>_` key** while export writes two prefixes: a crafted `.umbrabak` could plant identity, prekey, device-list-pin or pending-send rows on a freshly wiped device. Narrowed, with a test that tries to plant four control rows.
- Smaller: upload refused while the store holds UNDETERMINED rows; `_adopt` locks on a newer-version blob or a cached-key auth failure; late restore gated on the empty-store case (it was resurrecting swept peers); `blob`/`ct` constrained to base64; PUT throttle 30→10/min; refused CK delete retried + recorded; prune no longer depends on that delete; unused `restoredCount` gone.

## Key files
- Edited: `frontend/lib/services/contacts/contact_backup{,_service}.dart`, `frontend/lib/services/backup/history_backup_service.dart`, `frontend/lib/services/auth_token_store.dart`, `frontend/lib/providers/{auth,connection}_provider.dart`, `backend/src/backup/**` (service, controller, entity, dto, both specs), `backend/src/main.ts`, `backend/migrations/0021_contact_backups.sql`, `docs/METADATA.md`, `frontend/docs/e2e-invariants.md`, `CLAUDE.md`, 3 frontend test files (+6 regressions).
- Read only (load-bearing): `agent://Pr24Reviewer`, `agent://Pr24Security` (full findings), `content_sealer.dart`, `contact_store.dart:_serial`.

## Verification
- `npm test` **1156 / 66** (was 1151/66). `flutter test` **2287 / 14 skipped** (was 2281/14). `flutter test test_e2e` **46 / 14** — baseline. Ratchet PASS at **3166**. `verify-no-user-logs.mjs` PASS. `verify-context-budget.mjs` OK.
- Live wire re-driven AFTER the atomicity rewrite: `GET` 404 → create rev 1 → no-op holds rev AND updatedAt → stale 409 `stale_backup` → 409 `salt_mismatch` → non-base64 400 (new DTO guard) → **two concurrent PUTs at one baseRev answer 200/409, exactly one winner** (both won before).
- Body limit live: 1.5 MB → `/backup/contacts` **200**; 1.5 MB → `/auth/login` **413**; small `/auth/login` **401** (global parser intact). The sub-agent's negative control proved the named-wrapper requirement: with a bare `json()` mount, `/auth/login` accepted 1.5 MB and lost its body entirely.
- 6 new regressions, each red without its fix: 409-keeps-the-wrap, 409-does-not-roll-the-graph-back, upload-refused-on-undetermined-rows, unchanged-graph-is-not-re-uploaded, blob-length-is-bucketed, crafted-file-cannot-plant-control-rows.
- Commit `1cfdc7f2`, pushed. CI: see LATEST.
- **NOT re-verified after these fixes:** the Pixel_7 device drive (last run was on `3915f4f8`; the restore path changed shape, so it is owed), web, the import half on a device, iOS, prod.

## Notes for next session
- **The emulator drive must be re-run before G2** — `pm clear` → login → `CONTACT_BACKUP_RESTORED` — because `applyRestore` and the connect-time gate both changed after the last device run.
- Owner-owed: G2 (Phase 2a → master + deploy). Reviewer NIT left deliberately open: `updatedAt` is stored and returned but no client reads it; the plan sanctions it as accepted disclosure, so deleting the column is an owner call, not a silent deviation.
- Security MINOR left open: a stolen 24 h token can PUT garbage under a new `ckId` and permanently lock every honest device out; the suggested fix is keeping one previous row generation. Recorded, not built.
- Traps (also in `traps.md`): a bare `express.json()` mount disables Nest's global parser; a server-side byte compare cannot detect an unchanged payload under a fresh IV; AES-GCM length is a record counter; a 409 re-read must not adopt the server's state wholesale.
