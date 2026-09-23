# A wiped PWA shows no unreadable placeholders (Part A shipped on the branch); PR1.0 + throttler fix; lever (d) and reseal built, then dropped by the owner

**Date:** 2026-09-23 · **Version:** unchanged · **Tiers deployed:** none (owner: no deploys until the programme ends)

## What was done
- **PR1.0** `efba8a72`: `WsThrottlerGuard.getTracker` returns the user id, else `proxiedClientIp` (new `common/client-ip.ts`, shared with `HttpThrottlerGuard`; reads X-Real-IP only), else `handshake.address`. **Unasked** `77c550c9`: `@nestjs/throttler` 6.5.0 → 6.7.0, since one tracker's lapsed block froze every other client's window. **Unasked** `1cc12aa7`: a blank X-Real-IP first hop counts as absent, never as one `''` bucket.
- **Gaps 1-3:**
  - `faac4e56`: `ConnectionProvider.setProviders` wires `onOwnIdentitySinceChanged`.
  - `4a68137f`: both hidden-row shapes pinned, F61/F62.
  - `d55bfa56`: (lxxxvi) documents the chat-list preview.
- **Gap 5:** a real password login on a fresh origin, full evidence in `findings.md`.
- **G3:** the owner picked surface A. The owner also decided: the softer own-key notice, one neutral divider text, lever (d) (the corrected trade-off was accepted), Arti stays in Phase 5, "Nowa wiadomość" for unopened messages, and a one-time password prompt for sessions already logged in.
- **Owner priority, mid-session:** after a PWA cache clear, no placeholders, and live send and receive must work.
  - Reproduced live with two web clients and a CDP `Storage.clearDataForOrigin`: the list read "Wiadomość zaszyfrowana"; the contact's next message read "Nie można odczytać"; the contact got the red pill and `AccountIdentityMismatch` on send.
  - Design: `.planning/metadata-privacy/storage-loss-design.md`, Parts A/B/C, with corrections folded in.
- **Part A** `f8a81f23`, (lxxxviii):
  - `MessagingProvider.listPreviewFor` shows the stored plaintext, else "Nowa wiadomość" for an unread peer row, else nothing.
  - Post-`T` noSession/identityReset failures are hidden and not counted.
  - The divider key is now `historyNotOnThisDevice`.
- **Built, NOT committed** (all 38 files are in `.planning/metadata-privacy/wip-partB-partC-2026-09-23.zip`):
  - **Part B**, lever (d): `contact_backups."identityBlob"` (migration 0022), sealed under HKDF(PBKDF2 password key, `umbra.identity-backup.v1|<userId>`); an un-enrolled restore keeps device 1, purges its unused OTPs, and stays loud.
  - **Part C backend:** `requestSessionRebuild {messageIds}` plus `resealMessage`, gated by an outstanding grant and the origin device.

## Key files
- Edited:
  - `backend/src/chat/guards/ws-throttler.guard.ts`, `backend/src/common/http-throttler.guard.ts`, `backend/package.json` + lock;
  - `frontend/lib/providers/{connection_provider,messaging_provider}.dart`, `providers/messaging/{messaging_provider.decrypt,messaging_provider.events}.dart`, `providers/conversations_provider.dart`;
  - `frontend/lib/screens/conversations_screen.dart`, `frontend/lib/widgets/conversation_tile.dart`, `frontend/lib/utils/message_display_text.dart`, l10n;
  - `docs/design/multi-device.md` ((lxxxvi), (lxxxviii)).
- New: `backend/src/common/client-ip.ts`, `frontend/test/screens/conversations_list_preview_test.dart`, and planning docs (`g3-surface-designs.md`, `storage-loss-design.md`).
- Read only (load-bearing):
  - `key-bundles.service.ts:174-355`: restore proof; the OTP purge keeps same-identity rows;
  - `chat-key-exchange.service.ts:297-433`: every restore ran the §6.2 teardown.

## Verification
- **PR1.0:** 6/6 mutants killed; the real-socket A/B showed HEAD with one bucket and the fix with one per IP. Live `/auth/login`: 30×401 then 429.
- **Throttler bump:** the cross-client-freeze row was red on 6.5.0.
- **Blank hop:** 5 rows red first; 3 mutants killed; live, blank headers from 3 addresses no longer share a bucket.
- **Backend jest:** 1161 → 1166 / 66.
- **Gaps:** mutants M1/M2/M3 red; flutter 2309 → 2311.
- **Part A**, on a CLEAN worktree (HEAD + Part A only): flutter 2318 / 14 skipped, all passed; analyze 3163 infos, 0 errors/warnings. Mutants A-F1..A-F7 were red.
- **Part B targeted:** backend 362/362; frontend 94/94; B-F1..B-F7 mutants red.
- **Part C backend:** `src/chat src/messages` 27 suites / 662 tests, re-run by Main; 19 mutants red. Main reviewed `chat-reseal.service.ts`, `session-rebuild-requests.service.ts` and `resealEnvelopes` at the code.
- **CI:** 7/7 on `efba8a72`, `77c550c9`, `1cc12aa7` and `d55bfa56`; `f8a81f23` was pushed and is not yet checked.
- **NOT verified:** Parts B/C under full suites, the harness, and a live re-drive; iOS; prod.

## Notes for next session
- **UPDATE 2026-09-23 (later): the owner DROPPED Parts B and C** ("we dont really need this — leave A, drop B and C"). Nothing of them was committed; the worktree was reverted to `78e6719d`. The last state, incl. a new-account seal fix, is in the git-ignored `.planning/metadata-privacy/wip-partB-partC-2026-09-23.zip`. The dev DB still has the `0022_contact_backup_identity.sql` stamp from that work; PR1.1's migration is 0022 again (the runner keys on filename, so no clash).
- **Consequence, stated plainly:** a wiped linking-OFF account still re-mints; contacts get the red pill and are refused on send until they compare fingerprints. The first contact message sealed to the dead session is lost; the owner chose to SHOW it as "Nie można odczytać" rather than hide it, so Part A's A2 hide is reverted (follow-up commit).
- **Next:** the cold-start own-key self-alarm (a defect, independent of B), the softer pre-mint notice, then PR1.1.
- **Unverified claim:** "the list read 'Wiadomość zaszyfrowana' on every chat after a restart" comes from code. Observe it on a pre-change build with a stable backend.
- **Traps:** appended to `docs/agents/traps.md` (npm libc churn, dev reboot, hash-object LF, the own-key self-alarm, the peer anchor refusing a re-minted key, restore-ran-teardown).
