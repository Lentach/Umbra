# Friend handoff pass: subscribe before hand, resend to a device that talks, one durable failure line

**Date:** 2026-09-27 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only)

## What was done
- `f0e9c227` `BoxFriendHandoff._pass` (`frontend/lib/services/box/box_friend_handoff.dart`) now runs in two phases. It makes every queue first, sends ONE subscribe for the new ones, then hands them.
  - A queue whose subscribe the box has not taken (`_unsubscribed`, by rid) is never handed. Every later pass asks for it again first.
  - `rate_limited` on the subscribe stops the pass and arms the `retryAfter` retry. Before, the handoff went out before the subscribe, and a refused subscribe was only logged.
- New `BoxFriendLink.friendHeard` → `BoxSession` → `BoxFriendHandoff.friendHeard`, called after a successful decrypt in `_readBox` (box) and in the old-path decrypt (`messaging_provider.decrypt.dart`).
  - It acts when the friend device has not acked our queue, holds a `handedAt`, and was not handed this connect. It clears `handedAt[D]` (`ContactQueue.withoutHanded`) and runs `friendChanged`.
  - Once per device per box session. The 24 h gate now throttles only silent devices.
- `BOX_FRIEND_HANDOFF_FAILED` goes to the durable log once per `user:device:stage:code` per session; repeats go to the ring only. The payload field is now `code` (was `answer` / `rateLimited`).
- Test fakes gained `friendHeard`. The crossing harness `_Link` mirrors it (once per session, cleared by `restart()`).
- Docs:
  - wire.md "When";
  - decisions E20e;
  - the remainder plan E20e;
  - the traps line (`code: seal`);
  - root `CLAUDE.md` count 2814 → 2818.
- Out-of-repo:
  - local DB `fireplace-mp-db-1` keeps drive accounts 334/335 (pia/qed, abandoned) and 336/337 (rho/sig, conv with 1 `messages` row);
  - `.planning/metadata-item5/befriend.cjs` (gitignored) was kept;
  - uma 339's corrupted `key_bundles` row was deleted after the fix-3 drive (its next login republishes one); accounts 338–341 are drive leftovers;
  - `frontend/build/web` and the `%TEMP%/umbra-cx-*` profiles were deleted;
  - the web server was stopped.

## Key files
- Edited:
  - `frontend/lib/services/box/{box_friend_handoff,box_friends,box_session}.dart`
  - `frontend/lib/services/contacts/contact_record.dart`
  - `frontend/lib/providers/messaging/messaging_provider.{box,decrypt}.dart`
  - `frontend/test/services/box/box_session_friends_test.dart`
  - `frontend/test/providers/messaging_provider_box_friend{,_crossing}_test.dart`
  - `docs/contracts/wire.md`, `docs/plans/metadata-privacy-decisions.md`, `docs/plans/2026-09-25-metadata-pr31-remainder.md`, `docs/agents/traps.md`, `CLAUDE.md`
- Read only: `box_client.dart` `subscribe` (the client keeps a refused rid in its set), `e2e_persistent_diag.dart`.

## Verification
- CI: 7/7 green on `f0e9c227`.
- 4 new tests in `box_session_friends_test.dart`:
  - heard → resent at once, not while this connect's own handoff is in flight, once per session, `handedAt` re-stamped;
  - a rate-limited subscribe holds every send, then converges after `retryAfter`;
  - an outright-refused subscribe holds the queue, and the next pass subscribes it and then hands it;
  - one durable failure line over three passes.
  - All 3 fix tests were red before the code.
- Mutants: 8 of 8 killed (skip-unsubscribed, subscribe-failure-as-ok, heard `_handed` guard, heard once-per-session, no `friendChanged`, no `withoutHanded`, dedupe off, queue never held back).
- Full `flutter test`: exit 0, 2818 passed, 14 skipped. The count gate is OK. Dart lint ratchet PASS at baseline 3160.
- Live drive, release web, two Chrome profiles (offline = the tab on `about:blank`; a killed Chrome loses the web login, so pia/qed was abandoned):
  - rho 336 and sig 337 befriended while sig was offline. rho's handoff blob was deleted from `box_msgs`. With rho offline, sig handed off, and that blob was deleted too.
  - rho came back: no handoff (the gate held; 0 request-queue blobs). sig's composer showed the pending notice.
  - sig sent "sig old path 1" (old path). rho opened the chat, and its log shows, in order:
    - `DECRYPT_OK` 03:09:26;
    - `BOX_FRIEND_HANDOFF_SENT {device: 1, viaRequest: true}` 03:09:27;
    - `BOX_FRIEND_HANDOFF {acked: true}` 03:09:27.
  - Then "rho over the box" and "sig over the box" went both ways; `messages` rows stayed at 1, and sig's notice was gone.
- Fix 3 drive (same build, tau 338 / uma 339): uma's bundle signature was corrupted in `key_bundles`, so tau's session build failed. Two passes in one session: the ring logged `BOX_FRIEND_HANDOFF_FAILED {device: 1, stage: encrypt, code: no_frame}` at 03:27:56 and 03:28:37; `flutter.e2e_diag_persist_v1` held only the 03:27:56 line.
- NOT verified on a device:
  - the subscribe-before-hand ORDER (a normal pass ran it; no refused or rate-limited subscribe was provoked live);
  - Android, iOS, prod.

## Notes for next session
- Next action: slice (e), queue rotation, per `docs/plans/2026-09-25-metadata-pr31-remainder.md`.
- Owner-owed: none new.
- Carried:
  - the lost `conversationsList` store write (trap);
  - the `boxdel_v1` lost-write race;
  - reactions not ordered by `ts`;
  - `getMessages` / `markConversationRead` naming box chats;
  - the chat-list preview after a reload shows the last OLD-path message.
- Old-path messages are decrypted only when the chat opens (the chat list shows "Nowa wiadomość"), so `friendHeard` from the old path fires at chat open, not on arrival.
- Drive recipe (lost handoff), befriend script, DB queries: `.planning/metadata-item5/findings.md` § 2026-09-27 handoff-pass drive.
- Traps: offline in a drive = `about:blank`, never a killed Chrome (added to traps.md).
