# 0.2.100: cleanup batch 4 split five giant files — and found the Dart lint ratchet had been measuring nothing

**Date:** 2026-11-24 · **Version:** 0.2.99 → 0.2.100 · **Tiers deployed:** both (+ APK 20100)

## What was done
- Five splits, one file per PR, all `part of` the original library so no privacy widened and no caller changed: **#284** `connection_provider.dart` 1875 → 828 + 7 parts (`providers/connection/`); **#285** `link_ceremony_controller.dart` 1554 → 587 + 6 parts; **#286** `box_session.dart` 1377 → 792 + 5 parts; **#288** `contact_network_view.dart` 1793 → 709 + 4 parts (`widgets/contact_network/`); **#287** `chat-key-exchange.service.ts` 1049 → 924 plus `chat-key-exchange.util.ts` and `chat/utils/socket-data.ts`. Residue is what an extension cannot hold: fields, constructors, interface `@override`s (~600 lines in `box_session`), members test fakes override.
- **The Dart lint ratchet had been dead for months** (`scripts/dart-lint-ratchet.mjs`): its regex expects `info - … - rule`, but flutter_tools prints `•` on Linux, so CI parsed 0 findings every run and logged "PASS, IMPROVED — 2478 → 0". Fixed: both separators accepted, exit 2 when the parsed count differs from flutter's own `N issues found`, baseline re-measured to the true 2485 (Flutter 3.44.6 / Dart 3.12.2) — a measurement correction, not new debt. Bite-tested: a bogus doc reference now fails it 2485 → 2487.
- That dead gate had already let something through: #285 added two `comment_references` infos (`devices_screen.dart` cited `LinkCeremonyController.revokeDevice`/`.mintDak`, both now on `LinkCeremonyDevices`). Fixed before merge.
- **Agent rules had drifted out of reach of their own subject**: `wire-contracts` and `frontend-dart-idioms` are keyed on the exact path `connection_provider.dart`, so the socket handlers that moved to `providers/connection/` no longer triggered them. Added `providers/connection/**` and `providers/messaging/**` (the latter had the same gap since before this batch) to all six trigger lists.
- #287 follow-ups: the pending-rebuild map is owned in one place (`livePendingSessionRebuildRequesters`), its TTL export is gone, and the generic socket helpers moved to `chat/utils/socket-data.ts`.
- Doc drift fixed in the same batch: stale citations in `multi-device.md` (incl. a sentence that still claimed `persistArmed` where the path calls `persistPendingArmed`), `traps.md` ("70 `on()` sites" → the real 32), `e2e-decryption-failed.md`, `workflow-2.0.md`, two code comments and one test comment.
- Out of repo: local stack `fp4` built from master and left running (see cleanup owed), debug builds replaced by the 0.2.100 release APK on both devices, prod `.env` APK keys at 20100 (`.env.bak.pre-apk-0.2.100` kept), `Desktop/umbra-0.2.100.apk` created. Xiaomi stays MUTED (owner's request).

## Key files
- Edited: `frontend/lib/providers/connection_provider.dart`, `frontend/lib/services/device_link/link_ceremony_controller.dart`, `frontend/lib/services/box/box_session.dart`, `frontend/lib/widgets/contact_network_view.dart`, `backend/src/chat/services/chat-key-exchange.service.ts`, `scripts/dart-lint-ratchet.mjs`, `scripts/dart-lint-baseline.json`, the six rule files, `frontend/pubspec.yaml`.
- New: 22 `part` files, `chat-key-exchange.util.ts`, `backend/src/chat/utils/socket-data.ts`.
- Read only (load-bearing): `docs/plans/2026-11-23-cleanup-program.md` §3/§5, root `CLAUDE.md` §5 (version contract).

## Verification
- CI: 13 rows green on every PR head, 12 on master `4ffa92ab`.
- Tests: Flutter 3541 / 16 skipped and backend 902 / 56 — unchanged on every branch, as a structural batch requires. Analyze: no errors or warnings; per-file info counts equal to master.
- Review: two agents. Correctness found no BLOCKER: bodies verified line-for-line (multiset + difflib), the only changed line in the batch is `LinkCeremonyController._kResignRetryCap`. Because Dart extension methods dispatch STATICALLY, every moved member was checked for overrides, mocks, interface dispatch, `noSuchMethod`, `as dynamic` and tear-off identity — none affected. Standards found the ratchet and the rule-trigger gaps above.
- Local drive (debug build of master, stack `fp4`, emulator + Xiaomi): invite, accept, messages both ways, edit, backend restart then a message, the contact-network screen (geometry, painters, nodes), and the full enable-linking ceremony — `mintDak` → mandatory recovery key → word confirm → device list → rename. Table in `.planning/cleanup/batches.md` "4 drive".
- Deploy: backup offsite 3/3; `/version` and `version.json` 0.2.100 `4ffa92ab`; APK 20100 SHA256 `346ba421…` served with the same hash; smoke PASSED.
- Live drive (0.2.100 release APK, emulator + Xiaomi): register ×2, invite, accept, messages both ways, cold start, devices screen. Throwaways deleted; prod users 31.
- NOT verified: a second physical device through the link ceremony (needs a third device), web, iOS, passcode lock.

## Notes for next session
- Next action: batch 5 (test pruning and doc drift) — EC-9, O-4, TL-1..8 and the TD rows (TD-02/03/04/11) in `.planning/cleanup/findings.md`. Then the Phase 3 report `docs/plans/2026-1x-signal-grade-gap.md`.
- Owner-owed: BE-12 confirmation (`getDeviceLists` removed in 0.2.97 although O-7 names only BE-11); UI-16 (composer) and UI-17 (old `http` media fallbacks); whether `messaging_provider.box.dart` (2890 lines, the largest non-encryption file left) and the composer split should go in a batch 4b.
- Also open: `chat-search.service.ts:17-34` still has its own copy of the socket-data helpers; UI-23 (a fourth `m:ss` copy); WEB-16; the 6th account delete in an hour fails silently.
- Cleanup owed: worktrees `fireplace-4`, `fireplace-4-{conn,link,box,be,net}` and branches `cleanup/4*`; **`backend/node_modules` in `fireplace-4-be` is a JUNCTION — `[System.IO.Directory]::Delete(path)` first, never recursively**. Local stack `fp4` (`docker compose -p fp4 down -v`), emulator-5560, Chrome 9333.
- Traps (also in `traps.md`): a lint ratchet that parses tool output must fail when it parses nothing; agent rules keyed on an exact file path silently stop firing when that file is split; Dart extension methods dispatch statically, so a split that moves a method out of a class removes the ability to override or mock it.
