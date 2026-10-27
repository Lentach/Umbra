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
- CI: see Notes (filled after push).
- `flutter test`: 3281 passed / 14 skipped (was 3271). `flutter analyze` 0 warnings/errors; Dart ratchet 3145 → 3131 (`--update`).
- New tests: viewer paging (swipe, thumb pinch, zoomed drag, list shift/close/append) and composer batch (order IMAGE/VIDEO/IMAGE + draft kept, cap, leave mid-batch, unsupported file). Mutants killed: index-shift skip (`next == _index || true`), `scaleEnabled: _zoomed`, no pointer freeze (real red before the fix: thumb pinch turned the page, arena debug showed `HorizontalDragGestureRecognizer` winning).
- Drive (release web build, dev backend, s4pa@:8201): desktop UA — system picker `isMultiple()=true`, 3 photos sent at once, draft kept; gallery 3/3 → arrow 2/3 → ArrowLeft 1/3. Android UA + touch emulation — four-door sheet, Galeria input `accept=image/*,video/*` `multiple=true`; 12 picked → toast "Naraz można wysłać do 10 plików…", gallery counter 13/13 (3+10, last = 10th file); touch swipe pages; swipe-down closes; thumb pinch zooms and stays 12/13; zoomed horizontal drag pans; back right after a 10-file pick → toast "Część plików nie została wysłana — czat został zamknięty".
- NOT verified: receiver side (s4oa got nothing — not even a control text — dev box state between these accounts is broken, pre-existing), real iOS PWA picker multi-select, real Android phone, native APK.

## Notes for next session
- Next action: owner tries it on a phone (iOS PWA photo library multi-select via file_picker is the unproven door); then release with the next version.
- Owner-owed: nothing new.
- Drive recipe: serve the bundle on :8201/:8202 (`p4s4drive/serve-multi.mjs`, profile `p4s4drive/prof`, Chrome :9461 — SHARED with other sessions: attach CDP only to the target whose URL you opened). Android path = `Emulation.setUserAgentOverride` (Android UA) + `setDeviceMetricsOverride mobile` + `setTouchEmulationEnabled`, reload; pick files with `Page.setInterceptFileChooserDialog` + `DOM.setFileInputFiles`.
- Traps: PageView steals the pinch; root navigator context has no Overlay (both in traps.md).
