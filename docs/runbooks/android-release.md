# Android release runbook

Status: **Phase 1 (release plumbing) — DONE 2026-07-29. Phase 2 (encrypted local message store) —
DONE and ON MASTER** (verified 2026-08-04: `native_content_store.dart` etc. live in
`frontend/lib/services/encryption/`; the old `feature/android-encrypted-store` branch ref is gone —
an earlier revision of this header said "not yet merged", which was stale).
A release APK keeps decrypted plaintext, media keys, pending-send plaintext
and the JWT out of the SharedPreferences XML: content lives sealed in a SQLCipher database
(`files/fp_content.db`) and the JWT lives in Keystore-backed secure storage. **Distribution is
gated on the real-phone smoke (owner task):** voice play/seek/cached replay, push with the app
KILLED on a release-signed build, upgrade from a pre-Phase-2 install. The **`.jks` off-PC backup
is DONE (2026-09-02)** — see "Backing it up" for the fingerprints and where the copies are.
See `frontend/CLAUDE.md` §5 for the store's invariants.

**`CONTENT_KEY_CANARY_LOST` is NOT one of these gates.** `ContentKeyCanary.checkAndArm()` is
`if (!_isWeb) return;` — a no-op on native; it measures web IndexedDB+WebCrypto durability and
gates a separate web-sealing effort. It can produce no evidence about Android Keystore. What
covers Android key loss instead: no auth binding, keys co-located with the Signal identity, the
armed-gate, and `CONTENT_KEY_LOST` → retired-id rendering.

## What is enforced mechanically (do not re-implement by hand)

| Gate | Where | Failure mode it kills |
|---|---|---|
| Release packaging without a keystore **throws at execution time** (exactly `packageRelease`/`packageReleaseBundle` — covers bare `gradlew build`/`assemble`; release `signingConfig` is NULL without a keystore, so any missed path yields an inert UNSIGNED apk) | `frontend/android/app/build.gradle.kts` | silent fallback to debug signing |
| Signer check on the built APK (`apksigner verify --print-certs`; NOT keytool — minSdk 24 means v2/v3-only signatures, which keytool can't read) | `build-android.ps1` | debug-signed APK shipping anyway |
| 16KB ELF alignment of every 64-bit `.so` | `scripts/verify-apk-16k.mjs` (falsified by `verify-apk-16k.selftest.mjs`) | webcrypto pub-cache patch silently dropped → crash on Android 15 16KB devices |
| Backup lockdown | `AndroidManifest.xml` `allowBackup=false` + `res/xml/data_extraction_rules.xml` | plaintext SharedPreferences uploaded to Google Drive; secure-storage blob restored without its Keystore key (= permanently dead Signal identity) |
| versionCode monotonicity | `build-android.ps1` derives `major*1_000_000 + minor*10_000 + patch` | Play rejecting non-incrementing uploads; `+N` never enters pubspec (root CLAUDE.md §5) |

Firebase/FCM needs **no secret provisioning**: Android initializes from the committed
`google-services.json` natively (`Firebase.initializeApp()` with no options — the Dart-side
`firebase_options.dart`/`firebase_secrets.dart` placeholder files were deleted 2026-07-29; passing
their placeholder options was why a clean-checkout APK had dead push).

## One-time setup: release keystore (OWNER TASK)

The keystore IS the app's identity. **Lose it → you can never update the app for existing installs**
(users must uninstall, which destroys their local Signal keys and history). Treat it like the VM SSH key.

```powershell
cd frontend/android
mkdir keystore
# keytool ships with a JDK, which is often NOT on PATH when only Android Studio
# is installed. If `keytool` is not recognized, use Android Studio's bundled JBR:
#   & "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" ...
# (or "$env:JAVA_HOME\bin\keytool.exe" if JAVA_HOME is set).
keytool -genkeypair -v `
  -keystore keystore/fireplace-release.jks `
  -alias fireplace -keyalg RSA -keysize 4096 -validity 10000
# It prompts for: keystore password, name/org fields (values are cosmetic), key password.
# GIVE THE SAME VALUE FOR BOTH. keytool writes PKCS12, where the key password MUST equal the
# store password. A mismatch does not say so — it fails later with the opaque
# "final block not properly padded". This cost a debugging session on 2026-07-29.
copy key.properties.example key.properties
# Edit key.properties: fill storePassword/keyPassword with that SAME value; keyAlias=fireplace
# and storeFile=../keystore/fireplace-release.jks are already correct.
```

- `key.properties` and `keystore/` are gitignored (both `frontend/keystore/` and
  `frontend/android/keystore/` are covered). **Never commit either.** Verified 2026-08-02:
  neither path is tracked, and `git check-ignore -v` names the rules
  (`frontend/android/.gitignore:12`, root `.gitignore:47`).

### Backing it up (the one unrecoverable artifact) — DONE 2026-09-02

`frontend/android/keystore/fireplace-release.jks` is the app's identity. Lose it and existing
installs can never be updated again — the only path left for a user is uninstall, which destroys
their Signal keys and history. This outranks every other gate in this runbook.

**Known-good fingerprints (public-safe, record-of-truth):**

| What | SHA-256 | Meaning |
|---|---|---|
| `fireplace-release.jks` file (4430 bytes) | `9559773E3232D091F5CECB2149B8D5A1B937E2540DC2F31F6370AA8E6421052C` | every backup copy must hash to this |
| Signing certificate (alias `fireplace`, PKCS12, created 2026-07-29, valid to 2053-12-14) | `8E:9A:6B:F3:7B:58:A8:43:2C:42:D8:9E:31:99:00:7C:4A:A9:07:7E:29:7A:96:6A:2F:2C:A7:58:5C:DF:40:5D` | what `apksigner verify --print-certs` must print on every shipped APK; what Play/Firebase ask for |
| `fireplace-release.jks.enc` (4448 bytes, AES-256-CBC, PBKDF2 600k iters) | `B0FF9B2F7F412D48D772DB7CC25D0BAF5A61D47BDE0590A4A18EE2C1F7165BED` | the cloud copy; check before decrypting |

**Where the copies are (two failure domains, neither is the dev PC):**
1. Plain `.jks` + a restore `README.txt` on an external USB drive the owner keeps off-site.
   Written, cache-flushed (`Write-VolumeCache`), read back → file hash matched.
2. `fireplace-release.jks.enc` in the owner's personal cloud storage — ciphertext only; the provider
   never sees the key. Passphrase is NOT the keystore password and exists only on paper (transcription
   was PROVEN: the paper copy was typed back and decrypted the archive to the file hash above; the first
   attempt had several base64 confusables mistranscribed, which is why the round-trip check is mandatory).
3. **Passwords are on paper, hidden, separate from the USB**: the keystore/key password (also in the
   gitignored `frontend/android/key.properties` on the dev PC) and the archive passphrase.

**Restore proof done 2026-09-02:** an APK signed with the USB copy
(`apksigner sign --ks <usb>/fireplace-release.jks --ks-key-alias fireplace …`) verifies with the
certificate SHA-256 above — the backup is usable, not merely byte-identical.

**Restore recipe:**
```powershell
# from the USB: copy, then hash must equal the file SHA-256 above
Get-FileHash fireplace-release.jks -Algorithm SHA256
# from Google Drive: check the .enc hash, then decrypt (openssl ships with Git for Windows)
Get-FileHash fireplace-release.jks.enc -Algorithm SHA256
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in fireplace-release.jks.enc -out fireplace-release.jks
# then: place at frontend/android/keystore/, recreate android/key.properties from key.properties.example
# (storeFile=../keystore/fireplace-release.jks, keyAlias=fireplace, both passwords from the paper),
# build, and confirm: apksigner verify --print-certs app-release.apk  → certificate SHA-256 above
```

**Re-doing a backup (e.g. new USB):** copy → `Write-VolumeCache -DriveLetter X` → `Get-FileHash` on the
copy must equal the file hash. For a new encrypted copy: `openssl enc -aes-256-cbc -pbkdf2 -iter 600000
-salt -in fireplace-release.jks -out fireplace-release.jks.enc -pass file:<passfile>`; put the passphrase
in a local file (never in a chat/terminal history), strip CRLF (`tr -d '\r\n'`) before use, decrypt
back and hash-compare, have the paper copy typed back and verified the same way, then delete the
pass files. apksigner reads `--ks-pass file:` and `--key-pass file:` from the SAME file line by line —
write the password twice.

## Build

```powershell
# repo root, on the PC (never the VM)
.\build-android.ps1              # clean build + all gates
.\build-android.ps1 -SkipClean   # faster iteration
```

Output: `frontend/build/app/outputs/flutter-apk/app-release.apk` + SHA256 in the summary.
The script reads `GiphyApiKey` ONLY from the `GIPHY_API_KEY` env var — dot-source the config first:
`. .\deploy-web.config.ps1; $env:GIPHY_API_KEY = $GiphyApiKey; .\build-android.ps1` (there is no
embedded fallback key despite the script's warning text; empty = GIF search disabled). `BASE_URL`
defaults to production; override with `-BaseUrl` for a staging build. Requires an Android SDK with
build-tools (for `apksigner`) via `ANDROID_HOME`/`ANDROID_SDK_ROOT`/`%LOCALAPPDATA%\Android\Sdk`.

⚠️ **Since `useLegacyPackaging = true` (2026-09-14) a `--dart-define` can NO LONGER be byte-searched
in the raw APK.** `lib/<abi>/libapp.so` is now DEFLATED inside the zip, so grepping `app-release.apk`
for `fireplace.ignorelist.com` finds nothing and reads as "the define was lost" when it was not.
Extract the entry first, then search it:
`python -c "import zipfile,sys; open('libapp.so','wb').write(zipfile.ZipFile(sys.argv[1]).read('lib/arm64-v8a/libapp.so'))" <apk>`
then `grep -c fireplace.ignorelist.com libapp.so`. Everything else is unchanged: `apksigner`,
`scripts/verify-apk-16k.mjs` (it inflates), `adb install -r`, and the on-device `base.apk` hash check.

**versionCode floor — 20047 since 2026-09-14** (0.2.47 is INSTALLED on the owner's real phone,
`f849cc68`; 20043/20044/20045/20046 each held the floor on the way there). History: the first release build
(2026-09-02) was `0.1.24` from `feat/video-messages` (`1f9d96f`) → versionCode `10024`, SHA256
`743612453b44ff2a961760cb010a4dac9b87868594080517c9c1ac1a2bc40ef1`, built for the owner's phone;
`master` was still `0.1.21`, so a build from master would derive `10021` and Android would REFUSE
it as a downgrade. Every build meant to install over an existing one must bump
`frontend/pubspec.yaml` past the highest version ever installed — regardless of branch.

⛔ **`install -r` only works FORWARD, and on a linked device there is NO rollback.** Android
rejects a lower versionCode with `INSTALL_FAILED_VERSION_DOWNGRADE`; the only way to install an
older APK is `uninstall`, which is exactly the action that destroys that device's Signal keys and
SQLCipher history (root `CLAUDE.md` §6) and forces the peer safety-number confirmation on every
contact. So once a real device is on 20044, **never hand the owner an older APK to "go back"** —
every later test build must be ≥ the installed versionCode. A bad build is fixed by bumping the
patch and rolling FORWARD, never by reverting the install.

**Build record — 0.2.41, 2026-09-13 (the friends-test candidate).** `master` @ `3122cc1` →
versionCode `20041`, **105.2 MB**, SHA256
`9fdc7ef106449a32e95d83ff25ce8af2869cb7d33039412aa1022ef5adc57c10`. Signer verified
`CN=Rick Sanches`, certificate SHA-256 **matches the record-of-truth fingerprint above**
(`8e9a6b…5cdf405d`) — this APK is updatable from the USB/cloud keystore backups. 16KB gate 16/16
(incl. `libsqlcipher`, `libwebcrypto`, `libbarhopper_v3`). Universal APK: three ABIs
(`arm64-v8a`, `armeabi-v7a`, `x86_64` — the gate checks the two 64-bit ones by design). NOT yet
installed anywhere and NOT smoke-tested; the floor becomes 20041 the moment it is.
`--split-per-abi` would roughly halve the download but interacts with both the versionCode
formula and Play's monotonicity — not done, deliberately.

**Build record — 0.2.42, 2026-09-13 (SUPERSEDED by 0.2.43 below; its binary no longer exists on
the dev PC — the 0.2.43 build overwrote `app-release.apk`).** `master` @
**`633f4dd`** → versionCode `20042`, 105.2 MB, SHA256
`7818786948ca79e11674a48e4999cc291bd749ba061361a9197efca200085bf0`, same signer cert, 16KB 16/16,
CI 6/6 green on that commit. Installs and launches; footer reads `633f4dd`. Carries both arms of
the issue-#175 fix (`23be77d` route guard + local-notification latch, `fa97358` terminated-state
FCM latch) AND the per-login `onTokenRefresh` cancel (`633f4dd`).

**Build record — 0.2.43, 2026-09-14 (SUPERSEDED by 0.2.44 below — the phone was upgraded off it
the same night; this is the binary the link ceremony ran on).**
`feat/passcode-lock` @ **`aae1defe`**, which is byte-identical to `origin/master`; the code gate is
`5c91ccd6` (CI 6/6 green) and everything after it is docs-only → versionCode `20043`, 105.2 MB,
SHA256 `40f02824057d2c215ce2df762e13caaab066f57c0b262fe3f48ae1d7dedad7a4`, 16KB gate 16/16.
**Signer MEASURED, not inherited:** `apksigner verify --print-certs` → DN `CN=Rick Sanches`,
certificate SHA-256 `8e9a6bf37b58a8432c42d89e3199007c4aa9077e297a966a2f2ca7585cdf405d`, equal to
the record-of-truth fingerprint above — so the USB/cloud keystore copies can sign every future
update for this install. `build-android.ps1` itself only asserts the DN and rejects the debug cert;
the digest comparison is a manual step. Adds what the 0.2.42 binary lacks:
`sentinelDisplayText` for unreadable rows and the un-gated key-change pill. **All three
dart-defines were verified INSIDE `lib/arm64-v8a/libapp.so`** — host `fireplace.ignorelist.com`,
`GIT_COMMIT` `aae1defe`, and the 32-char Giphy key (`deploy-web.config.ps1` assigns it in SINGLE
quotes, and `build-android.ps1` dot-sources that file itself, so no env-var export is needed); a
byte search of `libapp.so` is the only proof a define survived into a release AOT build.
Staged for hand-transfer at `C:/Users/Lentach/Desktop/umbra-0.2.43-aae1defe.apk`, hash re-verified
after the copy.

**Build record — 0.2.44, 2026-09-14 (superseded by 0.2.45/0.2.46 below).** `master` @
**`c7bcee7e`**, **CI 6/6 green on that exact commit** → versionCode `20044`, 105.2 MB, SHA256
`20f46b671865ccfcfa3a28c13edf893ce34874b117d939427c1c068cc520176e`, 16KB gate 16/16, signer
MEASURED `8e9a6bf3…5cdf405d` (= record-of-truth). Built with `-SkipClean` in 167 s. Carries the
conversation-list sentinel fix: before it, a freshly linked device's ENTIRE chat list printed raw
`[encrypted]`. **Installed over 0.2.43 on the phone with `adb install -r`** — see "Field test" below.

**Build record — 0.2.45, 2026-09-14 (superseded by 0.2.46).** `master` @ **`eb455f5b`**, CI 6/6 →
versionCode `20045`, SHA256 `99e1bfdebffd81cffa921b84467fd0567b9c19d6743f5a3d123d5d6ef101519f`, signer digest
MEASURED = record-of-truth, 16KB 16/16. Two owner nits from the field test: the shell now pays the status-bar
inset ONCE (see "Field test"), and fullscreen stills/GIFs dismiss on swipe down like video.

**Build record — 0.2.46, 2026-09-14 (superseded by 0.2.47 below; still the version PROD runs).**
`master` @ **`43481643`**, CI 6/6 → versionCode `20046`, 105.2 MB, SHA256
`58ec84a96672c1aeeed73ea1467986e0a2dc0c340be6b22ffea535bc33875103`, signer digest MEASURED
`8e9a6bf3…5cdf405d`, 16KB 16/16. Moves the key-loss warning off the version footer into Privacy & Safety
(owner's call — he asked for it gone from the footer, NOT deleted; native is the one platform where it is true).
**Installed over 0.2.45 with `adb install -r`; `firstInstallTime` `2026-09-13 23:53:44` has now survived FOUR
in-place upgrades (20043 → 20044 → 20045 → 20046) on that phone.** Both prod tiers were deployed at this commit
the same night (`/version` → `0.2.46 / 43481643`, web smoke 5/5).

**Build record — 0.2.47, 2026-09-14 (superseded by 0.2.48 below; the build that PROVED
`useLegacyPackaging` on real hardware).** `feat/passcode-lock` @ **`320c11dd`**,
byte-identical to `origin/master`, **CI 6/6 success on that exact commit** → versionCode `20047`,
**48.9 MB** (was 105.2 — `useLegacyPackaging`, see "APK size" below), SHA256
`788aba471ba4af3664289a56f2e4aa2e59de19b2f0b3619f43ff346c1466fec5`. Signer DN `CN=Rick Sanches`
and certificate SHA-256 **MEASURED `8e9a6bf37b58a8432c42d89e3199007c4aa9077e297a966a2f2ca7585cdf405d`
= the record-of-truth fingerprint**, so every future update can sign over this install; 16KB gate
**16/16 on the packed APK** (the gate inflates method-8 entries, so compression does not blind it).
All three dart-defines verified in the **EXTRACTED** `lib/arm64-v8a/libapp.so` — host, `320c11dd`,
and the 32-char Giphy key — while the same search across the RAW apk bytes returns **0 hits**.
**Installed over 0.2.46 with `adb install -r`** in 6.5 s: on-device `base.apk` hashes to
`788aba47…`, `firstInstallTime` `2026-09-13 23:53:44` has now survived FIVE in-place upgrades
(20043 → 20044 → 20045 → 20046 → 20047), and the app cold-started live. Device footprint FELL
105.3 → 82.9 MiB because only the arm64 slice is extracted. Owner confirmed the keystore is backed
up in two places (cloud + paper). **NOT driven:** no UI was exercised on the phone (MIUI blocks
synthetic input, `FLAG_SECURE` blocks screencap) — the footer, an E2E round trip and a voice note
on 0.2.47 are owner-eyeball items before the APK goes to friends. Staged for hand-transfer at
`C:/Users/Lentach/Desktop/umbra-0.2.47-320c11dd.apk`, hash re-verified after the copy.

**Build record — 0.2.48, 2026-09-14 (THE FRIENDS-SHARE FILE — hand-delivered by cloud link,
awaiting the owner's device smoke).** `feat/passcode-lock` @ **`75601dc4`** (a version-bump commit
on top of `0a7031ae`; the code gate is **`1f05e3e6`, CI 6/6 green** — authorize before unlinking
media on delete-for-everyone, and the identity banner no longer sticks in the top bar) → versionCode
`20048`, **48.9 MB**, SHA256
`976106d7b3cb44d870bc8c4267e14f0966214bfa1b4d79995ce818a1cddb6e0c`. Signer DN `CN=Rick Sanches`,
16KB gate 16/16, 24 libs all deflated, all three dart-defines verified in the EXTRACTED
`lib/arm64-v8a/libapp.so`. `aapt2 dump badging` confirms `application-label:'Umbra'` and
`package: name='com.fireplace.app' versionCode='20048' versionName='0.2.48'`.
⚠️ **NOT installed anywhere and NOT smoke-tested** — the phone and the emulator were both
disconnected during the 10.5-minute build. The floor stays **20047** until it is installed, and
**0.2.47 remains the only build ever proven on real arm64 hardware.**
Staged for hand-transfer at `C:/Users/Lentach/Desktop/umbra-0.2.48.apk`, hash re-verified after the
copy; send the SHA256 with the file. A `v0.2.48` GitHub DRAFT release was created and then
**DELETED** when the owner chose the cloud link (see "Distribution" below) — there is no release and
no tag, so do NOT look for `gh release edit … --draft=false`. Friend-facing notes (Polish install
steps, the Play Protect warning, the never-uninstall rule) are kept at
`C:/Users/Lentach/Desktop/release-notes-0.2.48.md` — paste them alongside the link.
⚠️ If a release is ever wanted again: `gh release create --target <sha>` is REJECTED with
`Release.target_commitish is invalid` — pass a BRANCH name (`--target master`).

⚠️ **Two earlier 0.2.42 builds exist and must NOT be shipped.** `601248e0…` was built from a
working tree whose fix was still uncommitted, so its embedded `GIT_COMMIT` (`f35ef7b`) names a
tree WITHOUT the fix. `7c8bb2ce…` (`fa97358`) was honest but predates the listener fix. Rule:
**build from the tip of a pushed commit, and re-record the hash whenever code lands after it** —
otherwise the footer and the SHA256↔commit pairing lie to whoever is testing.

**Device drill RE-RUN on `7818786…` — 2026-09-13, PASS** (Pixel_7 AVD `emulator-5554`, prod
backend, three throwaway accounts, all deleted at the end). The earlier run was on `601248e0…`.
**Identity of the binary under test was PROVEN by hash, not by the version string** — three
0.2.42 builds exist and all report `versionName 0.2.42 / versionCode 20042`, so the footer and
`dumpsys package` cannot tell them apart:
`adb shell sha256sum "$(adb shell pm path com.fireplace.app | sed 's/^package://')"` →
`7818786948ca…`, equal to the recorded shippable hash. Nothing was reinstalled mid-drill, and
`pm clear` wipes data, not the APK. Driven over `uiautomator` + `adb input`.

| Leg | Result |
|---|---|
| Push wakes a KILLED app (`am kill`, never force-stop) | **PASS — 3.16 s and 3.29 s** in two independent runs, measured as the notification record's `when=` minus the send click on the DEVICE clock; FCM cold-started a NEW process each time (`ActivityManager: Start proc … for broadcast` +2.73/+2.81 s, `FLTFireMsgReceiver: broadcast received` +2.88/+2.95 s) |
| Notification tap → right chat | **PASS** — tap on the shade entry ("Umbra / You have a new message") opened the correct conversation in the FCM-woken process. ⚠️ Only ONE conversation existed this run, so "the RIGHT chat" is weakly discriminating here; the multi-conversation proof stands from the 0.2.41 run |
| notification-tap → logout → login-as-enrolled → link gate | **PASS** — password-only login as an enrolled account landed on `Połącz to urządzenie` with **nothing rendered over it**, in the SAME process (pid 11694) that had consumed the tap |
| Gate's own scanner survives the sweep | **PASS** — `Zeskanuj kod` opened and was still up after 27 s (the `kLinkScanRouteName` carve-out holds) |

**Reproducing the gate needs a device with NO local identity for that account — `pm clear`, not
logout.** Logging out and immediately logging back in with the password lands in the normal shell:
the account's identity keys survive logout on that device, so the §6.1 lock has nothing to refuse.
Only the true fresh-install state (what a friend's phone is in) reaches the gate.

Two flow facts this run pinned down, both un-recorded before:
- **Enabling linking forces a recovery phrase first** — `Włącz łączenie` routes to the recovery-key
  screen with NO "Później" escape, and the 12 words + a word challenge must be completed before the
  device becomes primary. Budget for it when writing user instructions.
- **A keyless login RE-MINTS the identity on an UN-ENROLLED account** — diag logs
  `IDENTITY_GUARD_UNLOCKED_REMINT` + `IDENTITY_MINTED {reason: server-bundle-unlocked-remint}` +
  `OWN_IDENTITY_REPLACED`. This is the identity-bootstrap guard
  (`encryption_service.dart:1201-1208`), NOT a property of the door: an ENROLLED account hits
  `:1166` instead and gets `E2eIdentityIncompleteException` → the gate. Observed here via "Nie
  pamiętam hasła", which is why that door looked like the cause; **the phrase door is a
  password-recovery door and does not restore keys** — the gate's `linkGateRestoreAction` is the
  separate key-restore path. Not tested: the phrase door against an ENROLLED keyless device.

**Release builds cannot be screenshotted** — `MainActivity.kt` sets `FLAG_SECURE` when not
debuggable, so `screencap` returns rc=1 while the app window is live (even from recents). Verify
release behavior via logcat, the prod DB, and the notification shade with the app dead.

## Device smoke checklist (before any distribution)

Build from a **fresh clone** at least once (proves no local-only file is load-bearing), then on a real device:

1. Install APK, register/login → conversations load.
2. E2E round trip with a PWA peer: PreKey (`3:`) first message, whisper (`2:`) replies, both directions decrypt.
3. **Push with the app killed** (data-only FCM → local notification, tap opens the right chat). This
   specifically validates the no-options Firebase init from `google-services.json`.
   ⚠️ "Killed" = swipe away from recents or `adb shell am kill <pkg>` — **never `am force-stop`**:
   force-stop puts the package in Android's *stopped state*, in which the OS drops every FCM message
   until the user launches the app again. A force-stopped app receiving nothing is not a push bug.
4. Voice note record + playback; image send/receive (validates the 16KB-patched webcrypto at runtime).
5. Delete-for-everyone + expiry: plaintext purged locally (Privacy & Safety diags clean).
6. **Link ceremony on the release build** (the instructions we ship — see "User wording"):
   primary (INSTALLED PWA) enables linking → APK logs in → `DeviceLinkGateScreen` → either side
   displays its code and the other scans/types it → the same **6-digit** code on both screens →
   **approve on the primary**. Then: a send from the phone self-syncs to the primary, and
   revoking the phone from the primary kicks it.
7. **Un-enrolled flip-flop drill** (the hazard the wording steers users away from): on an account
   that never enabled linking, log in on APK + PWA and force reconnects on both → identity thrash
   (peers see repeated identity-changed notices). Log OUT of the PWA → epochs stabilize, E2E round
   trip recovers. Ship no instruction we have not watched fail and recover.

**Emulator pre-smoke of the first release build (2026-09-02, Pixel_7 AVD, prod backend):** items 1
and 3 PASS on the release-signed, R8-minified APK — fresh account registered on prod, `fcm_token` row
written, process killed with `am kill`, a web→APK message woke a NEW process
(`FLTFireMsgReceiver: broadcast received for message` → background engine → local notification),
shade shows "Umbra / You have a new message" with the hex icon, tap cold-starts `MainActivity`.
Screenshots (gitignored): `.planning/push-release-shade.png`, `.planning/push-release-statusbar.png`.
Items 2, 4, 5, 6 and "tap opens the RIGHT chat" remain for the real phone (release screenshots are
impossible, see `FLAG_SECURE` above).

**Emulator smoke of the 0.2.41 build (2026-09-13, Pixel_7 AVD `emulator-5554`, prod backend,
driven over `uiautomator` + `adb input` because `FLAG_SECURE` blocks `screencap`):**

| # | Item | Result |
|---|---|---|
| 1 | install → register → shell | **PASS** — `apkeae3#4259` registered on prod; recovery phrase offered right after registration ((lxxxiii)), generated + word-3 challenge passed |
| 2 | E2E round trip with a web peer | **PASS** — APK→web PreKey leg and web→APK whisper leg both decrypted |
| 3 | push with the app KILLED (`am kill`) | **PASS** — notification `conversation-129` within 5 s; "Umbra / You have a new message"; **tap cold-started into the RIGHT chat** (the leg left open on 2026-09-02) |
| 6 | link ceremony | **PASS** — SAS `334 092` matched; `android · #2` committed; gate closed; **self-sync proven** (phone→primary own-message); the primary's own history stayed decryptable throughout |
| 4, 5, 7 | voice/image, delete-for-everyone, un-enrolled drill | **NOT RUN** |

Incidental but load-bearing: after `am kill`, the cold start rendered previously-decrypted
plaintext — the SQLCipher store + Keystore content keys work on a real device, not just in tests.
**Two defects found, see "User wording" state 1 and `docs/agents/traps.md`:** the link gate can be
covered by a route pushed after the verdict, and a pending notification deep-link survived a
logout→login in the SAME process and was consumed by the NEXT account.

**Emulator pre-flight of the 0.2.43 build (2026-09-13, Pixel_7 AVD, prod backend
`0.2.41/49c77c10`) — PASS, and it doubles as the UPGRADE-PATH proof:**

| Leg | Result |
|---|---|
| `adb install -r` over the install already on the AVD — a REAL versionCode bump 20042 → 20043 | **PASS** — `Success`; `firstInstallTime=2026-09-13 01:28:30` (predates this session and matches the overnight `7818786…` drill install, so the outgoing build was 0.2.42/20042 — inferred from the timestamp, not measured before the overwrite) stayed put while only `lastUpdateTime` moved; on-device `base.apk` then hashes to `40f02824…`, the identity check the version string cannot give |
| boot | **PASS** — auth screen, footer commit `aae1defe` |
| register on prod → shell | **PASS** — `updtest0913#7416`; the recovery phrase is offered right after registration ((lxxxiii)), skipped with "Później" |
| **`adb install -r` AGAIN, over the LOGGED-IN install** | **PASS — nothing lost.** The relaunch went straight to Czaty (no auth screen: the JWT in Keystore-backed storage survived) and server-side the identity key stayed byte-identical (`BUOpbmrldsbm50zt…`) with `identity_change_audit` still EMPTY — a patch install is invisible to peers: no re-link, no safety-number confirmation |
| footer after the upgrade | **PASS** — `0.2.43 · aae1defe · 2026-09-13T20:21:41Z` |

Throwaway `updtest0913` was deleted in-app (password-confirmed dialog) and its `users`,
`key_bundles` and `devices` rows are gone. NOT covered — every leg needing a second human device:
E2E round trip, push-with-app-killed, voice/image, and the LINK ceremony (checklist items 2-7).

**First command on the owner's REAL phone, before any claim about its state:**
`adb shell dumpsys package com.fireplace.app | grep -E "versionCode|firstInstallTime"`. An empty
`fcm_token` for the account proves only that no LIVE push registration exists — not that the app is
absent — and the 0.1.24 build (versionCode `10024`, 2026-09-02) was made FOR that phone. Three
outcomes, three different flows:

- nothing installed → clean first install; the account is enrolled, so login lands on the link gate.
- `10024` present, not logged into the account → plain in-place upgrade, then the gate as above.
- `10024` present AND logged in as the account → **that install already IS a live device** (it would
  be the `platform = legacy` row in `devices`), so `install -r` upgrades it in place and **no link
  ceremony is needed at all**.

**This is NOT the untested "pre-Phase-2 install" upgrade gate** named in this runbook's header:
`native_content_store.dart` landed in `33a906f4` (2026-07-29), so the 0.1.24 tree (`1f9d96f`,
2026-09-02) already carried the SQLCipher store, and `content_db.dart` reads `schemaVersion => 1`
in BOTH trees — no Drift migration crosses a 10024 → 20043 upgrade. **Answered on the night of
2026-09-14: the phone had NOTHING installed** (`Unable to find package: com.fireplace.app`), so
0.1.24 never lived there and this was a clean first install.

## Field test — the owner's real phone, 2026-09-14 (account `bob208`)

Mi 11 Lite 5G (`M2101K9G` / renoir_eea, Android 11, arm64-v8a), adb serial `f849cc68`, against prod
(`0.2.41 / 49c77c10`). The owner drove every tap: **MIUI refuses synthetic input** —
`adb shell input` dies with `SecurityException: Injecting to another application requires
INJECT_EVENTS permission` unless the Mi-account-gated "USB debugging (Security settings)" is on.
`adb install` worked (plain "Install via USB" was enough). The agent observed via logcat, the a11y
tree and the prod DB.

| Leg | Result |
|---|---|
| clean install of 0.2.43 | **PASS** — on-device `base.apk` hashes to `40f02824…`; `versionName 0.2.43 / versionCode 20043`; COLD start 1.34 s; footer `aae1defe` |
| login as an ENROLLED account → §6.1 lock | **PASS on real hardware** — logcat `[EncryptionService] Identity incomplete — refusing to regenerate` + `E2eIdentityIncompleteException`, and `DeviceLinkGateScreen` rendered |
| link ceremony | **PASS** — `devices` row `deviceId=11, platform=android`, un-revoked; its key bundle carries the SAME account identity key (`BQLKjKiYsGSO…`) as devices 1 and 5, and `identity_change_audit` stayed EMPTY — linking JOINS the identity, it never replaces it |
| pre-link history | **PASS by design** — the thread shows the `historyBeforeDeviceLinked` pill (lxxxi). The conversation LIST did not: it printed raw `[encrypted]`, fixed in 0.2.44 |
| E2E round trip | **PASS** — text and voice both directions (`24385` in, `24386`/`24387` out) |
| self-sync | **PASS** — the phone's sends fan out to `37:1` and `37:5`; the owner saw AND heard them on his iOS PWA primary |
| **in-place upgrade 20043 → 20044** | **PASS — the update path, on real hardware.** `adb install -r` → `Success`; `firstInstallTime` PRESERVED while `lastUpdateTime` moved; `base.apk` now `20f46b67…`; device #11 `lastSeenAt` advanced **43 s later with no login**, key bundle re-uploaded with the same identity key, `identity_change_audit` still 0 |
| **push with the app KILLED, on 0.2.44** (item 3) | **PASS — 3.54 s to process start, 3.65 s to the receiver.** `am kill` only reaps BACKGROUND processes, so the app was first sent behind the launcher (`am start -c android.intent.category.HOME`) and the test gated on `pidof` returning EMPTY. Peer sent at server `23:01:51.931Z`; logcat `Start proc 26446 … FlutterFirebaseMessagingReceiver caller=com.google.android.gms` at device `23:01:54.887` and `FLTFireMsgReceiver: broadcast received` at `23:01:54.996`, with the device clock measured **585 ms behind** the server and corrected for. **The tap opened the RIGHT chat and the message decrypted.** Pairing proven sound: no other message exists between 23:00:00 and 23:01:50, so nothing else could have woken the process |
| **image send/receive, plus an unplanned VIDEO** (item 5) | **PASS for images — the 16KB-patched `libwebcrypto.so` works at runtime on a real ARM device**, which no emulator run had ever shown. Phone → peer IMAGE `24390` (envelopes `37:1 37:5 75:1`) and peer → phone IMAGE `24392` (`37:1 37:5 37:11`): the owner confirmed images work, so encrypt-on-send AND decrypt-on-receive are both exercised. VIDEO `24391` (peer → phone) also arrived with a `mediaUrl` and envelopes for device #11, but **its rendering was never separately confirmed** — the owner was answering an images-only instruction and the follow-up screen dump caught a notification shade, not the thread. Treat video as arrived-but-unverified |
| **disappearing-message expiry** (item 5, second half) | **PASS end-to-end — and the "it didn't disappear" report was correct behaviour, not a defect.** The timer is **read-triggered**: the row is created with `expiresAt: null` + `disappearAfterSeconds` (`chat-message.service.ts:346, 446`) and `expiresAt = now + ttl` is stamped only in the READ handler (`messages.service.ts:811-813`). The owner's two 60 s rows (`24393`, `24394`) therefore sat at `DELIVERED` with `expiresAt` NULL for SEVEN MINUTES while the peer had not opened the thread — a send-time countdown would burn down in the recipient's pocket, so this is by design. Backstop for a never-read row: `createdAt + DISAPPEARING_MAX_UNREAD_SECONDS` = **1 day** (`disappearing.constants.ts:8`). Once he read them the clock armed and an `EVERY_MINUTE` cron HARD-deleted both, media unlinked first (`message-cleanup.service.ts:39-99`): **`select count(*) … where id in (24393,24394)` → 0** and `max(id)` fell back to 24392. Real `repository.remove()`, not a display filter. **Never report "it didn't disappear" without reading `expiresAt` first.** |

Two things this run could not do and the next one should plan for: **release builds cannot be
screenshotted** (`FLAG_SECURE`) so the owner cannot send a screenshot either — he photographs the
screen or describes it; and with input injection blocked, every tap is the owner's, so batch the
instructions instead of driving step by step.

**The "0 s voice note" is CLOSED — not a defect.** The label is `position/duration`, and the a11y
tree after the push test reads `0:00/0:11` for the inbound 11 s note (plus `0:00/0:06` and
`0:00/0:04` for the owner's own sends): the duration was always correct and the leading `0:00` is
the PLAYBACK POSITION before play is pressed. Keep this in mind when a user reports a "0 second"
clip — ask what the whole label said. (The earlier hypothesis about the loopback-proxied
`just_audio` source reporting an unknown duration was never needed; the metadata fallback at
`playback_controller.dart:78-84` was doing its job all along.) Incidental, and worth knowing before
diagnosing a "vanishing" message in that thread: it has **disappearing messages ON at 2 days**.

## Distribution — SETTLED 2026-09-14 by the owner: a PLAIN CLOUD LINK, not GitHub Releases

- **Hand the APK over as a direct file/cloud link (Drive, Telegram, …). NOT a GitHub Release.**
  The owner was asked and chose this over three alternatives, because a release on a PUBLIC repo is
  world-downloadable and **registration against prod is open** — the APK is not the gate,
  REGISTRATION is, and "friends" is not the same audience as "anyone who finds the repo".
  The alternatives and what they cost, so this is not re-litigated from scratch:
  (a) public release + open registration — one permanent link and Obtainium auto-update, but
  anyone can join; (b) private-repo releases — friends each need a GitHub account and repo access;
  (c) **plain cloud link — CHOSEN**; (d) public release + a server-side invite gate on registration,
  the only option that separates "can install" from "can join", but that is backend work nobody has
  scheduled. Revisit (d) if the user base ever outgrows hand-delivery.
- **The cost of (c), stated plainly: there is NO auto-update path.** Obtainium needs a release feed,
  so every update means the owner re-sends the file and each friend taps it. Budget for that, and
  keep the version list below current so a friend can be told what they should be on.
- **Name it `umbra-<version>.apk`.** The repo is now `Lentach/Umbra` (renamed from `Fireplace`
  2026-09-14, on the owner's call, BEFORE anything was published — so no redirect behaviour is being
  relied on; GitHub redirects the old URL and `gh api repos/Lentach/Fireplace` still resolves, but
  nothing depends on it). `applicationId` remains **`com.fireplace.app`** and can NEVER change:
  Android identifies the app by it, so a rename would be a different app and every friend would have
  to uninstall, destroying their keys and history. The only name a friend ever sees is **Umbra**
  (`aapt2 dump badging` → `application-label:'Umbra'`).
- **No GitHub release has ever been published.** A `v0.2.48` DRAFT was created and then DELETED when
  the owner chose the cloud link; `git ls-remote --tags` shows no `v*` tag, because a draft release
  never creates one. `gh release list` is empty — which also keeps the Play App Signing PEPK door
  open (see the trap about a Google-generated cert).
- **Give friends the SHA256 with the file** so a re-download can be verified, and keep recording
  every shipped hash in the build records above — that is the only way to tell two same-version
  binaries apart.
- **Updating a sideload is NOT a reinstall-from-scratch — MEASURED 2026-09-13 (pre-flight above).**
  A newer APK installed OVER the old one (`adb install -r <apk>`, or the user taps the downloaded
  file) keeps session, Signal identity, SQLCipher history and content keys, and leaves
  `identity_change_audit` empty, so no peer is asked to confirm a safety number. What destroys data
  is `uninstall`, "Clear storage" and `pm clear` — drill tools for reproducing a fresh install,
  never an update step. **Updates are FORWARD-ONLY:** versionCode must rise (bump
  `frontend/pubspec.yaml`), Android answers a lower one with `INSTALL_FAILED_VERSION_DOWNGRADE`,
  and the only way past that is `uninstall` — i.e. there is no rollback on a real device, only
  another bump. See the ⛔ note under "versionCode floor".
- **No auto-update exists for sideloads, and the CHOSEN route has none at all** — with a plain cloud
  link the owner re-sends the file and each friend taps it, every time. That is the accepted cost of
  the 2026-09-14 decision above, not an oversight. The alternatives, cheapest first, ALL require
  abandoning or supplementing the cloud link: Obtainium (zero app code, each user installs it once,
  but it needs a **release feed** — i.e. GitHub Releases, which was declined for exposure reasons,
  so it would only work on a PRIVATE repo the friends are invited to); a self-hosted manifest +
  in-app "update available" banner (the JSON and APK must live OUTSIDE `frontend-build`, which every
  `deploy-web.ps1` deletes — an `android-dist/` nginx alias beside `landing-build/` — plus
  `REQUEST_INSTALL_PACKAGES` for a one-tap install; this is the only option that keeps distribution
  entirely in our hands); or a Play internal-testing track (real silent updates, but the whole Play
  gate list below applies).
- Play Store later: needs `flutter build appbundle` — and the signer + 16KB gates must move onto the
  BUNDLE's output, because `build-android.ps1` only ever inspects an APK — plus a privacy policy,
  the data-safety form, and an in-app report path (UGC policy); 16KB + targetSdk are already met.
- ⛔ **The signing certificate is a one-way door, and the trigger is a USER INSTALL — not a
  published release.** The old wording tied the deadline to "`gh release list` empty", which under
  the cloud-link decision above is unreachable: there will never be a release, so that test would
  read "still open" forever. What actually matters: any device holding an APK signed with THIS
  keystore can only take a Play update if Play App Signing ADOPTED this keystore via PEPK. Let
  Google generate its own key instead and those installs are refused (different cert) with uninstall
  as the only path — which destroys that user's Signal identity and local history.
  **Status: the door is ALREADY partly shut.** The owner's phone has been running builds signed with
  this key since 0.2.43, and he can wipe his own device; **friends cannot be asked to.** So this is a
  decision owed BEFORE `umbra-0.2.48.apk` is sent to anyone, not after: either commit to PEPK
  adoption if Play is ever wanted, or accept sideload-forever for everyone who installs from now on.
  Rotation later does not repair already-installed sideloads.
- **Foreground-service declaration (Play only, and avoidable).** `light_compressor_v2-1.9.1`'s
  library manifest merges `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` and a
  `CompressionForegroundService` (`foregroundServiceType="dataSync"`) into our APK
  unconditionally. At targetSdk 34+ Play then requires an App-content declaration for that type:
  use-case description, user impact, **and a link to a demo video showing the user steps that
  trigger it** — a mismatch is a rejection. **We never start that service**: `transcodeVideoToFit`
  (`frontend/lib/utils/video_transcode_io.dart:37-56`) passes no `BackgroundConfig`, which is the
  plugin's opt-in for background execution. So the honest options are (a) strip the service and
  both permissions with `tools:node="remove"` in our manifest and re-verify against the MERGED
  manifest, or (b) file a declaration plus a video for a service that cannot run. Prefer (a).
  Unrelated but recorded from the same README: that plugin needs no R8/ProGuard keep rules.
- **The permission set Play sees is the MERGED one — MEASURED 2026-09-13, not inferred.** Generate
  it with `cd frontend/android && sh ./gradlew :app:processReleaseManifest` (~2.5 min, needs NO
  keystore — the signing gate fires at `packageRelease`), then read
  `frontend/build/app/intermediates/merged_manifest/release/outputReleaseAppLinkSettings/AndroidManifest.xml`.
  Exactly nine `uses-permission` entries: `INTERNET`, `POST_NOTIFICATIONS`, `CAMERA` (ours),
  `RECORD_AUDIO` (record_android), `VIBRATE` (flutter_local_notifications), `WAKE_LOCK` +
  `ACCESS_NETWORK_STATE` (firebase_messaging), `FOREGROUND_SERVICE` +
  `FOREGROUND_SERVICE_DATA_SYNC` (light_compressor_v2, with its
  `foregroundServiceType="dataSync"` service at line 237). `BIND_JOB_SERVICE`/`DUMP` appear only
  as `android:permission` attributes on Google services — they are NOT requested permissions.
  **No `READ_MEDIA_*`/`READ_EXTERNAL_STORAGE`** (image_picker/file_picker declare none), so Play's
  Photo and Video Permissions policy does not apply. Re-measure after any plugin bump.

## User wording (APK) — rewritten 2026-09-13: LINK THE DEVICE, never a new account

**Multi-device is LIVE on prod** (verified 2026-09-13: `/version` → `0.2.41 / 49c77c10`,
`/version.json` → `0.2.41 / 9d13d25`; `git merge-base --is-ancestor 2c553b2 <each>` passes for the
PR #144 merge). The previous "NEW ACCOUNTS ONLY / one account works on one device" text was written
while #144 was merged-but-undeployed and is now simply false.

The model (`docs/design/multi-device.md` §1, §5.1, §8): one account = **1 primary + up to 2 linked
= 3 concurrent devices**; adding one REQUIRES physical possession of the primary (QR + SAS word
comparison; the QR is a link step, never a credential — I3). **Logging in does not create a
device**: `resolveLoginDeviceId` (`backend/src/auth/auth.service.ts:158`) hands a fresh install the
LIVE PRIMARY's id.

Two starting states, and they do NOT behave the same:

1. **Account already enrolled** (linked devices enabled on the primary): the §6.1 registration lock
   refuses a password-only identity replacement — device-proven 2026-09-13, logcat reads
   `[EncryptionService] Identity incomplete — refusing to regenerate` — and `AuthGate` renders
   `DeviceLinkGateScreen` (`frontend/lib/screens/device_link_gate_screen.dart:24-35`).
   **The gate used to be COVERABLE — FIXED in 0.2.42 (`23be77d`, issue #175).** On 0.2.41 a route
   pushed AFTER the verdict rendered on top (`MainShell` keeps BUILDING under `Offstage`, and its
   pending-notification consumer replayed the previous account's tap), so the user met a keyless
   `[encrypted]` shell and had to press Back. Now `DeviceLinkGateRouteGuard` removes page routes
   pushed while gated, and the cold-start tap is delivered once per process. Re-verified on the
   0.2.42 APK: the same sequence lands on the gate, and the gate's own scanner still opens.
2. **Account NOT enrolled** (linking never enabled) — **the re-mint is device-proven (a `pm clear`
   install logged in with no gate), but the FLIP-FLOP itself is still INFERENCE, never
   exercised:** §6.1 is not armed (§8, amendment
   (lxxiii)), so the phone re-mints the identity **into the primary slot** — and because every
   client
   re-uploads its key bundle on EVERY socket connect (`encryption_provider.dart`), two live devices
   then clobber each other's identity epoch on every reconnect: a permanent flip-flop that burns
   both sides' prekeys and spams identity notices. **Enable linking on the web FIRST, then link the
   phone.** Never install-and-log-in on an un-enrolled account while the PWA is still live.
   **A recovery phrase does NOT protect an un-enrolled account** (device-proven 2026-09-13): with
   12 words saved but linking off, `pm clear` → log in re-mints silently
   (`Generating new keys (fresh install)`) and never offers the restore door. The phrase becomes
   usable only once linking is on, because the door lives on the device-link gate.
   **And the peer does not merely see a muted note:** the "nowe urządzenie — klucze
   zaktualizowane" line is only half of it — their next send hard-fails with
   `AccountIdentityMismatch` until they confirm the new safety number (full account in
   § "What a reinstall / Clear storage costs" below).

History does NOT transfer on link (Phase 4 "history-on-link" is unbuilt, §9): the phone starts
empty and fills from new traffic. Old history stays readable on the device that already has it.

**Device-proven 2026-09-13** on the 0.2.41 release APK (Pixel_7 AVD, prod backend): enroll → code
→ SAS `334 092` identical on both screens → approve on primary → `android · #2` in the device
list → gate closes → self-sync works. Corrections the run forced on the earlier draft:
the PRIMARY must be an INSTALLED PWA **to ENABLE linking** — that gate sits inside the
`notEnrolled` branch (`devices_screen.dart:426`, a plain tab shows only "Najpierw zainstaluj Umbra
jako aplikację"); once the account IS enrolled the browser-tab case gets only an informational
nudge (`:468`) and `devices-link-a-device` still renders (`:485`), so **an enrolled account can
approve a new device from a plain tab**. The ceremony is
SYMMETRIC (both sides display a code — `.web.p` and `.android.n`; either side may scan or type
the other's), and the comparison code is a **6-digit number, not words**. Use EXACTLY this:

> Umbra for Android joins your existing account as a second device — **do not create a new
> account**.
>
> **On your computer/phone browser first:** Umbra must be INSTALLED as an app (browser menu →
> Install / Add to Home Screen), otherwise the Devices screen only tells you to install it. Then:
> Settings → Devices → **turn on linking**. You will be asked to write down 12 recovery words —
> do it, on paper; they are the only way back if you lose the device.
>
> **Then on the phone:** install the app, log in with the SAME username and password. The app
> shows a "Link this device" screen with a QR code.
>
> **Now connect them:** on the primary, Settings → Devices → **Link device**. It shows its own QR
> code, and the phone can scan it — or scan/paste the phone's code there instead. Either
> direction works. Both screens then show **the same 6-digit number**: check they match, then
> approve on the primary.
>
> Your old messages stay where they are — the phone starts from "Earlier messages aren't available
> on this device" and receives everything sent from then on. Up to three devices per account.
> **Never delete your account, never clear site data, and on the phone never uninstall or use
> "Clear storage"** — that destroys that device's history. iPhone: keep using the web app as-is.
>
> If the phone lands in a chat showing `[encrypted]` instead of the link screen, press Back — the
> link screen is behind it.

A Play listing must state **up to 3 devices per account, and adding one needs the first device in
hand** — the old "one account, one device" claim must not ship.

## What a reinstall / "Clear storage" costs — SETTLED 2026-09-13, NOT a ship-blocker

Device-proven on the shippable 0.2.42 APK (`7818786…`, Pixel_7 AVD, prod) across four
`pm clear` → re-login cycles. Mechanism, durable diag rows and the ruled-out fixes are in
`docs/runbooks/e2e-decryption-failed.md` **Step 3G**. The short version:

- **The channel always comes back. The backlog never does.** Everything a friend sent that the
  phone had not already decrypted stays unreadable forever, and so do your own sent copies (a
  sender cannot decrypt its own ciphertext, so their plaintext lived only in the wiped cache).
  On this 0.2.42 APK both read as raw `[Decryption failed]` / `[encrypted]`; 0.2.43 replaces
  them with "This message can't be read on this device." — **that needs a rebuild, the binary
  above does not contain it.**
- **Our side self-heals unprompted:** the first failing decrypt after a re-mint asks the peer to
  re-key (`notifyPeer: true`), the server replays that request to a peer that reconnects later,
  and once the peer re-keys every message from then on decrypts — verified live, in the
  foreground, twice.
- **The friend pays exactly one manual step**, by design (anti-MITM anchor, amendment (xlvi)):
  they tap the red "Klucze … się zmieniły. Dotknij, aby sprawdzić" pill and confirm "Odciski się
  zgadzają". Sending them a message first does NOT spare them this. **Since 0.2.43 that pill
  appears as soon as your keys change, so they can clear it before they ever type** — on 0.2.42
  and earlier the default hid it behind a calm note and the first symptom was their message
  bouncing with "Ponów".
- **The way to avoid the confirmation:** linked devices ON + the 12 words on paper. Then a
  reinstall meets the gate's "Mam frazę odzyskiwania", the SAME identity comes back, and no peer
  sees a key change. With linking off the login re-mints silently and never asks for the phrase.
  **It is not completely free:** the restore REBINDS the device id, so a friend whose app was
  already open keeps sending to the old one
  (`Bad state: Recipient has no key bundle (… deviceId=1)`) and sees your first message as
  `[encrypted]` until they close and reopen the app once — measured across ~90 s of retries.

Add this to the friend-facing text:

> If you ever reinstall Umbra or use "Clear storage" on the phone, the messages already on it are
> gone for good — and everyone you chat with has to confirm your new security code once before
> their messages reach you again. Their app shows "Klucze … się zmieniły. Dotknij, aby sprawdzić";
> they tap it and confirm the codes match, and that's it. If they miss it, their next message to
> you bounces with "Ponów" until they do. To avoid the whole thing: turn on linked devices, write
> the 12 words down on paper, and after a reinstall use **"Mam frazę odzyskiwania"** instead of
> just logging in — that brings the same keys back, so nobody has to confirm a code. If a friend
> had the app open while you did it, they may need to close and reopen it once before messages
> flow again.

## Known-not-done (tracked, do not rediscover)

- **Phase 2 (launch gate) — BUILT, see `frontend/CLAUDE.md` §5.** Drift+SQLCipher store with the DB
  key and rotating content keys in Keystore-backed secure storage, armed-gate before any use,
  rotate-and-destroy shredding. Shredding still comes from key rotation, NOT from SQLite deletes —
  freed pages/WAL keep old bytes; `PRAGMA secure_delete` is defense-in-depth only. Content-key loss
  = whole local history unreadable (plaintext cache is NOT re-derivable: the ratchet consumed the
  keys, and media records hold the only copy of `mediaKey`/`mediaIv`) — budgeted, not denied, and
  rendered as retired ids rather than `[Decryption failed]`.
  Acceptance is executable: `cd frontend && flutter test integration_test -d <deviceId>` (8 tests,
  including a real-Keystore content-key wipe that must retire history, never crash).
- **APK size — SETTLED 2026-09-14. `useLegacyPackaging = true` is APPLIED**
  (`frontend/android/app/build.gradle.kts`), taking the universal APK from **105.2 MiB to 48.9 MiB
  with nothing removed** (measured, not projected). Every ABI still ships, so the file installs on
  any friend's phone and on the x86_64 emulator. The 24 `.so` entries are STORED by default (AGP
  does that for minSdk >= 23) and deflate **100.29 MiB → 44.19 MiB (44.1%)** — `libapp.so` 40.6%,
  `libflutter.so` 46.7%, `libsqlcipher.so` 44.0%, `libbarhopper_v3.so` 41.3%. Flag is live:
  `android:extractNativeLibs="true"` in the merged release manifest
  (`cmd /c gradlew.bat :app:processReleaseManifest`, no keystore needed).
  **16KB compliance is unaffected** — the loader mmaps the EXTRACTED copy, so ELF
  `p_align >= 16384` still governs, and `scripts/verify-apk-16k.mjs` inflates method-8 entries
  (`entryData`) so the gate keeps reading real program headers: **16/16 green on the packed APK.**
  **It costs nothing on the device either — only the ONE matching ABI is extracted.** Measured on
  real hardware at the same app version:
  | device | `base.apk` | extracted `lib/` | total |
  |---|---|---|---|
  | phone `f849cc68`, stored | 105.3 MiB | 7 KB (empty) | **105.3** |
  | `emulator-5554`, legacy packaging | 48.9 MiB | 37.2 MiB (x86_64 only) | **86.2** |

  So the on-device footprint drops ~19 MiB as well. It would only GROW for a single-ABI APK
  (38.8 stored vs 19.7 + 33.9 extracted) — another reason the universal build is the right shape
  here. Install on the emulator took 9.8 s and the app cold-started in **3.94 s** (`am start -W` →
  `Status: ok`, `LaunchState: COLD`) with no `dlopen`/`UnsatisfiedLink`/FATAL in logcat.
  ⚠️ **Revisit for an AAB** — Play does its own delivery compression and prefers uncompressed libs.
- **Anatomy behind that number (measured on 0.2.44, units are MiB).** 105.2 total, of which
  **100.3 is native libraries in three ABIs** — `x86_64` 37.2 (emulator only), `arm64-v8a` 33.9,
  `armeabi-v7a` 29.2; everything else is 2.6 dex + 2.1 assets/res. Per-ABI on arm64: `libapp.so`
  12.75 (our Dart AOT), `libflutter.so` 11.05 (engine), `libsqlcipher.so` 4.95,
  `libbarhopper_v3.so` 4.72 (ML Kit barcode model), `libwebcrypto.so` 0.37. `frontend/assets` is
  416 KiB — app assets are never the problem here.
  `libapp.so` by package (`--analyze-size`, fully accounted): `package:flutter` 3.17,
  `package:fireplace` 1.76, `package:emoji_picker_flutter` 1.38, `@unknown` 1.06,
  `package:unorm_dart` 0.81 (transitive from `bip39_mnemonic` — BIP-39 mandates NFKD, so it is
  load-bearing recovery-phrase crypto, not bloat), then 113 entries under 0.4 each.
- **Remaining size levers, in order of payoff — none applied:**
  1. **ABI narrowing → 19.7 MiB arm64-only, 33.6 MiB dropping just x86_64** (on top of legacy
     packaging). **NOT applied by decision 2026-09-14: the APK is shared with friends whose
     hardware is unknown, and `armeabi-v7a` is the only ABI a 32-bit-only phone will accept — there
     is no fallback, the install just fails with `INSTALL_FAILED_NO_MATCHING_ABIS`.** Dropping
     x86_64 alone is free for distribution but kills the release-APK drill on the x86_64 Pixel_7
     AVD. ⚠️ Two mechanics to get right if this is ever revisited:
     - `--target-platform android-arm64` **alone does NOT do it** — measured 2026-09-14 at
       **57.26 MiB**, because the Flutter plugin forces `abiFilters` to all three ABIs on every
       non-split build (`FlutterPlugin.kt:589-598` `configureAbiWithoutSplits` +
       `FlutterPluginConstants.kt:60-63`). It narrows only `libapp.so`/`libflutter.so`; the six
       third-party natives (`libsqlcipher`, `libbarhopper_v3`, `libwebcrypto`,
       `libimage_processing_util_jni`, `libsurface_util_jni`, `libdatastore_shared_counter`) still
       ship ×3, leaving 18.5 MiB of dead weight. You also need an explicit `ndk { abiFilters }` plus
       `-Pdisable-abi-filtering=true` (`FlutterPluginUtils.kt:41,292-294`).
     - the 1000×ABI versionCode offset is **exclusive to `--split-per-abi`**
       (`FlutterPlugin.kt:655-677`, `ABI_VERSION` arm32=1/arm64=2/x86_64=4). A
       `--target-platform` build leaves versionCode on our `major*1e6+minor*1e4+patch` formula.
       `--split-per-abi` would put arm64 at 22046 — a ONE-WAY DOOR against the installed floor, and
       it renames the output so `build-android.ps1:125`'s `Test-Path` fails.
  2. `dev.steenbakker.mobile_scanner.useUnbundled=true` in `frontend/android/gradle.properties`
     swaps the bundled ML Kit model for the Play-Services one (`mobile_scanner-7.4.0`
     `android/build.gradle:62-70`): saves `libbarhopper_v3.so` + `assets/mlkit_barcode_models`,
     ≈2.8 MiB post-compression on a single-ABI build. **Evaluated 2026-09-13, NOT applied:**
     the model then downloads on FIRST USE, and the scanner's only job is the link ceremony, so a
     weak connection breaks the one flow a new install must complete. Degradation is graceful
     (`LinkScanUnsupported` + the mandatory typed-code path, spec §12(i)) and Play Services is
     already required for FCM, so the dependency itself is not new — revisit once the ceremony is
     device-proven, and note it matters less on Play, where the AAB splits ABIs anyway.
  3. `--split-debug-info=<dir>` — **the payoff is UNMEASURED and the old "~3-5 MB strips symbols"
     claim was wrong.** Release AOT is already stripped: `libapp.so` has 11 sections, no `.symtab`,
     no `.debug_*`, `.dynsym` ≈ 0, just `.text` 7.58 MB + `.rodata` 5.73 MB. The flag removes the
     Dart name table INSIDE `.rodata`, which section headers cannot size, and `--analyze-size`
     refuses to combine with it. Avoid `--obfuscate` while there is no crash reporting — logcat is
     the only diagnostic channel.
  4. R8/minify is OFF (default); not a security gate. There is only 2.6 MiB of compressed dex, so
     the payoff is ~1 MiB against keep-rule risk in libsignal, drift and Firebase reflection.
     `light_compressor_v2` needs no keep-rules (its README); the others are unassessed.
  5. `package:emoji_picker_flutter` 1.38 MiB of Dart — real, but not worth replacing a working
     picker.
- `network_security_config` now EXISTS and is deliberately narrow: `frontend/android/app/src/main/res/xml/`
  permits cleartext to `127.0.0.1`/`localhost` ONLY (just_audio serves unsealed voice bytes through a
  loopback proxy; API 28+ blocks that otherwise), with no `base-config`, so every other host keeps
  the platform block. The debug variant adds `10.0.2.2` for a local backend. Never widen this to
  `usesCleartextTraffic="true"`.
- iOS: no Firebase app, no runner signing, no `Podfile` (never `pod install`ed) — out of scope until an
  iOS release is planned. **When it is:** the bundle id is still the template's `com.rpgchat.frontend`
  (`frontend/ios/Runner.xcodeproj/project.pbxproj:371,550,572` + three `RunnerTests` lines) — set it to
  `com.fireplace.app` to mirror Android before the first build; store identities are permanent. Building
  needs macOS + Xcode (or a cloud Mac such as Codemagic) and the $99/yr Apple Developer account; the Dart
  tree is shared, nothing forks (owner decision 2026-09-19: Android first).
