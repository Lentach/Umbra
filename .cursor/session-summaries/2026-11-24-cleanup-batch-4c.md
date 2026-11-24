# Cleanup batch 4c: the last four audited giant files split (auth provider, first contact, chat screen, user card)

**Date:** 2026-11-24 · **Version:** 0.2.102 → 0.2.103 · **Tiers deployed:** both (+ APK 20103)

## What was done
- **Structural only; behaviour and test counts unchanged** (898 unit / 56 suites; 3554 Flutter / 1 skipped). PRs #297–#300.
- **CONT-21 (#298):** `frontend/lib/providers/auth_provider.dart` 1182 → 519. `AuthStatusCode`, `AuthAttempt`, `classifyAuthFailure` moved to `providers/auth/auth_status.dart` (re-exported, no importer changed). Private session and credential helpers moved to part-file extensions `auth_provider.session.dart`, `auth_provider.credentials.dart`. Every member a test fake shadows stays on the class.
- **CONT-19 (#299):** `messaging_provider.first_contact.dart` 1210 → 274, plus parts `first_contact_{relay,receive,accept,end,friend}.dart`. The statics stay in `MessagingFirstContact`; calls from the new parts are qualified.
- **UI-29 (#300):** `screens/chat_detail_screen.dart` 1168 → 615, plus `screens/chat_detail/{scroll,header}.dart` (private extensions on the State). Lifecycle overrides, `build`, `_onScroll`, `_onWebKeyboardInsetChanged` and the composer wiring (`_composerKey`, `_buildComposerFooter`) stay in the class. No composer file touched.
- **UI-30 (#297):** `screens/user_card_screen.dart` 1120 → 523, plus `screens/user_card/{user_card_data (re-exported), user_card_hero, user_card_parts}.dart`.
- **Reasons recorded** for the seven files still over 1 000 lines: audit status line in `docs/plans/2026-11-23-cleanup-audit.md`. All 12 GIANT rows are now split except UI-28 (composer).
- Doc citations that pointed at moved lines now name the symbol: `frontend/docs/e2e-invariants.md`, `docs/review/composer-keyboard-audit.md`, `frontend/CLAUDE.md`, `docs/agents/traps.md`, two plan docs.
- Out of repo: release APK 0.2.103 on emulator-5560 and the Xiaomi (vibrate, `screen_off_timeout` 60000); `Desktop/umbra-0.2.103.apk`; local stack `fp4c` and its volumes removed; worktrees `fireplace-4b*`, `fireplace-4c-*` and their branches removed; VM keeps `.env.bak.pre-apk-0.2.103`.

## Key files
- Edited: the four split files; `frontend/lib/providers/messaging_provider.dart` (part list); `frontend/pubspec.yaml`; the docs named above.
- New: `frontend/lib/providers/auth/` (3 files), five `messaging_provider.first_contact_*.dart`, `frontend/lib/screens/chat_detail/` (2), `frontend/lib/screens/user_card/` (3).
- Read only (load-bearing): `.planning/cleanup/findings.md` rows CONT-19, CONT-21, UI-29, UI-30; `.planning/cleanup/batches.md` sections "Batch 4c" to "4c release"; `.planning/cleanup/metrics.md` ("After batch 4c").

## Verification
- CI: 13/13 on each PR head (`bb21e293`, `4b90f9a5`, `32fabf4d`, `31658bb0`); 12/12 on master `b3b5393d`.
- Order-preserving line check, run by me on all four branches: only `part`/`import`/`export` lines, extension headers, comments and forced static qualifications differ from master.
- Reviews, correctness and standards: no blocker. Fixes applied: ignore rationale in `chat_detail/scroll.dart`, two stale citations, one test comment.
  - Auth: the reviewer re-listed the fakes' overrides (14 members, all on the class); 0 `override_on_non_overriding_member`.
  - Mutants in moved code that turned tests red: 2 auth, 2 first contact, 2 user card, 1 chat detail.
  - **Survivor:** `_getHeaderStatusText` returning null for typing passed all 802 screen and widget tests. The typing/recording header line has no test. Left as an open finding: the gap predates the batch and a structural batch adds no tests.
- Dart ratchet (dart-lint-ratchet.mjs): 2482 on three branches, 2481 on auth; baseline left at 2482.
- Local drive, merged build `902c4a45` (before the comment-only review fixes), emulator-5560 + Xiaomi + Chrome:
  - register ×3, invite and accept (emulator → Xiaomi, web → Xiaomi), text all directions;
  - user card from the chat header on emulator and web;
  - 15 filler messages, Xiaomi scrolled up, new message showed the scroll-to-bottom button with badge 1, tap jumped to newest;
  - emulator logout → login, Xiaomi cold start, web page reload: session and chats restored each time; backend log 0 errors.
- Release: backup `chatdb-20261124T210407Z.dump.gpg`, offsite 3/3. Backend and web serve `0.2.103 / b3b5393d`; web smoke PASSED. APK SHA256 `1ef9a8d1a9be2d4535622dea648ef64178f1e7ce9c867ca9d2bd0539c509ae67`; served file hashes the same.
- Live drive, release APK, emulator-5560 + Xiaomi: register ×2, invite, accept, text both ways, user card, cold start both, message after, logout → login. Throwaways deleted in-app; users 31. `post-deploy-smoke.mjs`: SMOKE PASSED.
- NOT verified: iOS; installed PWA on a real phone; web on prod (only the deploy smoke); user-card hero collapse and mute dialog; photo send on this build.

## Notes for next session
- **Next action:** none queued in the cleanup program; it waits on the owner's answers. Release B (avatar file deletion, TD-13) is due on or after 2026-12-08.
- Owner-owed: the eight questions in `docs/plans/2026-11-24-signal-grade-gap.md` §6; BE-12; UI-16/UI-17; the composer split (UI-28); TD-07.
- Open findings (no owner decision needed, not started): no test for the typing/recording header line; 4b M1 (`_boxRoute` list provenance not pinned by send tests); B3 holds at the provider layer only; five IPv6 `blocked` link-preview entries guard nothing; seven `isNot(contains('sendMessage'))` expects cannot fail; `chat-search.service.ts:17-34` duplicate helpers; UI-23; WEB-16.
- `refresh-tokens ↔ users` folder cycle remains (needs a behavioural change).
- Traps (also in `docs/agents/traps.md`):
  - A method added and removed as a listener tear-off must stay a class member; an extension tear-off is a new closure each time.
  - omp's headless WebKit tab never got past the app's loading screen; drive the web build in Chrome on port 9333.
