# Two-axis review since 0.2.71; a picked video no longer goes into a chat opened while it was being prepared

**Date:** 2026-10-27 · **Version:** unchanged (0.2.71 on prod; the multi-photo work and this fix ship with the next version) · **Tiers deployed:** none

## What was done
- **Review (owner: "review skill", fixed point `63bbc53c` = 0.2.71, two subagents as the skill says).** Only code in range: the other session's multi-photo/gallery commit `a1d1a955` + the staging freeze passthrough. Standards: 3 hard (doc says "one file in RAM at a time" but `chat_action_tiles.dart:225-227` passes `withData: kIsWeb`; stale "byte-identical" comment `:181`; `image_message_content.dart:81-82` drops `showMediaGallery`'s Future without `.ignore()`), 7 judgement smells. Spec: 3 hard (below; the RAM doc claim twice), 3 judgement (cap counts unsupported files; multi-document pick + counter unasked; web GIF tap re-downloads). Full reports were given to the owner in chat.
- **Fixed the worst spec finding on the owner's word ("yes fix it for him").** `sendPickedFiles` checked the active conversation only before each file; `sendPickedVideo` then awaited transcode + probe checking only `mounted`, and `AttachmentHandler.sendVideo` sent into whatever chat was active. The desktop split view keeps the composer mounted across a chat switch, so the clip went into the newly opened chat. Now `sendPickedVideo` captures the conversation at entry and returns `false` (nothing sent) when `!mounted || _chatSwitchedFrom(id)` after the transcode and after the probe; `_sendPickedFile` returns that, and the batch stops with the existing root-overlay toast (`attachmentBatchInterrupted`).
- `frontend/docs/composer-media.md` line 28 says the check now runs inside a video too.
- Not fixed (reported, owner to decide): the other review findings; a switch while file_picker is still READING the picked files (before `sendPickedFiles` starts) sends to the new chat on both builds.

## Key files
- Edited: `frontend/lib/widgets/input/chat_input_bar.dart` (`sendPickedFiles`, `_chatSwitchedFrom`, `_sendPickedFile` → `Future<bool>`, `sendPickedVideo` → `Future<bool>`), `frontend/test/widgets/input/chat_input_bar_attachment_test.dart` (new test), `frontend/docs/composer-media.md`, `docs/agents/traps.md` (2 lines), this summary, LATEST, NEXT.
- Out of repo: `%TEMP%/fixdrive/` (bundles `web-head`, `web-fix`, `clip15.mp4`, `audio_only.mp4`, screenshots). Dev DB gained account `mpz1027` (272, password `Test123123`), friends with `mpx1027` (270). Dev stack started for the drive and stopped again (`docker compose stop`, volumes kept).

## Verification
- **Red first:** new test "switching chats while a video is being prepared sends it nowhere and says so" (transcode override opens chat 11 mid-prepare) failed `Expected: empty, Actual: ['VIDEO']` before the fix, passes after.
- **Device drive (release web builds, dev backend, desktop 1600×1000 split view, mpx1027 @:8211, third friend mpz1027 registered in an isolated browser context @:8212):** pick an audio-only `.mp4` in mpy's chat, click mpz's chat 1 s later. HEAD bundle (`main.dart.js` 8489180 B): the clip appeared in **mpz's** chat (18:23, `x_aoh_end.png`). Fix bundle (8489433 B): toast "Część plików nie została wysłana — czat został zamknięty" at +1–2 s (`ao_strip.png`), nothing new in mpz or mpy.
- Gates: `dart-lint-ratchet` held at baseline 3131; `flutter analyze` 0 warnings/errors; attachment test file 21/21 (see the flake below); full suite **3282 passed / 14 skipped** (+1, `CLAUDE.md` count updated, `verify-claude-frontend-test-counts` OK).
- **Pre-existing flake found:** "every file goes out at once…" loses its third file in 1–3 of 6 full-file runs, also at pristine HEAD (1/6). Log: `SEND_DUPLICATE_BLOCKED` — two sends in the same millisecond share `tempId = temp_<millis>_<userId>`. Real uploads make that a test-only collision in practice. Trap added; not fixed.
- NOT verified: Android/iOS (the bug needs the desktop split view, where the composer outlives a chat switch; on phones the chat screen unmounts).

## Notes for next session
- Owner-owed: which other review findings to fix (the file_picker read window, the RAM doc claim, the `.ignore()`, the stale comment); whether to fix the tempId collision (`messaging_provider.send.dart` mints `temp_<millis>_<userId>` in 6 places).
- The Phase 4 items in NEXT.md are unchanged (post-wipe handoff bug decision, pair tests, freeze ≥ 10-30).
