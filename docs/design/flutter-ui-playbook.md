# Flutter UI Playbook — Fireplace

**Read this before building or changing any Flutter UI.** It exists because agent-built UI here has been low-quality "AI slop": ad-hoc colors, no motion, never actually looked at. This playbook is the anti-slop contract for THIS repo (Flutter, not web).

> The global `frontend-design` plugin skill is written for **HTML/CSS/React** (CSS variables, the Motion library, web fonts). Ignore its stack-specific advice here — this playbook overrides it. Keep its one good instinct: commit to an intentional aesthetic instead of a timid default.

## 0. The one rule that matters most: LOOK AT IT

Slop ships because the widget is written, compiles, and is never rendered. Every UI change MUST close this loop before you call it done:

```text
launch once → edit → hot reload → runtime errors → screenshot → compare to docs/design/liquid-glass/after/*.png → critique → iterate
```

- Web is the fastest surface: run `flutter run -d web-server --web-port <p> -t tool/preview/glass_preview.dart` (or `-d chrome`) as a BACKGROUND job, and CANCEL it in cleanup. NEVER await its completion — `flutter run` never exits, so blocking / `job poll`-to-finish on it hangs (a review agent burned 40 min this way). **Readiness is NOT `/` returning 200** — that's just the index shell before the bundle compiles, and a screenshot then is BLANK (learned the hard way). Real readiness: the job has logged its compile/"serving" success (non-blocking log check) AND the browser actually rendered the expected content (re-`tab.screenshot()` if blank; the first compile can take 40–90s). Bound the wait (~120s) and give up rather than block. Then judge the screenshot like a designer; do not just assert "looks good."
- Compare against the accepted references in `docs/design/liquid-glass/after/*.png` and the spec in `docs/design/liquid-glass/SPEC.md`. If it does not match the established look, it is wrong.
- Check **every theme you touched** (`light`, `teal`, `dark`, `blue`, `cosmic`) and both light/dark — a color that works in one theme is often invisible in another (see the jumbo-emoji meta-color trap in `frontend/CLAUDE.md` §6).
- **The Dart MCP is the middle of the loop** (since 2026-09-10; on a 30-session probation — `frontend/CLAUDE.md` §9). Once `flutter run` is serving: `mcp__dart_hot_reload` applies an edit in ~1 s instead of a 40–90 s rebuild; `mcp__dart_get_runtime_errors` returns red-screen/console errors without a screenshot; `mcp__dart_widget_inspector` reads the live tree; `mcp__dart_analyze_files` checks only the files you touched. **First call each session:** `mcp__dart_roots add file:///<abs path>/frontend` — every tool answers "no roots" until then. **The mount is per-machine:** the committed `.omp/mcp.json` points at THIS PC's pub-cache `dart_mcp_server.bat` (1.1.1 since 2026-09-12 — its single changelog entry pushes agents to hot-reload proactively; the SDK-bundled `dart mcp-server` is 0.1.4). On another clone, repoint `command`/`args` (`dart pub global activate dart_mcp_server`, then the local `Pub/Cache/bin` path) or the MCP is silently dead.
- **Driving the app for a two-party or form flow:** Flutter's semantics tree does not populate from synthetic clicks, so `tab.observe()` returns nothing useful. Use pixel-coordinate clicks from screenshots and CDP `Input.insertText` for typing; two isolated Chromes on separate `--remote-debugging-port`s for two-party ceremonies; read a link code from the focused field's mirrored DOM `<input>`. An occluded Chrome window is `hidden` and Flutter stops ticking — bring it to the front before screenshotting, or the transition is frozen mid-frame.
- Widget tests do NOT count as visual verification. They prove logic, not that it looks good.

## 1. Use the design system — never invent

Inventing values is the #1 slop source. Everything you need already exists:

- **Colors:** `RpgTheme` static tokens + `FireplaceColors.of(context)` (ThemeExtension) + `GlassTheme.of(context)`. NEVER hardcode a `Color(0x...)` in a screen/widget. If a color is missing, add it to the theme, not the widget.
- **Glass vs content grammar (locked, `SPEC.md` §1):** glass lives ONLY on floating chrome (top capsules, bottom-nav pill, composer pill, sheets/menus). Content — conversation rows, message bubbles — stays **opaque**. Never put translucency on a text surface.
- **Type:** `RpgTheme.bodyFont(...)` / the RPG font helpers via `google_fonts`. Do not introduce a new font family per screen.
- **Spacing/radius:** colors and fonts MUST be tokens; spacing need not be (there is no full spacing-token system yet). Reuse `SPEC.md` §5 metrics for chrome/bubble geometry (pills radius 26, bubbles radius 16, etc.), keep spacing consistent with neighboring widgets, and centralize any value you repeat. Standard literals (`8`, `12`, `16`) are fine; scattered arbitrary paddings that fight neighbors read as slop.
- **Contrast is a gate, not a suggestion:** every text-on-surface pair must clear WCAG 4.5:1. `SPEC.md` §8 has the computed table; recompute on any color change.

## 2. Motion spec (approved values)

Motion makes UI feel alive — but uncapped, replayed, or unavoidable motion is just a fancier slop. Rules:

| Aspect | Rule |
|---|---|
| Entrance duration | 180–280 ms. Never > 400 ms for UI chrome/content. |
| Curve | `Curves.easeOut` / `easeOutCubic` for entrances; `easeInOut` for state changes. No linear. |
| Distance | Subtle: `slideY` begin ≤ 0.08, opacity 0→1. No big flies-across-screen moves. |
| Stagger | Cap it: only the first ~6 items stagger (≤ 40 ms step). Never `index * step` unbounded — item 50 must not wait 2 s. |
| Replay | Entrance plays ONCE per element, not on every provider rebuild. Track "already animated" ids (see the conversation-list showcase). |
| Reduce-motion | ALWAYS honor `MediaQuery.disableAnimationsOf(context)`: skip entrances, swap shimmer for a static fill. |
| Simultaneity | One well-orchestrated moment (staggered list-in, one hero) beats scattered micro-jitters everywhere. |

**Ratified exception — user-triggered travel (owner, 2026-07-24).** The Contacts honeycomb
fills a contact's route from their hex up to the core in **480 ms** on tap
(`contact_network_view.dart`, `_routeController`). It knowingly exceeds the 400 ms cap: the
travel IS the interaction's feedback, not chrome, and the owner slowed it from 260 ms on
device precisely so the link reads ("it works better now, links is slower and visible to
user"). Reduce-motion still short-circuits to an instant open. Do not "fix" this back to
400 ms, and do not treat it as licence for slow chrome — the cap stands everywhere else.

### Where motion is BANNED (device-proven, do not relearn the hard way)

`frontend/CLAUDE.md` §7 documents these in detail — animating them causes real iOS/Android bugs:

- **Composer / keyboard-adjacent blocks** — no `SizeTransition`/entrance. A ~300px block animating through the keyboard show/hide window = iOS counter-pan flash, Android stale-region void. Panels mount/unmount INSTANTLY by design.
- **Chat-entry route** — `utils/instant_opaque_route.dart` is deliberately zero-duration to avoid iOS/Web split-screen lag. Do not add a page transition there.
- **Emoji / message content** — no animated emoji, ever (copyright + E2E metadata leak, §6).

Motion belongs on: **list entrances, cards/profile (e.g. the User Card), buttons, loading states, hero avatars** — not the messaging hot paths.

## 3. Animation & polish toolkit

Installed (`pubspec.yaml`): `skeletonizer` (loading skeletons). Everything else below is a Flutter built-in or an OPTIONAL package you would add to `pubspec.yaml` first.

- **Built-ins first** (no dependency, cover most cases): `AnimatedContainer`, `AnimatedOpacity`, `AnimatedSwitcher`, `AnimatedAlign`, `TweenAnimationBuilder`, `Hero` (shared-element), `PageRouteBuilder` (custom route transitions), `HapticFeedback.lightImpact()`.
- **`skeletonizer`** (installed) — skeleton loaders instead of spinners. Gate on a REAL fetch signal (e.g. `ConversationsProvider.hasLoadedConversationsOnce`), never a timer — a timer lies about state (an empty account is not "loading"). Use `SolidColorEffect` under reduce-motion.
- **Optional (NOT installed — add the dep first, only if it earns its place):** `flutter_animate` (declarative `.animate().fadeIn().slideY()` entrances), `animations` (Material shared-axis / container-transform / fade-through), `lottie` / `rive` (vector micro-animations). Adding a dependency is a real cost in this repo (pinned deps, bleeding-edge SDK) — prefer the built-ins above.

**Reference implementation:** `frontend/lib/widgets/conversation_list_skeleton.dart` wired into `conversations_screen.dart` (`_buildConversationList`) — a fetch-gated shimmer skeleton that swaps to a static fill under reduce-motion. `skeletonizer` is the only added UI dependency; use Flutter built-ins (`AnimatedContainer`/`AnimatedSwitcher`/`Hero`) for entrance/transition motion. Copy this shape.

## 4. Reference-driven prompts (for whoever delegates UI work)

"Make it look nice" produces slop. Give the agent a target and constraints:

- Hand it a target image (`docs/design/.../after/*.png`, a mockup, or an app screenshot you like) + `SPEC.md` + the theme token file.
- State the motion intent explicitly (e.g. a subtle fade+slide list entrance, or a shared-element `Hero`).
- Require the screenshot loop (§0) and a per-theme check.

## 5. Design-review checkpoint

Non-trivial UI work gets a design review before merge: spawn the `designer` agent with (a) the rendered screenshot(s) you already captured, (b) `docs/design/liquid-glass/SPEC.md`, (c) this playbook, and tell it to read root `CLAUDE.md`, `frontend/CLAUDE.md`, and `.cursor/session-summaries/LATEST.md` (subagents inherit no context). The review agent MUST stay READ-ONLY and judge from the screenshots — it must NOT launch `flutter run` / a render server itself (that hangs it). It critiques against the spec/references and flags slop, contrast failures, and banned-zone motion.
