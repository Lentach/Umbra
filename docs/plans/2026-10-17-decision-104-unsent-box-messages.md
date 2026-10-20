# Decision 104: keep a failed box message on the device

Owner, 2026-10-17. This amends decision 19. A box message that did not go out stays on the device: it shows red with "Ponów" after leaving the chat and after a restart. It is never resent until the user taps it, and the retry reuses its wire id.

## Why

Driven 10-17 on release web builds (0.2.66 and 0.2.67, dev stack, d101 accounts). A failed or stuck box message was lost on reload, and even on just leaving the chat; it never reached the friend (`hang1`, `r1`–`r3`). Today the row lives only in RAM (decision 19).

Confirmed in code, not driven: `_sendOverBox` stores the sender's own record only after a peer device took a frame (`messaging_provider.box.dart:2494`). A reload mid-`deliver` can therefore leave the friend with the message and the sender without it.

## Before building: the rerun

The d101 drive accounts most likely can't take a box send to d101a. d101a (user 253) holds a never-online 0.2.65 sibling, device 8, and under E101b that would make every friend's send fail red at once. [INFERENCE, unconfirmed: the diagnostics panel was not read. Step 2 confirms or refutes it.]

1. Revoke device 8 from d101a's Devices screen on origin 8091. Not by SQL: the signed list decides coverage.
2. A control send from F4 (8094) to d101a must go green.
3. Hold only the box's `send` ack: drop the incoming `43/box,…` frame and let the outgoing frame through. Reload the sender and check both sides.
4. Read the reason for every red send in Privacy & Safety → the diagnostics panel. The page console doesn't carry `BOX_*`/`SEND_*` lines.

### Rerun result (2026-10-20, release web 0.2.67 / `002fce58`, dev stack)

1. Device 8 revoked from d101a's Devices screen on 8091 (d101a's primary, #1). Live after: #1, #6.
2. Control send F4 (8094) → d101a: `ctl1` went ✓ and arrived. The 10-17 instant reds were most likely device 8 under E101b; their diag was never read, so that stays an inference.
3. With an init-script `WebSocket` subclass dropping only the incoming `43/box,` ack (one dropped: `43/box,3[{"ok":true}]`), `held1` sat on the clock; after a reload F4 showed no `held1`, d101a had it. The loss mode "the friend has it, the sender lost it" is confirmed.
4. No send went red, so there was no reason to read.

## Design (built 2026-10-20: E104a in `metadata-privacy-decisions.md`)

- **Store:** `e2e_<uid>_boxunsent_v1_<tempId>` in content kv, one key per message.
  - It holds message text, like `pendsend_v1_` (also pending-send plaintext, also sealed), not control data like `boxact_v1`. Register it:
    - the sealed-family regex `_familyKey` in `sealed_web_content_kv.dart:86` (web localStorage is otherwise unsealed);
    - `NativeContentStore.isSealedKey` (`native_content_store.dart:125-129`). Only those families are sealed under the rotating content key and shredded on removal (class doc `:29-34`, `:59-66`); anything else stays under the never-rotated SQLCipher key, so a deleted entry's words would survive as freelist/WAL residue. Make the matcher agree with the key shape: `contains('_boxunsent_v1_')` never matches a single-blob key `e2e_<uid>_boxunsent_v1`. Prefer one key per tempId (`e2e_<uid>_boxunsent_v1_<tempId>`), which also makes a removal flip `rotationPending`;
    - the logout, `clearAllKeys` and account-delete sweeps. Logout must destroy unsent rows, as it drops decision 19's RAM retry today.
  - Don't reuse `pendsend_v1_`: the old path's lost-ack reconcile consumes it (`messaging_provider.decrypt.dart:1222-1287`, keyed by ciphertext/token), and a box row there could be matched or pruned under the wrong rules.
  - Mirror `boxact_v1` (`encryption_service.dart:4184-4327`) for concurrency and bounds only: the cross-context lock plus an in-process queue, no backup, a count cap, and a 30-day prune.
- **Entry**, keyed by tempId: chat, peer, createdAt, wire id (`_sendTokenFor`), type, content, ttl, reply, and the box media fields if the attachment was uploaded.
- **Write:**
  - When a send enters the box branch: `messaging_provider.send.dart:1655-1695`, before `_boxRoute`.
  - At `BOX_RETRY_NO_ROUTE` (`:1705`).
- **Drop:** after the sent record is stored (`messaging_provider.box.dart:2494`), and when the user deletes the failed row.
- **Disappearing messages:** an entry with a `ttl` dies at `createdAt + ttl`, like the shown row (`isMessageExpired` / `_recordExpiryDeadlineMs`). Decision 41 counts the sender's copy from the send, and E18 forbids keeping a disappearing message's words. Past that point it is neither shown nor retryable, and its plaintext is gone from storage.
- **Never a sent message to anyone else:** unsent rows must stay out of every reader of local box records, above all the sibling catch-up blob (`catchUpRecords` / `_answerCatchUp`, `messaging_provider.box_sync.dart:188-195`). Also the history file, the unread seed, search and the contact backup. Keeping them out of `localMessageRecords` / `allLocalMessageRecords` (a separate family) does this naturally; check each reader anyway.
- **Restore:**
  - In `_mergeLocalBoxRows` (`messaging_provider.box.dart:1619`, which runs on every chat open and launch) as `failed` rows.
  - Re-seed `_pendingSendContent`, `_sendTokenByTempId` and `_boxTempIds`, so a retry never falls back to the old path. The box may already hold the message, and receivers drop a repeated wire id.
- **Residual:** an attachment whose upload never finished can't be retried after a restart, because its bytes are gone.
- **Found, not fixed (owner call):** `boxact_v1` holds edit text and emoji (`sealed_web_content_kv.dart:80`) but is not in `NativeContentStore.isSealedKey`, so on Android a removed parked edit's words have the same unshredded residue gap. Out of scope for 104.

## Tests to write first (red before the fix)

- A failed box message is still shown, red and retryable, after the chat is left and reopened, and after a restart (a fresh provider over the same storage).
- A retry after a restart re-seals under the same wire id (`_sendTokenByTempId` restored) and never takes the old path.
- An unsent entry past its `ttl` is neither shown nor retryable after a reload, and its key is gone.
- An unsent row never appears in `catchUpRecords`.
- On web, a value written under `boxunsent_v1` reads back as a sealed envelope.
- On Android, `isSealedKey` matches a real `boxunsent` key, and removing one flips `rotationPending`.
- Logout clears the family.

## As built: where it differs from the sketch

- API on `EncryptionService`: `saveBoxUnsent(uid, …)`, `boxUnsent(uid, chat)` (also destroys dead entries), `dropBoxUnsent(uid, …)`, `clearBoxUnsent(uid)`. The account is always passed in: the service's own user id survives logout. The cap is 200.
- The entry keeps no peer id: the retry finds the chat's peer.
- The write sits before `_boxRoute` inside the box branch, and runs again at `BOX_RETRY_NO_ROUTE`. It is skipped once the account that started the send has signed out. When the route chooses the old path, the entry is dropped without an await, so the old path's emit keeps its turns.
- The drop after a send waits for the sent record to be PROVEN stored; an unproven store keeps the entry, so the message comes back red rather than not at all.
- On chat open, an entry whose wire id a stored sent row of ours already carries (the app died between the record write and the drop) is dropped, not shown.
- Logout clears the family from `MessagingProvider.clearAll` (logout and an account switch). "Delete all local history" (`clearDecryptedContentCache`) sweeps it too.
- A restored row is `sending`, not `failed`, while this session's attempt for it is still running. A negative id is never an action target: pin and delete-for-everyone stay off, and the long-press reaction bar (shown on any failed temp row, as before 104) only answers with "reaction unavailable" (`_emitReaction` refuses a non-server id; nothing is sent).
- Deleting a red row: delete-for-me drops it on the device. The old code emitted a negative id to the server.
- `_pendingSendContent` is not re-seeded: a box send never reads it.
- Residual: a second web tab of the same account shows the other tab's in-flight send red; its retry reuses the wire id (the friend drops the repeat), but this device may store it twice.
