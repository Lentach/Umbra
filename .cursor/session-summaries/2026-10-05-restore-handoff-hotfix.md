# A restored friend device receives again: its new queue's handoff is no longer refused (0.2.59, decision 88)

**Date:** 2026-10-05 · **Version:** 0.2.58 → 0.2.59 · **Tiers deployed:** both (web + backend redeploy for the APK channel) + APK 20059

## What was done
- Cause found (red local repro, same diag as prod): the restore DID re-mint a queue and hand it over the queue the backup's `outbound` names, but under the re-minted identity the frame is a PreKey nobody asked for, so the peer refused it `BOX_FRIEND_HANDOFF_REFUSED {why: prekey_unasked}` (`messaging_provider.box.dart` `_readBox`) and kept writing to the dead pre-wipe queue.
- `prekey_identity.dart`: new `preKeyFromNewIdentity(record, ct)`: some session state knew the device under another identity and no ARCHIVED state ever held this one. `EncryptionService.preKeyFromNewIdentitySession` / `EncryptionProvider.preKeyFromNewIdentity` read it under the per-address lock.
- `_readBox`: judged BEFORE the decrypt (it moves the session), only when the friend's held list is NOT enrolled; such a handoff is taken (`BOX_FRIEND_HANDOFF_NEW_IDENTITY`). Everything else keeps decision 37's refusal. Engineering call logged as E88a in master's `metadata-privacy-decisions.md`.
- Docs: `e2e-invariants.md` (hand-back bullet), `wire.md` Item 5, `traps.md` (restore trap rewritten as fixed), root `CLAUDE.md` count 3078, pubspec 0.2.59.
- Out-of-repo: local dev stack `fireplace` up (DB :5433, backend :3000) with throwaway users 249 `rsta1` / 250 `rstb1` (local-only password, not recorded here); python servers 8091–8094 on `%TEMP%\fp-drive\web` (stopped at the end); Pixel_7 emulator running a DEBUG-signed profile 0.2.59 APK (the prod 0.2.53 APK and its account-130 data were uninstalled).

## Key files
- Edited: `frontend/lib/services/encryption/prekey_identity.dart`, `frontend/lib/services/encryption_service.dart`, `frontend/lib/providers/encryption_provider.dart`, `frontend/lib/providers/messaging/messaging_provider.box.dart`, `frontend/test/providers/messaging_provider_box_friend_crossing_test.dart`, `frontend/pubspec.yaml`, `CLAUDE.md`, `frontend/docs/e2e-invariants.md`, `docs/contracts/wire.md`, `docs/plans/metadata-privacy-decisions.md`, `docs/agents/traps.md`.
- Read only (load-bearing): `box_friend_handoff.dart` (`targetOf` prefers held `outbound`), `box_session.dart` (`_takeHandoff`), `contact_record.dart:637` (`toBackupJson` drops `queues`), `device_list_cache.dart` (`VerifiedDeviceList.notEnrolled` = single device 1).

## Verification
- CI: `d8cc4706` cancelled (superseded by the comment fix `fd9ad95f`, same code); `fd9ad95f` GREEN 6/6 (backend, Flutter, Web Lock, wire harness, isolated probes, CodeQL).
- `flutter test`: 3078 passed, 14 skipped; count gate OK; Dart ratchet PASS (baseline 3153); `flutter analyze` on touched files: infos only.
- Crossing suite (real Signal both sides) +5 cases: restore taken; pair refused pre-fix heals on resend; unchanged-identity PreKey refused; old identity refused after the new one was taken; enrolled friend refused. Red before the fix (2 fail with `prekey_unasked`). Mutants killed: drop archived exclusion, drop `!newIdentity`, drop the enrolled check.
- Live drives (release web, local stack): (1) old bundle: A wiped (fresh origin) → B refused `prekey_unasked`, `b2` stuck in `box_msgs` — the prod bug. (2) Fixed bundle on B, A's clock +25 h → A's resend taken (`NEW_IDENTITY`), `b3` reached A: a pre-fix pair heals. (3) B wiped on fixed build → A took B's handoff at once, messages both ways. (4) Android Pixel_7, profile APK 0.2.59: `rstb1` restored by password login, web A took its handoff, `a4 to android` shown on the phone.
- NOT verified: iPhone PWA; prod; an enrolled account's phrase restore (rebinds the device id — separate path, may be broken the same way); a pair where BOTH sides were wiped (see Notes).

## Notes for next session
- DEPLOYED 2026-10-05: web `0.2.59/abb662ca` (smoke 8/8), backend `0.2.59/abb662ca` (code unchanged; redeployed so `/version` announces APK 20059), APK at `/apk/umbra-0.2.59.apk` (SHA256 `dcdce501dcce28d41aadffeb1db7d31af4bd32fcd739b8177f3a5304b4c372dd`, prod host + commit verified inside `libapp.so`). Backup `chatdb-20261004T234738Z.dump.gpg`; `.env.bak.pre-0259` on the VM. Next action: on a fresh prod pair, wipe ONE side and confirm delivery TO it. The FIX lives on the RECEIVING side: a peer heals only once IT runs 0.2.59.
- Then: decisions 91/92 (empty notifications, reactions never notify), merge 0.2.55 (carry E88a into the branch log; bump past 0.2.59), deploy; owner calls Phase 4.
- OPEN (owner): a box-only pair where BOTH sides lost storage cannot re-converge — each side's backup `outbound` names the other's dead queue, and no server list names a box friend's request queue. Prod 130/131 is that shape. Needs a design call (one `searchUsers` of the handle after a restore, naming the pair?).
- Healing pairs broken before 0.2.59: automatic, on the restored side's next connect ≥ 24 h after its last handoff, once the peer runs 0.2.59.
- Recipe: drive several devices with one managed Chrome on 127.0.0.1:8091–8094 (each origin = a device); read diag by long-pressing the shield on Privacy & Safety and clicking `Copy` via the DOM with `navigator.clipboard` shimmed; fake the 24-h resend with an init script shifting `Date`. Debug APKs are too slow for PBKDF2-600k (ANRs); use `flutter build apk --profile` (debug-signed, installs over debug, keeps data).
- Traps: see `traps.md` E2E line for this fix; uiautomator dumps need unique filenames (a stale `/sdcard/ui.xml` showed prod account data) — already trap L411.
