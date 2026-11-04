# #208: a re-linked device starts fresh and no longer breaks the primary's sends

**Date:** 2026-11-03 → 11-04 · **Version:** unchanged (0.2.73 on prod; fix unreleased) · **Tiers deployed:** none

## What was done
- Round 1 (`63764ec8`): a link adopt wipes the `e2e_<uid>_` namespace; a previous device life (stamp != stored session id) shows the gate from the first frame and E2E init refuses before any publish; a gated install never publishes the contact backup; the friend handoff uses the request queue; copy says a re-link starts fresh.
- Review 1 (`c59e1a96`, `cad490a8`): proven wipe (stamp last, `localIdCounterKey` kept), `beforeWipe` after the blob parses, old queues deleted before the wipe, handoff keyed on `friendAnswered`, one-shot `openProvisioning` re-send.
- Review 2 + gaps (`80b98d53`): `openProvisioning` re-sent when owed (`ProvisioningEventSink.onSessionLost`); a lock-refused restore keeps history; a reset disposal whose teardown throws defers (`RESET_STALE_DISPOSAL_DEFERRED`); hard per-delete deadline; new install holds the honeycomb until its verdict (`awaitingIdentityVerdict`, 20 s); the gate deletes old queues at once (`_retirePreviousLifeQueues`, stamp re-read before the box is taken — found driving); server drops box notifiers on a revoked device's push tokens (decision 125) and the client re-registers its token when the device id moves; unconfirmed deletes stay owed in `boxgone_v1`.
- Review 3 (this commit; owner: "fix it", ruling "Keep history"):
  - A live secondary that signed out and back in keeps its history on a phrase restore: fresh start only when the served list names the stamped id revoked (`EncryptionProvider.stampedDeviceRevoked`; no answer fails the restore, `device_list`); `restoreStartsFresh` → `restoreMayStartFresh`.
  - The gate retire waits for the account socket (`socketReady` trigger) and the same revoked check; a live secondary's queues stay for its restore or link.
  - Web-push notifiers matched on the exact JSON endpoint, in `box/box-notifier-teardown.ts` (`deleteNotifiersOnPushTokens`, `CASE` guards the cast), int-tested on Postgres.
  - Standards: `[rows, rowCount]` mock, push re-register test (`ConnectionProvider(pushService:)` seam), stale test title, `shellMayShow`, comment moved, traps split.
- OTP fix (owner: "fix it now"): the restore's `restored` ack clears `_deviceMaterialMismatch` (`_restoreObserveUploadAck`) before the flush releases the stashed one-time pre-keys; before, a mismatch-flagged install dropped them (`OTP_UPLOAD_DROPPED {reason: device_material_mismatch}`) because the rebind reconnect keeps the flag.

## Key files
- Frontend: `providers/{connection,encryption}_provider.dart`, `services/encryption_service.dart`, `services/box/{box_session,box_friend_handoff}.dart`, `services/contacts/{contact_store,contact_store_owed_deletes}.dart`, `services/push_service.dart`, `main.dart`.
- Backend: `chat-device-revocation.service.ts` (+ spec), `box/box-notifier-teardown.ts` (+ `box.int-spec.ts`), `fcm-tokens.service.ts`, `web-push-subscriptions.service.ts`.
- Docs: `e2e-invariants.md`, `multi-device.md` (xc), `wire.md`, `metadata-privacy-decisions.md` (125), `traps.md`, `CLAUDE.md` counts.

## Verification
- CI 6/6 on `63764ec8`, `c59e1a96`, `80b98d53`, `a56e382d` (review 3), `54f3d1f8` (restore tests) `3ea4e176` (OTP fix) and `ef0aea65` (exact-once tests): backend, Flutter, E2E wire, isolated probes, Web Lock probe, CodeQL. #208 comments: review 3, follow-up, OTP fix, correction.
- Review 3 gates: Flutter 3338 passed / 14 skipped, backend 1264 / 71, analyzer 0, Dart lint 3130, backend ratchet PASS, int test on dev Postgres. Mutants killed and reverted: retire without the revoked check; `stampedDeviceRevoked` ignoring `revokedAt`; no `registerAgain`; substring endpoint match. A dropped `CASE` survived (PG short-circuits here): kept as a guard, not claimed.
- Follow-up (advisory: the fresh half of the restore was not driven): 3 `restoreFromPhrase` tests on a previous device life (list says revoked → fresh; live → kept; no answer → `device_list`, nothing adopted); mutants killed and reverted: `freshDeviceLife: restoreMayStartFresh`; unknown list treated as keep. Flutter 3341 passed / 14 skipped, Dart lint 3130.
- Drive 3 (web, `r208a`; detail in `.planning/208-relink/findings.md`): only the exact-endpoint web-push notifier went; a revoked tab's gate deleted 2 `box_queues` rows (SQL); a live secondary's gate deleted none and its restore kept all 12 rows (rebound to 26); the unlinked tab's restore retired its queues, then started fresh (rebound to 28, `x3_t_restore_ram.txt`).
- OTP drop, FIXED. Before the fix the restore-ack batch was dropped on both shapes, but only the kept-history shape ended with an empty pool. Backend log: the 11→26 keep restore (18:21 UTC) uploaded none; the 26→28 fresh restore (21:08) still got one batch from the reconnect init's re-upload.
  - Tests: "a mismatch-flagged fresh / kept restore uploads its OTPs once, after the rebind" (real stale material minted as device 2, session 7; exactly one `uploadOneTimePreKeys`, after `RECONNECTED`). Red before the fix; with the clear removed both fail; mutant reverted. Flutter 3343 passed / 14 skipped, analyzer 0.
  - Drive 4, fresh shape (web build with the fix): keyless tab U restored → device 30; tab T (material 28) password login → `E2E_DEVICE_MISMATCH {30, 28}` → restore → rebound to 32, no `OTP_UPLOAD_DROPPED`.
  - Drive 5, keep shape: U linked from T (SAS 499 282) as live secondary 33; password login → `E2E_DEVICE_MISMATCH {32, 33}` → restore → no `E2E_FRESH_DEVICE_LIFE`, 12/12 `e2e_283_*` rows kept, rebound to 36; 20 `one_time_pre_keys` rows for 36 at the rebind second (`x5_u_keep_otp_ram.txt`).
  - Both drives, backend: `from→to`, `Uploaded 20` (restore-ack flush, new id), bundle upsert, `Uploaded 20` (reconnect init `E2E_KEYS_UPLOADED`), all on the new id; the keyless restore shows the same pair.
  - Two RAM `OTP_UPLOAD_AFTER_ACK` lines = two real flushes, not a duplicate print. Both carry the one adopt's `_keysForUpload` [INFERENCE from code: no `IDENTITY_MINTED` between], and the server upserts by `keyId`, so the second rewrites the same keys. This predates the fix; left as is.

## Notes for next session
- Next action: the owner's 0.2.74 OK (backend decision 125 + web + APK), then `production-vm-deploy`.
- NOT verified on a device: lock-only restore (needs `identityUploadLocked`); a reset whose teardown throws (fault injection); `onSessionLost` with an open in flight at a socket drop; a real FCM wake (no service account); iOS PWA, prod, release APK.
- Seen, not changed: the contact-backup prompt opens on top of the link gate on web.
- Owner-owed: the 0.2.74 OK; 0.2.73 on his phone; the step-4 both-ways test; copying `backup.pass` off the VM.
- Still open: #206, #204, Phase 4 step 5. #208 stays open until it ships.
- Residuals: a new device sends `own_uncovered` until every live sibling swapped with it (a ghost sibling blocks it: revoke it); a logged-out, unrevoked device is a silent sibling.
- Recipes: re-link drives need PASSWORD logins; one `input keyevent` per field; the hacker-mode log is an inner list; the link flow is throttled (`openProvisioning` 10 / 15 min per account).
- Traps (in `traps.md`): new device cannot send until every sibling swapped; adb typing a long code ANRs; per-char adb typing scrambles; re-link drive needs password logins; friend made while the contact backup is LOCKED; `Pixel_7` snapshot holds a release app; CDP `setBlockedURLs` misses WebSockets; web linking needs installed mode.
