# Android distribution decided (Play + APK, PEPK), privacy policy and terms drafted in PL+EN

**Date:** 2026-11-17 · **Version:** unchanged (0.2.88) · **Tiers deployed:** none

## What was done
- Owner decisions (ask forms, 2026-11-17):
  - Google Play, public, under a personal developer account in his name (none exists yet), plus the self-hosted APK. Play App Signing must adopt `fireplace-release.jks` through PEPK.
  - The agent drafts the privacy policy and terms in PL+EN and he reviews them; no lawyer for now.
  - Buy our own domain, but first decide whether to keep the name "Umbra".
  - He confirmed the 0.2.88 Settings footer.
- New `docs/legal/{privacy-policy,terms}.{en,pl}.md`: DRAFTS, not published. `[OWNER: …]` fields hold what only he can give: name, residence address, email, dates, contact-form retention, the Cloudflare transfer basis and the no-app deletion path. The EN privacy policy opens with a claim → source table.
- `docs/runbooks/android-release.md` "Distribution" rewritten:
  - the 2026-11-17 decision and its open list;
  - Android developer verification (2027);
  - today's `/apk/` + `UpdateAvailableBanner` channel (the "cloud link, no update path" text had been stale since 0.2.51);
  - PEPK now REQUIRED.
- `docs/METADATA.md`:
  - the Android key-storage line no longer claims a plaintext SharedPreferences fallback (A3 removed it in 0.2.84);
  - added the Docker log caps and the nginx access-log facts.
- `docs/plans/2026-11-16-security-hardening.md` Tier F Android line and `docs/agents/traps.md` (Owner-owed Android line, PEPK line) updated.
- Out-of-repo (VM, owner's OK): deleted the rotated nginx access logs from 6–19 Sep 2026 (IPs, paths); they never aged out because `notifempty` never rotated the empty live log. `/etc/logrotate.d/nginx` now says `ifempty` (backup `~/logrotate-nginx.bak.1794884265`; `logrotate -d` shows both logs rotating), so the old error logs with `client:` lines age out within 14 days. Seen, not touched: `/etc/nginx/sites-enabled/.fireplace.bak-1788229413` is not loaded (`nginx -T`; the glob skips dotfiles).

## Key files
- New: `docs/legal/privacy-policy.en.md`, `privacy-policy.pl.md`, `terms.en.md`, `terms.pl.md`.
- Edited: `docs/runbooks/android-release.md`, `docs/METADATA.md`, `docs/plans/2026-11-16-security-hardening.md`, `docs/agents/traps.md`.
- Read only (load-bearing): `docs/METADATA.md`, `frontend/lib/providers/auth_provider.dart` (deleteAccount), `frontend/lib/services/link_preview_service.dart`, `infra/nginx/fireplace.conf`, `docker-compose.prod.yml`, VM `~/fireplace-inbox/src/db.ts`, VM crontab (backup remote `fireplace-r2`).

## Verification
- CI: NOT RUN on this commit: docs-only (`.cursor/**` and `docs/**` are path-ignored). Code is unchanged since `aa45e290` (12/12).
- External facts were read from primary sources this session:
  - developer.android.com/developer-verification (guides + FAQ): 2027 global rollout, $25 full account, free limited account (20 devices), advanced flow with a 24-hour wait;
  - Play Console Help 14151465 (12 testers / 14 days, personal accounts after 2023-11-13), 13327111 (account deletion in-app + web link) and 9876937 (UGC: terms, report, block);
  - UŚUDE art. 5 and art. 8 (lexlege.pb.pl, as of 2026-11-17);
  - ignorelist.com is a FreeDNS shared domain.
- Domain checks (RDAP + DNS): `umbra.chat`, `umbra.app`, `umbrachat.com/.app/.org`, `umbramessenger.com` are taken. `umbramessenger.com` is a live "UMBRA" encrypted messenger (on-chain).
- No device drive: no code changed.

## Notes for next session
- Next action: the owner reviews the four drafts and supplies the `[OWNER: …]` fields, then the agent publishes them as static pages (`/privacy`, `/terms`; today both paths serve the app shell). Before that, the owner decides on the name, then the domain.
- Owner-owed:
  - his home address (he chose to publish it; UŚUDE art. 5), given at publication. His name is kept OUT of the public repo until then.
  - the contact email: he chose `umbra.kontakt@proton.me` and creates it himself (now in all four drafts); confirm the mailbox exists before publishing.
  - the app name (he is thinking it over); the domain follows it.
- Contact-form retention is set to 12 months in both drafts (his choice).
- Play checklist (not started): Play Console account; PEPK; `flutter build appbundle` gates; an in-app report flow (decide what a report sends); terms accepted at sign-up; a web account-deletion path; Data safety form; reviewer account; strip `light_compressor_v2`'s foreground service; closed test (12 × 14 days).
- Traps: none new (the Owner-owed Android line was rewritten in place).
