# CLAUDE.md — Fireplace Frontend (Flutter)

Root rules, production safety, shared wire contracts, version policy, and env overview live in `../CLAUDE.md`. This file is for Flutter/PWA/client-specific facts only. Rationale, history and evidence behind the one-line rules below live in `frontend/docs/dev-workflow.md` (§1) and `frontend/docs/client-reference.md` (§2, §4, §6, §9); each rule names its heading there.

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

- Test scope: iterate on ONE file or ONE directory, then run the full suite before a commit or PR — never a long explicit file list (compile cost is per argument). Cost curve: `dev-workflow.md#test-run-cost-curve`; examples: `dev-workflow.md#targeted-test-examples`.
- Do NOT build a "run only the affected tests" runner on top of `scripts/impact.mjs` — measured strictly worse (`dev-workflow.md#test-run-cost-curve`).
- `test_e2e/` wire harness (needs a live backend; CI job `e2e-wire` turns the run red, but red is not a gate — check the run yourself): `docker-compose up` at repo root, then `cd frontend; flutter test test_e2e`. Fresh accounts every run BY DESIGN (reuse ⇒ phantom bad-MAC); `docker compose restart backend` resets the in-memory register throttle. `dev-workflow.md#e2e-wire-harness`.
- `integration_test/` on-device acceptance (emulator/phone, CANNOT run in CI): `flutter test integration_test -d <deviceId>`. Re-run `native_content_store_device_test.dart` (destructive, LAST on purpose) after touching `lib/services/encryption/`, `auth_token_store.dart` or the audio seal path; `identity_recovery_durability_device_test.dart` after touching the persisted session-rebuild intent, the identity-warning set or the device-list rollback pin. `dev-workflow.md#on-device-acceptance`.
- Patrol runs only `patrolTest(...)` files; keep the four `testWidgets` device files on `flutter test integration_test -d`. Web leg is owner-owed, not a pending retry. `dev-workflow.md#patrol`.
- Local devices: emulator `--dart-define=BASE_URL=http://10.0.2.2:3000`; phone on WiFi `.\run_web_for_phone.ps1`; low-space Android `.\run_android_on_x.ps1` (needs `X:`). `dev-workflow.md#local-devices`.
- Android RELEASE APK: `.\build-android.ps1` from the repo root (runbook `docs/runbooks/android-release.md`); `allowBackup=false` + `res/xml/data_extraction_rules.xml` — never relax. Signing/16KB/versionCode gates: `dev-workflow.md#android-release-apk`.
- Gradle cache corruption: `flutter clean` alone is not enough — `dev-workflow.md#gradle-cache-corruption`.
- Production web deploy: `git pull ; .\deploy-web.ps1` from the repo root on the PC, not the VM; never run `flutter build web` on the 2 GB VM. `dev-workflow.md#production-web-deploy`.

## 2. App architecture

- Entry: `lib/main.dart` initializes portrait lock, native Firebase/FCM background handler, pending push deep-link drain, then `FireplaceApp`.
- Providers: exactly 8 top-level `ChangeNotifierProvider`s: `AuthProvider`, `SettingsProvider`, `EncryptionProvider`, `FriendsProvider`, `ConversationsProvider`, `MessagingProvider`, `ConnectionProvider`, `PasscodeProvider` (8th added 2026-09-03 with the Passcode Lock; §10).
- Runtime wiring happens in `ConversationsScreen.initState`: provider references are connected, auth session is refreshed, then `ConnectionProvider.connect(userId, token, AppConfig.baseUrl)`.
- `ConnectionProvider` owns socket lifecycle and event routing. It waits for server `socketReady` before fetching conversations/friends/messages.
- `ContactStore` (`lib/services/contacts/`): client-owned contact list, hydrated by `ConnectionProvider.connect()` BEFORE the socket, written through by every list handler. Rules: `frontend/docs/e2e-invariants.md`.
- `MessagingProvider` is one `ChangeNotifier` split into part-files under `lib/providers/messaging/`: `history`, `events`, `send`, `decrypt`, `actions`. Core fields and `dispose` stay in `messaging_provider.dart`; extensions may use private fields.
- Primary services: `SocketService` (Socket.IO auth + `enableForceNew()`), `ApiService` (REST/media), `EncryptionService` (Signal), `EncryptedMediaUploadService` (AES-GCM encrypt+upload), `PushService`, `WebPushBridge`, `PushSwChannel`, `IncomingMessageSoundService`, `VoiceAudioCoordinator`.
- Navigation: `AuthGate` → restoring spinner while saved auth is being checked, then `AuthScreen` or `MainShell` (`IndexedStack`: Conversations/Contacts/Settings). **`MaterialApp.builder` wraps every route in `PortraitLockShell(child: PasscodeGate(child: …))`** — the passcode barrier must sit above the Navigator (§10). Desktop width >=600 uses sidebar/detail. Mobile chat entry uses `utils/instant_opaque_route.dart`: ENTRY opaque + zero-duration, POP a 180ms fade (reduce-motion skips it); `test/utils/instant_opaque_route_test.dart` guards both. `client-reference.md#navigation-and-chat-entry-route`.

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
- Every push the SW receives must post a notification inside `waitUntil`: Safari REVOKES the subscription after 3 silent pushes. The box `notifier_challenge` (E9) is forwarded to open pages and posted-then-closed unless a visible page took it on a non-Apple endpoint; never add a data-only branch (`docs/contracts/wire.md` "Client push registration").
- iOS killed/suspended PWA deep links: `clients.openWindow('/?notify_conv=...')` can lose the URL. SW persists `{conversationId, at}` in IndexedDB `fireplace-push/kv/pending-deep-link`; `main.dart` drains it before `runApp`.
- Android native push is data-only FCM → `flutter_local_notifications`; small icon is `@drawable/ic_stat_umbra` in notifications. Main plugin initialization still uses launcher icon; do not claim every native init path uses the drawable icon.
- Notification small/badge icon must be monochrome white-on-transparent. Full-color opaque PNGs become white squares.
- `deploy-web.ps1` validates generated `frontend/build/web/version.json`. If code does not change after deploy, run a clean build and hard-bust PWA cache by fully closing/reopening. Never uninstall/clear site data on a real user account.
- Cold-start boot loader `#fp-boot` (`web/index.html`, logic in `web/fp_boot.js`): keep the logic in the EXTERNAL same-origin file (inline needs a new CSP sha256) and one z-index BELOW `#fp-curtain`. It masks the cold ~15 s download, it does not shorten it. `client-reference.md#cold-start-boot-loader`.

## 5. E2E and local storage invariants

**Moved to `frontend/docs/e2e-invariants.md` (2026-09-10) — read it BEFORE touching `frontend/lib/services/encryption/**`, `encryption_service.dart`, `services/device_list/**`, `services/device_link/**`, `recovery_phrase.dart`, `content_key_canary.dart`, `e2e_lock_revoker.dart`, `providers/encryption_provider.dart`, the device-link gate / recovery-key screens, `secure_storage`/`localStorage`/IndexedDB access, anything that reads or writes Signal key material, or the reset/restore/link ceremonies**

## 6. Messaging and UI contracts

- Optimistic send: temp message (`id` = a monotonic NEGATIVE counter, `SENDING`, `tempId` = `temp_<millis>_<userId>`) → encrypt/upload → WS `sendMessage` → `messageSent` replaces temp with real row.
- Auto-scroll on new messages: decision is the pure `utils/chat_auto_scroll.dart` (`shouldAutoScrollOnNewMessages`) — OWN sends always scroll to newest (text/emote-panel/media alike); peer messages scroll only near-bottom, else unread badge. Do not rely on the keyboard-open `didChangeMetrics` scroll for send behavior — the emoji panel opens without the keyboard.
- Text edit: `messageEditEligible` gates own TEXT positive-id sent/delivered/read rows within 15 minutes. `beginEditMessage` shows `EditPreviewBar`; send emits new ciphertext via `editMessage`; reject reverts optimistic content.
- Message model `copyWith` must include every field. Missing fields silently drop data.
- Reactions: quick row calls `MessagingActions.addReaction/removeReaction`; the chevron expands `FireplaceEmojiPicker` in place (never covers bubble/keyboard). Read `MediaQuery` inside the `OverlayEntry` builder, never the pre-overlay context. Test emoji selection through the suggested row keys only. `client-reference.md#reactions-context-menu`.
- Emoji glyphs MUST render with an emoji family as the PRIMARY `TextStyle.fontFamily` (`withEmojiFont` in `utils/jumbo_emoji.dart`), NOT Inter — a `fontFamilyFallback` alone does not fix the white-outline ❤️. `client-reference.md#emoji-font`.
- Jumbo emoji: static only — no animated emoji, ever (copyright + E2E metadata leak). Metadata stacks UNDER the emote in a side-aligned `Column` (never an inline `Wrap`) with `MessageMetadataRow.onChatSurface: true` + the received-side meta color (the sent color is white, invisible on a light chat background). `client-reference.md#jumbo-emoji`.
- Text-bubble metadata is a real `MessageMetadataRow` sibling (`Wrap` on the single-line path; `Column` WITHOUT an `Align` wrapper on multi-line/reply). Do not reintroduce timestamp-width subtraction, fake placeholder spans, `WidgetSpan` in message text, or `Stack`/`Positioned` timestamp overlays. `client-reference.md#text-bubble-metadata`.
- Pinned banner shows when `pinnedMessageId` + preview exist, even if the message is not loaded locally; tap paginates and scrolls.
- Reply preview uses type labels for encrypted media; never leak plaintext to backend snapshots.
- Provider cannot navigate directly. Use pending-consume patterns (`consumePendingOpen`, notification request/consume, friend request sent/accepted flags).
- Do not call `getConversations()`/`getFriends()` inside `onFriendRequestAccepted`; it races and can overwrite fresh state with stale snapshots.
- `conversationsList` unread merge trusts the server count (open conversation forced to 0); the old `max(prev, server)` merge left badges stuck. `client-reference.md#unread-merge`.
- On reconnect for the same user, preserve conversations/friends and active conversation. Ignore empty payloads when lists are already populated. `socketReady` and resume resync re-emit `pushClientState {clientVisible}` with or without an open chat (the push skip lives on the fresh socket); the server is never told WHICH chat is open (PR0.2).
- **Both honeycombs speak one caption language: hex + 11px `w600` name underneath.** `client-reference.md#honeycomb-captions`.
- **Caption heights come from `measureCaptionHeight` (`utils/caption_metrics.dart`) — never a hand-rolled `TextPainter`.** `client-reference.md#caption-heights`.
- **`ChatHoneycombPicker` re-checks reduce-motion on EVERY `didChangeDependencies`, and latches only the `forward()`** — never hoist the `_entranceStarted` guard above the check. `client-reference.md#honeycomb-picker-reduce-motion`.
- **A pending outbound invitation says so in a word, not a glyph** (`invitationStatusPending`); `ContactNetworkView` stays l10n-free — strings are injected by `ContactsScreen`. `client-reference.md#pending-invitation-label`.
- **Honeycomb wire routing (`ContactHexLayout.routePath`):** vertical travel only inside a gap corridor, sideways only between rows; rim fan per CORRIDOR, never per contact; gap ties break OUTWARD. **Horizontal rails were rejected by the owner (2026-07-29); do not reintroduce them.** `client-reference.md#honeycomb-wire-routing`.
- **The Chats `+` badge must have a door:** the picker leads with `friendRequests` senders and routes them to `InvitationsScreen`; it NEVER accepts inline. `client-reference.md#chats-plus-badge`.

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

- **Look at it.** Every UI change closes the loop `launch once → edit → hot reload → runtime errors → screenshot → compare to docs/design/liquid-glass/after/*.png → iterate`, across every theme touched (`light`/`teal`/`dark`/`blue`/`cosmic`). Widget tests are not visual verification. **The Dart MCP is the middle of that loop** (probation: delete the `.omp/mcp.json` entry if unused 30 sessions after 2026-09-10). Run the render server as a BACKGROUND job — NEVER wait-to-finish on `flutter run`; a design-review subagent stays READ-ONLY on already-captured screenshots. Setup, readiness, probation check: `client-reference.md#ui-verification-loop-and-dart-mcp`.
- **Never invent values.** Use `RpgTheme` / `FireplaceColors.of(context)` / `GlassTheme.of(context)` tokens and `SPEC.md` metrics; no hardcoded `Color(0x...)` or font families in screens/widgets (spacing literals are fine).
- **Motion is capped and reduce-motion-aware.** Entrances 180–280 ms, `easeOut(Cubic)`, subtle distance; play entrances ONCE (not per provider rebuild); always honor `MediaQuery.disableAnimationsOf(context)`. Prefer Flutter built-ins (`AnimatedContainer`/`AnimatedSwitcher`/`Hero`); the only added UI dep is `skeletonizer`. Reference impl: `conversation_list_skeleton.dart` (`client-reference.md#motion-reference-implementation`).
- **Motion BANNED zones** (§7 device-proven): composer/keyboard-adjacent blocks, the zero-duration `instant_opaque_route` chat entry, and message/emoji content. Animate lists, cards, buttons, loading, hero avatars instead.
- The user-level `flutter-frontend-design` skill is the Flutter-specific companion to the playbook (history: `client-reference.md#design-skills-history`).

## 10. Passcode Lock (app-level gate + web key wrapping; RELEASED — merged to master `d446a9d` 2026-09-06, live as 0.2.22)

**Moved to `frontend/docs/passcode-lock.md` (2026-09-10) — read it BEFORE touching `**/passcode*` (store, kdf, gate, provider, screens, curtain), `utils/privacy_curtain*`, `#fp-curtain` in `web/index.html`, `e2e_lock_revoker.dart`, KEK/wrapping code (`encryption/content_key_wrap.dart`, `fpwk1:` envelopes), the auto-lock timer, or the erase panel

