# A box delivery is now read on the device: journaled, acked, decrypted under a local id, shown, and still there after a restart

**Date:** 2026-09-24 · **Version:** unchanged · **Tiers deployed:** none

## What was done
- Owner decisions 12–14 (asked before any test; `task_plan.md` above "Slice (a) as-built"): binary in-seal body `v ‖ kind ‖ u16be device ‖ raw Signal` (`box_frame.dart`); envelope `t`/`ts`, sender clock clamped to receive time (`e2e_envelope.dart`); a box message's id is LOCAL, ≥ 2^48 (`utils/message_ids.dart`).
- Delivery journal `e2e_<uid>_boxin_v1_<rid>.<id>` in `ContactStore` (`contact_store_inbox.dart`, sealed web family `boxin_v1_`): the local id comes from the counter `e2e_<uid>_boxlid_v1` bumped under the store lock, written before the row, never lowered; a lost counter seeds above every local id a record, the retired set or the ledger names. A redelivered blob maps back to its id — Signal never sees a ciphertext twice.
- `BoxInbox` (`box_inbox.dart`): journal → ack → offer, one at a time. Nothing waits unacked (16-slot window per socket): a delivery the journal could not take is held in RAM and retried by the next drain; unreadable blobs, request-queue frames (until slice (f)) and orphaned rids are acked and dropped.
- `BoxSession` subscribes every contact queue once box + store are up; drains on ready, store open, reader wired, E2E ready (`ConnectionProvider.onE2EReady`).
- The ONE dispatcher, `MessagingProvider.consumeBoxEntry` (`messaging_provider.box.dart`): I7 gate, decrypt under the local id, route on `t`, `EncryptionService.wireHeldByOther` dedup, plaintext store PROVEN by read-back (else shown from `_boxUnsaved`, cleared on fresh connect, stored on the next offer), sound only for the chat on screen (decision 11), local rows merged after the first history page.
- A local id names no server row: pin/edit/delete-for-everyone/reaction/receipt/`replyToMessageId` gated on `isServerMessageId`; delete-for-me on a LOCAL id removes this device's copy (temp ids keep their path). **Bug prevented:** `getServedMessageIds` reconciliation would have destroyed every box message within 6 h — it now skips local ids.
- Independent review (Pr31bReview) REQUEST_CHANGES, all 4 fixed test-first: local ids crowded the id-ordered raw replay cache (server and local ids capped apart, every finished box entry drops its replay row; the LRU half is owed for N+1); refused acks never retried (drain re-acks, retry timer); acks waited behind reads (separate read chain, E2E-not-ready hands back); box decrypt failures skipped the re-key policy (`decideDecryptionFailure`, `_askPeerToRekey`; no-session stays pending, drained after each history pass).
- Docs: `wire.md` (envelope `t`/`ts`, sealed body, Receive, local ids; stale "nothing reads it yet" fixed), `e2e-invariants.md` (journal + local-id bullet), root `CLAUDE.md` test count, `traps.md` (+7).

## Key files
- New: `frontend/lib/services/box/box_frame.dart`, `box_inbox.dart`, `lib/services/contacts/contact_store_inbox.dart`, `lib/providers/messaging/messaging_provider.box.dart`, `lib/utils/message_ids.dart`; their tests + `encryption_service_local_id_cache_test.dart`.
- Edited: box (`box_session`, `box_client`), `contact_store`, `sealed_web_content_kv`, `encryption_service`, `encryption_provider`, `connection_provider`, `messaging_provider{,.actions,.decrypt,.history,.send}`, `message_model`, `e2e_envelope`, `incoming_message_sound_service`, and the message widgets' server-action gates. Full list: `git show --stat`.

## Verification
- Test-first for the frame, reconcile, inbox, journal-race and review-fix tests; the envelope, journal and reader tests were written with their code and are backed by the mutation run. Suites: frame 10, envelope 20, journal 11, inbox 16, session 12, reader 19, reconcile 17, local-id cache 1. Full `flutter test`: 2459 passed, 14 skipped (clean tree, after the review fixes). Analyzer: 0 errors/warnings. Lint ratchet held at 3163 (the +1/+2 found by a per-file/per-rule diff against a temp worktree at HEAD).
- Mutants 41/41 killed on the final code; files byte-identical after the run. List: `findings.md` § PR3.1 slice (b).
- Two-instance counter race: RED with a pass-through lock, green with a serializing one (needs a slow-commit kv). Real libsignal: a 5 000-char CJK PreKey message with a link preview fits one frame.
- Browser drive (release web, peer 264): open chat, closed-chat badge, reload — box acked, 0 server rows, sealed record. Detail: `findings.md`.
- Emulator drive (Pixel_7, user 262 + peer 266): same three, force-stop + relaunch from SQLCipher. Detail: `findings.md`.
- Re-drive of the REVIEWED build (browser, peer 267): same three, and no journal or replay rows left. Detail: `findings.md`.
- NOT verified: the sound rule (decision 11) on a device — web never plays it (`kIsWeb`) and the Android drive did not observe it, so only the unit test proves it; iOS; prod (box OFF there); a real peer SENDING through app code (slice (c)). CI 7/7 green on `279a1c25` via draft PR #185.

## Notes for next session
- Next: slice (c) — send via ContactStore addresses, with a hard refusal for a body over `BoxFrame.maxSignalBytes`.
- Owed from (b): plaintext LRU / retired set / ledger still rank by id (before N+1, without per-save unsealing); a box-path re-key request rides the account socket (design I2 — an E2E control envelope before N+1); no age cap on no-session entries; the chat LIST preview/badge after a restart still comes from the server; reactions/reply/pin/edit/delete-for-everyone over E2E (the reaction bar is offered on a box message and fails); withheld entries retried on a device-list change; history-file import can collide with local ids received before it.
- Traps (+7 in `traps.md`): sync mock hides races; stuck mutant vs `diff --stat`; Python rewrites LF; server-evidence destroyers skip local ids; never leave a delivery unacked; history import vs local ids; `build web -o` fails in impellerc.
