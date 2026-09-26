# PR2.1 A2: the wire id is scoped by its authenticated sender, and an own row's wire id is the token this device minted

**Date:** 2026-09-24 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only, pushed to the branch per the owner; nothing to master or prod)

## What was done
- Owner go-ahead on review finding A2 (the "quality, not cheap" question). `05aa4c69`: `typedef WireKey = ({int senderId, String wireId})` (`encryption_service.dart`); `saveDecryptedContent(wire:)` stamps `_wid` + `_wsid` (`PlaintextRecordCodec.wireSenderKey`) as ONE pair, first write wins; `wireIdIndex()` → `Map<WireKey,int>?`; a `_wid` without `_wsid` claims nothing; one sender's duplicate still maps to nothing (backstop).
- Messaging: `_wireKey(senderId, wireId)` (`messaging_provider.decrypt.dart`). Decrypt persists under `decrypted.senderId` (the pairwise session is keyed by it, so a relabelled row fails decrypt); ack + lost-ack under `_currentUserId!` (both inside `msg.senderId == _currentUserId`).
- Two independent reviewers (A: security lens, B: tests/contract): both APPROVE. Fold `a6de1f3a`, test-first:
  - A (predated A2): the ack/lost-ack took the wire id from the server's ECHOED `sendToken`; a server echoing a sibling device's token would pre-claim it under our name. Now the ack uses `_sendTokenByTempId[tempId]`, and the pending-send record carries the minted token (`_wid`) for a lost-ack after restart; a record without one gets no wire id.
  - B: nothing pinned "a later write never supplies the sender of a senderless `_wid`" — a restored row re-persists under the SERVER row's senderId. New test; the `_persistDecryptedContent` comment no longer overclaims.
- Docs: `wire.md` msgId contract, `e2e-invariants.md` wire-id rule, `CLAUDE.md` §3 count 2365 → 2371, `task_plan.md` PR2.1 as-built, `traps.md`: 2 lines rewritten, 1 extended, 1 new.

## Key files
- Edited: `frontend/lib/services/{encryption_service,plaintext_record_codec}.dart`, `providers/encryption_provider.dart`, `providers/messaging/messaging_provider.{decrypt,history,send}.dart`; 8 test fakes (`WireKey? wire`).
- Tests: `test/services/encryption_service_content_cache_test.dart` (group "EncryptionService wire id"), `test/providers/messaging_provider_wire_id_test.dart`.
- Read only (load-bearing): `g3-surface-designs.md:438,654,698` (the wire id dedups a SENDER's retries), `sealed_web_envelope.dart`.

## Verification
- TDD: service slice compile-red → green; provider race test proven red by mutant P1; fold tests red on the real bug (index held `(1, temp_…-sibling)`) before the fix.
- Tests +6 net: service +3 (the group is now 8, its 5 old tests rewritten to the record key), provider +3. Mutants 12/12 killed: S1 index ignores sender, S2 later write moves sender, S3 senderless claims, S4 no duplicate backstop, P1 decrypt stamps own account, P2 decrypt drops wire, P3/P4 ack/lost-ack wrong sender; fold F1 fill-in missing sender, F2 ack trusts echo, F3 record drops minted token, F4 lost-ack trusts echo.
- `flutter test` 2368/14 after `05aa4c69`, **2371/14** after the fold (`verify-claude-frontend-test-counts.mjs` OK both times). Ratchet 3163 both times. CI **7/7 green** on `05aa4c69` and on `a6de1f3a`.
- Live Dart probe (throwaway `test_e2e`, deleted): two fresh accounts, real `MessagingProvider`s, real Signal. Alice's index `{(225, token): 527}` = Bob's; Bob then encrypted an envelope carrying Alice's token under his REAL session → Alice's index `{(225,t): 527, (226,t): 528}`. Anti-vacuity: mutant P1 → red.
- **Browser drive (owner ask), release web build served from `build/web_wiresender` (deleted after):** alice on `localhost:8081`, bob on `127.0.0.1:8081`, fresh accounts 229/230; invite → accept → bob "hello from bob" (530) → alice "reply from alice" (531). Unsealed the web records in-page (FlutterSecureStorage key → `fp_content_key_<kid>` → AES-GCM): both browsers hold `530 → (_wsid 230, temp_…_230-hmkrnx50yo)`, `531 → (_wsid 229, temp_…_229-hmkroh5els)`, equal to the DB `messages."sendToken"`. Reload → history renders from the records, stamps unchanged.
- NOT verified: Android device/emulator (the mobile path is the one the unit tests and the Dart probe run; no platform-specific code changed), iOS.

## Notes for next session
- NEXT: PR3.2 backend (`task_plan.md` "PR3.2"), on the branch. PR3.1 dedups on `WireKey`, never on a bare wire id.
- Observed, not investigated: an own row acked via `messageSent` is persisted WITHOUT `_cid` (web envelope `fps1:<kid>:-:…` for alice 531 / bob 530) — `history.dart` ack persist passes no `conversationId`. Check whether the history self-heal stamps it before relying on conversation purge for own sends.
- Owner-owed (unchanged): prod background-push check; web-deploy gate; 16 MiB box cap; `deleteQueue` → `auth_failed`; I2b; in-app cue for other chats.
- Traps (also in `docs/agents/traps.md`): wire id unique only per sender; never take a wire id from the ack echo; web records are whole-record sealed; two-origin browser drives need a release build.
