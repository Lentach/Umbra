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

## Key files
- Frontend: `providers/{connection,encryption}_provider.dart`, `services/encryption_service.dart`, `services/box/{box_session,box_friend_handoff}.dart`, `services/contacts/{contact_store,contact_store_owed_deletes}.dart`, `services/push_service.dart`, `main.dart`.
- Backend: `chat-device-revocation.service.ts` (+ spec), `box/box-notifier-teardown.ts` (+ `box.int-spec.ts`), `fcm-tokens.service.ts`, `web-push-subscriptions.service.ts`.
- Docs: `e2e-invariants.md`, `multi-device.md` (xc), `wire.md`, `metadata-privacy-decisions.md` (125), `traps.md`, `CLAUDE.md` counts.

## Verification
- CI 6/6 on `63764ec8`, `c59e1a96`, `80b98d53`, and on `a56e382d` (review 3: backend, Flutter, E2E wire, isolated probes, Web Lock probe, CodeQL). #208 comment 6641992393.
- Review 3 gates: Flutter 3338 passed / 14 skipped, backend 1264 / 71, analyzer 0, Dart lint 3130, backend ratchet PASS, int test on dev Postgres. Mutants killed and reverted: retire without the revoked check; `stampedDeviceRevoked` ignoring `revokedAt`; no `registerAgain`; substring endpoint match. A dropped `CASE` survived (PG short-circuits here): kept as a guard, not claimed.
- Follow-up (advisory: the fresh half of the restore was not driven): 3 `restoreFromPhrase` tests on a previous device life (list says revoked → fresh; live → kept; no answer → `device_list`, nothing adopted); mutants killed and reverted: `freshDeviceLife: restoreMayStartFresh`; unknown list treated as keep. Flutter 3341 passed / 14 skipped, Dart lint 3130.
- Drive 3 (web build of this tree, dev account `r208a`):
  - planted `web_push_subscription` for device 13 + webpush notifiers on its endpoint and on `…web13x`, plus an FCM control; revoked 13 from the primary → only the exact-endpoint row went;
  - device 18 revoked while its tab was closed → password login → stale gate → 2 rows gone from `box_queues` (rid diff), none added: the acceptance check, by SQL;
  - live secondary 23 signed out (Wyloguj) and back in: stale gate, 0 rows gone from `box_queues`; phrase restore (fresh phrase from the primary; the drive-2 phrase predates the reset and failed `identity_locked`) → `RESTORE_STALE_MATERIAL_DISPOSED`, no `E2E_FRESH_DEVICE_LIFE`, all 12 `flutter.e2e_283_*` rows kept, 0 queues gone, rebound to 26, gate released.
  - unlinked device 18's tab, password login → stale gate → phrase restore: RAM log `E2E_PREVIOUS_DEVICE_LIFE` → `DEVICE_LIST_FETCH_EMIT` → `BOX_PREVIOUS_LIFE_RETIRE` → `BOX_REVOKED_QUEUES_RETIRED {held: 2, owed: 0}`, then `DEVICE_LIST_FETCH_EMIT` → `RESTORE_STALE_MATERIAL_DISPOSED` → `E2E_FRESH_DEVICE_LIFE` → rebound to 28, gate released (`x3_t_restore_ram.txt`). `held: 2` on a second gate visit [INFERENCE: the 2 already deleted on the first, still in the store until the wipe; a harmless repeat].
- Found, NOT fixed: a restore on a mismatch-flagged install drops its one-time pre-keys (`OTP_UPLOAD_DROPPED {reason: device_material_mismatch}`: `_deviceMaterialMismatch` outlives the rebind), on BOTH restore shapes (seen on device 26, keep; and 28, fresh); device 26 had 0 OTPs, still 0 after a reload. Owner to decide: fix before 0.2.74 or after.

## Notes for next session
- Next action: owner rulings — the restore OTP drop before or after 0.2.74; then the 0.2.74 OK (backend decision 125 + web + APK) and `production-vm-deploy`.
- NOT verified on a device: lock-only restore (needs `identityUploadLocked`); a reset whose teardown throws (fault injection); `onSessionLost` with an open in flight at a socket drop; a real FCM wake (no service account); iOS PWA, prod, release APK.
- Seen, not changed: the contact-backup prompt opens on top of the link gate on web.
- Owner-owed: the 0.2.74 OK; 0.2.73 on his phone; the step-4 both-ways test; copying `backup.pass` off the VM.
- Still open: #206, #204, Phase 4 step 5. #208 stays open until it ships.
- Residuals: a new device sends `own_uncovered` until every live sibling swapped with it (a ghost sibling blocks it: revoke it); a logged-out, unrevoked device is a silent sibling.
- Recipes: re-link drives need PASSWORD logins; one `input keyevent` per field; the hacker-mode log is an inner list; the link flow is throttled (`openProvisioning` 10 / 15 min per account).
- Traps (in `traps.md`): new device cannot send until every sibling swapped; adb typing a long code ANRs; per-char adb typing scrambles; re-link drive needs password logins; friend made while the contact backup is LOCKED; `Pixel_7` snapshot holds a release app; CDP `setBlockedURLs` misses WebSockets; web linking needs installed mode.
