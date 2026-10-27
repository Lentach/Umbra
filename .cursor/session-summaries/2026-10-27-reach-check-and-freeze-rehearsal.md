# Reach check done, PrezydentKarol deleted, E111c corrected from the backups, freeze rehearsed on staging (PASSED)

**Date:** 2026-10-27 · **Version:** unchanged (0.2.71 / `63bbc53c` on prod) · **Tiers deployed:** none (one prod data write: an account delete on the owner's word)

## What was done
- **Reach check (decision 122):** 18 of 23 friendship accounts refreshed a session after the 0.2.71 deploy; the other 5 (goonboy, Norway, alteregobob8, Morion, duchdupy) have no session since before 0.2.70, so no old tab runs and they load 0.2.71 at the next open. 0 live devices without `requestSid`. Native: goonboytest on 20071 and KucharkaZeStolicy (135, new 10-25) "working fine" by the owner's word.
- **PrezydentKarol (132) deleted** at the owner's request ("he created new one kucharkazestolicy"): backup `chatdb-20261027T145431Z.dump.gpg`, one-time password, `POST /auth/login` 201, `DELETE /users/account` 200; after: 0 rows in users/devices/tokens/key_bundles/contact_backups/fcm/web_push for 132, 26 users, 0 backend errors. Two failed attempts first (stdin swallowed by `psql`; `passwordChangedAt = now()` after the JWT `iat`) changed only his password: trap added.
- **E111c corrected (E111c-r):** the backups prove `max("createdAt")` is no write signal. `messages_id_seq.last_value` read from every kept backup: 26855 (10-13) → 26956 (10-20 17:01), flat since in every backup and on prod. 78 of the 101 ids mapped to pairs: ruchens69 (deleted) 58, benz93 ↔ bob208 8, BestiaBestia → bob208 7, SaraLee → bob208 4, R0yb3r → bob208 1. Owed before the flag: **SaraLee ↔ bob208 and BestiaBestia ↔ bob208 both ways**, counter unchanged after.
- **Backup passphrase:** it lives on the VM (`~/.config/fireplace/backup.pass`, 0600, 07-08); the owner had none off the VM. Decrypted with that file, never printed. The owner was told to copy it into his password manager himself.
- **Freeze rehearsal on staging, PASSED** (full record: plan doc §"Freeze rehearsal 10-27"). Prod compose in production mode, restored from the 10-13 backup, `LEGACY_WRITES_FROZEN=true`. Web builds of the working tree and of 0.2.61 against `:3100`. Under the freeze, with the counter flat at 26855 throughout: pre-box messages both ways (current ↔ current and current ↔ 0.2.61), a box friendship made and used, timer change, wipe + backup restore + messages, block, unfriend and account delete all took effect on both sides, and raw `sendMessage` / `sendFriendRequest` were refused `legacy_frozen`.
- Corrected the owner twice: the order is freeze → watch 1–2 weeks → step 4 server half (plan line 51), and the server half is NOT built yet (only `LEGACY_WRITES_FROZEN` exists in `backend/src`).

## Key files
- Edited: `docker-compose.staging.yml` (`LEGACY_WRITES_FROZEN: ${STAGING_LEGACY_WRITES_FROZEN:-false}`), `docs/plans/2026-10-08-friend-row-gap-check.md` (step 3 status, E111c paragraph, §"Freeze rehearsal 10-27"), `docs/plans/metadata-privacy-decisions.md` (E111c-r rewritten), `docs/agents/traps.md` (prod account delete, id sequence is the write signal, old APK cannot reach staging), this summary, LATEST, NEXT.
- Local only: `.env.staging` (origins 8301–8304/8311–8312 added; `STAGING_LEGACY_WRITES_FROZEN=false`), `%TEMP%/stg-drive/` (builds `web-cur`, `web-0261`, `stg.mjs`, `raw-oldpath.cjs`, screenshots, `accts.json`).

## Verification
- Prod (read-only SQL 10-27 14:53Z): backend/web `0.2.71 / 63bbc53c`, `LEGACY_WRITES_FROZEN=false`, `BOX_ENABLED=true`, 0 error lines in 96 h; `messages` 49 rows, `last_value` 26956.
- Staging drive: every step screenshotted in `%TEMP%/stg-drive/`; durable lines `CONTACT_BACKUP_RESTORED {count: 1}`, `BOX_ACCOUNT_GOODBYE {told: 1, missed: 0, ms: 390}`; probe output `error {"message":"legacy_frozen"}`, `friendRequestFailed … "reason":"legacy_frozen"`; `friend_requests` / `conversations` / `last_value` unchanged by the probe; 0 staging backend error lines.
- NOT verified: a native device under the freeze (no APK can reach staging); a pre-box pair with NO box route under the freeze (every rehearsal pair got a route within seconds); anything of the step 4 silence.
- No code changed beyond the staging overlay, so no suite or CI run (docs-only push).

## Notes for next session
- Next: the owner's SaraLee and BestiaBestia tests → re-read `last_value` (must stay 26956) → owner's go for the freeze (flip `docker-compose.prod.yml:95`, a reviewed commit, `./deploy-backend.sh`), no earlier than 10-30 → build the step 4 server half during the watch.
- Finding for step 5: a timer change on a pre-box chat UPDATES `conversations."disappearingTimer"` (rehearsal); the timer must leave that column before the drop.
- The worktree holds another session's uncommitted composer/attachment work (17 frontend files, a staged test rename, two traps lines): never stage it; commit with explicit paths.
- Owner-owed: the two pair tests; the passphrase copy off the VM; jarekk's backup (optional, before step 4).
