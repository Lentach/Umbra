# Box actions survive multi-device ordering and partial delivery; reaction chips take taps everywhere; typing and recording indicators no longer reach the server for box chats

**Date:** 2026-09-26 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only; prod `BOX_ENABLED: 'false'`)

## What was done
- Item 4 gap 1 (E19k, `f19af9bd`): a `react`, `pin` or `edit` whose target `(s, w)` is not held yet is parked in `e2e_<uid>_boxact_v1` (30 d, ≤ 5 000, in no backup). It is applied by the live rules once the target is proven stored (`_storeBoxMessage` → `_applyParkedBoxActions`). Before this, a sibling's copy of an action that arrived ahead of the peer's message was dropped for good.
- Item 4 gap 2 (E19l, same commit): an action reverts and shows a snackbar only when NO device took it. If at least one device took it, the action stays applied locally, and an in-RAM retry resends the same envelopes to the devices that missed them. The retry runs on box ready, then after 30 s, 2 min, 10 min and every 30 min, for up to 30 d; logout clears it.
- Reaction chips (`9a526b0c`): in `chat_message_bubble.dart` and `voice_message_content.dart`, the 14 px room above the bubble moved INSIDE the `Stack` (`Positioned(top: 0)`), so the whole chip takes taps. Pixels are unchanged.
- Typing (`9a526b0c`) and the voice-recording indicator (`2b92d7cc`): `MessagingProvider.sendTypingIndicator` / `sendRecordingVoiceIndicator` send nothing for a box-covered peer (decision 33 stopgap until item 8). The recorder now goes through the provider, and `SocketService.emitRecordingVoice` was deleted.
- Docs: `box_client.dart` comments now say that `limit` is not gone. `wire.md` has the typing/recording bullet plus the item-4 E19k/E19l text; the decision log has E19k/E19l (E19h/E19i marked superseded); the invariants and traps are updated.

## Key files
- Edited: `messaging_provider{.box_actions,.box,.send,}.dart`, `encryption_service.dart`, `encryption_provider.dart`, `chat_message_bubble.dart`, `voice_message_content.dart`, `recording_controller.dart`, `socket_service.dart`, `box_client.dart`, docs.
- New tests: `messaging_provider_box_typing_test.dart`, `chat_message_bubble_reaction_hit_test.dart`; `messaging_provider_box_actions_test.dart` extended.

## Verification
- Red before green:
  - The chip taps failed with "Found 0 widgets with text …" on text and voice bubbles; the geometry pins were already green on the old code.
  - Typing failed with `Expected: empty, Actual: ['typing']`, recording with `Actual: ['recordingVoice', 'recordingVoice']`.
  - Gaps: 11 failures on the first run.
- Pixel identity: a throwaway test rendered 5 themes × mine/theirs × text/voice, and all 20 PNGs were byte-identical between the old and the new code. The test is deleted.
- Gaps mutants: all killed except M15, the second lookup after parking, which guards a race between two queues that could not be reproduced.
- Suites: Flutter 2785/14, analyze 0 errors or warnings, lint ratchet held at 3160. CI 7/7 on `37202756`; `2b92d7cc` is pushed after that.
- Live drive on `37202756`: release web with a throwaway scaffold (since deleted), fxalice 296 with A1 and a linked A2, fxbob 297. All passed:
  - Park: A2 was offline while A1 reacted to and pinned B's message. Back online, A2 showed `BOX_ACTION_PARKED {t: pin}` and `{t: react}` before the target arrived, `boxact_v1` filled and then emptied, and the banner and ❤️ were right.
  - Partial delivery: forcing `queue_full` on A2 gave `accepted: 1`, no revert, then `BOX_ACTION_RETRY {frames: 1, accepted: 1}` at +30 s and A2 converged. With nothing accepted, the reaction reverted.
  - Chip: taps on the upper part and the middle toggled on text and voice bubbles.
  - Typing: no `typing` frame for the box peer; the uncovered peer still sent it.
- NOT verified: the reverse park path live (A2 happened to read the self-queue first and converged without parking; unit-tested); edit parking live (an edit rides its target's queue); Android and iOS.

## Notes for next session
- Next: item 5 (slice (d)). Batch its OWNER questions first (S8).
- Open, found and not fixed:
  - The tombstone store (`boxdel_v1`) has the same lost-write race the park had; it needs an in-process queue.
  - Receivers do not order reactions by `ts`, so a late retry can overwrite a newer reaction.
  - `getMessages` and `markConversationRead` still name the box chat on the account socket (read receipts belong to item 8; history reads until PR4.x).
- Residuals: retries are lost on restart (decision 19); a crash between storing a target and applying its parked actions loses those actions.
- Traps → `docs/agents/traps.md` (chip hit area; `fakeAsync` setup).
