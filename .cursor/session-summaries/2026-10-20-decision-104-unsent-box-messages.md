# A box message that did not go out stays on the device, red with "Ponów" (decision 104)

**Date:** 2026-10-20 · **Version:** unchanged (0.2.67, unreleased on `feat/passcode-lock`) · **Tiers deployed:** none

## What was done
- Rerun before building, on a 0.2.67 HEAD release web build with the dev stack:
  - revoked d101a (253) device 8 from its Devices screen;
  - a control send F4 → d101a went ✓;
  - with the box's `send` ack dropped and the sender reloaded, d101a had `held1` and F4 had nothing.
- `encryption_service.dart`: new sealed content-kv family `e2e_<uid>_boxunsent_v1_<tempId>`:
  - `saveBoxUnsent` / `boxUnsent` / `dropBoxUnsent` / `clearBoxUnsent`; the uid is always passed in;
  - an entry dies at `at + ttl`, after 30 d or past 200; an unreadable row is never deleted;
  - writes go under a cross-context lock; "delete all local history" sweeps the family.
- Sealed on both platforms: `sealed_web_content_kv.dart` `_familyKey` and `native_content_store.dart` `isSealedKey`.
- `messaging_provider.send.dart` `_encryptAndSend`:
  - keeps the send before `_boxRoute` and again at `BOX_RETRY_NO_ROUTE`;
  - drops it on an old-path fall-through;
  - the account that started the send is captured, and nothing is written after it signs out.
- `messaging_provider.box.dart`:
  - `_keepBoxUnsent` blanks the quote of a disappearing message;
  - `_unsentBoxRows` restores red rows (`sending` while this tab's attempt runs) with the wire id and the box pin;
  - `_mergeLocalBoxRows` drops an entry whose wire id a stored sent row already carries;
  - `_sendOverBox` drops the entry only after `recordExists` proves the sent record stored.
- `messaging_provider.actions.dart` `deleteMessage`: a failed kept row is removed locally; no negative id goes to the server any more.
- `messaging_provider.dart`: `clearAll` sweeps the family (logout, account switch).
- Docs: decisions log rows 19/104 and E104a; the 104 plan "As built"; `wire.md`; `e2e-invariants.md`; `traps.md` (two lines); `CLAUDE.md` count.
- Out of repo: `backend/package-lock.json` npm churn from `docker start` was restored; the dev stack is left running; Chrome and static servers stopped; `%TEMP%/d104rev` build left.

## Key files
- Edited: `frontend/lib/services/encryption_service.dart`, `frontend/lib/services/encryption/{sealed_web_content_kv,native_content_store}.dart`, `frontend/lib/providers/encryption_provider.dart`, `frontend/lib/providers/messaging_provider.dart`, `frontend/lib/providers/messaging/messaging_provider.{send,box,actions}.dart`.
- Tests: new `frontend/test/services/encryption_service_box_unsent_test.dart` (9); `messaging_provider_box_send_test.dart` (decision-104 group, 15); `sealed_web_content_kv_test.dart`; `native_content_store_test.dart`.
- Read only (load-bearing): `utils/message_ids.dart` (a negative id is never an action target), `messaging_provider.history.dart`.

## Verification
- CI: filled in after the push (see the follow-up line below).
- `flutter test` (full): `+3192 ~14: All tests passed!`. Dart lint ratchet (`node scripts/dart-lint-ratchet.mjs`): PASS at 3146.
- Red first: the sealed/native tests failed before the lib change, and the provider group (8) failed before the wiring.
- Mutants, 12, each run against its test and restored byte-for-byte; all killed:
  - the sent drop removed, then its proven-store gate removed;
  - the old-path drop removed; the history-wipe sweep removed;
  - the ttl clause, the cap loop, the clear prefix, the explicit uid;
  - the in-flight `sending` status, the quote blanking, the kept attachment shape, the crash-window dedup.
- Survivor: the sign-out owner guard in `_keepBoxUnsent`.
  - No provider test reaches a keep after `clearAll`: the post-route keep needs a null route, and none follows the hold.
  - Both attempted race tests were deleted. The guard stays, commented; the store test pins the explicit uid.
- Web drive on release build `0.2.67 · d104rev` (F4 at 8091/8094, d101a):
  - control `rv0` ✓;
  - `rv1` with the incoming `43/box,` ack dropped (1 drop) → reload → red Ponów → tap → ✓, the key was gone, and d101a showed `rv1` once;
  - `rv2` with the outgoing `42/box,` send dropped → red; survived leave+reopen and a reload;
  - Usuń → "Usuń u mnie" removed it, no key, still gone after reload.
- NOT verified: Android native store, logout sweep on a device, iOS, prod.

## Notes for next session
- Next action: Phase 4 step 1, the hardening release (decision 105's order). 104 ships with it.
- Owner-owed: the `getMessages` local-id fix; the same-origin re-link bug; bob208 must remove the old ruchens69 contact.
- Seen, not touched:
  - A retried box row's shown time moves to the retry time (`rv1` 20:46 → 20:47).
  - A failed temp row still offers reactions and reply in its long-press menu.
- Residuals (E104a):
  - an attachment whose upload never finished is not kept;
  - a second web tab shows the other tab's in-flight send red; its Ponów reuses the wire id, but this device may store the message twice.
- Drive recipe: `traps.md` (d101 accounts line). Chrome via `%TEMP%/d101drive/launch.ps1` (CDP 9461); one window per origin via `Target.createTarget {newWindow: true}`.
  - The F4 init-script `WebSocket` subclass drops incoming `43/box,` while `__dropBoxAcks` is set, and outgoing `42/box,…"send"` while `__dropBoxSends` is set; `__drops` counts them.
  - Before trusting a reload, purge `caches`, unregister service workers, and check the footer build tag.
