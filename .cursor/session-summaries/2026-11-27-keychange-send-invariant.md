# 0.2.112 released: a friend's new key is one calm line, one tap, and a send gate tied to the pinned key

**Date:** 2026-11-27 to 2026-11-28 · **Version:** 0.2.111 → 0.2.112 · **Tiers deployed:** both (backend, web) + signed APK

## What was done
- PR #318 squash-merged as `04ee2b1c` (decisions 152/153/154 in `docs/plans/metadata-privacy-decisions.md`). With key warnings off, a friend's new key shows `CalmHoldLine` (`frontend/lib/widgets/calm_hold_line.dart`); messages written meanwhile are kept as waiting rows and go out, in order, after the tap. With warnings on the red bar is unchanged.
- Send gate `FriendGate` (`frontend/lib/services/box/box_friend_gate.dart`): a friend frame is sealed only for an address tagged (`ContactOutbound.idk`) with the friend's CURRENT pinned identity; a missing tag reads as stale; the ungated lane is a positive list. Waiting rows are persisted and released by the state-kicked pump (`messaging_provider.box_pump.dart`).
- The probe queue was deleted before release; a friend that kept its queue is healed by re-announce (`box_friend_handoff.dart`, `_takeHandoff` compares `idk`). An ack counts only under the pinned identity (`BoxSession.friendAcked`).
- Review 5 P2-A fixed (`3805e6cf`): `ContactQueue.withoutHandoffState(quiet: true)` clears and records in `qs` only ACKED devices; handed-never-acked devices keep `handedAt`. P3-A (ack just before the TTL) left open on purpose: a re-stamp would cost a store write per pass.
- Experiment "step 0" (web, local stack): an enrolled account with its phrase keeps the same key over one and two reinstalls, no bar; a phrase saved at registration alone does NOT enrol. Rows G1-G8 in `.planning/cleanup/batches.md`; owner decisions in `.planning/keychange/plan-2026-11-28-rethink.md`.
- Release: backup `20261128T054629Z` (offsite 3/3), backend, tag `v0.2.112`, web, CI-built APK signed on the PC (signed `405c6b1c639b6e41a7c3aed3d277b2060022ba30e5d4c87a670c9b4e049242ff`, unsigned `2f957cfdc82ab626f307d928f4e4a30ecc0c80c3ef18c56ce18cda831dc0969a`), APK channel moved to 20112.
- Out of repo: VM `.env` three `ANDROID_APK_*` lines (copy `.env.bak.pre-apk-0.2.112`); local stack `fp14` removed with its volumes; worktrees `fp14-kc`, `fp14-e2e` and branch `feat/keychange-b` (local + remote) removed, copied keystore/`key.properties`/`.env` deleted with them; an EMPTY folder `Desktop/fp14-kc/frontend` is held by some process and remains. Xiaomi `f849cc68`: `com.fireplace.app` is the signed 0.2.112, logged out, stay-awake off, screen timeout 60 s.

## Key files
- Edited: `frontend/lib/services/encryption_service.dart`, `frontend/lib/services/box/box_session*.dart`, `box_friend_handoff.dart`, `box_inbox.dart`, `frontend/lib/services/contacts/contact_record.dart`, `contact_store.dart`, `frontend/lib/providers/messaging/messaging_provider.box*.dart`, `messaging_provider.send.dart`, `encryption_provider.dart`, `connection_provider.dart`, `frontend/lib/screens/chat_detail_screen.dart`, l10n arb files, `docs/agents/traps.md`, `frontend/docs/e2e-invariants.md`, `CLAUDE.md` (Flutter count 4262).
- New: `box_friend_gate.dart`, `messaging_provider.box_pump.dart`, `calm_hold_line.dart`, tests `messaging_provider_box_pump_test.dart`, `messaging_provider_box_calm_send_test.dart`, `contact_queue_taken_by_test.dart`.
- Read only (load-bearing): `docs/design/multi-device.md` (lxxiii, lxxiv, lxxviii), `docs/runbooks/android-release.md`.

## Verification
- CI: 13 rows success on `04ee2b1c` (master); 15 with `Build unsigned release APK` + `Publish the GitHub release` after the tag. The handoff commit is docs-only.
- Local on the branch head `b800fed3`: `flutter test` `+4249 ~14: All tests passed!`; analyze 0 errors/warnings; Dart ratchet PASS 2463; context budget OK.
- Reviews: `.planning/keychange/review-final-4.md`, `review-final-5.md` (re-review after `3805e6cf`: RELEASE OK).
- Deploy: `/version` = `0.2.112 / 04ee2b1c` with android 20112; `post-deploy-smoke.mjs` SMOKE PASSED (8 checks) after the APK flip; `deploy-web.ps1` PUBLISHED_OK + SMOKE PASSED; `sha256sum -c` OK on the VM; `sign-ci-apk.ps1`: signer pinned, v2 only, 16 KB alignment OK, signed = CI file + signature.
- Local drives (Xiaomi, build `b800fed3`, rows H1-H12): upgrade in place from 0.2.111 debug, calm line, waiting rows, restart, delete a waiting row, reconnect, tap, friend writes first, red bar, refused tap, release-signed build.
- Live drive on prod (rows L1-L6, throwaways `zzt112p`/`zzt112w`, both deleted, users 31): live 0.2.111 APK ↔ new web; signed 0.2.112 installed over it with history kept; a message each way; web friend reinstalls → calm line → waiting message → tap → delivered; reply arrives.
- NOT verified: zero-outgoing-frames while waiting on the PHONE (recorded on web only, on an earlier commit); a waiting photo; notifications; two phones; a linked second device; iOS; red bar and refusal paths on prod.

## Notes for next session
- Next action: build "honest delivery ticks" (part C, closes G8). Design: `.planning/keychange/design-honest-ticks.md` (gitignored; gist in the next bullet). First get the owner's one-line confirmation of the answers, then verify the design's two "TO VERIFY" points, build on a branch + worktree, add the decision rows to `docs/plans/metadata-privacy-decisions.md` in the same change, replay G8 on a device, release as 0.2.113.
- Owner answers to the part C `ask` form, 2026-11-28. All three equal the preselected option, which the form also submits on a timeout: UNCONFIRMED until the owner says so.
  - Arrival confirmation (`rcpt d`) ALWAYS on for everyone, no switch; read receipts and typing stay behind `receiptsAndTyping`, default off (amends D5 / 62 for the delivered half). Proposed with it: a random delay before the confirmation.
  - Ticks: one grey = sent, two grey = arrived, two coloured = read (amends 63).
  - Own rows still at `sent` are re-sent AUTOMATICALLY (same wire id, within 30 days) when a new address of the friend is taken under his pinned identity; no lookup. To verify first: the receiver drops a held (sender, wire id) arriving over a new session and still confirms it.
- After part C: the design of part A: the identity lock on by default on Android and installed web, plain tabs stay opt-in; needs an amendment in `docs/design/multi-device.md` reversing (lxxiii) clause 1 where storage is stable.
- Open for part A: can the sign-up phrase be reused when the lock is armed later (G3 issued a new phrase); the 30 existing accounts; the 6 h reset path was never driven; repeat the reinstall drives on Android.
- Known limits shipped: two un-enrolled friends who both reinstall can stay stuck (F5); a waiting VOICE message is RAM-only and lost on restart; a message written to a friend who has not restored yet shows sent and is lost (G8, also on 0.2.111).
- Not fixed: G6 (rate-limited handoff shows a false "older app" note, failed rows need "Ponów"); hacker-mode diag "Copy" wrote nothing to the clipboard on web (cause not looked at); web composer with semantics on.
- Audit close-out still owed: record BOX-02 and A3-SVC-C-1; stale cells `findings.md:367,369`; P1 count (ledger `.planning/cleanup/audit-ledger-2026-11-28.md`: 1 P0 + 29 P1 = 26 fixed, 2 accepted, 1 parked); `metrics.md` section after 0.2.103; 9 P2 test gaps (MF-04, MF-05, MB-1, MB-2, MC-04, MC-05, MC-08, MC-13, MC-W6); Release B on or after 2026-12-08; owner sign-off.
- Carried: "connect again", forged red bar exposure, `_clearBoxQuotes`, `stageAccountIdentity` race, R12Screens N7, R12Messages N4, R11Svc S3/N1, UI-13, UI-17, invite card taps, raw `unknown_stage`, privacy-policy drafts, licence lawyer, key-warning toggle subtitle.
- Recipes: phone helpers `.planning/cleanup/drive/` (`adbui.py`, `psend.sh`, `PHONE.md`); MIUI install prompt: poll `mCurrentFocus` for `AdbInstallActivity`, then `input tap 311 2185`; web "reinstall" = CDP `Storage.clearDataForOrigin` + reload + login.
- Traps: six lines in `docs/agents/traps.md` name this file.
