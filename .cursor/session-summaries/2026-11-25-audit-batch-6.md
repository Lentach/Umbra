# Audit batch 6: composer split, leftovers, l10n-based tests, SECURITY.md; 0.2.105 released

**Date:** 2026-11-25 · **Version:** 0.2.105 · **Tiers deployed:** backend, web, APK

## What was done
- Owner decisions O-12..O-17 (form, 2026-11-25), recorded in `docs/plans/2026-11-23-cleanup-audit.md` §8: split the composer; keep the old media fallbacks and measure first; BE-12 removal confirmed; TD-07 all files; do the review leftovers; the freeze stays until these are done. The owner then gave full permission to merge and deploy the audit work overnight.
- PR #307 (docs): `SECURITY.md` with the owner's contact address.
- PR #308: header status line tests (+7); a send test for the unverified-device-list guard (+1); 40 `isNot(contains('sendMessage'))` → `isEmpty`; the IPv6 SSRF entries now reach the rule through a redirect hop; `chat-search.service.ts` uses the shared `socketData`; the video bubble's `m:ss` delegates to `formatClock` (+10 pin tests).
- PR #309 (tests only, TD-07): 35 test files read UI text through `frontend/test/support/l10n.dart`.
- PR #310 (structural, UI-28 / UI-16): `chat_input_bar.dart` 1649 → 659 + mixin parts in `widgets/input/chat_input_bar/`; `chat_action_tiles.dart` 950 → 275 + `widgets/chat_action_tiles/`; dead `AttachmentHandler.openGifPicker` deleted; mic comments say tap-to-toggle; rule triggers follow the new paths; version 0.2.105.
- UI-17 measured (O-13): the server cannot see message rows and nginx access logging is off; the old path was removed on 2026-11-04 and holds no files, so an own-server old link already fails; only a `res.cloudinary.com` link could still load. Code kept.
- Desktop cleaned on the owner's word: worktrees `fireplace-drive` (7 local-only merge commits), `fireplace-1c`, `fireplace-b7` and this session's four removed. Kept: `fireplace-backups`, `fireplace-landing`.
- Out of repo: prod `.env` `ANDROID_APK_*` → 20105 / 0.2.105 (backup `.env.bak.pre-apk-0.2.105`).

## Key files
- `frontend/lib/widgets/input/chat_input_bar.dart` + `chat_input_bar/{core,emoji_panel,focus,send,trailing_slot}.dart`; `frontend/lib/widgets/chat_action_tiles.dart` + `chat_action_tiles/{attachment_doors,tiles}.dart`.
- `frontend/test/support/l10n.dart`; `frontend/test/screens/chat_detail_header_status_test.dart`.
- `backend/src/link-preview/link-preview.service.unit.spec.ts`; `backend/src/chat/services/chat-search.service.ts`.
- `SECURITY.md`; `.omp/rules/frontend-composer-media.md` (+ `.claude` mirror).

## Verification
- Review of #310, two reviewers, no blocker: verbatim proof re-derived (only headers, the `with` chain, qualified statics, comments differ); mutants on the emoji pin, chat-surface tap, batch order, caption chat-switch guard and collapse guard all red; one survivor (mic layer `IgnorePointer` while recording) is a gap already on master. Lead on #308: an IPv6-rule mutant fails 6 tests.
- Counts by full runs: backend 898 / 57; Flutter 3604 / 1 skipped. Dart ratchet 2479 against baseline 2482 (not lowered).
- CI by name: #307 14, #308 14, #310 15 + expected skip; #309 11 rows on its stacked base (after a ratchet fix `a658f8ca`); master `7b99c0fb` 13 rows success.
- Local drive (stack `fp6`, composer + #308; emulator, Xiaomi, Chrome): handle search + invite; text sends keep the keyboard; emoji panel (open, insert, send from panel, BACK closes panel only); four attachment doors; photo + video in pick order with the `m:ss` chip; file; GIF; voice; pasted image then caption (web); two-file pick (web); edit; reply. Backend log 0 errors.
- Release: backup `chatdb-20261125T142520Z.dump.gpg` (3 files on R2); backend + web `0.2.105 / 7b99c0fb`; tag `v0.2.105` → CI built the APK; `sign-ci-apk.ps1 -Tag v0.2.105 -PublishChecksum` ran from master (first run of the merged #306 path); unsigned SHA256 `e3f645bf69cc21735958fe66cfa0d2df4d3f6f1110c5e06751ad3ac9b2f10d1c`, signed `38691ef98b5cea795c12f510999b031fe01309a12c191e13fcaee648526a5d0e` (equal on the PC, the server, the release). Live drive on prod (`rel105a`/`rel105b`: search, invite, text both ways, photo + video; deleted in-app); web and post-deploy smoke PASSED; users 31.
- Prod legacy rows: 6 `phrase_v1` + 1 `auth_v2` (7 legacy at the 0.2.104 release): one account replaced its key.

## Notes for next session
- **Next action:** ask the owner whether the feature freeze is over (O-17), with the findings below.
- NOT driven: voice on web; camera doors (Aparat, Nagraj wideo); ping; disappearing-timer banner; clear-chat hold; desktop split-view chat switch during a send; iOS.
- Found, not fixed (not asked): (1) flaky wall-clock test `identity-reset.service.spec.ts:684` (`> 15` ms; failed once on #310 at 14.84 ms); (2) replying to your OWN message shows "Unknown" in the composer preview (`reply_preview_bar.dart:71`, hardcoded English) and "Nieznany" in the bubble quote; (3) no test covers the attachment doors or the mic layer's pointer guard.
- An agent wrote into the main checkout through relative paths again (reversed); the lead's own `cd /tmp/x` failure dropped two files in the repo root (moved out). See traps.
- Owner-owed: re-read both privacy-policy drafts; a lawyer on the licence; UI-17 decision (data above). Release B (avatar file deletion) due on or after 2026-12-08.
