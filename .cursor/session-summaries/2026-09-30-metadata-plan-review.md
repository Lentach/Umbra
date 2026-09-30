# Plan after release N re-decided: 0.2.55 (H1 + password prompt) before any table drop

**Date:** 2026-09-30 · **Version:** unchanged (0.2.54) · **Tiers deployed:** none

## What was done
- Re-checked the rest of the metadata plan (convergence O1, PR4.1, PR4.2, Phase 5) against code and prod, then took the owner's decisions 76–84 into `docs/plans/metadata-privacy-decisions.md` (new section "Plan review after release N"; B4 → SUPERSEDED by 82; O1 → answered).
- The finding that drove it: prod held 2 of 117 `contact_backups` rows. `contact_backup_service.dart:523-527` mints only when a password is typed, and refresh sessions slide 365 d (`refresh-tokens.service.ts:9`), so O1's 09-21 condition never fills by itself.
- Decisions: 76 one-time dismissible password prompt to mint the backup; 77 drop condition (every account active in 90 d has a row AND no live device of theirs lacks a request queue; backstop 6 weeks after the 0.2.55 deploy; no version gate); 78 security-only push table survives PR4.1 (`chat-key-exchange.service.ts:763,865`); 79 no `box_media` backfill, old attachments go with the tables; 80 the stale "older version" notice (E69a) stays until N+1; 81 H1 = local content-free notification, notification problem first; 82 Arti dropped (Orbot VPN only, Tor Browser unsupported); 83 0.2.55 ships 81 + 76 before PR4.x; 84 Phase 5 keeps account-delete UX + avatar signed URLs only.
- princepolo logout, investigated: both refresh rows alive to 2027, last slide 2026-09-29 14:28 UTC, no revoke, no password change, no `[auth-session-end]` since 03:46Z; his client is Chrome web push (no `fcm_token`). No fleet-wide login bump (2 new sessions on 09-30 = the test accounts). Client-side session loss, most likely Chrome storage; unproven.
- goonboy (48) ↔ bob208 (37): 14 old-path rows 04:49–04:53Z while goonboy's device first joined the box (E69a), none after; `box_msgs` grew 3 → 14. The 04:49 WARN "REFUSED legacy send to an enrolled party" is the normal `deviceListStale` bounce and resend, not a blocked client.
- Gitignored notes pointed at 76–84: `.planning/metadata-privacy/convergence-decision.md` head, `task_plan.md` above Phase 4.
- Out-of-repo: none.

## Key files
- Edited: `docs/plans/metadata-privacy-decisions.md`, `docs/agents/traps.md`, `.cursor/session-summaries/LATEST.md`.
- Read only (load-bearing): `frontend/lib/services/contacts/contact_backup_service.dart:500-560`, `backend/src/auth/refresh-tokens.service.ts`, `backend/src/chat/services/chat-key-exchange.service.ts:763,865`, `frontend/lib/l10n/app_en.arb:183` (the notice), `infra/nginx/fireplace.conf:181` (`/box/` 32m already live).

## Verification
- CI: 6/6 `ci.yml` success on `80957c7f` (last code commit); this commit is docs-only.
- Prod, read-only psql aggregates: 117 accounts, 75 with pairing rows, 2 with a backup, 73 at risk (35 refreshed within 30 d); 116 live devices, 111 without a request queue at 04:36Z; 33 old messages with media. `curl /backup/contacts` without a token → 401 (route live).
- Log filters proven against known lines (BoxModule/BoxGateway startup lines match; every line carries ANSI codes).
- No device drive: no code changed.

## Notes for next session
- Next action: build 0.2.55's H1 first (decision 81): when a box message is journaled while the page is hidden, post a local content-free notification (web PWA; check the Android app path too). Then decision 76's prompt. Read `frontend/CLAUDE.md` and the box client (`messaging_provider.box.dart`) first.
- Decision 77's measurement: accounts active in 90 d = refresh row slid within 90 d (`expires_at - 365 d`); join `contact_backups` and `devices` (`"requestSid" is null`, `"revokedAt" is null`). Never count `messages` per day: `MessageCleanupService` deletes expired rows every minute.
- Open: princepolo — ask him when, which device/browser, whether history survived; after he logs in, a new `identity_change_audit` row confirms storage loss. Week-one watch continues (baseline in `2026-09-30-metadata-week-one-watch-day0.md`). E73b; NOT driven on a device: decision 70's re-key/`no_anchor`, typing to a partly covered friend, APK smoke items 4–7.
- PR4.1 now: no backfill (79), keep a security-only push table (78), everything else as `task_plan.md` Phase 4. PR4.2 must also wire the storage-loss screen (G2 S1) before the local store is the only copy.
- Scout caveat: helpers run in the main checkout and misread gitignored `.planning/` there (traps.md:416); two scouts claimed backups were never deployed and that `convergence-decision.md` is missing — both false.
- Traps: Owner-owed (Arti resolved; contact-backup mint) in traps.md.
