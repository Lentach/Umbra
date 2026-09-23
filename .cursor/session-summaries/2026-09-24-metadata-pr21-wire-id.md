# PR2.1 on the branch: every message carries a wire id, persisted as `_wid` and indexed wireId -> local id

**Date:** 2026-09-24 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only, owner ruling "branch until release N"; nothing to master or prod)

## What was done
- Draft PR **#185** `feat/metadata-privacy → master` opened for branch CI only (the old ones were merged at G4). Not for merge.
- `E2eEnvelope.build(msgId:)` / `parse().msgId`: the sender's `sendToken` rides inside the plaintext. A receiver keeps it only if it matches `^[A-Za-z0-9_-]{8,64}$` (the client's minting charset, the DTO's length) and otherwise drops the field, not the message.
- `messaging_provider.send.dart` `_encryptAndSend`: the token is minted (memoised per tempId) BEFORE the envelope, so a retry carries the same `msgId`. Edit envelopes (`actions.dart`) carry none, by design.
- `MessageModel.wireId` (ctor + `copyWith`), NEVER read from a server field. Own rows take the echoed token only on the origin-scoped ack (`_addMessageToState`) and lost-ack paths. Other rows take it from `msgId` at decrypt (`msg.wireId ?? parsed.msgId`, so an edit cannot re-point it) or from the record's `_wid` in all three restore paths. `_mergeMessagePreferNewer` keeps the local value.
- `EncryptionService.saveDecryptedContent(wireId:)` stamps `_wid` (`PlaintextRecordCodec.wireIdKey`, a metadata key). FIRST WRITE WINS, and it is carried forward across narrower writes. `EncryptionProvider` passes it through. Persist sites: `_persistDecryptedContent`, the `messageSent` ack (`history.dart`) and the lost-ack reconcile (`decrypt.dart`).
- `EncryptionService.wireIdIndex()` → `Map<String,int>?` over the content store plus the mobile legacy secure store (the content store wins for the same key), read from the authoritative view. A wire id held by 2+ records maps to nothing; `null` means the stores were not enumerated. Nothing reads it yet.
- Docs: `wire.md` envelope contract, `e2e-invariants.md` `_wid` rule, `CLAUDE.md` §3 count 2351 → 2365, `task_plan.md` PR2.1 "as built".
- **Two independent reviewers** (`reviewer` agents): both APPROVE, no blockers. Fold commit:
  - A1: `fromJson` let the SERVER's `sendToken` become a PEER row's wire id, pinned by first-write-wins. Reproduced red, then fixed: the wire id is never read from a server field.
  - B1–B3: wire.md / e2e-invariants / codec comments now match the code (charset ≠ DTO; many records lack `_wid`; the index decodes whole records; on web it can be partial).
  - B4: unrelated formatter hunks reverted.
  - A2 (index is sender-blind) is DEFERRED; see Notes.

## Key files
- Edited: `frontend/lib/utils/e2e_envelope.dart`, `models/message_model.dart`, `services/plaintext_record_codec.dart`, `services/encryption_service.dart`, `providers/encryption_provider.dart`, `providers/messaging/messaging_provider.{send,decrypt,history}.dart`. 8 test fakes gained the `wireId` param (signature only).
- New: `frontend/test/providers/messaging_provider_wire_id_test.dart`. Tests added to `test/utils/e2e_envelope_test.dart` and `test/services/encryption_service_content_cache_test.dart`.
- Read only (load-bearing): `encryption_service.dart` `getDecryptedContent` / `_legacyDecryptedContentFallback` / `_messageIdsMatching`, `sealed_web_content_kv.dart`, backend `chat.dto.ts` `sendToken` bound.

## Verification
- TDD per slice (envelope → service → provider). Each red was observed before its lib change: compile-red for the new API, then behavioural red 4/4 on the provider slice once the API existed.
- 14 new tests: envelope 4, service 5, provider 5 (real `EncryptionService` store; asserts `wireIdIndex()` after a send+ack, a lost-ack reconcile, an inbound decrypt, and a peer row carrying a server-planted `sendToken`).
- Mutants: 10/10 killed, each run as a subprocess and restored (the diff was byte-identical afterwards):
  - M1–M5: drop the carry-forward; incoming-wins; no legacy scan; legacy outvotes the store; no ambiguity rule.
  - M6–M10: send omits `msgId`; ack omits `wireId`; lost-ack omits `wireId`; decrypt drops `msgId`; persist drops `wireId`.
  - Fold, 3/3 killed: M11 `fromJson` derives `wireId` again; M12 the ack `copyWith` drops the token; M13 the lost-ack persist drops it.
- `flutter test`: **2365 passed / 14 skipped** after the fold. `verify-claude-frontend-test-counts.mjs` → OK.
- `flutter analyze`: 0 errors / 0 warnings. `dart-lint-ratchet.mjs` held at 3163 after fixing 5 new infos I had introduced.
- `flutter test test_e2e` (local stack `fireplace-mp-*`): 44 passed / 16 skipped / 2 failed. Both failures were `e2eSql` hitting `fireplace-db-1`. Re-ran with `E2E_DB_CONTAINER=fireplace-mp-db-1` → `registration_lock_test` 4/4, so the harness is **46/16** (backend restarted once to reset the register throttle; the 96-line `libc` lock churn it caused was checked out).
- **Live local proof** (throwaway `test_e2e` probe, deleted after), run before AND after the review fold: two fresh accounts on the `fireplace-mp` stack, each running the REAL `MessagingProvider` over the harness's real socket and `EncryptionService`. Alice typed through `sendMessage`; the DB `messages."sendToken"` equals the token she emitted, and Bob's `newMessage.sendToken` is **null** (the server withholds it). Bob decrypted the text with `wireId` = Alice's token, and BOTH `wireIdIndex()` returned `{token: serverId}` (ids 524, then 526). Anti-vacuity: the same probe with `msgId` removed from the send path → Bob's `wireId` null, index `{}`, red.
- Commit `cbe187ba` pushed to `origin/feat/metadata-privacy` only. Branch CI on PR #185: **7/7 green**. The fold commit's CI: see LATEST.

## Notes for next session
- NEXT: PR3.2 (backend first, `task_plan.md` §2 order: PR2.1 → PR3.2 → PR3.1), on the branch.
- **PR3.1 must dedup on (sender, wire id).** Review A2: a peer can PRE-claim one of our tokens on an offline sibling device, and records carry no sender. Stamping a `_sid` beside `_wid` now would avoid a later backfill. Owner/PR3.1 decision: the spec names `wireId → localId`.
- NOT verified: no device/APK/PWA drive (nothing reads the id yet, so there is no user-visible surface). The real wire was proven only by the throwaway probe; no committed `test_e2e` case sends `msgId`.
- Owner-owed (unchanged from G4): the prod background-push check; a separate web-deploy gate; the 16 MiB box cap; `deleteQueue` → `auth_failed`; I2b; an in-app cue for other chats.
- Traps (also in `docs/agents/traps.md`): in `fireplace-mp`, set `E2E_DB_CONTAINER=fireplace-mp-db-1` for `test_e2e`; the wire id is not sender-scoped; "BOTH record stores" = the content store + the mobile legacy secure store.
