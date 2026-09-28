# Receipts and typing on box chats travel inside E2E behind one switch, and never wake a device

**Date:** 2026-09-28 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only)

## What was done
- Owner batch O24–O30 answered → decisions 56–62 (`docs/plans/metadata-privacy-decisions.md`); decision 59 carries the full slice-(e) residual (queue handoff to a possibly stolen device). Remainder plan rows 1–3, 5, 7 marked done (were stale), row 8 done.
- Backend (E61a): box `send {v, sid, blob, mode?}`; `live` is pushed only to a subscribed socket with window room, never stored/counted/woken, `{ok:true}` either way; `quiet` is stored but never schedules a notifier (send or socket-gone wake). `box-wire.ts parseSend`, `box.gateway.ts send`, `BoxDeliveryService.pushLive`, `BoxService.enqueue(quiet)`/`ridBySid`/`waitingNids`, migration `0025_box_msgs_quiet.sql`.
- Client: `BoxSendMode` through `BoxClient.send`/`deliver`; `E2eEnvelope` `rcpt {k:d|r, w:[1..100]}` / `typ {k:t|v, on}`; new `messaging_provider.box_receipts.dart` (`MessagingBoxReceipts`): delivered per drain (`BoxInbox.onReadsIdle`), read on mark-read, typing ≤ 1/5 s, shown 6 s; `_boxRoute(peerOnly:)`; own box rows keep `tick` in their record.
- Switch: `SettingsProvider.receiptsAndTyping` (pref `receipts_and_typing`, default OFF, device-local, E61c) in Privacy & Safety; en/pl ARB.
- Docs: wire.md (send verb, Item 8, envelope keys, typing bullet, local-id line), e2e-invariants slice (g) bullet, CLAUDE.md counts.
- Out-of-repo: local DB accounts `sg_ana` 352 and `sg_bob` 353 (one device each); dev backend restarted (migration 0025 applied). Nothing else.

## Key files
- Edited: `backend/src/box/{box-wire,box.gateway,box-delivery.service,box.service}.ts`, `entities/box-msg.entity.ts`, specs; frontend `services/box/{box_wire,box_client,box_outbox,box_session,box_inbox}.dart`, `providers/{settings,connection}_provider.dart`, `messaging_provider.dart`, `messaging/*.{box,send,actions,decrypt}.dart`, `utils/e2e_envelope.dart`, `screens/{privacy_safety,conversations}_screen.dart`, l10n.
- New: `backend/migrations/0025_box_msgs_quiet.sql`, `messaging_provider.box_receipts.dart`, tests `messaging_provider_box_receipts_test.dart`, `e2e_envelope_receipts_test.dart`, `settings_provider_receipts_and_typing_test.dart`.

## Verification
- CI: 7/7 success on `303de27e` (Backend tests, Flutter analyze and tests, E2E wire harness, E2E isolated probes, Web Lock probe, CodeQL, Analyze (actions)).
- flutter test 2975 passed / 14 skipped (full run on the final tree). `flutter analyze`: 0 errors/warnings. Dart ratchet PASS 3160 → 3157. Jest 1217/68. `box.int-spec` 40/40, `box-wire.spec` 13/13 (red first). ESLint `src/box` 0 errors (1 pre-existing warning, `box-push.transport.ts`). `verify-box-imports` OK.
- Mutants (client helper, in place, restored + hash-checked): 23/23 killed (switch gates both sides, throttle, 6 s show, tick persist/restore, forward-only, 100-id chunking, peerOnly, modes swapped, read-once, d-after-r, delivered collection, onReadsIdle once per batch, `mode` key presence, parser bounds, target = own messages). Review fixes: 10 more client mutants, 10/10 killed. Backend: 18 mutants, 16 killed; the 2 survivors (pushLive to a socket that does not own the rid, or to every subscriber) are killed by a new int test.
- Independent review: 2 P2s, both fixed test-first — (1) read receipts re-sent for the whole stored chat after every reload: a peer box row now keeps `tick: read` once its receipt was taken, and a receipt no device took is retried on the next show; (2) the voice indicator could stick: the sender re-sends `on` every 5 s while recording, the receiver clears it 12 s after the last `on`.
- Deflaked `messaging_provider_box_lists_test.dart` ("a stamp older than the box TTL"): an un-awaited stamp write could land after the old stamp; 1/6 red before, 10/10 green after.
- Live drive, release web of the working tree (+ throwaway always-on `_e2eFlowLog` print, reverted; `build/web` deleted), ports 8121/8122, one tab each:
  - Box-only friendship made (0 `friend_requests`/`conversations`/`messages` rows).
  - Switch OFF: sent message stayed ✓ while the peer had the chat open.
  - Both ON: opening the chat sent `rcpt` and the sender's messages turned read ✓✓; typing showed "pisze…" and cleared ~6 s later.
  - Delivered: the peer on the chat list sent `rcpt` on receipt; the sender shows ✓ — `delivered` renders as ✓ like the old path (`message_metadata_row.dart`), so the step is not visible.
  - Server: with the sender's tab closed, the reader's `rcpt` landed as ONE `box_msgs` row `quiet = t`; its typing left no row.
- Second drive, release web of `493d294c` (review fixes in): Bob read Ana's `rr1` and it turned read ✓✓ on Ana; with Ana's tab closed, Bob reloaded and reopened the chat: `box_msgs` quiet rows 0 → 0 (no read receipt re-sent).
- NOT verified: the voice-indicator refresh/expiry on a device (unit + mutant only); Android/iOS; a wake push suppressed on a device with a registered notifier (int-tested only); the mutual OFF side on a device; voice-recording indicator.

## Notes for next session
- Next action: G5 prep — plan row 10 (gate review, migration rehearsal on a device: master APK, then the branch APK over it). Every PR3.1 slice is done.
- Owner-owed: (1) turning the switch on reports as read the messages already open or read while it was off (seen in the drive: `off-1` turned read); accept or limit to messages received after it was turned on. (2) `delivered` renders the same ✓ as `sent` (the old path's look, `message_metadata_row.dart`), so decision 62's delivered tick is invisible — a distinct delivered icon, or accept. Decision 59: the 09-28 question omitted the queue-handoff clause; the log now states it for G5.
- Known UI gap (pre-existing): unfriending the only chat leaves a blank "?" chat.
- Drive recipe: register via `/auth/register`, tokens from `/auth/login` into `localStorage` `flutter.jwt_token`/`flutter.refresh_token` (JSON strings), click `flt-semantics-placeholder`. The composer often keeps only the first typed character after the textarea is focused, switch ON or OFF alike (A/B run); retry the click and type with ~700 ms between characters. Managed tabs FREEZE between turns: run send→observe inside one eval cell.
- Traps → `docs/agents/traps.md`: E2E ×1, Tests ×1, Agent tooling ×2.
