# Overnight hardening, 2026-11-17: ten PRs, nothing merged

**Date:** 2026-11-17 (night, owner asleep; "spawn as many agents as you like")

## What was done
- Owner asked for C1, then the next items. The lead split the open plan rows into one worktree + agent each, sent every branch through a reviewer agent, fixed every finding in new commits, ran the gates, and drove the merged result on a dedicated emulator plus a release web peer.
- **Code PRs (draft, CI 13/13 green, none merged — owner OK needed):**
  - #262 C1: link-preview image travels as a ≤6 KiB JPEG (`linkPreview.img`) inside E2E; receivers never fetch it; `imageUrl` no longer sent. Web gets `imageData` from the SSRF-safe proxy; on web the thumbnail is memory-only (localStorage quota).
  - #268 D3: `Box-Delete-Hash` at upload, `DELETE /box/media/:id` with the secret (migration 0029); only the uploading device holds the secret.
  - #261 B5: search spends ≤5 OTPs per target device per hour, then serves the signed pre-key only.
  - #263 D4: Argon2id (19 MiB, t=2, p=1, ≤2 concurrent, queue 64 → 503), bcrypt rehashed at login, failed-login backoff per (name, client /64), equal failure timing.
  - #259 E4 (#204): reaper logs WARN 50% / ERROR 80% of the open band, once per transition; missing `box_totals` row is an ERROR.
  - #260: startup sweep deletes leftover plaintext `voice_<ms>.m4a`.
  - #267 Play: `build-android.ps1 -Bundle` (pinned signer SHA-256 + 16 KB gates on the .aab), light_compressor foreground service and its permissions stripped, PEPK runbook (hybrid-signing check).
- **Design PRs (docs only):** #264 B3 (red tests, skipped) — chain confirmed, and a new finding B7: the recovery phrase reaches the server in plaintext; #265 D2 box-flood options; #266 Play policy gaps (reporting, web deletion, terms, Data safety).
- **On master (docs):** A4 done — offsite backups are R2, not B2; lifecycle ~31-32 d set in the dashboard; the VM's R2 token CAN delete (probed), bucket lock owner-owed; E5 corrected; plan rows annotated with the PRs and B7.

## Key files
- Plan: `docs/plans/2026-11-16-security-hardening.md` (B7 row new). Design docs: `docs/plans/2026-11-17-{b3-impersonation,d2-box-flood,play-policy-gaps}.md` (in their PRs).
- Worktrees: `../fireplace-{c1,d3,b5,d4,e4,voicetmp,play,b3,d2,playugc}`; drive tree `../fireplace-drive` (local branch `drive/integration`, never pushed).

## Verification
- CI 13/13 on every code PR head; docs PRs 3/3. Backend lint ratchet, no-user-logs, box-imports, knip run per backend branch.
- Signed `-Bundle` on `ac9bea27`: signer pinned `8E:9A:6B…40:5D` OK, 16 KB OK (16 libs), versionCode 20088. Staged keystore copies deleted after.
- Device drive, merged build `int-v2` (all seven code PRs), local stack, dedicated AVD `umbra_drive` (emulator-5560) + release web on :8091:
  - D4: 5 wrong passwords then "Zbyt wiele prób"; right password from another client IP 201 while the first IP gets 429; device login migrated `drvold` bcrypt → argon2id.
  - B5: 8 searches spent exactly 5 OTPs (9 → 14 used); the invite after the cap (no OTP) was accepted on web and the chat opened.
  - C1: native → web and web → native previews show the thumbnail; the web peer requested nothing from github.com or flutter.dev (its request log); the native receiver neither (emulator `-tcpdump` with Wi-Fi and private DNS off: backend traffic present, every other connection a Google/Play service, no lookup of either site); native keeps it after a force-stop; web shows the title card after reload (by design).
  - D3: photo upload row has `deleteHash`; GET 200, wrong-secret DELETE 404; delete-for-everyone → GET 404, row and file gone, web bubble removed.
  - Voice: failed voice send left `cache/voice_*.m4a`; next launch removed it (and the file_picker copy).
  - Play manifest: a 20 MB video sent untouched; a 45 MB video transcoded by light_compressor while backgrounded (~45 s, no crash) and, in the foreground, transcoded and sent.
  - E4 (local stack, server log): `msgCount=16000` gave one `[box] ceiling … (53%) ok->warn` per process, no repeats; reset to 0 gave one `warn->ok`.
- NOT verified: any real phone; the web leg of D3/B5 beyond the peer's view.

## Notes for next session
- **Owner-owed:** merge order and OK per PR; B5 budget 5/h; D3 delete on timer expiry / profile-photo replace / retry; D4 global per-account cap; B3/B7 (hold changed-identity frames with warnings off = partial B2 reversal; client-side phrase verifier with re-enrolment; phrase required to restore contacts); D2 six questions; Play policy ten questions; R2 bucket lock; app name → domain → contact email.
- Merging: every PR edits the `CLAUDE.md` §3 counts; merge one at a time and fix the count line on the next (CI verifies exact counts).
- Seen in the drive, pre-existing (no PR touches it): a failed media row vanished after HOME + relaunch (no process restart); needs a master repro.
- First photo after returning from the file picker failed (`BOX_ROUTE_UNVERIFIED`, device list not looked up on the fresh connect); 'Ponów' worked. Pre-existing, not from these PRs.
- The shared `Pixel_7` emulator is used by another project's agent (Dzwonek app); drive on `umbra_drive` instead.
