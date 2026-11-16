# 0.2.85 live: A5 with its review fixes (one audio-cache lock, picker copies swept); B1 dropped by the owner

**Date:** 2026-11-16 · **Version:** 0.2.84 → 0.2.85 · **Tiers deployed:** both + APK

## What was done
- **Two-axis review of #253 (A5)** by two reviewer subagents. Fixed in PR #254 (`4e8f89df`, merged `18c2684a`):
  - `AudioCacheStore.exclusive` is one lock for every read-then-rename on the voice cache: `remove`/`clear`, `writeSealed`, the launch pass `sealPlainAudioCacheFiles` and the rotation's `resealAudioCacheFiles`. Before, the launch pass could rename a purged note back. Inside the lock, the key a seal reads is the one a rotation sees.
  - One temp suffix (`.tmp`), owned by `AudioCacheStore` (`isNoteName`, `isTempName`, `replaceAtomically`). `remove` deletes a note's temp files; the launch pass deletes stale ones, including older builds' `.reseal`.
  - New `utils/plaintext_temp_sweep_io.dart` (`sweepStalePlaintextTempFiles`, called after `runApp`) replaces the video-only sweep. It also deletes file_picker's `cache/file_picker/<ms>/` copies of every picked file and image_picker's `cache/<UUID>/` copies. `voice_*.m4a` is still kept for retries.
  - `PlaybackController._playCachedFile` always plays from memory.
  - Stale docs and comments fixed; negative sweep tests got positive controls; single-group wrappers dropped.
- **Owner: B1 dropped** (QR, safety number and the lasting "verified" mark). The plan row records what stays: with B2 also dropped, only manual key comparison catches a substituted key.
- **Released 0.2.85** on the owner's word: web, backend (APK pointer only) and APK 20085, all at `18c2684a`.
- **Owner OK:** throwaway prod accounts `rel85a4555` and `rel85b6577` (ids 159–160) deleted after backup `chatdb-20261116T144836Z`. Users went 31 → 29; every table holding a user id has 0 rows for them.
- A parallel session pushed `6cc3d7e9`/`54f32055`: CI test legs, tests 3304 → 3288. #254 was rebased onto it; the CLAUDE.md count and lint floor were resolved to the merged values.
- **Out-of-repo:**
  - VM `.env` `ANDROID_APK_*` set to 20085 (backup `.env.bak.pre-apk-0.2.85`); `apk/umbra-0.2.85.apk` added.
  - `Desktop/umbra-0.2.85.apk` kept.
  - Local stack downed `-v`; Pixel_7 killed with the release build installed; worktree `fireplace-a5r` removed, branch deleted.

## Key files
- Edited:
  - `frontend/lib/services/audio_cache_store.dart`, `services/encryption/audio_reseal.dart`
  - `frontend/lib/widgets/audio/playback_controller.dart`, `utils/video_temp_file_{io,stub}.dart`, `main.dart`
  - `providers/encryption_provider.dart` (comment only)
  - `frontend/docs/e2e-invariants.md`, `docs/plans/2026-11-16-security-hardening.md` (status line, A5, B1, B2), `CLAUDE.md` (3292)
- New: `frontend/lib/utils/plaintext_temp_sweep_{io,stub}.dart`, `frontend/test/utils/plaintext_temp_sweep_io_test.dart`.
- Removed: `frontend/test/utils/video_temp_file_io_test.dart` (superseded).
- Read only (load-bearing):
  - file_picker 11.0.2 Android copies picks to `cacheDir/file_picker/<ms>/`, confirmed on the device.
  - image_picker_android `FileUtils.java` copies to `cacheDir/<uuid>/`.

## Verification
- CI: success on `4e8f89df` (12/12) and on `18c2684a` (11/11 master, the deployed sha).
- Red first: with the old purge and seal behaviour behind the new `removeIn` seam, the purge-race, temp-purge and stale-temp tests failed. The picker-copy test was not run against the old sweep.
- Full suite 3292 pass / 14 skip after the rebase. Dart lint ratchet PASS, 2486 → 2481, floor lowered.
- `integration_test/native_content_store_device_test.dart` on the emulator: 8/8 (it had not been run for A3 or A5 before).
- Debug drive (local stack, web peer):
  - Planted stale picker, UUID and audio temp files were deleted at launch; `voice_*.m4a` was kept.
  - A real paperclip pick landed in `cache/file_picker/1794810692223/` and was gone after the next launch.
  - A voice note was cached as `FPAE 01` with no `.tmp`; "Usuń u mnie" emptied `audio_cache/`.
- Prod:
  - Backup `chatdb-20261116T065438Z`. `deploy-web.ps1` printed `PUBLISHED_OK`.
  - APK SHA256 `4b3021a542a7682c441fabae1a5b8dce44d201d1269bc41368f0c11749a96d23`, the same on the VM; signer `8e9a6bf3…5cdf405d`; 16/16 ELF OK; `libapp.so` has the prod host and `18c2684a`, no local hosts.
  - `deploy-backend.sh` healthy; smoke 8/8; `/version` is 0.2.85 / `18c2684a` / 20085; the APK URL answers 200; 0 error log lines.
- Release APK ↔ prod web on the emulator (read via `uiautomator`): footer `18c2684a`, invite accepted, text both ways, a voice note sent and played back.
- NOT verified: iOS; the owner's own phone; the legacy-plain playback branch (the launch pass seals before any tap).

## Notes for next session
- Next action: pick the next plan item with the owner. Cheap first: C3 (bundle the fonts: the app still downloads `.ttf` into `files/`, seen again on the emulator), D6, D5, D1. Then B4, D3, C1, C2.
- Owner-owed: confirm his Settings footer reads `0.2.85 · 18c2684a`; store decision, privacy policy and ToS.
- Not covered by A5: a failed voice send's `voice_*.m4a`.
- Traps: one Android line (picker copies in cache).
