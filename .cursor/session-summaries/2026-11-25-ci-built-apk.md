# Release APK is now built unsigned in CI and signed on the PC; first real use is the next release

**Date:** 2026-11-25 · **Version:** unchanged (0.2.103) · **Tiers deployed:** none

## What was done
- Owner decisions (form, 2026-11-25): the CI build ships, signed offline; the Giphy key goes into an Actions secret; the checksum is published in a GitHub release and beside the APK under `/apk/`. This reverses the 2026-09-14 "never a GitHub Release" decision; a release holds only the unsigned build and checksums (trap rewritten).
- PR #303 (merged on the owner's word, master `4cadce9b`):
  - `.github/workflows/release-apk.yml`: on a `v<version>` tag (must equal pubspec, must be on master) builds the unsigned release APK, runs the gates, creates the GitHub release with the APK and its SHA-256. On a pull request touching the Android project, pubspec files or the APK scripts it runs the build job only.
  - `frontend/android/app/build.gradle.kts`: opt-in property `umbraUnsignedRelease` (APK only; the bundle refuses it). Default behaviour unchanged.
  - `sign-ci-apk.ps1`: checks where the release came from, signs v2-only with `--alignment-preserved true`, gates (pinned signer, 16KB, signed = CI file + signature), writes and optionally uploads the checksum.
  - `scripts/verify-apk-signed-matches-unsigned.mjs` + selftest (13 cases).
  - Docs: runbook (new release recipe; PC build is the fallback), gap report §4.4, traps, both `CLAUDE.md`, `testing-and-ci.md`, `dev-workflow.md`.
- Out of repo: Actions secret `GIPHY_API_KEY` set from `deploy-web.config.ps1` (value never printed).

## Key files
- New: `.github/workflows/release-apk.yml`, `sign-ci-apk.ps1`, `scripts/verify-apk-signed-matches-unsigned.mjs`, its `.selftest.mjs`.
- Edited: `frontend/android/app/build.gradle.kts`, `build-android.ps1` (closing text only), `docs/runbooks/android-release.md`.

## Verification
- PR head `c49f2408`: 16 rows, 15 success, `Publish the GitHub release` skipped (expected on a PR). Master `4cadce9b`: 13 rows, all success. CodeQL: 0 open alerts.
- Review: two reviewers, no blocker; applied provenance check, passwords cleared on Ctrl+C, v2-only gate, selftest, bundle guard, stale comments. Declined: sharing signer code with `build-android.ps1` (would restructure a working release script).
- Local: unsigned build works; refusals work (signed input, wrong signer, bundle with the property). MEASURED: without `--alignment-preserved` apksigner rewrites entry padding and the byte comparison fails.
- Drive: the CI-built APK (signed with a throwaway key, since deleted) on `emulator-5560` against the PC-built 0.2.103 on the Xiaomi: register, invite, accept, messages both ways, a GIF sent from the CI build. The CI build points at PROD: throwaways `ciapk1125a` and `ciapk1125b` were registered on prod and deleted in-app; users 31. Emulator restored to the official 0.2.103.
- After merge: `sign-ci-apk.ps1 -UnsignedApk` run from master with the REAL release key on the PR artifact: pinned signer, v2-only, 16KB and byte comparison passed; the output was deleted, nothing was installed or shipped.

## Notes for next session
- **NOT verified:** the tag path (`Publish the GitHub release` never ran) and `sign-ci-apk.ps1 -Tag` (release download, tag-on-master check, `github-actions[bot]` author check). The first end-to-end test is the 0.2.104 release, which also creates the first public GitHub release. Keep `build-android.ps1` ready as the fallback.
- **Next action:** B7 tail (count `phrase_v1` rows on prod, re-enrol prompt, remove the legacy branch): behavioural, failing tests first, staging rehearsal, own release 0.2.104 through the new path.
- Not done: reproducible builds and pinning (gap report §4.4 steps 2-3); `.sha256` under `/apk/` downloads instead of displaying (needs an nginx change).
- Every version-bump PR now also runs the APK build (about 11 min).
- Owner-owed: `SECURITY.md` contact address; re-read of the changed privacy-policy drafts; a lawyer on the licence; BE-12; UI-16/UI-17; composer split (UI-28); TD-07.
