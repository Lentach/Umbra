# The vendored Signal port now has a pinned origin and known-answer tests; owner answered the gap report

**Date:** 2026-11-24 · **Version:** unchanged (0.2.103) · **Tiers deployed:** none

## What was done
- **Owner answers recorded** in `docs/plans/2026-11-24-signal-grade-gap.md` §6.1 (Q1–Q8): retire the PWA before B6; iOS on hold; B1/B2 stay dropped; E143g accepted; lawyer before a licence file; audit after B6; yes to CI-built APK + checksum, CodeQL for TypeScript, `SECURITY.md`, the B7 tail, and §1.5.
- **§1.5 done (PR #301), tests and docs only:**
  - `frontend/third_party/libsignal_protocol_dart/PATCHES.md`: origin (pub.dev 0.8.2 archive SHA-256 = upstream commit `9f093cfb`), the two code patches, what was not copied, the proof for each claim.
  - `frontend/test/services/encryption/libsignal_known_answer_test.dart`: 12 tests. Vectors from `signalapp/libsignal-protocol-java` unit tests (commit `fde96d22`) and one from libsignal v0.74.1. Covers HKDF, the symmetric and DH ratchet steps, session setup on both sides, X25519 agreement, signature verification.
- **Finding:** the port clamps X25519 private keys on use; the Java vectors were computed without clamping. Two Java cases match only with the Java arithmetic plugged in (`Curve.agreementCalculator`). libsignal clamps like the port and its own copy of that test expects the port's value. No effect in Umbra: every private key in `frontend/lib` comes from the port's generators.
- Flutter count 3554 → 3566 (root `CLAUDE.md`).
- Out of repo: worktree `fireplace-kat` and branch `test/port-known-answers` removed; scratch `Desktop/_kat` deleted.

## Key files
- New: `frontend/third_party/libsignal_protocol_dart/PATCHES.md`, `frontend/test/services/encryption/libsignal_known_answer_test.dart`.
- Edited: `CLAUDE.md` (count), `docs/plans/2026-11-24-signal-grade-gap.md` (§1.5 Done block, §5 table cell, §6.1), `docs/agents/traps.md`.
- Read only (load-bearing): `frontend/test/services/encryption/libsignal_trial_decrypt_test.dart` (the proof of both patches).

## Verification
- CI: 13/13 on PR head `d159c20a`; 12/12 on master `cd6918b1`.
- Blob comparison: 95 of the 98 vendored files are byte-identical to the pub.dev archive; the other three are the two patched files and `pubspec.yaml`. Redone independently by the reviewer.
- Each patch undone separately: `libsignal_trial_decrypt_test.dart` fails at its "Patch 1" / "Patch 2" expectation.
- Every hex literal in the new test compared by script with the Java byte arrays (mine and the reviewer's extractor).
- The clamping explanation was computed independently twice (Python ladder + HKDF): the Java values appear without clamping, the port's and libsignal's with it.
- Reviewer mutants in the port: changed `WhisperRatchet` info string, swapped DH terms in `initializeSessionAlice`, changed `chainKeySeed`: each turned the matching known-answer test red. The first was caught by nothing else.
- Dart ratchet (dart-lint-ratchet.mjs): 2481 against baseline 2482; baseline not lowered.
- No device drive and no deploy: no shipped code changed.

## Notes for next session
- **Next action:** the next approved item, in this order: threat-model wording for Q3 and Q4; CodeQL for TypeScript; CI-built APK with a published checksum (gap report §4.4 step 1); B7 tail (behavioural, own release).
- Owner-owed: a contact address for `SECURITY.md`; the lawyer on the licence; BE-12; UI-16/UI-17; composer split (UI-28); TD-07.
- Not proven by the known-answer tests (no published vector): a complete message (wire format, AES-CBC, MAC), session setup with a one-time pre-key, the DH ratchet step under the v3 KDF.
- Not verified: the claim that libsignal removed the classic protocol exactly in v0.75.0 was taken from the earlier research note, not re-checked here.
- Trap (also in `docs/agents/traps.md`): the Dart port clamps every X25519 private key before use; a Java reference vector with an unclamped key cannot match it as is.
