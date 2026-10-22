# Phase 4 step 4 client built and driven: pre-box friends move to the box by handle lookup (114), account delete says goodbye (113), the resume probe counts `serverTime`, the first-snapshot wait settles (121); the drive found and fixed a carried-lookup budget bug (E114l)

**Date:** 2026-10-22 · **Version:** unchanged (0.2.69, no bump, no release) · **Tiers deployed:** none

## What was done
- 114/120 (E114a-f): `EncryptionProvider.listsByHandle`/`listIsByHandle`: a friend's list never goes by id, `friendsList` `devices` is no longer read. `BoxFriendHandoff` takes addresses from the handle lookup (`takeServedAddresses`, RAM), looks up once per friend per process and once per 24 h while unrouted, and writes durable `BOX_ROUTES {friends, routed, owed}`.
- 113 (E114h-i): `AuthProvider.deleteAccount` = verify password, `MessagingProvider.goodbyeToBoxFriends` (10 s budget, durable `BOX_ACCOUNT_GOODBYE {told, missed, ms}`), DELETE, logout.
- Resume probe (E114g): `ConnectionProvider._resyncAfterResume` also emits `getServerTime`; `serverTime` moves the response counter. 121 (E114k): the 8 s first-snapshot wait is released by its own flag, no list handler runs.
- E114l (found on the drive): `EncryptionProvider.adoptCarriedDeviceList` gives back the friend's first-sight lookup budget before its one carried refresh; a friend that enrolled or linked a device after our first lookup was unreachable on the new device.
- Code `9511fd91` (design `a3be00f2`), fix `E114l` commit on top. Design and decisions: plan doc §"Step 4 design", decisions 120-122, E114a-l.

## Key files
- Edited: `providers/{encryption,connection,conversations,messaging,auth}_provider.dart`, `messaging/messaging_provider.{box,first_contact}.dart`, `screens/settings_screen.dart`, `services/box/{box_first_contact,box_friend_handoff,box_session}.dart`, `test_e2e/box_roundtrip_test.dart` (real `searchUsers` lookup), wire/e2e docs, plan doc, decisions log, root `CLAUDE.md` count.
- New: `test/providers/auth_provider_delete_account_test.dart`; E114l test in `encryption_provider_carried_device_list_test.dart`.

## Verification
- CI `9511fd91`: all 6 jobs success (Analyze (actions), Web Lock probe, wire harness, isolated probes with the new `_lookup`, Flutter analyze and tests, Backend). CI on the E114l commit: see the line added after the push.
- E114l tree: Flutter full suite `+3237 ~14: All tests passed!` (root `CLAUDE.md` bumped 3236 to 3237, `verify-claude-frontend-test-counts.mjs` OK); `flutter analyze --no-fatal-infos` 0 warnings/errors; Dart ratchet (`scripts/dart-lint-ratchet.mjs`) PASS at the 3146 baseline. Backend untouched, not run. Mutant: the E114l test is RED with the fix off (`Expected: <2> Actual: <1>`), green with it.
- Dev drives, real Chrome windows, one origin per device, release web; interception init script in the page: drops by-id `getDeviceList(s)`, strips `friendsList` `devices`, silences or delays `conversationsList`/`friendsList`. Bundle `9511fd91` for (i) and the first (ii); the fixed bundle (md5 `d7849101`) for the re-drive of (ii) and (iii)-(v).
- (i) Pre-box pair s4pa (265) / s4pb (266): `friend_requests` 97 accepted + `conversations` 80 inserted by psql after both devices were on the box. Decrypted contact rows: `state friend`, `legacy.conversationId 80`, NO `box` key, one queue. `__fp.byId` stayed `[]`, one `searchUsers` of the friend's handle each; durable `BOX_ROUTES {1,0,1}` then `{1,1,0}`; RAM `DEVICE_LIST_BOX_LOOKUP {userId: 266}`, `BOX_FRIEND_HANDOFF_SENT {device: 1, viaRequest: true}`, `BOX_FRIEND_HANDOFF {acked, handedBack}` on both. Messages both ways in the UI; 0 `sendMessage` emits, 0 `messages` rows for chat 80.
- (ii) B enabled linking (recovery phrase, "Włącz łączenie") and linked B2, then B3 (device 4). First run (`9511fd91`): A logged `BOX_LIST_CARRIED refetched` with no second lookup, then `BOX_FRIEND_HANDOFF_REFUSED {device: 2, why: not_live}`: RED. Fixed run: A `DEVICE_LIST_BOX_LOOKUP`, list v3 `[1, 2, 4]`, `BOX_FRIEND_HANDOFF {device: 4, handedBack: true}`; B3 `BOX_ROUTES` 0 to 1; A's message shown on B3, B3's reply shown on A. B2 (its only handoff was refused before the fix, resent after 24 h) was not re-proved.
- (iii) s4oa on old 0.2.69 (`p112`), `conversationsList` silenced, window minimized 4 s then restored: sockets 2 to 3 (forced reconnect after the 6 s probe). s4na on the new build, same: 2 to 2, `getServerTime` 2, `serverTime` 2 delivered.
- (iv) s4na (no chats, both lists silenced): skeleton at 6.4 s, "Brak czatów" at 14.2 s, badge flush `clearAppBadge` at 11.3 s. s4pa (held contact + chat 80, `?notify_conv=80`, lists delayed 16 s): chat list from the store at 5 s, chat 80 opened at 13.6 s with no list delivered; contact rows `identical` key by key across a 16 s full silence; the late lists then applied (friends 266 became 266, 268).
- (v) s4pb deleted its account from the dialog: durable `BOX_ACCOUNT_GOODBYE {told: 1, missed: 0, ms: 542}` 13:53:05; s4pa `BOX_FRIENDSHIP_ENDED {peer: 266}` 13:53:05, contact row and chat gone; DB rows of 266 all 0.
- NOT verified: Android and iOS, prod, a real server silence (simulated in the page), B2's heal, the server half.

## Notes for next session
- Next action (owner's go): version bump 0.2.70 (`pubspec.yaml`), CI green on the release commit, backup, `.\deploy-web.ps1` (no backend change), APK per `docs/runbooks/android-release.md`; then the reach check (plan doc §"Pairs with no route"), then the step 4 server half (§"What remains for step 4's server half"). No owner question is open (O37, O38 answered).
- E114l is an engineering call: at most two handle lookups per friend per process.
- Drive kit (outside the repo, `%TEMP%/p4s4drive`): `intercept.js`, `h.mjs`, `h2.mjs`, `serve-multi.mjs`, `evidence/`; recipes are the new traps. Dev DB keeps accounts s4pa 265, s4oa 267, s4na 268 (s4pb deleted), password `Test123123`.
- Traps (also in `docs/agents/traps.md`): backslash root for the static server; eval cell deadline resets the kernel; a pre-box pair is proved by the decrypted contact row; a friend enrolling after our lookup; diff contact rows key by key.
