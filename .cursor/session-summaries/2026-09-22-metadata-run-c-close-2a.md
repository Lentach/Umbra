# Run C driven: keys match after a phrase restore, but every live peer was wedged until reload — fixed client-side, plus two gate surfaces reordered

**Date:** 2026-09-22 · **Version:** unchanged (prod web `0.2.50`/`d37e2dcc`, backend `0.2.51`/`9e621f63`) · **Tiers deployed:** none

## What was done
- Owner chose "close Phase 2a first". Run C / C′ driven on `Pixel_7` (tester1, linking ON) + a static web build in managed Chromium (tester2): four phrase restores (device 1 → 3 → 5 → 7 → 9), `key_bundles.identityPublicKey` byte-identical, `contact_backups` untouched at rev 19, no key-change pill, pre-restore rows behind the "Historia sprzed połączenia" divider — never a placeholder. Evidence: `.planning/metadata-privacy/findings.md` §2026-09-22.
- **g3** `messaging_provider.send.dart:_refreshRecipientDeviceListAfterDeadAddress`, `messaging_provider.decrypt.dart:_originDeviceIsLive`, `encryption_provider.dart:onSessionRebuildNeeded` — a peer's live client kept the restored account's verified list at the old version for as long as it stayed open (>5 min measured; `traps.md` said "~90 s"): every send failed `no key bundle … deviceId=1` as "Ponów", every inbound row from the new device was withheld, and a reload dropped the unsent row. Now one rate-limited verified refetch on a dead-address send failure, on a cache hit that lacks the origin device, and on `sessionRebuildNeeded` (`97728b81`).
- **g1** `passcode_gate.dart:_StorageLossLayer` yields while `needsDeviceLink || identityCheckUnavailable` — the file-only loss notice covered the device-link gate's phrase door on a Keystore-only loss (`53ec981f`).
- **g2** `device_link_gate_screen.dart` — `LinkRestoreSection` now renders above the reset block; it was last, below the fold, under "Rozpocznij reset" (`53ec981f`; spec (lxxviii) clause 3 amended).
- Owner decisions: **S2** web boot-markers half NOT built, residual accepted and recorded in `docs/METADATA.md`; **S1** `contactStoreUnavailableStage` stays deferred to before PR4.2; g3 shape client-only (no `deviceListChanged` fan-out to peers).
- `CLAUDE.md` 2295 → 2304 Flutter tests (3 from the previous session never recorded + 6 today); lint floor 3166 → 3165 (`4260a47f`).
- Housekeeping: pushed the previous session's unpushed `f0ab1911`; opened draft PR #184 so CI runs on the branch at all.

## Key files
- Edited: `frontend/lib/providers/messaging/messaging_provider.{send,decrypt}.dart`, `frontend/lib/providers/encryption_provider.dart`, `frontend/lib/widgets/passcode_gate.dart`, `frontend/lib/screens/device_link_gate_screen.dart`; tests `messaging_provider_{accept_revoked,fanout}_test.dart`, `encryption_provider_session_rebuild_test.dart`, `device_link_gate_screen_test.dart`; docs `docs/contracts/wire.md:48`, `frontend/docs/e2e-invariants.md`, `frontend/docs/passcode-lock.md`, `docs/design/multi-device.md` (lxxviii/lxxx), `docs/METADATA.md`, `CLAUDE.md`, `scripts/dart-lint-baseline.json`, `docs/agents/traps.md`.
- New: `frontend/test/widgets/storage_loss_layer_test.dart`; `C:/Users/Lentach/Desktop/_ios_drive/serve_web.py` (rig, outside the repo).
- Read only (load-bearing): `content_kv_opener_io.dart:114-128` (`db-recreate` is the ONLY loss latch), `main.dart:199` (`PasscodeGate` is the `MaterialApp.builder` wrapper), `encryption_service.dart:1344` (gate = `exists && linkingEnabled`), `chat-key-exchange.service.ts:1073`, `.planning/metadata-privacy/task_plan.md` Phase 2a.

## Verification
- Red-first, all six: g1 `findsNothing` failed at line 97 pre-fix; g2 `Expected: less than 312.0, Actual: 392.0` with the reorder parked; F2 `Expected: [2] Actual: []` (no refetch); F1 same on the fetch ledger; F3 `Expected: null, Actual: VerifiedDeviceList`. Greens: loss-layer + gate suite 18/18, gate screen 9/9, providers 24/24.
- `flutter test` full: **2304 passed / 14 skipped, 0 errors** (7 min, as a `hub` process). `node scripts/verify-claude-frontend-test-counts.mjs --log` OK. `node scripts/dart-lint-ratchet.mjs` **3166 → 3165, improved**, floor updated.
- Live re-drive on the fixed builds: (g1) `CONTENT_DB_RECREATED` 20:37:49 → gate at login+9 s, loss notice only after `RESTORE_GATE_RELEASED`; (g2) restore door y=1644 above reset y=2043; (F1) tester2 not reloaded, one `SEND_FAIL` at 20:40:07 then the 4 s retry landed on device 7, pins `{"114":4}`; (F2) after another restore the first message from device 9 rendered on the open peer at t+13 s, no send, no reload, pins `{"114":5}`.
- **NOT verified:** CI on the three commits (PR #184 just opened; `4260a47f` not yet pushed at write time), iOS, prod, Android release build, the peer's dropped-on-reload failed row (pre-existing, unchanged).

## Notes for next session
- Deploy still parked by the owner; `master` untouched at `2ab9265c`. Next per `task_plan.md:37-38`: **PR0.2** (`activeConversationId` end to end), then PR1.0.
- Owner-owed: G3 box-surface designs before PR1.1; the (b)/(c) rough edges in `traps.md` (reset copy "6 h" vs doc "1 h"; `Włącz łączenie` regenerates an existing phrase) remain open.
- Product fact: "keys match after a loss" needs linking ON — the nudge-only phrase gives no restore door.
- Traps (also in `traps.md`): orphaned `flutter_tester.exe` after a deadline kill = frozen log, use `hub start`; a red run that compiles after the fix is not red; `pm clear` never shows the loss screen; Flutter web a11y textbox keeps one char from Puppeteer typing (use CDP `insertText`); a swipe on the open Gboard glide-types; nudge-only phrase ≠ restore door.
