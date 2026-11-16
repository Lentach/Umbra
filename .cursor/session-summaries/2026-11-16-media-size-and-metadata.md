# Attachment size sealed inside the encryption (A1), camera metadata scrubbed from photos and videos (A2)

**Date:** 2026-11-16 · **Version:** 0.2.82 → 0.2.83 (merged, NOT deployed) · **Tiers deployed:** none

## What was done
- A1, `services/box/box_media_frame.dart` `padMediaPlaintext`/`unpadMediaPlaintext`:
  - `MediaCryptoService.encrypt` seals `file ‖ zeros ‖ uint32be(len) ‖ "UmbraPad"`, sized so the frame fills its rung. The server now sees `rung − 4` in every prefix and no zero tail.
  - `decrypt` cuts the padding only at a well-formed trailer, so pre-A1 files read unchanged. No wire-shape change, so a 0.2.82 reader still decrypts.
  - Receiver cap: `maxCiphertextBytes` = `kBoxMediaTopRung − 4` (new const in `box_wire.dart`). The old `/media` path keeps `maxBytes + 16`.
  - `MediaCipher` seam added (webcrypto in the app, `PointyMediaCipher` in tests).
- A2, new `utils/media_metadata.dart`:
  - `scrubImageMetadata`, lossless for JPEG/PNG/WebP. A JPEG keeps a one-entry Exif with its orientation; everything after EOI and MPF are dropped.
  - `scrubVideoMetadataInPlace` for MP4/MOV: `udta`, `meta` and XMP `uuid` boxes are zeroed and renamed `free`; the file keeps its exact size.
  - Hooked in `sendImageMessage` and `sendVideoMessage`, with diag line `MEDIA_METADATA_SCRUBBED {type, bytes}`. Documents, GIF, HEIC and WebM go as they are.
- iOS (owner question): quest-api.fly.dev is Ad Hoc OTA.
  - Its `/install` page links `itms-services://` to `/install/manifest.plist`, which points to an `.ipa` on Supabase storage.
  - The app is Flutter. Its `embedded.mobileprovision` lists 4 registered iPhones and has production push; `get-task-allow` is false; it expires 2027-10-15.
  - The owner's iPhone has to be one of those 4 UDIDs. No UDID-enrolment page was found on the host.
- Docs updated: `wire.md` (media bullets), `composer-media.md`, `METADATA.md`, plan A1/A2 marked done, a trap, and the `CLAUDE.md` test count (3285).
- Out-of-repo:
  - local stack `dmed` was removed (`down -v`);
  - the Pixel_7 emulator now holds the debug app; the 0.2.82 release install was uninstalled with its data, which belonged to an already-deleted prod test account;
  - the `fireplace-old0282` worktree was removed;
  - `C:/Users/olek2/Desktop/fireplace-media` is the feature worktree.

## Key files
- New: `frontend/lib/utils/media_metadata.dart`, `test/utils/media_metadata_test.dart`, `test/support/media_metadata_fixtures.dart`.
- Edited:
  - lib: `services/media_crypto_service.dart`, `services/box/box_media_frame.dart`, `box_wire.dart`, `box_media_fetcher.dart` (doc only), `utils/encrypted_media_loader.dart`, `providers/messaging/messaging_provider.send.dart`;
  - tests: `test/services/box/box_media_frame_test.dart`, `test/support/box_fakes.dart`, `test/providers/messaging_provider_media_send_test.dart`.

## Verification
- CI: success 7/7 on `86168a18` (PR #249 head). The first run (`64f28f93`) failed only on the `CLAUDE.md` test-count gate.
- Local: full Flutter suite 3285 pass / 14 skip; Dart ratchet PASS (baseline 2494); `flutter analyze` clean on touched files.
- Mutants: 10/10 killed. They removed the scrub on image or video, padding on encrypt, unpadding on decrypt, the zero check, the APP1 drop, the orientation segment, video zeroing, the post-EOI drop, and the MPF drop.
- Device drive, local stack, web release build (Chrome) ↔ Android debug APK (Pixel_7):
  - **Web → Android:** a GPS photo and a located MP4 both show and play. The photo saved on Android has no Exif or GPS and is pixel-identical to the original.
  - **Android → web:** a gallery photo and video both show and play. The photo saved on web has no Exif or GPS and is pixel-identical.
  - **Server frames:** every new-build upload starts `rung − 4` (`0000fffc`, `00003ffc`) with no zero tail. A 0.2.82 sender's upload starts `0000670f`, the exact size, which is the leak A1 closes.
  - **Mixed versions:** a 0.2.82 web build (Chrome) shows the padded photo and plays the padded video; the new build shows the 0.2.82 sender's unpadded photo.
- NOT verified:
  - voice notes and documents sent to a pre-0.2.83 reader (it keeps the padding bytes on the end);
  - a padded file over 16 MiB to a pre-0.2.83 reader (refused: old cap 20 MiB + 16);
  - iOS; prod.

## Notes for next session
- Next action: release 0.2.83 on the owner's go. Web via `deploy-web.ps1` from the main checkout; APK via `build-android.ps1`; set the VM `.env` `ANDROID_APK_*`, then `deploy-backend.sh`; take a backup first. Recipe: `2026-11-10-release-0282.md`.
- Owner-owed:
  - the release go;
  - deleting the 8 plaintext hash files on the VM;
  - an end date for `step5-archive`;
  - B2, the key-change default;
  - Apple Developer enrolment (for iOS Ad Hoc, see plan §6).
- Seen on the device: the Android app downloaded Archivo/Inter `.ttf` files into `files/` at runtime (plan C3, confirmed).
- Traps: one added to `traps.md` (Composer): box media plaintext is padded, so open it only through `MediaCryptoService.decrypt`.
