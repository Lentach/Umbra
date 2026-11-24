# Cleanup batch 5: tests pruned, 13 crypto tests now run in CI, Signal-grade gap report delivered

**Date:** 2026-11-24 · **Version:** 0.2.100 → 0.2.101 · **Tiers deployed:** both (+ APK 20101)

## What was done
- **No shipped code changed.** Tests, docs and CI only; 0.2.101 differs from 0.2.100 by the version. PRs #289–#294.
- **CI runs the real crypto tests (O-4, TD-10):** `ci.yml` builds native `webcrypto` on the services leg (cached), and `REQUIRE_NATIVE_WEBCRYPTO=1` makes a missing library a failure (`frontend/test/support/native_webcrypto.dart`). 13 AES-GCM / PBKDF2 tests went from skipped to passed; none failed.
- **Deleted, each with a named cover:** `encryption_b3_impersonation_test.dart` (2 skipped; cover = the 7 `B3:` tests in `messaging_provider_box_test.dart`), 3 duplicate link-preview tests, the `register` controller echo (cover = CI `e2e-wire` only), one secret-notes assertion.
- **Kept against the audit, with proof:** two `og:image` tests (only pins of `imageUrl === null`), `logout` controller test (deleted, restored in review: nothing else fails if the controller stops revoking), TD-09, TL-2, TL-7.
- **One fake instead of two (TD-02):** `messaging_provider_box_send_test.dart` runs on `test/support/box_send_harness.dart` (2554 → 2211 lines; 82 tests / 394 expects unchanged). TD-03: only 3 of 34 `EncryptionProvider` fakes were identical.
- **Renames / rewords (TD-11, TL-1..5):** `_box_list_test` → `_box_last_message_test`, `_box_friend_test` → `_box_friend_handoff_test`; "old path" titles now state what is asserted.
- **Docs (TD-14..17, 19..21):** README against the code; `backend/src/box/**` is a wire-contracts trigger; root `CLAUDE.md` §3 gained the Test bar; hardening plan rows that said "unmerged" corrected (all shipped in 0.2.89–0.2.91).
- **Phase 3 report:** `docs/plans/2026-11-24-signal-grade-gap.md`, with primary-source notes in `2026-11-24-libsignal-ffi-research.md`.
- Out of repo: worktrees `fireplace-5-*` and branches `cleanup/5-*` removed; release APK 0.2.101 on emulator-5560 and the Xiaomi (muted, `screen_off_timeout` 60000); `Desktop/umbra-0.2.101.apk`.

## Key files
- Edited: `.github/workflows/ci.yml`, `CLAUDE.md` (line 66 counts, Test bar), `scripts/verify-claude-frontend-test-counts.mjs`, `scripts/dart-lint-baseline.json`, `frontend/test/support/box_send_harness.dart`, `README.md`, `.omp/rules/*`, `.claude/rules/*`, `docs/plans/2026-11-16-security-hardening.md`, `docs/plans/2026-11-23-cleanup-audit.md`.
- New: `frontend/test/support/native_webcrypto.dart`, `frontend/test/support/encryption_fakes.dart`, the two `docs/plans/2026-11-24-*` files.
- Read only (load-bearing): `.planning/cleanup/findings.md` (TD/TL rows), `.planning/cleanup/batches.md` ("Batch 5", "5 review", "5 release").

## Verification
- CI: 12/12 success on `bbd2d6ef` (total and success counted, not a non-success filter). Every PR head 13/13 before its merge.
- Counts: backend 902 → 898 unit / 56 suites; Flutter 3541 / 16 skipped → 3554 / 1 skipped (the one left is the `kIsWeb` skip). Dart lint ratchet baseline 2485 → 2482; backend ESLint ratchet 250 held; knip clean.
- Mutants (reviewers, all reverted): page-URL guard off → 16 red; `og:image` filter off → exactly the 2 kept tests red; new wire id per retry → 5 red; send doing its own list lookup → 1 red; controller `register` args swapped → 0 of 124 `src/auth` unit tests red (hence the e2e cover). Not run: Flutter mutants for the `B3:` cover and TL-2 beyond the slice agent's own.
- CI timing, services leg test step: 117–170 s over five runs without the crypto tests; 159 s (cache miss, +8 s build) and 156 s (cache hit) with them. No cost separable from runner noise.
- Deploy: backup `chatdb-20261124T162750Z.dump.gpg`, 3 files on R2; backend + web `0.2.101 / bbd2d6ef`; APK 20101 SHA256 `7b35e324…`, served hash equal; web smoke and post-deploy smoke PASSED.
- Live drive, release APK on emulator-5560 + Xiaomi: register ×2, invite, accept, messages both ways, cold start, message after cold start. Throwaways deleted in-app; prod users 31.
- NOT verified: web beyond the smoke's app boot (no web code changed), iOS, the CI fail path with the library missing (shown only in a container).

## Notes for next session
- **Next action:** the execution batches are done. Remaining for §8 "Done means": the after-metrics in `.planning/cleanup/metrics.md` and a recorded reason for each non-encryption file still over ~1 000 lines. Then the owner's answers to the report's Q1–Q8.
- Owner-owed: report §6 (PWA vs libsignal, iOS, verification, E143g, licence, audit, reproducible builds, small yes/no items); BE-12; UI-16/UI-17; batch 4b (`messaging_provider.box.dart` 2890, composer); TD-07; the two "hold-to-record" composer comments (`chat_input_bar.dart:1583`, `hex_send_button.dart:13`); `frontend-composer-media` rule has two triggers matching no file.
- Open findings: B3 is one layer (the service layer moves the pin for a foreign-identity PreKey unless the provider marked the peer held; report §2.2); five IPv6 `blocked` link-preview entries guard nothing; seven `isNot(contains('sendMessage'))` expects cannot fail; `chat-search.service.ts:17-34`; UI-23; WEB-16.
- Release B (avatar file deletion, TD-13) due on or after 2026-12-08.
- On a machine without native webcrypto the count script reports 13 fewer passed / 13 more skipped than `CLAUDE.md`: not drift.
- Traps (also in `traps.md`): a subagent's relative paths write into the main checkout; an empty "non-success" filter is not a green CI; libsignal no longer speaks classic X3DH.
