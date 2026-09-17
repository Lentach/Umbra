# Reactions are blinded end to end on `feat/reaction-tokens` — and the wiring's seven key-destroying paths are closed

**Date:** 2026-09-17 · **Version:** unchanged (prod stays `0.2.48 / eefc44b0`) · **Tiers deployed:** none

## What was done
- `messaging_provider.dart`: built `ReactionKeyService` (store/request/resolveTargets/encryptFor/decryptFrom), a socket request-response bridge for `uploadReactionKey`/`fetchReactionKey`, `_renderableReactions` / `_reRenderReactions` / `_reactionWireKey` / `_peerUserIdFor`, plus reaction-key reset on connect, reconnect and logout.
- `messaging_provider.actions.dart`: `addReaction`/`removeReaction` are `Future<bool>` and emit a 22-char token; they NEVER fall back to a plaintext emoji. `reaction_tap.dart` (new) shows `snackbarReactionUnavailable` on failure, shared by all four tap sites.
- Reactions resolve where they ENTER (`events.dart` `_handleIncomingMessage` + `_handleReactionUpdated`, `history.dart` ingest); `_handleReactionUpdated` also patches `_conversationCache`, or a chat switch served raw tokens back.
- `reaction_key_service.dart`: `ensureCodec` is a per-conversation MUTEX (a mailbox row decrypts once); `_publish` persists before announcing and marks the record `pending`; `_reconcile` resolves a provisional record against the server's epoch (confirm / resume-publish same key / drop).
- `encryption_service.dart`: reaction-key reads go through `_authoritativeSnapshot()` (absence is what spends the row); added `dropReactionKey`; `saveReactionKey` takes `pending`.
- `messages.service.ts`: `removeReaction` strips the user from EVERY key and lost its `emoji` argument — a pre-upgrade plaintext reaction was otherwise unremovable by a token-sending client.
- `chat-reaction-key.service.ts`: every `reactionKeyUploaded` answer now echoes `conversationId`; the client has one upload slot and drops mismatched answers.
- `_reactionKeyTargets` RESOLVES both device lists and fails closed — the send path's device-1 fallback is safe for a send, permanent damage for a key.

## Key files
- Edited: `frontend/lib/providers/messaging_provider.dart`, `messaging/messaging_provider.{actions,events,history}.dart`, `connection_provider.dart`, `services/encryption_service.dart`, `services/reactions/reaction_key_{service,lookup}.dart`, `services/socket_service.dart` (2 dead plaintext emitters deleted), `widgets/message/{reaction_chips_row,chat_message_bubble,voice_message_content}.dart`, `l10n/app_{en,pl}.arb`, `backend/src/messages/messages.service.ts`, `backend/src/chat/services/chat-reaction{,-key}.service.ts`, `docs/contracts/wire.md`, `docs/design/reaction-privacy.md`, `CLAUDE.md`.
- New: `frontend/lib/widgets/message/reaction_tap.dart`.
- Read only (load-bearing): `frontend/docs/e2e-invariants.md`, `frontend/docs/passcode-lock.md`, `docs/design/reaction-privacy.md`, `messaging_provider.send.dart` `_resolveFanOut`.

## Verification
- `flutter test` **2192 passed / 14 skipped**; backend `npx jest --config jest.config.json` **1159 / 64 suites**; `flutter analyze --no-fatal-infos lib test test_e2e` no errors or warnings; `dart-lint-ratchet.mjs` PASS at 3166; backend `lint-ratchet.mjs` PASS (898 → 897); both `verify-claude-*-test-counts.mjs` OK.
- Mutants killed: removing the epoch gate → `a device linked after the key was made does NOT re-key` fails `Expected: false / Actual: <true>`; deleting the `_reRenderReactions` call → `chips rendered before the key arrives flip to emoji` fails `Expected: [2] / Actual: <null>`.
- Two independent reviews (security + standards) produced 7 blockers / 4 majors / 6 minors; all fixed except the one below. One finding REJECTED with evidence: the reaction handlers do have a bidirectional block gate (`chat-reaction.service.ts:52`, `:108`).
- **NOT verified: anything at runtime.** No browser, no emulator, no device, no local stack. `test_e2e/full_stack_e2e_test.dart` was rewritten (raw-socket emits + a new removal-under-a-different-key assertion) and has only been ANALYZED, never run — CLAIMS in `CLAUDE.md` §3 about the e2e run predate this edit.

## Notes for next session
- FIRST TASK: drive it. Chrome + Android emulator against a LOCAL stack with `0018` applied; assert in `psql` that `messages.reactions` keys are 22-char tokens, never emoji; check peer render, un-react, and relaunch (falsification R7). Owner offered a USB phone (`f849cc68`) if the emulator falls short.
- Owner-owed: whether to build the same-epoch top-up (without it a device linked after distribution shows placeholders forever — stated in `wire.md` and design row 6); bundling fonts locally to drop `fonts.gstatic.com` from CSP `connect-src`; the commit that removes the plaintext branch and actually closes D10.
- Reported, NOT fixed: `envelopeRefusal` validates envelope shape but never COVERAGE, so a participant can advance the epoch with envelopes reaching nobody else and blind the peer. Our client can no longer do it accidentally; a crafted one can. Needs an `incomplete_fanout` refusal.
- CSP stays Report-Only: clause 4 (`media-src blob:`, `worker-src blob:`) is UNMEASURED — voice, media messages and the QR scanner were never driven.
- Traps (also in `docs/agents/traps.md`): l10n template is `app_pl.arb`, not en; a `ContentKv` test fake whose `noSuchMethod` returns null now breaks on `authoritativeSnapshot()`; bound ratchet drift with a per-RULE diff, never `file:line`; reaction-key reads must use the authoritative snapshot; silence from an upload is not refusal.
