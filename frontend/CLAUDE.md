# CLAUDE.md — Fireplace Frontend (Flutter)

Root rules, production safety, shared wire contracts, version policy, and env overview live in `../CLAUDE.md`. This file is for Flutter/PWA/client-specific facts only.

## 1. Commands

```powershell
cd frontend
flutter pub get
flutter analyze --no-fatal-infos          # very_good_analysis 10.3.0 base; errors/warnings fatal
node ..\scripts\dart-lint-ratchet.mjs     # CI gate: INFO count must not rise above scripts/dart-lint-baseline.json
flutter test
flutter run -d chrome
```

Lint conventions are recorded in `frontend/analysis_options.yaml` (relative imports, no `public_member_api_docs`, no 80-col rule; `strict-casts`/`strict-inference` off until the `dynamic` crypto params are typed). Pay lint debt only in files you touch; `--update` lowers the floor.

Targeted examples:

```powershell
cd frontend
flutter test test/utils/instant_opaque_route_test.dart
flutter test test/services/api_service_media_url_test.dart
flutter test test/providers/message_editing_test.dart
```

**Test-run cost curve (measured 2026-07-27 on the dev PC) — pick the right scope, and never a file list:**

| Scope | Tests | Wall |
|---|---|---|
| one file | 1 | **7 s** |
| one directory (`test/utils`) | 175 | **21 s** |
| full suite (`flutter test`) | 960 | **170–310 s** |
| **45 explicit files on one command line** | ~45 | **timed out past 11 min — ≥5× the FULL suite** |

`flutter test` appears to pay a compile cost **per argument** rather than once per run, so a
long explicit file list is pathologically slow: running *everything* is dramatically faster
than running a "smart" subset. Iterate on one file or one directory, then run the full suite
before a commit or PR (still required by project policy).

**Do NOT build a "run only the affected tests" runner on top of `scripts/impact.mjs`.** It was
tried and measured on 2026-07-27 and it is strictly worse than `flutter test`. `impact.mjs`'s
test list is for knowing *what you touched*, never for feeding to `flutter test`.

Full-stack E2E wire harness (`test_e2e/` — a sibling of `test/`, so the DEFAULT suite never picks it up; needs a live backend). As of 2026-07-27 it runs in CI as the `e2e-wire` job against a real Postgres + backend, and a failure now turns the CI run red (it is no longer `continue-on-error`). It is the only automated check that client and server still agree on the wire — it caught two disaster-recovery bugs on its first two runs. Red is not a mechanical gate on this repo, so check the run yourself. Locally:

```powershell
docker-compose up            # repo root, separate terminal
cd frontend
flutter test test_e2e
```

Two headless accounts run the REAL `ApiService`+`SocketService`+`EncryptionService` (real libsignal) against the local backend: register → WS key upload → friendship → conversation → PreKey(3:)/whisper(2:) round trips → mid-conversation session rebuild → edit → reactions, asserting decryption both ends. Fresh accounts every run BY DESIGN (server keeps old unused OTPs oldest-first; reuse ⇒ phantom bad-MAC). Register throttle 10/hr/IP is in-memory — `docker compose restart backend` resets it. The harness resets the flutter_test binding's HTTP-blocking `HttpOverrides` globally (`enableRealNetwork()`); found the burned-but-never-served OTP backend bug on its first run.

On-device acceptance (`integration_test/` — also a sibling of `test/`, so the default suite never
picks it up; needs a running emulator or phone, and CANNOT run in CI). Four files; two carry the
E2E-critical reasons to exist:

- `native_content_store_device_test.dart` (8 tests) — the encrypted content store. The only check
  that exercises the REAL Android Keystore, the REAL SQLCipher `.so` from the APK and the REAL
  native webcrypto — the host VM has no webcrypto native (no MSVC), so those crypto assertions are
  `skip`ped in `flutter test` and only run here. Re-run after touching anything under
  `lib/services/encryption/`, `auth_token_store.dart`, or the audio seal path. **Destructive and
  LAST on purpose:** its final test destroys every content key in the real Keystore.
- `identity_recovery_durability_device_test.dart` (4 tests) — amendments (xlviii)/(xlix). Every
  property it asserts is a PERSISTENCE property, and the unit suite proves them against
  `SharedPreferences.setMockInitialValues`, an in-memory map that cannot fail the way a device
  fails. It constructs `EncryptionService` TWICE over the same on-device storage; the second
  construction is the relaunch. Re-run after touching the persisted session-rebuild intent, the
  identity-warning set, or the device-list rollback pin.
- `video_probe_device_test.dart` (3 tests) + `video_transcode_device_test.dart` (2 tests) — the
  native video probe and the MediaCodec transcode, both fed a real container pushed to
  `/data/local/tmp/clip.mp4`; an absent fixture SKIPS rather than fails.

```powershell
cd frontend
flutter test integration_test -d <deviceId>   # 17 tests, ~2-9 min incl. the gradle build
# or one file:
flutter test integration_test/identity_recovery_durability_device_test.dart -d <deviceId>
```

Patrol (`patrol` 4.9.0 + `patrol_cli` 4.7.0, since 2026-09-12) is wired for Android: `PatrolJUnitRunner` +
orchestrator in `android/app/build.gradle.kts`, `androidTest/.../MainActivityTest.java`, `patrol:` block in
`pubspec.yaml` (`test_directory: integration_test`). Only `patrolTest(...)` files run under it —
`integration_test/patrol_harness_test.dart` is the framework-only self-test (green on the Pixel_7 AVD, 1/1).
The four `testWidgets` device files above are NOT ported: under `patrol test` the run sat in "Executing
tests" for 40 min; keep `flutter test integration_test -d`. Web leg (`-d chrome`) NOT green after two
attempts: run 1 (concurrent with the Android build) served the bundle but Playwright listed 0 tests
(`web_runner/tests/setup.ts` got no `__patrol__getTests`); run 2 (serial) hung 100 min at `npx playwright
install chromium`. Owner stopped further runs — treat as owner-owed, not a pending retry. Needs `ANDROID_HOME`
and `<sdk>/platform-tools` on PATH; `patrol.bat` lives in `%LOCALAPPDATA%\Pub\Cache\bin`.

Local devices:

- Android emulator: `cd frontend && flutter run -d <deviceId> --dart-define=BASE_URL=http://10.0.2.2:3000`.
- Phone on WiFi: `cd frontend && .\run_web_for_phone.ps1` (serves `0.0.0.0:8080`, sets `BASE_URL=http://<HostIP>:3000`, includes git/build dart-defines).
- Low-space Android builds: `cd frontend && .\run_android_on_x.ps1`; requires `X:` drive, redirects Gradle/temp/build dirs, runs `patch_webcrypto_16k.ps1`.
- **Android RELEASE APK: `.\build-android.ps1` from the repo root** (runbook: `docs/runbooks/android-release.md`). Gates: Gradle throws AT EXECUTION TIME on exactly `packageRelease`/`packageReleaseBundle` without `android/key.properties` (covers task-name-free `gradlew build`/`assemble`; exact names because `packageReleaseResources` feeds lintRelease/testReleaseUnitTest), and the release `signingConfig` is NULL without a keystore — a missed path yields an inert UNSIGNED apk, never debug-signed; `apksigner` rejects a debug cert (keytool can't read v2/v3-only signatures at minSdk 24); `scripts/verify-apk-16k.mjs` fails the build if any 64-bit `.so` in the APK lacks 16KB-aligned PT_LOAD segments (falsification harness: `verify-apk-16k.selftest.mjs`). versionCode = `major*1_000_000 + minor*10_000 + patch` via `--build-number`. `allowBackup=false` + `res/xml/data_extraction_rules.xml` are dual-purpose (plaintext-prefs leak AND the restore-blob-without-Keystore-key corruption) — never relax.
- Gradle cache corruption: set `$env:GRADLE_USER_HOME='D:\gradle-home'`, run `gradlew.bat --stop`, delete the broken `%USERPROFILE%\.gradle\caches\<version>` dir, then `flutter clean` + rebuild. `flutter clean` alone is not enough.

Production web deploy:

```powershell
# from repo root on the PC, not the VM
git pull ; .\deploy-web.ps1
```

`deploy-web.ps1` runs `flutter clean`, then `flutter build web --release --no-wasm-dry-run --no-web-resources-cdn` with `BASE_URL`, `GIT_COMMIT`, `BUILD_TIME`, `WEB_PUSH_VAPID_PUBLIC_KEY`, `GIPHY_API_KEY`; publishes by atomic swap to VM `frontend-build/`; verifies `/version.json` and backend `/version`. Never run `flutter build web` on the 2 GB VM.

## 2. App architecture

- Entry: `lib/main.dart` initializes portrait lock, native Firebase/FCM background handler, pending push deep-link drain, then `FireplaceApp`.
- Providers: exactly 8 top-level `ChangeNotifierProvider`s: `AuthProvider`, `SettingsProvider`, `EncryptionProvider`, `FriendsProvider`, `ConversationsProvider`, `MessagingProvider`, `ConnectionProvider`, `PasscodeProvider` (8th added 2026-09-03 with the Passcode Lock; §10).
- Runtime wiring happens in `ConversationsScreen.initState`: provider references are connected, auth session is refreshed, then `ConnectionProvider.connect(userId, token, AppConfig.baseUrl)`.
- `ConnectionProvider` owns socket lifecycle and event routing. It waits for server `socketReady` before fetching conversations/friends/messages.
- `ContactStore` (`lib/services/contacts/`): client-owned contact list, hydrated by `ConnectionProvider.connect()` BEFORE the socket, written through by every list handler. Rules: `frontend/docs/e2e-invariants.md`.
- `MessagingProvider` is one `ChangeNotifier` split into part-files under `lib/providers/messaging/`: `history`, `events`, `send`, `decrypt`, `actions`. Core fields and `dispose` stay in `messaging_provider.dart`; extensions may use private fields.
- Primary services: `SocketService` (Socket.IO auth + `enableForceNew()`), `ApiService` (REST/media), `EncryptionService` (Signal), `EncryptedMediaUploadService` (AES-GCM encrypt+upload), `PushService`, `WebPushBridge`, `PushSwChannel`, `IncomingMessageSoundService`, `VoiceAudioCoordinator`.
- Navigation: `AuthGate` → restoring spinner while saved auth is being checked, then `AuthScreen` or `MainShell` (`IndexedStack`: Conversations/Contacts/Settings). **Above all of it, `MaterialApp.builder` wraps every route in `PortraitLockShell(child: PasscodeGate(child: …))`** — the passcode barrier must sit above the Navigator or a pushed chat route would paint over it (§10). Desktop width >=600 uses sidebar/detail. Mobile chat entry routes use `utils/instant_opaque_route.dart` — ENTRY stays opaque + zero-duration to avoid iOS/Web half-transition split-screen lag, while the POP is a 180ms fade-out (reduce-motion skips it) so back-out isn't a single teardown frame; regression `test/utils/instant_opaque_route_test.dart` guards both directions.

## 3. Dart defines and versioning

- `BASE_URL`: `AppConfig.baseUrl`; dart-define wins, else `http://<browser-host>:3000`.
- `GIPHY_API_KEY`: dart-define only — no embedded fallback; an empty key disables GIF search rather than shipping a committed key.
- `WEB_PUSH_VAPID_PUBLIC_KEY`: used by `PushService`; production build must pass the real public key. There is NO fallback — an empty define makes web-push subscribe fail loudly. The Docker web build (`frontend/Dockerfile`) does not pass it, so Docker-built web bundles have no web push at all.
- `GIT_COMMIT`, `BUILD_TIME`: used by `AppVersionInfo`; local scripts load them via `scripts/version_dart_defines.ps1`.
- App semver comes from `pubspec.yaml` through `package_info_plus`; it is not a dart-define.
- Settings footer label is ARB-localized, but value is `AppVersionInfo.displayLine`: `version · gitCommit · buildTime` with build time omitted when empty. For deploy freshness trust the commit, not just `version`.

## 4. PWA, push, and cache traps

- Web push SW: `web/web-push-sw.js`, registered at scope `/web-push-scope/` by `WebPushBridge`. Do not confuse it with Flutter's generated app service worker.
- `WebPushBridge.listenForNotificationClicks` must call `navigator.serviceWorker.startMessages()` after adding the message listener; WebKit queues messages forever without it.
- App → push-SW messages go through `PushSwChannel` using `getRegistration('/web-push-scope/')` and `reg.active.postMessage`. Do not use `serviceWorker.ready` / `.controller`; that targets Flutter's app SW.
- Push SW owns notification tray and app badge. It close-before-shows stable `conversation-<id>` tags because iOS WebKit does not replace same-tag notifications reliably.
- iOS killed/suspended PWA deep links: `clients.openWindow('/?notify_conv=...')` can lose the URL. SW persists `{conversationId, at}` in IndexedDB `fireplace-push/kv/pending-deep-link`; `main.dart` drains it before `runApp`.
- Android native push is data-only FCM → `flutter_local_notifications`; small icon is `@drawable/ic_stat_umbra` in notifications. Main plugin initialization still uses launcher icon; do not claim every native init path uses the drawable icon.
- Notification small/badge icon must be monochrome white-on-transparent. Full-color opaque PNGs become white squares.
- `deploy-web.ps1` validates generated `frontend/build/web/version.json`. If code does not change after deploy, run a clean build and hard-bust PWA cache by fully closing/reopening. Never uninstall/clear site data on a real user account.
- **Cold-start boot loader (`#fp-boot` in `web/index.html`, logic in `web/fp_boot.js`).** There is NO offline cache: Flutter 3.x's generated `flutter_service_worker.js` self-unregisters on `activate`, and `infra/nginx/fireplace.conf` serves `/` `Cache-Control: no-cache`. So a daily user stays warm in the HTTP cache (instant boot), but an idle-return or post-deploy launch re-downloads the whole shell (`main.dart.js` ~7.6 MB + local `canvaskit.wasm` ~6.9 MB + fonts) over the network — ~15 s on mobile with a BLANK screen, read as "broken" and swiped away. The inert DOM loader (shield + determinate fake-progress bar + localized "Wczytywanie…/Loading…", theme-accent + `flutter.locale_preference`) paints instantly and is removed on Flutter's `flutter-first-frame` event. The logic is an EXTERNAL same-origin file on purpose — an inline block would need a third CSP `script-src` sha256 (`infra/nginx/security-headers.conf`, `scripts/verify-csp-inline-hashes.mjs`); `'self'` covers `fp_boot.js`. It sits one z-index BELOW `#fp-curtain` so a locked relaunch still shows the shield on top. It MASKS the ~15 s, it does not shorten it — real fix is gzip/brotli + immutable `/canvaskit/` cache.

## 5. E2E and local storage invariants

**Moved to `frontend/docs/e2e-invariants.md` (2026-09-10) — read it BEFORE touching `frontend/lib/services/encryption/**`, `encryption_service.dart`, `services/device_list/**`, `services/device_link/**`, `recovery_phrase.dart`, `content_key_canary.dart`, `e2e_lock_revoker.dart`, `providers/encryption_provider.dart`, the device-link gate / recovery-key screens, `secure_storage`/`localStorage`/IndexedDB access, anything that reads or writes Signal key material, or the reset/restore/link ceremonies**

## 6. Messaging and UI contracts

- Optimistic send: temp message (`id` = a monotonic NEGATIVE counter, `SENDING`, `tempId` = `temp_<millis>_<userId>`) → encrypt/upload → WS `sendMessage` → `messageSent` replaces temp with real row.
- Auto-scroll on new messages: decision is the pure `utils/chat_auto_scroll.dart` (`shouldAutoScrollOnNewMessages`) — OWN sends always scroll to newest (text/emote-panel/media alike); peer messages scroll only near-bottom, else unread badge. Do not rely on the keyboard-open `didChangeMetrics` scroll for send behavior — the emoji panel opens without the keyboard.
- Text edit: `messageEditEligible` gates own TEXT positive-id sent/delivered/read rows within 15 minutes. `beginEditMessage` shows `EditPreviewBar`; send emits new ciphertext via `editMessage`; reject reverts optimistic content.
- Message model `copyWith` must include every field. Missing fields silently drop data.
- Reactions: context-menu quick row calls `MessagingActions.addReaction/removeReaction`; the chevron (`context-menu-expand-reactions`) expands `FireplaceEmojiPicker` in place via `computeExpandedReactionPickerLayout` (row + action panel unmount, bubble stays; never covers bubble/keyboard). Keep expanded overlay geometry based on `MediaQuery` read inside the `OverlayEntry` builder, not the pre-overlay message context, or iOS/PWA keyboard viewport changes will strand the picker. System back closes the menu via a `PopEntry` on the chat route. `emoji_picker_flutter`'s grid renders nothing under the widget-test binding — test emoji selection through the suggested row keys only.
- Emoji glyphs MUST render with an emoji family as the PRIMARY `TextStyle.fontFamily` (`withEmojiFont` / `kEmojiFontFamily` + `kEmojiFontFamilyFallback` in `utils/jumbo_emoji.dart`) — NOT the ambient Inter font. Inter ships a monochrome U+2764 glyph and Flutter-web CanvasKit renders emoji with the primary font's glyph (ignoring the U+FE0F emoji-presentation request), so ❤️ shows a white outline while SMP emoji stay color; a `fontFamilyFallback` alone does NOT fix it (Inter primary wins). Applied to picker suggested-row/grid, reaction quick row + chips, jumbo + `buildInlineEmojiSpans`, and the conversation-list preview. Proof harness: `tool/heart_preview.dart`.
- Jumbo emoji (Telegram parity, static only — no animated emoji, ever: copyright + E2E metadata leak): emoji-only TEXT messages render outside the normal bubble surface via `utils/jumbo_emoji.dart` (`emojiOnlyCount` grapheme regex — `Extended_Pictographic`, flags, keycaps; digits/`#`/`*` excluded; tiers 1→82, 2→78, 3→64, 4→52, 5+→44). Metadata stacks UNDER the emote in a side-aligned `Column` (never an inline `Wrap` — it shoved lone emotes toward center) and uses `MessageMetadataRow.onChatSurface: true` + the received-side meta color: the on-bubble sent color is white and invisible on a light chat background. Mixed text+emoji stays in-bubble with emoji runs at `kInlineEmojiFontSize` (18) via `buildInlineEmojiSpans` (text/URLs stay 14). Applied in `TextMessageContent` and mirrored in `MessageContextMenuBubbleHighlight`; previews (reply/pinned/conversation list) deliberately stay small.
- Plain text message metadata is a real `MessageMetadataRow` sibling in a `Wrap` next to `TextMessageContent` (single-line inline-time path). Multi-line/reply bubbles stack it in the `Column` WITHOUT an `Align` wrapper — `Align` greedily fills the bounded width and stretches every bubble to max width (the reply-to-emote stretch bug). Do not reintroduce Row-wide timestamp-width subtraction, fake placeholder spans, `WidgetSpan` inside message text, or `Stack`/`Positioned` timestamp overlays for text bubbles; those create empty rectangles or overlap/clamp wrapped/edited text.
- Pinned banner shows when `pinnedMessageId` + preview exist, even if the message is not loaded locally; tap paginates and scrolls.
- Reply preview uses type labels for encrypted media; never leak plaintext to backend snapshots.
- Provider cannot navigate directly. Use pending-consume patterns (`consumePendingOpen`, notification request/consume, friend request sent/accepted flags).
- Do not call `getConversations()`/`getFriends()` inside `onFriendRequestAccepted`; it races and can overwrite fresh state with stale snapshots.
- `conversationsList` unread merge trusts the server count (open conversation forced to 0). It replaced an old `max(prev, server)` merge that could only raise counts and left a badge permanently stuck after the conversation was read. Tradeoff: a stale snapshot can briefly reset a just-incremented local count, but the next snapshot restores it (and the message is already in the loaded list).
- On reconnect for the same user, preserve conversations/friends and active conversation. Ignore empty payloads when lists are already populated. `socketReady` and resume resync re-emit `pushClientState {clientVisible}` with or without an open chat (the push skip lives on the fresh socket); the server is never told WHICH chat is open (PR0.2).
- **Both honeycombs speak one caption language: hex + 11px `w600` name underneath.** The Chats `+` picker was avatar-only, which collapses to a single initial for anyone without a photo — unusable as an identifier. Its rows no longer overlap (`hexHeight + labelGap + labelHeight + rowGap`); the half-cell odd-row stagger is what still reads as a comb, exactly as on the Contacts board.
- **Caption heights come from `measureCaptionHeight` (`utils/caption_metrics.dart`) — never a hand-rolled `TextPainter`.** It takes the BARE style and does the `DefaultTextStyle.of(context).style.merge(...)` itself, because that merge is the whole trap: `Text` merges into the ambient default, which carries a line height the bare style omits, so measuring the bare style under-reports ~4px per line. At one line the shortfall hid inside the Contacts board's 9px row slack; at two it overflowed the caption box. Both combs call it; a third caller cannot reintroduce the bug.
- **`ChatHoneycombPicker` re-checks reduce-motion on EVERY `didChangeDependencies`, and latches only the `forward()`.** Hoisting the `_entranceStarted` guard above the `MediaQuery.disableAnimationsOf` check looks like a tidy-up and silently breaks playbook §9: a user switching reduce-motion on mid-entrance keeps getting the animation. Regression: `conversations_honeycomb_picker_test.dart` "reduce motion turned on mid-entrance snaps the picker to its end state" (fail-before: the latched version sits at 0.637 opacity).
- **A pending outbound invitation says so in a word, not a glyph.** Ghost cells on the Contacts board carried their state in `Icons.send_outlined` plus a screen-reader-only sentence — the sighted user got an arrow. They now render `invitationStatusPending` in `colorScheme.primary` (≥4.72:1 on every theme's field) under the name, and `ContactNetworkView` reserves a two-line `labelHeight` **only while `sentInvitees` is non-empty**, so the whole field pays the extra row height only until the last invitation resolves. Both strings are injected by `ContactsScreen` (`pendingInviteLabel`, `pendingInviteSemanticLabel`) — the view stays l10n-free by contract.
- **Honeycomb wire routing (`ContactHexLayout.routePath`) has two invariants; breaking either puts a wire through a hex.** A pointy-top lattice has NO straight vertical channel and NO clean long diagonal — a wide row's gaps sit exactly over the narrow row's CENTRES. So: vertical travel happens only inside a gap corridor (pitch/2 from either centre), and sideways travel only in the empty band between rows. The rim fan is per CORRIDOR (≤ `columnsWide + 1` rays), never per contact — a per-contact fan smears into a wedge past ~100 nodes. Gap-selection ties break OUTWARD, or a mirrored pair of contacts weaves the same way and the field stops being symmetric. **Horizontal rails were built and rejected by the owner (2026-07-29); do not reintroduce them.**
- **The Chats `+` badge must have a door.** It counts `pendingRequestsCount` (server truth — the backend re-emits it after accept and decline, so it is never fixed up client-side), but the sheet behind it used to show friends only. `showChatHoneycombPicker` now returns `ChatPickerChoice` (`ChatPickerFriend` | `ChatPickerReviewInvitations` | `ChatPickerInviteNew`) and leads the comb with the senders of `friendRequests` as accent terminals (`HexAvatar(ember: 1)` + `invitationStatusPending`). Tapping one routes to `InvitationsScreen`; the picker NEVER accepts inline, because accept/decline own a scoped-failure and retry state machine that already lives there and a second copy would drift.

## 7. Composer, media, and platform gotchas

**Moved to `frontend/docs/composer-media.md` (2026-09-10) — read it BEFORE touching `chat_input_bar*`, `composer*`, `chat_action_tiles.dart`, `web_file_input.dart`, attachment/picker code, `**/media*`, `**/video*`, `**/voice*`, `**/image*`, the iOS viewport pin, or anything keyboard-adjacent in the chat screen. **The 2026-08-19 composer rule lives here: nothing ships in the composer without a green repro AND the owner's explicit OK.****

## 8. Tests and localization

- Widget tests needing l10n must wrap `MaterialApp` with `AppLocalizations.localizationsDelegates` and `supportedLocales`.
- `SettingsScreen` tests need `RpgTheme.themeDataLight` because it expects `FireplaceColors` ThemeExtension.
- `blockedByUserIds` returns `Set.unmodifiable`; tests should drive state with provider methods, not mutate the set.
- `use_build_context_synchronously`: capture providers with `context.read<>()` before first `await`.
- Fire-and-forget futures use `.ignore()`, not empty `catchError` hacks.
- Use `showTopSnackBar()` and ARB keys; `ScaffoldMessenger` covers chat input and hardcoded English is a regression.
- Native `MediaCryptoService` round-trip tests may require `flutter pub run webcrypto:setup`/CMake; size-guard tests skip gracefully.

## 9. UI design quality (anti-slop)

Full doctrine: `docs/design/flutter-ui-playbook.md` — read it before building or changing any UI. Load-bearing rules:

- **Look at it.** Every UI change closes the loop `launch once → edit → hot reload → runtime errors → screenshot → compare to docs/design/liquid-glass/after/*.png → iterate`, across every theme touched (`light`/`teal`/`dark`/`blue`/`cosmic`). Widget tests are not visual verification. **The Dart MCP is the middle of that loop** (`mcp__dart_hot_reload`, `mcp__dart_get_runtime_errors`, `mcp__dart_widget_inspector`; `mcp__dart_roots add` first each session — setup, the per-machine mount path caveat, and the CDP drive recipe are in the playbook §0). **Probation:** if `grep -l 'mcp__dart\|hot_reload' .cursor/session-summaries/2026-1*` is still empty 30 sessions after 2026-09-10, delete the `.omp/mcp.json` entry. The render server runs as a BACKGROUND job (`hub start`) and is cancelled in cleanup — NEVER wait-to-finish on `flutter run` (it never exits; a subagent that waited on it hung 40 min). Readiness is NOT `/` returning 200 (that's the shell before the bundle compiles — the screenshot is blank): wait for the compile/"serving" log AND a non-blank screenshot (first compile 40–90 s), bounded (~120 s). A design-review subagent stays READ-ONLY and is handed already-captured screenshots; it must never launch `flutter run`.
- **Never invent values.** Use `RpgTheme` / `FireplaceColors.of(context)` / `GlassTheme.of(context)` tokens and `SPEC.md` metrics; no hardcoded `Color(0x...)` or font families in screens/widgets (spacing literals are fine).
- **Motion is capped and reduce-motion-aware.** Entrances 180–280 ms, `easeOut(Cubic)`, subtle distance; play entrances ONCE (not per provider rebuild); always honor `MediaQuery.disableAnimationsOf(context)`. Prefer Flutter built-ins (`AnimatedContainer`/`AnimatedSwitcher`/`Hero`); the only added UI dep is `skeletonizer` (loading skeletons). Reference impl: `conversation_list_skeleton.dart` (fetch-gated shimmer, static under reduce-motion) wired into `conversations_screen.dart`.
- **Motion BANNED zones** (§7 device-proven): composer/keyboard-adjacent blocks, the zero-duration `instant_opaque_route` chat entry, and message/emoji content. Animate lists, cards, buttons, loading, hero avatars instead.
- The user-level `flutter-frontend-design` skill is the Flutter-specific companion to the playbook. (The HTML/CSS/React `frontend-design` plugin that used to need a counter-instruction here was uninstalled 2026-09-10.)

## 10. Passcode Lock (app-level gate + web key wrapping; RELEASED — merged to master `d446a9d` 2026-09-06, live as 0.2.22)

**Moved to `frontend/docs/passcode-lock.md` (2026-09-10) — read it BEFORE touching `**/passcode*` (store, kdf, gate, provider, screens, curtain), `utils/privacy_curtain*`, `#fp-curtain` in `web/index.html`, `e2e_lock_revoker.dart`, KEK/wrapping code (`encryption/content_key_wrap.dart`, `fpwk1:` envelopes), the auto-lock timer, or the erase panel

