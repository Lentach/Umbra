# Strangers now befriend each other over the box: request, accept, chat, timer and goodbye leave no server row

**Date:** 2026-09-27 · **Version:** unchanged · **Tiers deployed:** none

## What was done
- Decision 4: `chat-search.service.ts` answers a friend like anyone. `FriendsProvider.searchResults` stays raw. `invitations_screen.dart` hides "add" for every known contact.
- A local chat id is `2^48 + peerUserId` (`message_ids.dart`). Every chat-keyed emit is skipped for it: read, clear, pin, delete, typing, mute, timer, session rebuild. A delete is a stored `chatHidden` mark.
- Claim-bearing frames 0x52/0x53 (`BoxFrame.carriedClaim`). `BoxInbox._intakeRequest` journals them from strangers only.
- `ContactRecord.boxOrigin` (kept frames, addresses, served bundles) and `BoxFirstContact`: keep, asked, befriend, drop, dropClaim, expired, forget.
- `messaging_provider.first_contact.dart`, the Signal half:
  - Send: E15a all-or-nothing, siblings told first.
  - Receive: kept undecrypted (E15c).
  - Accept: ONE `searchUsers`, served-IK check, then decrypt (E15d).
  - Crossing (E15f), decline (54), goodbye (E15j), timer (E15k).
  - List lookup by search (E15h, `EncryptionProvider.isBoxOnlyPeer` / `lookupBoxPeerList` / `servedBundleFor`).
- Review folds:
  - A kept frame joins the others and never renames the record (≤ 3 per device); a mismatch drops only that claim's frames.
  - No record holding an undeleted queue is ever forgotten (drop, forget, unblock, retire and end all check).
  - Box unfriend/block tells siblings first; a failure is shown to the user (`boxEndNotSynced`).
  - Local chats stay out of the server-list store write; the chat sweep is gated on server rows.
- Out-of-repo: local DB accounts `fc_ana` 350 and `fc_bob` 351 (2 devices each), plus e2e leftovers 348/349; nothing else.

## Key files
- Edited: `backend/src/chat/services/chat-search.service.ts`; frontend `providers/{conversations,friends,encryption,connection,messaging}_provider.dart`, `messaging/*.{box,decrypt,actions,history,send}.dart`, `services/box/{box_frame,box_inbox,box_session,box_friend_handoff}.dart`, `contact_record.dart`, `e2e_envelope.dart`, `invitations_screen.dart`, `user_card_screen.dart`, l10n; docs `wire.md` (Item 7), `e2e-invariants.md`, plan § Item 7, decisions 53, traps.
- New: `messaging_provider.first_contact.dart`, `box_first_contact.dart`, `local_chat_test.dart`, `box_first_contact_test.dart`, `messaging_provider_box_first_contact_test.dart`, `contact_record_box_origin_test.dart`.

## Verification
- CI: `edfe8c70` 6/7: Flutter failed on one test that ran "after completion" (an accept's handoff decrypting into the next setUp). Fixed with a draining `tearDown` in the follow-up commit; that commit's CI result is in LATEST and the baton.
- flutter test 2946 passed / 14 skipped (full run on the final tree). Dart ratchet PASS 3160 → 3158. Jest 1216/68. `flutter analyze`: 0 errors or warnings.
- `test_e2e/box_roundtrip_test.dart` with BOX_PROBE: 4/4, including the slice (f) case: search, kept request, accept via a second search, a message each way, 0 server rows.
- Mutants:
  - Pass 1, 46 mutants: 27 killed, 19 survived. All 19 now have kill tests (accept id mismatch, a pinned key vs a served one, E15a × 3, retire × 2, cap literal, hidden chat, E15f handoffs × 2, box-only lookups × 3, invitations filter × 4).
  - Pass 2 (review folds), 15 mutants: 9 killed, 6 survived. 5 now have kill tests (duplicate frame, blocked holder due, relay throw, unfriend/block keep the queue); R2a was moot, its code is gone.
  - Pass 3 (in place, final code): 5/5 killed (forget, unblock, failure report, dropClaim, drop).
- Independent review: 3 should-fix and 4 nits, all folded. The owner-class leftover is listed under Open.
- Live drive on a release web build, served on 8111–8114 (ana 1+3, bob 1+3), local stack:
  - Request from ana1; bob1 and bob2 both saw it with no photo. Accepted on bob2; chats appeared on all 4.
  - Bob2 → ana and ana2 → bob messages reached all 4. A 1-minute timer set on ana1 showed on all 4. Unfriend from bob1 removed the chat on all 4.
  - After the folds: decline on ana2 hid the request on both ana devices; a re-ask then worked with messages both ways. Block from ana2 cleared the other 3 and put bob in ana1's blocked list. Unblock worked. Re-friend and unfriend from ana1 cleared all 4.
  - `friend_requests`, `conversations` and `messages` rows for 350/351: 0 at every check.
- NOT verified: Android/iOS; the crossing (E15f) on a device (real-Signal unit test only); expiry at 30/60 d (clock tests); a failed sibling relay on a device.

## Notes for next session
- Next action: the owner answers the Open items (batch). Then plan row 8, slice (g): receipts and typing.
- Open (owner-class, batch before G5):
  - (a) Decision 53 says one lookup per accept. The code does one per tap. After a mismatch the next claimed name is shown, so a second tap does a second lookup. Confirm this, or choose "a mismatch drops the whole request".
  - (b) Frames and claims are unauthenticated. Three forged frames per device (or 50 forged requests) can crowd a real request out, as the box's own request queue already can (I3). Accept this residual, or ask for request tokens?
  - (c) A partial sibling relay on unfriend/block splits our own devices until the user retries. The user is told; nothing retries on its own.
  - Still owed from slice e: the missed-revoke residual; the E50a first-carry lookup.
- Known UI gap, not fixed (pre-existing rule): after unfriending the only chat, the initiating device shows a blank "?" chat. `chat_detail_screen` auto-pops only when other chats remain.
- Drive recipe: register via `/auth/register`; login needs `identifier`. The PWA init script (`navigator.standalone` + `matchMedia`) enables linking. Link by pasting the new device's code under "Wpisz kod ręcznie". Fresh origins 8111–8114.
- Traps → `docs/agents/traps.md`: E2E ×4, Tests ×1, Agent tooling ×1.
