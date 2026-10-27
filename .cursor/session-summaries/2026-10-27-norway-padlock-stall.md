# A passcode user's iPhone app showed only an orange padlock; it opened after waiting (investigation, no code change)

**Date:** 2026-10-27 · **Version:** unchanged (prod 0.2.71 / 63bbc53c) · **Tiers deployed:** none

## What was done
- Investigated a report from user 80 (iPhone home-screen app, passcode on): the app showed only an orange hexagon with a padlock, no keypad, while notifications and the badge kept working. No code changed.
- Identified the screen: it is the DOM boot cover `#fp-curtain` (`frontend/web/index.html:44-58`, shown at boot when `flutter.passcode_enabled` is `true`, z-index max). It sits OVER the `#fp-boot` loader and its 6 s hint, and only Dart lifts it (`passcode_gate.dart:76-79`, once the passcode state is known). The Flutter lock screen's hexagon is GREY; this one is ORANGE.
- Reproduced that exact screen on the release web bundle by stalling `main.dart:81` `consumePendingNotificationDeepLink()` (IndexedDB `fireplace-push`, `pending_deep_link_web.dart:69-102`, no timeout). Releasing the stall let the app start by itself.
- The stall was FORCED: a second tab held the db open and queued a version-2 upgrade. Every prod open uses version 1, so this exact hang cannot happen in prod. It shows what a stall at that point looks like, not why one would happen on his phone.
- Ruled out a release regression: 11 other iPhone home-screen users completed starts after the 10-23 deploy, and `git diff 655e7f0b 63bbc53c` (0.2.68 → 0.2.71) changes nothing that runs before the first screen (only `auth_provider.dart`, which runs after it).
- Outcome: the user opened the app, waited, and it started normally. Prod confirms his first good start since 10-21 at 19:40 UTC.
- Out-of-repo: none. Own Chrome :9471 and the throwaway servers on :8211-8213 are closed; the dev stack is stopped (volumes kept).

## Key files
- Edited: `docs/agents/traps.md` (2 lines), `.cursor/session-summaries/LATEST.md`.
- New: this file.
- Read only (load-bearing): `frontend/web/index.html`, `frontend/web/fp_boot.js`, `frontend/lib/main.dart`, `frontend/lib/utils/pending_deep_link_web.dart`, `frontend/lib/widgets/passcode_gate.dart`, `frontend/lib/widgets/passcode_curtain.dart`, `frontend/lib/screens/passcode_unlock_screen.dart`, `frontend/lib/providers/passcode_provider.dart`, `frontend/lib/services/encryption/content_key_wrap.dart`.

## Verification
- CI: NOT RUN for this entry: investigation only, no code commit.
- Repro (release web bundle from `a1d1a955`, own Chrome, fresh origin :8213, localStorage `flutter.passcode_enabled=true`):
  - control: normal lock screen with keypad, `#fp-curtain` hidden, `#fp-boot` gone;
  - stalled: `{curtain: block, boot: flex}` and the orange padlock only, after 25 s;
  - released: `{curtain: none, boot: false}`, the app started.
- Prod, read-only:
  - user 80 has 1 refresh row; its `expires_at − 365 d` was 10-21 04:03, the push subscription `updatedAt` was the same minute. After he waited: 10-27 19:40:43 / 19:40:44.
  - nginx access logs are empty since 09-20 and the backend logs nothing per user, so these two columns are the only per-user "did the app start" signal.
- NOT verified: the cause on his phone.

## Notes for next session
- Next action: none decided. Owner-owed: whether to build either fix below for the next version.
- Cause unconfirmed, two candidates:
  - a slow cold re-download of the app shell after days away, hidden behind the padlock;
  - the phone's storage stalling and later answering.
  - The question that separates them was NOT asked (owner closed it): how long he waited, and whether he restarted the phone first.
- Fix options, not built:
  - (1) time limits on the two unbounded waits that keep the padlock up: `main.dart:81` (time out → "no notification tap") and the wrapping check at `passcode_provider.dart:307` / `content_key_wrap.dart:192` (time out → LOCKED, never unlocked);
  - (2) show the loader's progress under the padlock, and after a long stall a line like "close and reopen the app" instead of the update hint (`fp_boot.js:39-41`), never mentioning clearing data. (2) only changes what a stuck user sees; only (1) gets a stalled start through.
- Repro recipe: serve the bundle on a fresh port, set `flutter.passcode_enabled=true`. In a second tab on the same origin, open `fireplace-push` v1 and keep the connection, then `indexedDB.open('fireplace-push', 2)` (it blocks). Reload the first tab. Close the held connection to release.
- Traps: both in traps.md (Auth; Deploy).
