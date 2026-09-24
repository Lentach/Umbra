# PR3.1 slice (c): a text to a peer the box fully covers goes over the box, and only there

**Date:** 2026-09-24 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy`)

## What was done
- Owner decisions (15)–(20) asked before any test, then routing re-decided with the owner the same day (all-or-nothing per message instead of split-per-device + a server `envelopeStatus: 'box'` marker, which would have patched 5 server read paths for throwaway N+1 code). Recorded in `.planning/metadata-privacy/task_plan.md`.
- `MessagingProvider._boxRoute` / `_sendOverBox` (`messaging_provider.box.dart`), entered from `_encryptAndSend` step 2b: a plain TEXT goes over the box only when every live device of the peer's VERIFIED list and every live other device of ours has an `outbound` address; one `BoxFrame` per peer device; SENT only when the box took every frame; any failure = failed row + ordinary retry under the same wire id.
- `BoxOutbox` (`services/box/box_outbox.dart`), implemented by `BoxSession` (addresses from the record whatever the box state, seal + `send`, local ids); `ContactStore.allocateLocalId`; `BoxFrame.fromSignalCiphertext`; `boxEnvelope` (`box_envelope.dart`) drops an oversize link preview, never the text.
- Box tempIds are pinned once a frame went out (`_boxTempIds`: no old-path retry, token kept across a same-user reconnect); in-flight box sends (`_boxInFlight`) are skipped by `markSendingMessagesFailed`; the peer list is re-verified on the first box send per connect, then ≤ every 10 min; a covered peer whose list cannot be verified FAILS the send (old path only on evidence: an unaddressed device in a verified list, or a sibling of ours) — follow-up commit, found on the re-drive.
- Own box rows restore as `sent`; composer limit `AppConstants.maxEnvelopeBytes` 45 000 → 14 000 in every chat (decision 18).
- Media, pings, replies and disappearing timers stay on the old path (the box envelope carries none yet).
- Docs: `docs/contracts/wire.md` "Send" + sealed-body limit, `frontend/docs/e2e-invariants.md` box-send invariant.

## Key files
- Edited: `frontend/lib/providers/messaging/messaging_provider.{box,send}.dart`, `messaging_provider.dart`, `connection_provider.dart`, `services/box/{box_session,box_frame}.dart`, `services/contacts/contact_store_inbox.dart`, `constants/app_constants.dart`, `utils/message_length.dart`, tests `box_session_test`, `box_frame_test`, `message_length_test`, docs above, `docs/agents/traps.md`.
- New: `frontend/lib/services/box/{box_outbox,box_envelope}.dart`, `test/providers/messaging_provider_box_send_test.dart`, `test/services/box/box_envelope_test.dart`.
- Read only: `backend/src/chat/services/chat-message.service.ts` (history `none_for_device` :670-678, push :560-572 — why no split), `encryption_provider.dart` `getVerifiedDeviceList`.

## Verification
- TDD for the slice: 6/13 send tests RED on behaviour before the route existed; frame-fit test RED at 46 214 Signal B under the old 45 000 limit, GREEN at 14 000 (real libsignal PreKey = 15 220 B ≤ 16 315; plaintext 15 072, overhead 148).
- Mutants: 33 unique (M1–M33), 30 killed; 3 survivors — M15 + M19 dead conditions, deleted (`mediaUrl == null` under the TEXT check; the store-open check before `byUserId`); M23 timing-only, accepted (an extra turn before `_boxRoute` for a box-capable peer). Files hash-identical after every run.
- Review `Pr31cReview` REQUEST_CHANGES (P1 stale cached peer list, P2 in-flight retry duplicate, P2 unbounded link preview, P3 pin before any frame) + advisor blocker (a READY-gated `addressesFor` leaked covered peers to the old path while the box was down): all fixed code-first, each proven by a new test and a killed mutant (M24–M33).
- `flutter analyze` 0 errors/warnings; lint ratchet held at 3163; full `flutter test` 2490 passed / 14 skipped (root `CLAUDE.md` count updated, `verify-claude-frontend-test-counts.mjs` OK).
- Drive 1, PRE-review build (mp stack, `BOX_ENABLED=true`): release web `localhost:8080` as alice 268 ↔ Pixel_7 AVD debug APK as bob 269, befriended over the socket, addresses traded through a throwaway `BOX_DRIVE` SharedPreferences scaffold (deleted; `box_session.dart` restored by sha256). Web → Android and Android → web: shown, single ✓, server `messages` 0, `box_msgs` unchanged (acked); web reload and Android force-stop + relaunch → both back, own rows ✓.
- Drive 2, the final code (`6b5f4e7b` + the unverified-list fix, same scaffold; alice 270 web ↔ bob 271 AVD): both directions over the box, server `messages` 0. First try at an offline send found the leak path (list fetch over a dead account socket → old path; CDP offline set on a throwaway session persisted, so the tab never came back online). Fixed build, puppeteer `setOfflineMode`: offline send → `Ponów`, 0 server rows after reconnect; the automatic timeout retry sent it once back online; bob shows it ONCE.
- CI 7/7 on `6b5f4e7b` (backend, flutter, e2e wire, isolated probes, Web Lock, CodeQL ×2).
- NOT verified: a box refusal live (queue_full — unit only), a peer linking a device mid-session live, iOS.

## Notes for next session
- Next slice: sibling queues (a sender with a second live device stays on the old path until then), then box push registration — no app code calls `challengeNotifier`/`activateNotifier`, so a box-only message wakes no closed app. Both before release N.
- Owed: a box-pinned retry whose route is gone stays failed for good; until slice (e) the first box send per connect makes a peer `getDeviceList` (names the pair to the server); a crash between the box accepting and the sent record's write loses the sender's copy; linked/revoked peer devices are seen only at the next re-verify (≤ 10 min) until slice (e).
- Traps (also in `docs/agents/traps.md`): an extra `await` before the old-path emit breaks `chat_input_bar_attachment_test`; a box route must never depend on the box being connected, nor fall to the old path on an unverifiable list; a same-user reconnect clears `_sendTokenByTempId`; CDP offline emulation belongs to its session.
