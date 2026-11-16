# Security and privacy review saved as a hardening plan; native-first direction; METADATA corrected

**Date:** 2026-11-16 · **Version:** unchanged (0.2.82) · **Tiers deployed:** none

## What was done
- Read-only review of master (`a12f850e`): message crypto, deletion and retention, media and third parties, server and infra, release readiness. Findings ranked in the new `docs/plans/2026-11-16-security-hardening.md`. Tiers: A small fixes, B trust and verification, C third-party leaks, D server, E reliability, F native distribution. Plus §7, PWA retirement.
- Owner direction (2026-11-16): native apps (Android now, iOS next) become the product; the PWA is frozen and retired step by step.
- iOS distribution researched from the owner's example, quest-api.fly.dev. Its `/install` page uses an `itms-services` manifest pointing at an `.ipa` on HTTPS storage. The app is Flutter, signed with an Ad Hoc profile for 4 registered iPhones, with production push. Limits and the TestFlight and EU options are in plan §6.
- `docs/METADATA.md`: corrected the false web key-storage claim (keys sit in `localStorage` with their unwrap key, not WebCrypto). Added the known gaps (exact media size, web link previews, preview image, Giphy, fonts), backup retention, and the password → contact-backup caveat.
- Out-of-repo: none. Prod was only read: `~/fireplace-backups` listing, R2 `rclone lsf`, row counts.

## Key files
- New: `docs/plans/2026-11-16-security-hardening.md`.
- Edited: `docs/METADATA.md`.
- Read only (load-bearing):
  - `frontend/lib/services/box/box_media_frame.dart:20`
  - `messaging_provider.send.dart:140-153,756-761`
  - `encryption_service.dart:352,372-393`
  - `encryption/signal_stores.dart:29-49`
  - `encryption/content_kv_opener_io.dart:95-100`
  - `widgets/message/text_message_content.dart:191-202`
  - `backend/src/auth/refresh-tokens.service.ts:9,108`
  - `chat/services/chat-search.service.ts:119-126`
  - `backend/src/main.ts:28`
  - `infra/nginx/security-headers.conf:133`

## Verification
- CI: NOT RUN on `a12f850e`: docs-only session, no code changed.
- Each `✔` line in the plan was checked by reading the cited code. Prod checks:
  - box state: 104 blobs, 299 queues, 87 media, 28 users;
  - the pre-box tables are gone from the live database;
  - `~/fireplace-backups` holds 27 local sets, 8 plaintext `user*-hash-*.txt` files and `step5-archive-20261106T153338Z/`;
  - R2 holds 32 sets, the oldest from 2026-10-16.
- Dependabot open alerts listed and classified by scope. Runtime alerts: undici, body-parser, qs, proxy-addr, multer, grpc-js and fast-xml-parser. proxy-addr does not apply with `trust proxy` 1. multer is unused.
- quest-api.fly.dev: `/install`, `manifest.plist` and the `.ipa`'s `embedded.mobileprovision` and `Info.plist` were read. The `.ipa` was deleted afterwards.
- NOT verified: the B3 impersonation chain (traced in code, never run); the `review` items in the plan; whether Ad Hoc OTA installs need Developer Mode (the owner installs the friend's app fine).

## Notes for next session
- Next action: owner picks the first fix. Recommended: A1 (encrypt the media length; a wire change, so receivers read both forms) and A2 (strip EXIF), then A4's backup cleanup with the owner's OK.
- Owner-owed:
  - delete the 8 hash files and set an end date for the step5 archive;
  - B2 key-change default (reverses amendment lxxix);
  - Apple Developer Program enrolment and the iPhone UDIDs;
  - Android store decision; privacy policy and ToS;
  - carried over: `backup.pass` off the VM, EN/PL release notes, the dormant contact tables, do83rman's log.
- iOS scaffold is bare: bundle id `com.rpgchat.frontend`, no push entitlement, no Firebase config, never built.
- Traps: none new.
