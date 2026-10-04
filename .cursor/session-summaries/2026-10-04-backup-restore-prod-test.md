# Contact backup restore on prod: the friends list comes back, but nothing sent TO the restored device arrives

**Date:** 2026-10-04 · **Version:** unchanged (0.2.58 web/backend, APK 0.2.53) · **Tiers deployed:** none

## What was done
- Owner asked for one real restore test on prod, Android and web. Two fresh prod accounts: `rbweb1808#5065` (id 131, managed Chromium, web 0.2.58) and `rbandr1808#8365` (id 130, Pixel_7 emulator, prod APK 0.2.53 from `/apk/`). Neither enrolled a recovery phrase ("Później").
- They became friends over the box (decision 52): prod held 0 `friend_requests`, 0 `conversations`, 0 `messages` rows for 130/131, so after a wipe only the contact backup can bring the friend back. `contact_backups` rev 2 for both at 03:23Z. One message each way delivered before the wipe.
- **Web wipe** (fresh Chrome profile, password login): diag `CONTACT_BACKUP_RESTORED {count: 1}` at 05:28:57 local, before `IDENTITY_MINTED {reason: server-bundle-unlocked-remint}`; `rbandr1808` back in Czaty. History gone (expected: history is device-local). Restore did not move the row's `rev` (no-op guard holds).
- **Android wipe** (`adb shell pm clear`, password login): `rbweb1808` back in Czaty.
- **Messaging after the restore:** the restored device SENDS fine (A→B delivered after A's wipe). Messages TO the restored device never arrive: B's 3 replies after A's wipe, and A's message after B's wipe, all sit unacked in the restored side's PRE-WIPE inbound queue (`box_msgs` rids `34e695…`, `18d88f…`), across an A reload and a B force-stop/relaunch. The sender sees a normal "sent" tick. Those blobs expire 30 d later.
- Out-of-repo: the emulator's debug `com.fireplace.app` (local-stack 0.2.55 build) was uninstalled and the prod APK 0.2.53 installed; the emulator was left running. Throwaway prod accounts 130/131 kept (credentials only in `%TEMP%\umbra-restore\creds.json`), with 6 stuck box messages. A fresh Chrome profile in `%TEMP%\umbra-restore\chrome-fresh`.

## Key files
- Edited: `.cursor/session-summaries/LATEST.md`, `docs/agents/traps.md`.
- New: this summary.
- Read only (load-bearing): `frontend/lib/services/contacts/contact_record.dart:625-646` (`toBackupJson` drops `queues`: "a restored device re-mints them anyway"), `contact_backup.dart` (`ContactBackupPayload`), `fireplace-mp/.planning/metadata-privacy/task_plan.md:152-155` (design: re-mint and hand off over `outbound[]`).

## Verification
- CI: no code changed; last code CI 6/6 on `58de6091`.
- Prod SQL (read-only) before and after each step: users 130/131, 0 old-path rows, `contact_backups` rev/updatedAt, `box_msgs` per rid and `box_queues` (the stuck queue: `normal`, created 10-04, no notifier).
- Live drives: web via managed Chromium + a fresh Chrome profile (pixel clicks, `keyboard.type`), Android via `adb` + `uiautomator dump` (`FLAG_SECURE` blanks `screencap`). NOT verified: an iPhone PWA restore; a restore with a recovery phrase; old-path (server-table) friends after a restore.
- Side observation, NOT an app finding: after CDP `Storage.clearDataForOrigin` the managed Chromium never painted the app again (`#fp-boot` stays, no canvas, localStorage stays empty), also in a new tab; a fresh Chrome profile booted normally. Cause unknown; not reproduced in real Chrome.

## Notes for next session
- Next action: find why the restored device's queues are not re-minted and handed to the peer. Scout lead `[INFERENCE]`, unconfirmed: `BoxFriendHandoff._pass` (`frontend/lib/services/box/box_friend_handoff.dart` ~L324-380) and `QueueKeys.ensureInbound` (`queue_keys.dart` ~L52-97) do not hand a fresh queue to a peer for a contact restored without `queues`. Repro: the two accounts above (or a local pair), wipe one side, send from the other, watch `box_msgs` by rid.
- This blocks Phase 4 and makes decision 85's forced backup half-useful until fixed: after any storage loss (iPhone PWA eviction, reinstall, new phone) a box friend's messages silently vanish. It applies on prod today to every box pair. The 56-message queue from the day-3 watch may be exactly this `[INFERENCE]`.
- Owner-owed: see the questions asked this session (Phase 4 rule 86 vs 77's backstop, the forced sheet's exit, release order for this fix, VAPID rotation, the 10-02 reports).
- Traps: restore re-mints no queue for the peer (traps.md, E2E group).
