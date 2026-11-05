# 0.2.74 broke every web user with a passcode; web rolled back to 0.2.73; hotfix 0.2.75

**Date:** 2026-11-05 · **Version:** 0.2.75 (hotfix, branch `fix/passcode-sig-open`) · **Tiers deployed:** web ROLLED BACK to 0.2.73 (`352278a1`); backend and APK stay 0.2.74

## What happened
- Report (owner, ~03:00Z): SaraLee's contact bob208 vanished from her chat list, a red "your keys changed" prompt, bob's messages notified but never appeared, her sends stayed "Ponów", invites failed.
- Cause, from her E2E Diagnostic Log + code, then reproduced: #208 (0.2.74) added `AuthGate` → `checkPreviousDeviceLife` → `EncryptionService.materialDeviceStamp` → `_storage.read` at FIRST FRAME, before the passcode screen. On web that is `DualStorage._webKv`, which opens `SealedWebSignalKv`; with the passcode vault still locked the open throws `SigSealOpenUnavailable('locked')`, and `_webKv` memoized the failed Future for the session. After the unlock E2E init hit the same failure (`E2E_INIT_FAIL SigSealOpenUnavailable(locked)`): no send, no decrypt, no invite, friends gone from the list.
- Scope: every web/PWA user with a passcode (wrapping is web-only), every boot. Android unaffected. Only 3 accounts were active after the 02:01Z deploy (bob208, alteregobob8: no passcode; SaraLee: passcode).
- Sara's data is intact: after her unlock `WEB_SEAL_OPEN {sealed: 9, unreadable: 0}` succeeded, so her KEK is right. bob's 3 messages (02:50, 02:50, 03:00Z) sit in her queue `3b446aef…` until 11-30.

## What was done
- Web rollback (owner: "Roll web back to 0.2.73 now, then hotfix"): built `352278a1` with `deploy-web.ps1` from a throwaway worktree, published; the live 0.2.74 bundle kept at `~/frontend-build.0274` on the VM. `post-deploy-smoke.mjs --commit 352278a1` 8/8.
- Fix (`frontend/lib/services/encryption/signal_stores.dart`): a `locked` open is no longer memoized (`_webOpen = null` before the rethrow), so the first op after the unlock re-opens under the same rules — the re-open `revokeWebSession` already sanctions; still locked it throws `locked` again, never the plaintext fallback.
- Test: `sealed_web_signal_kv_test.dart` "a store opened while the vault is locked opens after the unlock" — red before the fix (the post-unlock write rethrew `locked`), green after.
- Docs: `docs/design/web-sig-sealing.md` diag table (`SIG_KEY_UNAVAILABLE` `locked` exception), `traps.md` (Auth), `CLAUDE.md` Flutter count 3344.

## Key files
- `frontend/lib/services/encryption/signal_stores.dart` (`DualStorage._webKv`, `_openWeb`)
- `frontend/test/services/encryption/sealed_web_signal_kv_test.dart` (new test in "passcode-wrapped keys (Phase 2)")
- Trigger (unchanged): `frontend/lib/main.dart` `AuthGate` → `EncryptionProvider.checkPreviousDeviceLife` → `EncryptionService.materialDeviceStamp`

## Verification
- Browser drive, dev stack `hotfix` (backend 3200, db 5435), accounts `pca664` (1) ↔ `pcb664` (2):
  - Unfixed 0.2.74 build (`f3bdc1c9`): baseline send OK; passcode on (`PASSCODE_WRAP_ENABLED {keys: 2}`); reload + unlock → `SIG_KEY_UNAVAILABLE {locked}`, `CONTENT_STORE_LOCKED`, `CONTACT_STORE_UNAVAILABLE {locked}` (Sara's exact signature), empty chat list.
  - Fixed build, same origin and storage: reload + unlock → `E2E_RESTORE_UNLOCK` → `SIG_SEAL_OPEN {sealed: 26}` → `E2E_INIT_DONE` → `BOX_ROUTES {friends: 1, routed: 1}`; A→B "fixed send" delivered (B shows it), B→A "reply from B" decrypted on A.
  - 0.2.73 dev build (`352278a1`), A with 2 friends (C `pcc1747` added): reload + unlock → no `SIG_KEY_UNAVAILABLE`, `BOX_ROUTES {friends: 2, routed: 2}`, C→A "C to A on 0.2.73" decrypted on A — the rollback restores passcode users.
- Suites: `flutter test` 3344 passed / 14 skipped; `flutter analyze` 0 errors or warnings (3130 infos = baseline). CI: on the pushed branch.

## Notes for next session
- Next action: owner OK → ship 0.2.75 web (backend unchanged, APK optional: Android is unaffected); then tell passcode users to reload. Phase 4 step 5 moves to 0.2.76.
- Seen, not fixed: after a boot that started locked, the CHAT list stays empty until a message arrives, while Kontakty shows the friend. Sara's 10-31 durable entries (0.2.72: `CONTACT_STORE_UNAVAILABLE {locked}`, `BOX_ROUTES {friends: 1}`) suggest a pre-existing, separate issue with the contact/conversation lists after a locked boot.
- Driving a passcode-enabled tab: per-key typing dies (focus churn vs the privacy curtain); use one CDP `Input.insertText`.
