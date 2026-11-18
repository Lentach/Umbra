# B7 Option V: the recovery phrase never leaves the device (draft PR #PRNUM, unmerged)

**Date:** 2026-11-19 · **Version:** unchanged (0.2.88) · **Tiers deployed:** none

## What was done
- `frontend/lib/services/recovery_phrase.dart`: `deriveAuthSecret` (HKDF-SHA256, info `umbra/recovery/auth/v1`) and `deriveSealKey` (`umbra/recovery/seal/v2` + blob salt), reusing `link_crypto.hkdfSha256`; no new dependency.
- `encryption_provider.dart` `setRecoveryKey` emits `authSecret`, `requestIdentityReset` emits `recoveryAuth`; `api_service.dart` `recoverPassword` sends `authSecret`. No client path emits `phrase`/`recoveryPhrase`.
- `identity_backup.dart`: seal writes version 2 (`iterations: 0`, HKDF key); `unseal(version:)` still opens v1 (PBKDF2); absent version = 1.
- Backend: migration `0030_recovery_verifier_kind.sql` (`recovery_keys.verifierKind`, `phrase_v1` default, `auth_v2`); `IdentityResetService` verifies only the credential of the row's kind (`RecoveryCredential`), one counter and lockout for both, dummy verify on every mismatch.
- A `phrase_v1` row answers an authSecret with `legacy_recovery_key` (409 on `/auth/recover`, a status on `identityResetStatus`); `ownKeyBundleStatus.recoveryKeyLegacy`.
- DTOs: `CredentialXor` (`common/credential-xor.ts`) enforces exactly-one (`SetRecoveryKeyDto`, `RecoverPasswordDto`) or at-most-one (`ResetIdentityRequestDto`); `RecoveryBackupDto.version` 1|2.
- Settings: one-time dismissible prompt row (`settings-recovery-legacy-row`) opens `RecoveryKeyScreen`; EN+PL strings; `AuthStatusCode.legacyRecoveryKey`.
- Docs: wire.md, METADATA.md, both privacy policies, multi-device.md 6.2.1, e2e-invariants, plan B7 row, three traps.

## Key files
- Edited: `identity-reset.service.ts`, `chat-key-exchange.service.ts`, `auth.service.ts`, `identity-reset.dto.ts`, `recover-password.dto.ts`, `recovery-key.entity.ts`, `encryption_provider.dart`, `identity_backup.dart`, `settings_screen.dart`, `settings_provider.dart`, `api_service.dart`, `auth_provider.dart`.
- New: `migrations/0030_recovery_verifier_kind.sql`, `common/credential-xor.ts`, `recover-password.dto.spec.ts`, `settings_recovery_legacy_test.dart`.
- Read only: `docs/plans/metadata-privacy-decisions.md`, `link_crypto.dart`.

## Verification
- CI: NOT RUN on the head sha at the time of writing (see PR #PRNUM checks).
- Backend `npm test`: 868 tests, 49 suites; `lint-ratchet` held at 252; knip, `verify-no-user-logs`, `verify-box-imports` clean.
- Flutter `flutter test`: 3322 tests, 14 skipped; `flutter analyze --no-fatal-infos` exit 0; `dart-lint-ratchet` held at 2478.
- Live drives: NONE. Not driven on any device: enrol, recover on a v2 row, an old client recovering on a `phrase_v1` row, the legacy prompt, a v1 backup restore.

## Notes for next session
- Next action: the parent drives the device script in the PR body, then asks the owner for the merge OK. Do not merge or deploy without it.
- Owner-owed: a client on the build after 0.2.88 cannot recover a `phrase_v1` account (it gets `legacy_recovery_key`); the owner must replace the key from a signed-in device first.
- Old 0.2.88 clients ignore backup `version`, so they cannot open a v2 blob (reads as a failed restore); `test_e2e` still enrols with the legacy plaintext phrase on purpose (old-client coverage).
- Traps: three lines appended to `docs/agents/traps.md` (plaintext phrase field, HTTP whitelist, backup version).
