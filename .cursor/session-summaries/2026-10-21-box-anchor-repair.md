# Box friends' key anchor repaired: a restored install pins on its lookup (E38d); a re-met ex-friend's stale pin is replaced (decision 112)

**Date:** 2026-10-21 · **Version:** unchanged (0.2.68; fix not released) · **Tiers deployed:** none

## What was done
- Field case: PrezydentKarol (132) could send nothing to bob208 from his native app since 10-20 17:43Z, and bob208's accept of his new request vanished. Cause from both logs: his native login reminted and restored bob208 from the contact backup with no key (`DEVICE_LIST_REJECTED no_tofu_identity` → `box peer 37: lookup spent`); bob208 still held his pre-remint key, so the accept was dropped (`BOX_REQUEST_UNVERIFIED served_list`).
- `messaging_provider.first_contact.dart` `lookupBoxPeerList`: the one handle lookup per process now runs `adoptServedAccount`, which pins the served identity when no anchor is held (E38d). A held anchor that differs is left alone.
- `EncryptionProvider.adoptServedAccount(replaceStaleAnchor:)` + `EncryptionService.replaceStaleAccountAnchor`: a pin held for an account that is no contact any more is replaced, durable `ACCOUNT_ANCHOR_REPLACED` (decision 112, owner "A").
  - Accept: only when a kept request frame is sealed under the served key (`_keptCarries`).
  - Send: to a fresh contact (no record, or `former`).
- Decisions log: 112 and E38d. Traps (E2E): the box-made restore trap rewritten as fixed; the two-install identity flip (goonboy, PARKED).
- Earlier the same day (in `2026-10-21-phase4-step3-freeze.md`): O31–O36 asked and put on hold by the owner; the storage fix parked.
- Out-of-repo: dev stack `fireplace` running (Docker Desktop started); Chrome CDP 9461 still running; throwaway `%TEMP%/d101drive/serve-one.mjs`; web builds `%TEMP%/p112` (fix) and `%TEMP%/p4s3` (0.2.68).

## Key files
- Edited: `frontend/lib/providers/encryption_provider.dart`, `frontend/lib/providers/messaging/messaging_provider.first_contact.dart`, `frontend/lib/providers/messaging_provider.dart` (import), `frontend/lib/services/encryption_service.dart`, `frontend/test/providers/messaging_provider_box_first_contact_test.dart`, `docs/plans/metadata-privacy-decisions.md`, `docs/agents/traps.md`, `CLAUDE.md` (count).
- Read only (load-bearing): `encryption/signal_stores.dart` (`stageAccountIdentity`, `adoptAccountIdentity`, `isTrustedIdentity`), `device_list_cache.dart` `adopt`, `messaging_provider.box.dart` `_friendDeviceIsLive`.

## Verification
- CI: green on `9075aec2` (all six jobs). `731389ed` was RED: Flutter analyze `unnecessary_non_null_assertion` at `messaging_provider.first_contact.dart:583`, a `record!` made redundant by the new one; `9075aec2` drops it.
- 3 new tests in the first-contact harness, all RED with the fix mutated off (`unverified`, `failed`/`served_list`, `no_tofu_identity`), green with it. Existing "lookup serves another key" tests unchanged and green.
- Flutter full suite 3206 passed, 14 skipped. Dart lint ratchet 3146 (PASS).
- Drive, dev stack, release web build `p112` vs 0.2.68 `p4s3`, accounts pk112a (263) / bob112b (264, enrolled via "Włącz łączenie" with a `navigator.standalone` init script):
  - box friendship made over the box (0 `friend_requests` rows);
  - A wiped + password login (remint, contact restored): fixed build sends ✓ to enrolled B; the old build on another origin shows red "Ponów" (his exact symptom);
  - old-build A reminted (no key reaches B), B removes A, A removes B and invites, B accepts: friendship made; B's store holds `19:59:02 ACCOUNT_ANCHOR_REPLACED {peerId: 263}`; one message each way arrives.
  - the exact prod state, then the owner's recovery (driven 20:20–20:24): both on 0.2.68, B removes A, A reminted on 0.2.68 invites, B's accept drops it (`20:21:58 BOX_REQUEST_UNVERIFIED served_list`; B shows nothing, A "Oczekuje"). Both origins then served the fix and reloaded: A's invite cannot be withdrawn (no cancel exists), so B INVITES A; A's waiting request takes it as an accept (E15f), B logs `20:23:46 ACCOUNT_ANCHOR_REPLACED`, friends on both sides with no tap on A, one message each way arrives.
- NOT verified: Android/native build, prod.

## Notes for next session
- Next action: release the fix (0.2.69: version bump, CI green, backend unchanged, web + APK per `docs/runbooks/android-release.md`), when the owner says so. Then: PrezydentKarol installs the APK and opens it; bob208 reloads the PWA; bob208 INVITES PrezydentKarol (not the other way: a box invite cannot be withdrawn); his waiting invite turns it into a friendship by itself.
- Owner-owed: the release go; O31–O36 (on hold); the bob208 ↔ R0yb3r positive check (E111c); the step 3 rehearsal; jarekk / qwerty / benz93 backups.
- Recipe: the hacker-mode durable panel can render stale; read `localStorage['flutter.e2e_diag_persist_v1']`. Fake installed mode for "Włącz łączenie": init script `Object.defineProperty(Navigator.prototype,'standalone',{get:()=>true})`. A `--name` regex selects flutter tests (`--plain-name` broke under cmd quoting).
- Traps appended: E2E (box-made restore / stale pin, fixed); Tests (the Dart ratchet counts infos only, a warning fails CI).
