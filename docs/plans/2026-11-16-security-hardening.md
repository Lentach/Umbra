# Security and privacy hardening plan — native first

**Date:** 2026-11-16 · **Status:** open; A1 and A2 done (0.2.83, PRs #249/#250); A3 done (0.2.84); A5 done (0.2.85); C3, D1, D5, D6 done (0.2.86); C2 done (0.2.87); A4 hash files and the step5 archive deleted; B1 and B2 dropped by the owner · **Source:** read-only review of `master` (`a12f850e`), 2026-11-11 to 2026-11-16 (five scoped code reviews plus direct checks).

`✔` = confirmed in code or on prod by the lead reviewer. `review` = found by a scoped reviewer and not yet re-checked. Re-verify before fixing: code wins over this file.

## 0. Direction (owner, 2026-11-16)

Native apps (Android now, iOS next) become the product. **iOS is on hold (owner, 2026-11-16): no Apple Developer enrolment for now**, so iPhone users stay on the PWA and §7 cannot retire it for them until that changes. The PWA, where nearly all users are today, is frozen and retired step by step (§7). Items marked **web-only** disappear when the PWA does. Do them only if retirement slips.

## 1. Tier A — small, high value, every platform

| # | Problem | Evidence | Fix |
|---|---|---|---|
| A1 ✅ | The server reads every attachment's exact size: the 4-byte length prefix sits outside the encryption, so size rungs hide nothing | ✔ `frontend/lib/services/box/box_media_frame.dart:20`; callers `messaging_provider.box.dart:2288`, `box_sync.dart:206`, `profile_photos.dart:165` | Pad the plaintext before AES-GCM and put the length inside it. This is a wire change: receivers must read both forms for one release (shim window, see `2026-11-06-incident-0277-history-shim.md`) |
| A2 ✅ | Chat photos are sent with EXIF and GPS intact | ✔ `messaging_provider.send.dart:140-153` sends the raw file bytes; no EXIF handling anywhere in `lib/` | Strip metadata before encryption (re-encode, as `profile_photos.dart` already does). Same check for videos |
| A3 ✅ | Android writes message content to plaintext SharedPreferences when SQLCipher fails to open | ✔ `services/encryption/content_kv_opener_io.dart:95-100` (`CONTENT_STORE_FALLBACK`) | Done (0.2.84): the Android opener throws instead of opening prefs; the session runs without its store (no contacts, no E2E init, the box takes nothing) and a red line above the chat list retries the open. The field rate could not be checked first: diagnostics stay on the device and nothing reports them. iOS (not shipped) still opens prefs and needs an encrypted store before it ships |
| A4 (part ✅) | Backups outlive the stated retention | ✔ prod `~/fireplace-backups`: 8 unencrypted `user*-hash-*.txt` files (old bcrypt hashes kept to undo temp-password writes, 10-08 to 10-21). `step5-archive-20261106T153338Z/` holds the dropped pre-box tables and messages (encrypted, local only, no end date), with a copy on the owner's PC. Offsite R2 holds 32 sets, the oldest from 2026-10-16; the pruning rule lives in Cloudflare, not in the repo | Hash files shredded 2026-11-16 (owner OK, after backup `chatdb-20261116T022923Z`). The step5 archive was deleted on 2026-11-16, both copies (owner: "now"; decision 140). R2 copies from before the drop are left to expire (oldest kept about 32 days). Still open: write the R2 lifecycle rule into `backup-db.sh` docs. `docs/METADATA.md` now states backup retention |
| A5 ✅ | Some voice notes and video temp files are stored as plaintext | review: `playback_controller.dart:313-319` (fallback when the store is null), `video_temp_file_io.dart:9-16` (no startup sweep) | Done (0.2.85): a downloaded voice note is cached only sealed, else played from memory (`AudioCacheStore.writeSealed`); plain notes an older build cached are sealed in place once per launch after the store opens (`sealPlainAudioCacheFiles`), and every cache read-then-rename runs under one lock with the purge. `main()` deletes the plaintext copies left in temp and files (`sweepStalePlaintextTempFiles`): decrypted video and transcode files a killed process left, and file_picker's and image_picker's copies of picked files (found in the A5 review). A video still needs a plaintext temp file while it plays: the platform player reads a file. Not covered: a voice recording whose send failed stays in temp as `voice_*.m4a` until it is sent (the retry reads it from there), and so does one cut short by a kill |

## 2. Tier B — trust and verification (the gap to Signal)

| # | Problem | Evidence | Fix |
|---|---|---|---|
| B1 ✖ | Verification compares raw hex keys: no safety number, no QR, no lasting "verified" state | review: `encryption_service.dart:2902` | **Dropped by the owner, 2026-11-16** ("skip QR verification and lasting verified mark"). What stays: the raw-hex comparison screen; with B2 also dropped, a friend's key change shows one muted timeline line by default, so a substituted key is caught only by a user who compares keys by hand |
| B2 ✖ | A new identity key arriving in a message is accepted silently by default | ✔ `encryption_service.dart:352` (`keyChangeWarnings` defaults to `false`), `:372-393` auto-acknowledges; the red accept-and-compare pill shows only with Settings → key-change warnings ON, otherwise one muted timeline line (`peer_identity_changed_row.dart:77-80`) | **Dropped by the owner, 2026-11-16**: amendment (lxxix) stands. B1, which would have given a verified contact a blocking warning, was dropped too |
| B3 | A malicious server could likely impersonate a friend: login sends the raw password, the password unwraps the contact backup, the backup holds friends' queue addresses, and normal-queue frames skip the identity check that request and sibling queues get | review: `api_service.dart:104`, `contacts/contact_backup.dart:275-303`, `contact_record.dart:674-691`, `messaging_provider.box.dart:1086-1111`; acknowledged at `encryption/prekey_identity.dart:78-82`. Chain not run end to end | First a red-first integration test. Then apply the friend-identity check on normal queues, and stop deriving the backup wrap key from the login password (separate secret, or a password-blind login such as OPAQUE) |
| B4 | Refresh tokens never rotate, and their expiry slides out to 365 days on every use | ✔ `backend/src/auth/refresh-tokens.service.ts:9,108` | Rotate on refresh, with reuse detection that revokes the whole family |
| B5 | Every handle search consumes one of the target's one-time pre-keys | ✔ `backend/src/chat/services/chat-search.service.ts:119-126` | Hand out bundles at invite accept instead of at search, or rate-limit per target |
| B6 | Crypto library is an unaudited pure-Dart port, vendored with our patches; X3DH only, no post-quantum | ✔ `frontend/pubspec.yaml:116-123` | Long term: official libsignal through FFI (brings PQXDH). Large; schedule after native-first |

## 3. Tier C — leaks to third parties

| # | Problem | Evidence | Fix |
|---|---|---|---|
| C1 | The receiver loads a link preview's image straight from the sender's chosen host: a tracking pixel that reveals the receiver's IP and read time | ✔ `widgets/message/text_message_content.dart:191-202` | The sender fetches the image and sends it as encrypted media (what Signal does) |
| C2 ✅ | The GIF picker sends search terms and IP to Giphy, on by default | ✔ `services/gif_service.dart:34`; `deploy-web.ps1` refuses builds without the key | Done (0.2.87), opt-in chosen by the owner over a server proxy (decision 141): GIF search is OFF by default on every platform, per device (`SettingsProvider.gifSearch`, prefs `gif_search`). A GIF tap while it is off asks (`GifPickerSheet.show`: names Giphy, the searches, the previews, the picked GIF and the IP), and the picker opens only after a yes; every Giphy request starts there (search, previews, and `sendGif`'s download of the GIF picked in it); Settings → Privacy & Safety has the switch. A user who turns it on still shows Giphy their searches, the previews they load, the GIF they pick and their IP. The receiver never contacts Giphy: the sender downloads the GIF and sends it as encrypted box media |
| C3 ✅ | Google Fonts are fetched at runtime on every platform | ✔ `theme/rpg_theme.dart:332,341`, `screens/auth_screen.dart:147`; no `allowRuntimeFetching` override | Done (0.2.86): the six faces the app draws (Inter 400–800, Archivo 900) ship in `frontend/assets/google_fonts/`, byte-identical to what google_fonts fetched (sha256 checked against the package), with their OFL licences; `main()` sets `allowRuntimeFetching = false`; the unused Press Start 2P style was deleted. A weight with no file renders in the platform font; `test/flutter_test_config.dart` loads the six faces before every test file and fails the run if one is missing or misnamed. Still open, web-only: the CanvasKit engine downloads its default Roboto from fonts.gstatic.com on EVERY page load (`canvaskit/fonts.dart`: unless the FontManifest has a `Roboto` family) and Noto/emoji fallback fonts when a glyph is missing |
| C4 | **web-only:** link previews go through our server with the user's JWT, so the server sees the shared URLs | ✔ `messaging_provider.send.dart:756-761` | Retire with the PWA, or fetch through a non-authenticated path |

## 4. Tier D — server hardening

- **D1 ✅ (0.2.86), runtime dependencies (Dependabot, 2026-11-16):** `undici` (reachable via link previews) and `body-parser`/`qs` are in the production image. `proxy-addr` (critical on paper) does not apply because `trust proxy` is `1` (✔ `backend/src/main.ts:28`). Done: undici 7.30.2 (direct, `^7.30.1`), body-parser 2.4.0, qs 6.17.1, @grpc/grpc-js 1.14.7, fast-xml-parser 5.12.1, proxy-addr 2.0.8, multer 2.5.0. multer cannot be removed: it is no direct dependency since 0.2.79 but `@nestjs/platform-express` requires it, so its `overrides` floor was raised to `^2.5.0`. In-range dev fixes went in too (handlebars, fast-uri, smol-toml, brace-expansion; smoke: undici, grpc-js, moment, fast-xml-parser). Left: deepmerge (no fix published), smoke's @azure/msal-node (fix is a major, pinned by artillery).
- **D2:** an attacker with many IPs can fill the box's open band and request queues, which blocks new contacts (review: `box.constants.ts:85-110`, request queue 50 slots, drop-oldest).
- **D3:** no route deletes a box attachment, so a "delete for everyone" attachment stays downloadable for 14 days (review: `box-media.controller.ts`).
- **D4:** bcrypt cost 10 → Argon2id (already a dependency). Per-account login backoff.
- **D5 ✅ (0.2.86):** gitleaks only in the local pre-commit hook; add it to CI. Done: `.github/workflows/secrets.yml` scans the whole history on every master push and PR (docs-only too, unlike `ci.yml`); the 20 historic findings over the full history, all dead or placeholders (the one real one, a contact-inbox key in a July summary, was rotated in 10f733d1; prod's key differs, checked 2026-11-16), are fingerprinted in `.gitleaksignore`.
- **D6 ✅ (0.2.86):** dead plaintext `typing`/`recordingVoice` relay still in `chat-presence.service.ts` (review): delete it. Done: the service, its DTOs, `isUserOnline` and the client's `partnerTyping`/`partnerRecordingVoice` listeners are gone; no client since Phase 4 step 5 emitted either event.
- **D7, web-only:** the CSP is report-only (✔ `infra/nginx/security-headers.conf:133`).

## 5. Tier E — reliability before any public release

- E1: both friends restoring on new storage lose each other's messages while showing ✓ (decision 124; `traps.md`).
- E2: a newly linked device sometimes cannot send until every sibling swapped queues; cause not found (`traps.md`).
- E3: Android shows a new message 7–15 s after resuming from a 60 s background (`2026-11-10-release-0282.md`).
- E4: no warning before the box hits its global ceiling (#204).
- E5: no real-phone run since 0.2.47 and no real FCM wake-up ever verified. Triage #176 and #178.

## 6. Tier F — native distribution

- **Android:** decide Play Store or sideload, and whether Play App Signing can adopt the current keystore (`traps.md`: otherwise every installed user is stranded). Privacy policy and ToS.
- **iOS, stage 1 — Ad Hoc (what quest-api.fly.dev does, checked 2026-11-16):** a Flutter app, signed with an Ad Hoc profile listing registered iPhones, with production push. `/install` links `itms-services://?action=download-manifest&url=…/manifest.plist`; the manifest points at an `.ipa` on HTTPS storage. A new build with the same bundle id and a higher build number installs over the old one and keeps its data.
  - Needs: Apple Developer Program ($99/year), each iPhone's UDID, a Mac or macOS CI (the repo is public, so GitHub's macOS runners are free), an APNs key in Firebase for push.
  - Limit: 100 iPhones per membership year; disabling a device frees no slot; the count resets only at renewal. Each new device means a re-signed build.
  - Our `frontend/ios/` is the bare Flutter scaffold: bundle id `com.rpgchat.frontend`, no push entitlement, no Firebase config, never built.
- **iOS, stage 2 — TestFlight:** up to 10,000 external testers through a public link, no UDIDs, updates through the TestFlight app; builds expire after 90 days and need Beta App Review.
- **iOS, stage 3 — App Store.** EU Web Distribution needs company-level criteria (D&B score, listing, VC, audit, or a $1M letter of credit) and is not open to us.

## 7. PWA retirement

1. **Now:** feature freeze on web; security fixes only. Keep the existing web warning and add an "install the app" banner.
2. **Native available:** move users with the existing device-link ceremony (web primary links the native app), then retire the web device. History import exists only on Android; iOS needs it before stage 1 ends.
3. **Optional middle step:** web becomes a linked-only device (no new accounts on web).
4. **Retire** once decision 105/110's count shows users have moved. Then drop C4, D7, the web key-storage caveat and the Web Push service worker.
