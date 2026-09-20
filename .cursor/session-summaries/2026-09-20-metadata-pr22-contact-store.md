# Metadata privacy PR2.2: client-owned ContactStore hydrated before the socket, twice reviewed, proven offline on the emulator

**Date:** 2026-09-20 · **Version:** unchanged (0.2.51 backend / 0.2.50 web on prod; branch only) · **Tiers deployed:** none

## What was done
- G0 shipped earlier this session: master `f27c5712` = prod backend (`/version` 0.2.51, migrations 0019+0020 applied, 115 accounts — the "two devices" fleet claim was wrong). Owner then approved PR2.2 in chat after the "what is the other option / what about lost contacts" exchange.
- `frontend/lib/services/contacts/contact_record.dart` (new): `ContactRecord` v1 — profile, `ContactState`, `ContactSettings` (timer/mute/pin), `ContactLegacy` (server ids, deleted with Phase 4), `ContactQueue`/`ContactOutbound` slots for Phase 1. `fromJson` rejects `v > 1`.
- `frontend/lib/services/contacts/contact_store.dart` (new): `ContactStore(open, selfProfile, lock, accepts)`; `open` loads `e2e_<uid>_contact_v1_*` from `EncryptionService.contentKv` (one opener per process); `reconcile` = ONE lock + in-process queue + `authoritativeSnapshot()` + upsert + membership sweep decided on DISK state; unreadable rows are UNDETERMINED (kept, counted); a newer build's row is untouched; `_generation` refuses queued writes from a closed session; `settled` exposes the queue tail.
- `content_kv_opener_io.dart:contactStoreAccepts` refuses anything but `NativeContentStore` on Android; web twin accepts; `sealed_web_content_kv.dart:_familyKey` seals `contact_v1_`; `_openDb` recreate records `CONTACTS_DESTROYED`.
- `FriendsProvider`/`ConversationsProvider`: `contactStore` field, `hydrateFromStore()`, write-through in every list/event handler (`youWereBlocked` included), `rewriteStore()` after a passcode unlock, `hasFriendsSnapshot`; an EMPTY first snapshot replaces hydration.
- `ConnectionProvider.connect()` step 4b: opens the store bounded by `kContactStoreOpenBudget` (4 s, cancellable timer), hydrates BEFORE the socket, `_connectGeneration` guards same-user re-entry; socketReady retry gates on snapshots not emptiness; `disconnect(isLogout)` closes the store; `EncryptionProvider.onPasscodeLockRevoke/Restore` hooks (restore runs regardless of the E2E guard).
- `conversations_screen.dart`: skeleton yields to a non-empty hydrated list; wires `ContactStore(open: enc.encryptionService.contentKv, selfProfile: auth.currentUser)`.
- Docs: `e2e-invariants.md:48` rewritten (contact list is the offline exception; key names stay clear; web prefs fallback parity with `sig_`); `frontend/CLAUDE.md` §2 pointer; root `CLAUDE.md` test count 2215→2243. Plan: line budgets DELETED by the owner ("build proper code without bandwidth"); PR2.4 caches CK itself next to the session; PR1.2 owes the sweep→downgrade change once queue keys land.

## Key files
- Edited: `frontend/lib/providers/{connection,conversations,encryption,friends}_provider.dart`, `frontend/lib/screens/conversations_screen.dart`, `frontend/lib/services/encryption/{content_kv_opener_io,content_kv_opener_stub,sealed_web_content_kv}.dart`, `frontend/lib/services/encryption_service.dart`, `frontend/docs/e2e-invariants.md`, `frontend/CLAUDE.md`, `CLAUDE.md`
- New: `frontend/lib/services/contacts/{contact_record,contact_store}.dart`, `frontend/test/services/contacts/contact_store_test.dart` (13), `frontend/test/providers/contact_store_hydration_test.dart` (15)
- Read only (load-bearing): `docs/contracts/wire.md`, `frontend/docs/passcode-lock.md`, `content_kv.dart`, `native_content_store.dart:123-130`, `session_cross_context_lock_stub.dart` (pass-through off web), `e2e_lock_revoker.dart`, `chat-conversation.service.ts:71-79` (server filters blocked peers from conversations)

## Verification
- `flutter analyze --no-fatal-infos`: 0 errors / 0 warnings. `node scripts/dart-lint-ratchet.mjs`: PASS, held at 3166.
- `flutter test`: 2243 passed / 14 skipped on the committed tree; `verify-claude-frontend-test-counts.mjs` OK.
- `flutter test test_e2e` (local stack, backend restarted for the register throttle): 46 passed / 14 skipped.
- Two independent reviews on the diff: `agent://PR22Reviewer` (8 findings) + `agent://PR22Security` (9). Both REQUEST-CHANGES; every finding folded or refuted with evidence (blocked-peer create: server already filters). Advisor's 27 points folded (4 changed code).
- Live drive, Pixel_7 emulator, debug APK, local stack: seeded account (2 friends, 2 chats, 1 pending request) → login → `am force-stop` → wifi+data off (`ping 10.0.2.2` DOWN) → cold start → widget tree: 2 `ConversationTile` (bob, carol), Contacts "WĘZŁY 02"; VM-service eval: `NativeContentStore.instance` live, 4 `contact_v1_` rows (`self`, 53 friend+chat 16, 54, 55 pendingIn). Network on → server lists replace, no duplicates, badge appears. Screenshots impossible on this AVD (`screencap` 0 bytes under both GPU modes); semantics tree + `[E2E-FLOW]` are the observation.
- Commit `9c69c34b` on `feat/metadata-privacy`, pushed. CI on that sha: see LATEST (filled at session end).
- NOT verified: web (sealed family + Web Locks path only unit-tested), passcode re-lock on a real web build, iOS, prod.

## Notes for next session
- Next: PR2.4 server-held contact backup (plan text updated: cache CK, not the derived key), then PR2.3, then §2 order. Emulator AVD `Pixel_7` is booted; app installed and logged in as `e2e_dev_2de8bd17#4650` against the local stack.
- Owner rulings this session: no line budgets, ever; PR2.2 accepted at 937 code lines.
- Traps (also in `traps.md`): count users before any fleet claim; `./backup-db.sh` BEFORE a destructive migration; `deliveredAt` is ack-only; `Future.any` leaks the losing timer under `flutter test`; `runSessionCrossContextLocked` is a pass-through off web; emulator `screencap` writes 0 bytes on this AVD; `restoreAfterPasscodeUnlock`'s `_e2eInitialized` guard skips anything chained after it; `flutter test test_e2e` shares the 10/h register throttle with any seed script — run the harness FIRST.
