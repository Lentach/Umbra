# Frontend client runtime and UI reference

Detail relocated from `frontend/CLAUDE.md` §2, §4, §6 and §9 on 2026-09-24 to keep that file under its context budget. Each heading below is the target of a one-line rule in `frontend/CLAUDE.md`; the rule there binds, this file carries the rationale, history and evidence. Bullets are moved verbatim (full original text) unless noted.

## Navigation and chat-entry route

- Navigation: `AuthGate` → restoring spinner while saved auth is being checked, then `AuthScreen` or `MainShell` (`IndexedStack`: Conversations/Contacts/Settings). **Above all of it, `MaterialApp.builder` wraps every route in `PortraitLockShell(child: PasscodeGate(child: …))`** — the passcode barrier must sit above the Navigator or a pushed chat route would paint over it (§10). Desktop width >=600 uses sidebar/detail. Mobile chat entry routes use `utils/instant_opaque_route.dart` — ENTRY stays opaque + zero-duration to avoid iOS/Web half-transition split-screen lag, while the POP is a 180ms fade-out (reduce-motion skips it) so back-out isn't a single teardown frame; regression `test/utils/instant_opaque_route_test.dart` guards both directions.

## Cold-start boot loader

- **Cold-start boot loader (`#fp-boot` in `web/index.html`, logic in `web/fp_boot.js`).** There is NO offline cache: Flutter 3.x's generated `flutter_service_worker.js` self-unregisters on `activate`, and `infra/nginx/fireplace.conf` serves `/` `Cache-Control: no-cache`. So a daily user stays warm in the HTTP cache (instant boot), but an idle-return or post-deploy launch re-downloads the whole shell (`main.dart.js` ~7.6 MB + local `canvaskit.wasm` ~6.9 MB + fonts) over the network — ~15 s on mobile with a BLANK screen, read as "broken" and swiped away. The inert DOM loader (shield + determinate fake-progress bar + localized "Wczytywanie…/Loading…", theme-accent + `flutter.locale_preference`) paints instantly and is removed on Flutter's `flutter-first-frame` event. The logic is an EXTERNAL same-origin file on purpose — an inline block would need a third CSP `script-src` sha256 (`infra/nginx/security-headers.conf`, `scripts/verify-csp-inline-hashes.mjs`); `'self'` covers `fp_boot.js`. It sits one z-index BELOW `#fp-curtain` so a locked relaunch still shows the shield on top. It MASKS the ~15 s, it does not shorten it — real fix is gzip/brotli + immutable `/canvaskit/` cache.

## Reactions context menu

- Reactions: context-menu quick row calls `MessagingActions.addReaction/removeReaction`; the chevron (`context-menu-expand-reactions`) expands `FireplaceEmojiPicker` in place via `computeExpandedReactionPickerLayout` (row + action panel unmount, bubble stays; never covers bubble/keyboard). Keep expanded overlay geometry based on `MediaQuery` read inside the `OverlayEntry` builder, not the pre-overlay message context, or iOS/PWA keyboard viewport changes will strand the picker. System back closes the menu via a `PopEntry` on the chat route. `emoji_picker_flutter`'s grid renders nothing under the widget-test binding — test emoji selection through the suggested row keys only.

## Emoji font

- Emoji glyphs MUST render with an emoji family as the PRIMARY `TextStyle.fontFamily` (`withEmojiFont` / `kEmojiFontFamily` + `kEmojiFontFamilyFallback` in `utils/jumbo_emoji.dart`) — NOT the ambient Inter font. Inter ships a monochrome U+2764 glyph and Flutter-web CanvasKit renders emoji with the primary font's glyph (ignoring the U+FE0F emoji-presentation request), so ❤️ shows a white outline while SMP emoji stay color; a `fontFamilyFallback` alone does NOT fix it (Inter primary wins). Applied to picker suggested-row/grid, reaction quick row + chips, jumbo + `buildInlineEmojiSpans`, and the conversation-list preview. Proof harness: `tool/heart_preview.dart`.

## Jumbo emoji

- Jumbo emoji (Telegram parity, static only — no animated emoji, ever: copyright + E2E metadata leak): emoji-only TEXT messages render outside the normal bubble surface via `utils/jumbo_emoji.dart` (`emojiOnlyCount` grapheme regex — `Extended_Pictographic`, flags, keycaps; digits/`#`/`*` excluded; tiers 1→82, 2→78, 3→64, 4→52, 5+→44). Metadata stacks UNDER the emote in a side-aligned `Column` (never an inline `Wrap` — it shoved lone emotes toward center) and uses `MessageMetadataRow.onChatSurface: true` + the received-side meta color: the on-bubble sent color is white and invisible on a light chat background. Mixed text+emoji stays in-bubble with emoji runs at `kInlineEmojiFontSize` (18) via `buildInlineEmojiSpans` (text/URLs stay 14). Applied in `TextMessageContent` and mirrored in `MessageContextMenuBubbleHighlight`; previews (reply/pinned/conversation list) deliberately stay small.

## Text-bubble metadata

- Plain text message metadata is a real `MessageMetadataRow` sibling in a `Wrap` next to `TextMessageContent` (single-line inline-time path). Multi-line/reply bubbles stack it in the `Column` WITHOUT an `Align` wrapper — `Align` greedily fills the bounded width and stretches every bubble to max width (the reply-to-emote stretch bug). Do not reintroduce Row-wide timestamp-width subtraction, fake placeholder spans, `WidgetSpan` inside message text, or `Stack`/`Positioned` timestamp overlays for text bubbles; those create empty rectangles or overlap/clamp wrapped/edited text.

## Unread merge

- `conversationsList` unread merge trusts the server count (open conversation forced to 0). It replaced an old `max(prev, server)` merge that could only raise counts and left a badge permanently stuck after the conversation was read. Tradeoff: a stale snapshot can briefly reset a just-incremented local count, but the next snapshot restores it (and the message is already in the loaded list).

## Honeycomb captions

- **Both honeycombs speak one caption language: hex + 11px `w600` name underneath.** The Chats `+` picker was avatar-only, which collapses to a single initial for anyone without a photo — unusable as an identifier. Its rows no longer overlap (`hexHeight + labelGap + labelHeight + rowGap`); the half-cell odd-row stagger is what still reads as a comb, exactly as on the Contacts board.

## Caption heights

- **Caption heights come from `measureCaptionHeight` (`utils/caption_metrics.dart`) — never a hand-rolled `TextPainter`.** It takes the BARE style and does the `DefaultTextStyle.of(context).style.merge(...)` itself, because that merge is the whole trap: `Text` merges into the ambient default, which carries a line height the bare style omits, so measuring the bare style under-reports ~4px per line. At one line the shortfall hid inside the Contacts board's 9px row slack; at two it overflowed the caption box. Both combs call it; a third caller cannot reintroduce the bug.

## Honeycomb picker reduce-motion

- **`ChatHoneycombPicker` re-checks reduce-motion on EVERY `didChangeDependencies`, and latches only the `forward()`.** Hoisting the `_entranceStarted` guard above the `MediaQuery.disableAnimationsOf` check looks like a tidy-up and silently breaks playbook §9: a user switching reduce-motion on mid-entrance keeps getting the animation. Regression: `conversations_honeycomb_picker_test.dart` "reduce motion turned on mid-entrance snaps the picker to its end state" (fail-before: the latched version sits at 0.637 opacity).

## Pending invitation label

- **A pending outbound invitation says so in a word, not a glyph.** Ghost cells on the Contacts board carried their state in `Icons.send_outlined` plus a screen-reader-only sentence — the sighted user got an arrow. They now render `invitationStatusPending` in `colorScheme.primary` (≥4.72:1 on every theme's field) under the name, and `ContactNetworkView` reserves a two-line `labelHeight` **only while `sentInvitees` is non-empty**, so the whole field pays the extra row height only until the last invitation resolves. Both strings are injected by `ContactsScreen` (`pendingInviteLabel`, `pendingInviteSemanticLabel`) — the view stays l10n-free by contract.

## Honeycomb wire routing

- **Honeycomb wire routing (`ContactHexLayout.routePath`) has two invariants; breaking either puts a wire through a hex.** A pointy-top lattice has NO straight vertical channel and NO clean long diagonal — a wide row's gaps sit exactly over the narrow row's CENTRES. So: vertical travel happens only inside a gap corridor (pitch/2 from either centre), and sideways travel only in the empty band between rows. The rim fan is per CORRIDOR (≤ `columnsWide + 1` rays), never per contact — a per-contact fan smears into a wedge past ~100 nodes. Gap-selection ties break OUTWARD, or a mirrored pair of contacts weaves the same way and the field stops being symmetric. **Horizontal rails were built and rejected by the owner (2026-07-29); do not reintroduce them.**

## Chats plus badge

- **The Chats `+` badge must have a door.** It counts `pendingRequestsCount` (server truth — the backend re-emits it after accept and decline, so it is never fixed up client-side), but the sheet behind it used to show friends only. `showChatHoneycombPicker` now returns `ChatPickerChoice` (`ChatPickerFriend` | `ChatPickerReviewInvitations` | `ChatPickerInviteNew`) and leads the comb with the senders of `friendRequests` as accent terminals (`HexAvatar(ember: 1)` + `invitationStatusPending`). Tapping one routes to `InvitationsScreen`; the picker NEVER accepts inline, because accept/decline own a scoped-failure and retry state machine that already lives there and a second copy would drift.

## UI verification loop and Dart MCP

- **Look at it.** Every UI change closes the loop `launch once → edit → hot reload → runtime errors → screenshot → compare to docs/design/liquid-glass/after/*.png → iterate`, across every theme touched (`light`/`teal`/`dark`/`blue`/`cosmic`). Widget tests are not visual verification. **The Dart MCP is the middle of that loop** (`mcp__dart_hot_reload`, `mcp__dart_get_runtime_errors`, `mcp__dart_widget_inspector`; `mcp__dart_roots add` first each session — setup, the per-machine mount path caveat, and the CDP drive recipe are in the playbook §0). **Probation:** if `grep -l 'mcp__dart\|hot_reload' .cursor/session-summaries/2026-1*` is still empty 30 sessions after 2026-09-10, delete the `.omp/mcp.json` entry. The render server runs as a BACKGROUND job (`hub start`) and is cancelled in cleanup — NEVER wait-to-finish on `flutter run` (it never exits; a subagent that waited on it hung 40 min). Readiness is NOT `/` returning 200 (that's the shell before the bundle compiles — the screenshot is blank): wait for the compile/"serving" log AND a non-blank screenshot (first compile 40–90 s), bounded (~120 s). A design-review subagent stays READ-ONLY and is handed already-captured screenshots; it must never launch `flutter run`.

## Motion reference implementation

- **Motion is capped and reduce-motion-aware.** Entrances 180–280 ms, `easeOut(Cubic)`, subtle distance; play entrances ONCE (not per provider rebuild); always honor `MediaQuery.disableAnimationsOf(context)`. Prefer Flutter built-ins (`AnimatedContainer`/`AnimatedSwitcher`/`Hero`); the only added UI dep is `skeletonizer` (loading skeletons). Reference impl: `conversation_list_skeleton.dart` (fetch-gated shimmer, static under reduce-motion) wired into `conversations_screen.dart`.

## Design skills history

- The user-level `flutter-frontend-design` skill is the Flutter-specific companion to the playbook. (The HTML/CSS/React `frontend-design` plugin that used to need a counter-instruction here was uninstalled 2026-09-10.)
