# A re-minted install folds pre-loss rows into the divider, the takeover alarm stops losing a report, and the open-chat id is off the wire (PR0.2)

**Date:** 2026-09-22 · **Version:** unchanged (prod web `0.2.50`/`d37e2dcc`, backend `0.2.51`/`9e621f63`) · **Tiers deployed:** none

## What was done
- Owner picked lever **(b) first, then PR0.2** — over "PR0.2 now", "(a)+(b)", and a password-unlocked identity backup (the only lever that makes keys match for a linking-OFF user without a phrase; a trust-model change, still open).
- **(lxxxvi)** `EncryptionService.ownIdentitySince` = the SERVER audit instant of the change that ENDED at this install's key (`ownKeyBundleStatus.identityReplacedAt` when `identityReplacedTo` is our key), forward-only, persisted as `e2e_<uid>_own_identity_since_v1`. `EncryptionProvider.onKeyBundleUploaded` re-asks `checkOwnKeyBundle` after `identityChanged:true` (the minting session's connect-time answer predates the row). `MessagingProvider.messages` hides UNREADABLE rows (`[Decryption failed]`, unusable `[encrypted]`) stamped before it behind the (lxxxi) divider; `onOwnIdentitySinceChanged` re-filters an open thread (`e111706d`).
- **(lxxxvii)** `recordOwnIdentityReplacedFromServer`: the own-key branch now spends the armed (li) one-shot. Before, every re-mint / §6.2 ceremony left it armed and it swallowed the next FOREIGN replacement reported at reconnect — an offline device's only alarm path (`9b9d723a`).
- **PR0.2** `activeConversationId` off the wire: DTO `{clientVisible}`; `handlePushClientState` stores `{clientVisible}` only (an old client's id is dropped — `validateDto` does not strip extras); `isRecipientDeviceVisible` skips the push while EVERY delivered device is on screen, any chat or the list; client `reemitPushClientState` sends visibility + the SW post, chat open/close/remove/connect/logout post to the SW only; `socketReady` and the resume resync re-send visibility with or without an open chat (`482563f5`).
- Spec `docs/design/multi-device.md` (lxxxvi)/(lxxxvii); `backend/CLAUDE.md` §9, `frontend/CLAUDE.md` §6; counts jest 1156 → 1155, flutter 2304 → 2309; floors ESLint 891 → 890, Dart 3165 → 3163.

## Key files
- Edited (frontend): `providers/messaging_provider.dart` (`messages`), `providers/messaging/messaging_provider.decrypt.dart` (`_predatesThisDevice`), `providers/encryption_provider.dart`, `services/encryption_service.dart`, `providers/conversations_provider.dart`, `providers/connection_provider.dart`; comments in `main_shell.dart`, `chat_detail_screen.dart`, `utils/chat_resume_reassert.dart`.
- Edited (backend): `chat/dto/push-client-state.dto.ts`, `chat/services/chat-presence.service.ts`, `chat/services/chat-message.service.ts`.
- Tests: `messaging_provider_envelope_status_test.dart`, `encryption_provider_identity_reset_test.dart`, `conversations_provider_test.dart`, `connection_provider_socket_ready_test.dart`, `chat-message.service.spec.ts`, `chat-presence.service.spec.ts`.
- Read only (load-bearing): `key-bundles.service.ts:333-346, 540-555` (audit row write/read), `chat-key-exchange.service.ts:592-657` (`ownKeyBundleStatus`), `chat/utils/dto.validator.ts` (no whitelist), `utils/decryption_failure_policy.dart`.

## Verification
- (b): red first (3 assertion failures on the bare API), 6 mutants killed (F54–F59, files byte-restored), full flutter 2309/14. Live web drive (build of this tree, fresh origin :5611 = storage loss, tester2 linking OFF): `IDENTITY_GUARD_UNLOCKED_REMINT` → `IDENTITY_MINTED` → `OWN_IDENTITY_REPLACED_IS_SELF`; audit row 19:42:57.487 `BYuo…→BRKX…` = stored boundary; 13 server rows → ONE divider, no "Nie można odczytać", same after reload; a new message renders below it.
- (lxxxvii): throwaway probe, then suite test, red (`ownIdentityReplacedAt` null) → green.
- CI on `9b9d723a` (draft PR #184): **7/7 success**.
- PR0.2: red first (backend 4, frontend 5); jest 1155/66; flutter 2309/14; ESLint ratchet PASS (891 → 890); Dart 3164 → 3163; knip clean; `verify-no-user-logs` OK; `flutter test test_e2e` against the mp stack (`E2E_DB_CONTAINER=fireplace-mp-db-1`): 46 passed / 14 skipped. CI on `482563f5`: **7/7 success** (Flutter analyze+tests `106916055747`, E2E wire `106916055905`, backend `106916055719`).
- NOT verified: Android/iOS drive of (b) (web only); (lxxxvii) live (needs an offline foreign takeover); PR0.2 live push (no push infra on the dev stack — jest + harness only); prod.

## Notes for next session
- Next per `task_plan.md:37-38`: **PR1.0** (`WsThrottlerGuard.getTracker` → `x-real-ip` for tokenless sockets; spec must prove two `x-real-ip` values get two trackers), then **G3** (two box-surface designs to the owner) before PR1.1.
- Owner-owed: lever (a) and/or the password-unlocked identity backup (keys still re-mint on linking OFF); the red own-account banner a wiped linking-OFF install shows for its OWN previous re-mint (pre-existing, not fixed); `traps.md` rough edges (b) "6 h vs 1 h" copy and (c) `Włącz łączenie` regenerating a phrase.
- Test accounts: tester2/115 was re-minted by the drive — identity now `BRKX5yIFOisYUy1p`, held ONLY by origin `127.0.0.1:5611`; any other 115 client holds a dead identity. tester1/114 unchanged (device 9, linking ON).
- Traps (also in `traps.md`): `validateDto` keeps extras; Dart ratchet +1 comes from test code; a content-based early return must spend the one-shot; the post-re-mint divider is by design; wiped linking-OFF red banner (not fixed); push skipped while visible on any chat; split a file across commits via a built blob.
