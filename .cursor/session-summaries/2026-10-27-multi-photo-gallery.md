# Paperclip picks send several files at once, immediately; fullscreen photos/GIFs swipe left/right

**Date:** 2026-10-27 · **Version:** unchanged (0.2.71) · **Tiers deployed:** none

## What was done
- Owner asks (2026-10-27): pick several photos at once; a pick sends with no confirm step; swipe between photos in fullscreen. Owner answers: separate bubbles (no album), typed draft stays in the field, pasted images keep staging, swipe covers photos + GIFs (not video), cap 10 per pick, mixed photo+video picks send all.
- `ChatActionTiles`: file_picker `allowMultiple`; Android sheet Galeria + Plik set `multiple` on the anchored input (`pickFilesViaAnchoredInput`, lazy `readBytes` per file). One seam `onPickedFiles`; routing/document send moved out (`AttachmentHandler.sendDocument`).
- `ChatInputBarState.sendPickedFiles`: cap `kMaxFilesPerPick`=10 + toast, one message per file in pick order, each awaited to its emit; stops (root-overlay toast) when the active conversation changes or the composer unmounts. `stagePickedImage` removed; paste/IME insert still stage.
- `widgets/input/picked_attachment.dart` (new): `PickedAttachment`, kind by extension, image/document MIME.
- `FullscreenImageViewer` is now a pager (`pageKeys`, `pageBuilder`, `overlayBuilder`, `onPageChanged`): counter, desktop arrows + ←/→, pager frozen while zoomed or 2+ pointers down, keeps its page by key when the list changes, closes if the page on screen goes.
- `widgets/message/media_gallery.dart` (new): `showMediaGallery`, live list from `MessagingProvider` (IMAGE/GIF with `mediaUrl`), bytes cache ±2 pages, copy/save moved here from `ImageMessageContent`; `loadMessageMediaBytes` shared by both bubbles.
- `showTopSnackBar(..., overlay:)` to toast after the caller's screen is gone. l10n `attachmentPickLimit`, `attachmentBatchInterrupted` (en, pl).
- Out-of-repo: dev stack started for the drive and stopped again (`docker compose stop`, volumes kept); `%TEMP%/mpdrive/` (bundle copy, test images, screenshots). During the drive this session ONCE attached CDP Android emulation + reload to another session's tab (`127.0.0.1:8302`, staging drive) by picking the first page target; it was cleared within a minute.

## Key files
- Edited: `frontend/lib/widgets/{chat_action_tiles,top_snackbar}.dart`, `widgets/input/{chat_input_bar,attachment_handler,composer_attachment_controller}.dart`, `widgets/media/{fullscreen_image_viewer,swipe_down_to_dismiss}.dart`, `widgets/message/{image,gif}_message_content.dart`, `utils/web_file_input{,_stub,_web}.dart`, `l10n/app_{en,pl}.arb` (+ generated), `frontend/docs/composer-media.md`, `docs/agents/traps.md`, `CLAUDE.md` (counts), `scripts/dart-lint-baseline.json`
- New: `widgets/input/picked_attachment.dart`, `widgets/message/media_gallery.dart`; test renamed `fullscreen_image_viewer_dismiss_test.dart` → `fullscreen_image_viewer_test.dart`
- Read only (load-bearing): `providers/messaging/messaging_provider.send.dart` (`sendImageMessage` uses the ACTIVE conversation)

## Verification
- CI: green on `a1d1a955` (all 6 jobs: Flutter analyze and tests, Backend tests, E2E wire harness, E2E isolated probes, Web Lock probe, CodeQL).
- New tests: viewer paging (swipe, thumb pinch, zoomed drag, list shift/close/append) and composer batch (order IMAGE/VIDEO/IMAGE + draft kept, cap, leave mid-batch, unsupported file). Mutants killed: index-shift skip (`next == _index || true`), `scaleEnabled: _zoomed`, no pointer freeze (real red before the fix: thumb pinch turned the page, arena debug showed `HorizontalDragGestureRecognizer` winning).
- Drive (release web build, dev backend, s4pa@:8201): desktop UA — system picker `isMultiple()=true`, 3 photos sent at once, draft kept; gallery 3/3 → arrow 2/3 → ArrowLeft 1/3. Android UA + touch emulation — four-door sheet, Galeria input `accept=image/*,video/*` `multiple=true`; 12 picked → toast "Naraz można wysłać do 10 plików…", gallery counter 13/13 (3+10, last = 10th file); touch swipe pages; swipe-down closes; thumb pinch zooms and stays 12/13; zoomed horizontal drag pans; back right after a 10-file pick → toast "Część plików nie została wysłana — czat został zamknięty".
- Why s4oa got nothing: dev `box_queues` row `11d83e…` held all 15 of today's sends (3+10+1+text) with `touchedDay` 2026-10-22 — s4pa still sends to the queue s4oa's device had before it re-minted on the 10-22 drive, and nobody drains it. That is the known open E114 residual (stale `ackedBy` keeps sends on the old queue until the 24 h resend), not this change.
- Receiver drive (fresh pair registered for it: `mpx1027` 270 @:8211 → `mpy1027` 271 @:8212, own Chrome :9471, Android emulation): control text arrived; 4-photo Galeria pick arrived in pick order and the sender's draft stayed; Y's gallery 4/4 → 3/4 → 2/4 → 1/4 by touch swipe, pages matched picks p10, p08, p06, p04; mixed pick photo/video/photo arrived in that order and the gallery skipped the video (6/6 = p02, 5/6 = p01); a photo arriving while Y's gallery was open grew it 5/6 → 5/7 without moving the page.
- NOT verified: real iOS PWA picker multi-select, real Android phone, native APK.

## Notes for next session
- Next action: owner tries it on a phone (iOS PWA photo library multi-select via file_picker is the unproven door); then release with the next version.
- Owner-owed: nothing new.
- Drive recipe: `%TEMP%/mpdrive/d.mjs` (`device(name, port)` = own window on Chrome :9471 from `mpdrive/launch.ps1`, Android UA + mobile metrics + touch emulation, file chooser intercept → `pick(files)`), bundle served by `p4s4drive/serve-multi.mjs` on :8211/:8212. Dev accounts `mpx1027`/`mpy1027`, password `Test123123`. Never drive on Chrome :9461: other sessions share it.
- Traps: PageView steals the pinch; root navigator context has no Overlay (both in traps.md).
