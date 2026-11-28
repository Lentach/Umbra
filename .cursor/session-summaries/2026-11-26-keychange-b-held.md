# Key-change auto-accept (decision 152) built and reviewed five times; release 0.2.112 HELD for the owner

**Date:** 2026-11-26 · **Version:** unchanged on master (0.2.111); branch carries 0.2.112 · **Tiers deployed:** none

## What was done
- Built on `feat/keychange-b` (draft PR #318, head `c41f5720`, 23 commits over master `b4cf319a`): with warnings OFF an UNVERIFIED friend's new key is accepted and a permanent grey line is written into the chat; a VERIFIED friend, or warnings ON, still holds with the red bar.
- `encryption_service.dart`: `_autoAcceptUnverified`, `markPeerVerified(peerId, expectedIdentityBase64)`, `revertAutoAccept`, `snapshotFriendDevice` / `restoreFriendDevice`; records `e2e_<uid>_peer_verified_v1` (per device, bound to the key) and `e2e_<uid>_peer_key_change_log_v1` (first 5 + newest 45 per friend).
- `messaging_provider.box.dart` `_readBox`: a frame's accept is provisional; a failed decrypt or a `prekey_unasked` refusal reverts it, restores the session and identity row, and marks the address for rebuild.
- Dialog: "Oznacz jako zweryfikowane" / "Zweryfikowano" / "Klucz zmienił się w trakcie. Porównaj ponownie."; decision row 152 in `docs/plans/metadata-privacy-decisions.md` (on the branch).
- Five review passes. Passes 1–4 each found a serious defect, three of them in the fix for the previous one: MUST-1 (verified mark bound to the wrong key), N1 (blind revert), N2 (refused frame moved the anchor), R1 (refused frame's session used for sending), S1 (the same session still delivered inbound). All fixed. Pass 5: no P1/P2 known, eight P3 open, reviewer recommends replacing the frame design.
- NOT released: the unattended release was stopped at pass 4 by a rule set beforehand (another P1 → the owner decides).
- Out of repo: worktree `Desktop/fp14-kc` kept; local stack `fp14`, web server, drive Chrome stopped; debug app removed from the Xiaomi; Xiaomi power settings restored.

## Key files
- Edited (branch only): `frontend/lib/services/encryption_service.dart`, `signal_stores.dart`, `frontend/lib/providers/messaging_provider.box.dart`, `peer_identity_fingerprint_dialog.dart`, l10n arb, `docs/plans/metadata-privacy-decisions.md`, `docs/agents/traps.md`.
- New (branch only): `frontend/test/services/encryption_auto_accept_unverified_test.dart`; warnings-OFF variants in `messaging_provider_box_friend_crossing_test.dart`.
- Read only (load-bearing): decisions 37, 88, 143, 152; review transcripts `history://R14KeyChange`.

## Verification
- CI: draft PR #318 on `c41f5720`: 14 rows success (all test, analyze, count, E2E, gitleaks, CodeQL rows); `Build unsigned release APK` still running and the release row not yet listed when this was written: re-read before acting.
- Local gates on `c41f5720` (builder's run): `flutter test` `+3990 ~14: All tests passed!`, analyze 2466 infos, Dart lint ratchet PASS at the baseline. Backend untouched.
- Mutants (reviewer, temp copies): warnings-ON guard, verified guard, bundle signature, frame revert, pinned==offered, R2/R3/R4 guards all killed by named tests. Survivor: the S1 restore guard (the mutant did not compile; no evidence).
- Device drive on build `2e935acd` (BEFORE the S1–S3 fixes), Xiaomi observer + two web friends, 7 paths pass: table in `.planning/cleanup/batches.md`. Friend reinstalls and writes first; note survives newer messages and a restart; you write first; dialog open while the key changes; verified friend held and released; re-bind; warnings ON holds an unverified friend.
- NOT verified: the final build on any device; every refusal / handoff-crossing path on a device; inbound blocking through the real `_readBox` whisper path (probes only, no committed test); two tabs; a linked multi-device friend; iOS.

## Notes for next session
- Next action: get the owner's choice, then either (a) ship the branch as is: read PR #318 CI, re-drive the 7 paths on the final build, release 0.2.112; or (b, recommended by the reviewer and by me) replace the frame path: a new-key PreKey frame from an unverified friend is HELD until a fetched, signature-checked bundle confirms that key, and only the bundle path auto-accepts. Same visible result, one trust point, removes open items 1–4 and most of the revert code.
- Open P3 items (pass 5): a send queued during the provisional decrypt goes to the refused sender; an encrypt between snapshot and decrypt is rolled back and the next message reuses its message key; unawaited note alignment (crash leaves the line under its message); a kill between a frame's accept and its decrypt leaves an unproven key pinned; send-path note order; sibling tabs can undo a clear-chat; the lxxix local path ignores the verified flag (believed unreachable); no committed test for inbound blocking.
- UI seen on the phone: the toggle's subtitle is cut with "…" before the sentence about verified contacts; three key changes in a row give three identical grey lines.
- Owner-owed: ship as is or redesign; whether the accepted risk in decision 152 still stands after reading the above.
- Traps (also in `docs/agents/traps.md`): a review loop that finds a new serious defect in each fix is itself the finding: stop the unattended release.
