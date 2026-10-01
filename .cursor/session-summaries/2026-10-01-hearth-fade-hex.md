# Disappearing-message indicator: the cut-circle arc is now a hex ember

**Date:** 2026-10-01 · **Version:** 0.2.55 → 0.2.57 (0.2.56 hex, 0.2.57 hero scale) · **Tiers deployed:** web (backend untouched, still 0.2.54 / 80957c7f)

## What was done
- `lib/widgets/hearth_fade_hex.dart` (was `hearth_fade_arc.dart`): `HearthFadeHexPainter` draws a pointy-top hexagon — accent frame, six edge bars that burn out clockwise from the top vertex (gap at each corner), and a centre hex coal whose alpha is `0.22 + 0.78 * progress`. `preRead` (was `dotted`) = bright frame + full core, no bars.
- Frame and bars share ONE stroke width (1.5 px small, 2.5 px ≥16 px, 4 px hero) so a lit bar recolours its edge. Frame colour is the accent at 0.24 (0.55 pre-read).
- `trackColor` removed from painter, `HearthFadeHexIndicator`, `HearthFadeHexHero` and all five callers (conversation tile, metadata row, voice row, composer banner, timer sheet). `_buildEphemeralPrefix` lost its `secondaryColor` param.
- Renamed `HearthFadeArc*` → `HearthFadeHex*` in lib + 4 tests; test names and `arcProgress` say "hex". Size boxes are `size × kHexWidthRatio` by `size`.
- Chats list glyph is 14 px (was 12) for sharpness; bubble/voice metadata stay 12 px so ephemeral bubbles keep their height; the banner stays 14×14.
- `disappearing_timer_sheet.dart`: new top-level `disappearingHeroProgress(totalSeconds)` (log scale 5 s … 30 d → 0.35–1.0, Off 0.15) replaces the linear `_heroProgress()`. The 0.2 and then 0.6 linear floors put every timer under ~6 d / ~18 d on one hex; now 5 s ≈ 2 edges, 1 m ≈ 3, 1 h ≈ 4, 1 d ≈ 5, 7 d ≈ 5.5, 30 d full. Decorative only; the timer value is untouched.
- `scripts/dart-lint-baseline.json` 3156 → 3154 (floor lowered). `frontend/pubspec.yaml` 0.2.55 → 0.2.57. Root `CLAUDE.md` Flutter count 3055 → 3057 (2 new tests: `disappearingHeroProgress` distinct/monotonic, off + clamping).
- Out-of-repo: none left (render server stopped, browser tab closed, throwaway harness edits reverted).

## Key files
- Edited: `conversation_tile.dart`, `disappearing_timer_sheet.dart`, `input/chat_input_bar.dart` (import + 2 lines), `message/message_metadata_row.dart`, `message/voice_message_content.dart`, 4 widget tests, `scripts/dart-lint-baseline.json`
- New: `frontend/lib/widgets/hearth_fade_hex.dart` (rename of `hearth_fade_arc.dart`)
- Read only (load-bearing): `hex_avatar.dart` (`kHexWidthRatio`, `hexPath`), `docs/composer-media.md`, `test/preview/glass_preview.dart`

## Verification
- CI: `success on 279007e2` — all 6 check-runs green (Flutter analyze and tests, Backend tests, E2E wire harness, Web Lock probe, isolated probes, Analyze); `6311e5e1` (hex) and `50cb524b` (0.2.56) were green too. Later commits carry only docs/summary.
- Full suite via `verify-claude-frontend-test-counts.mjs`: 3057 tests / 14 skipped, matches `CLAUDE.md`. Sheet tests 16 passed. `dart-lint-ratchet.mjs`: PASS at the 3154 baseline. `flutter analyze` on the touched files: no errors/warnings.
- Deploy: `deploy-web.ps1` at `279007e2` → web 0.2.57 live, `/version.json` gitCommit `279007e2` (curl-checked), post-deploy smoke 8/8 PASS (bundle contains the commit). 0.2.56 (`50cb524b`) was deployed earlier the same way, smoke 8/8.
- Live drive (before deploy): real `ConversationTile`, `ChatDetailScreen` bubbles, composer banner and timer sheet in a browser via `test/preview/glass_preview.dart` with TEMPORARY seeding patches (reverted), Inter, light/teal/cosmic, 4× DPR. The 0.2.57 hero was driven with `?screen=timer&t=<seconds>` for Off/5 s/1 m/1 h/1 d/7 d/30 d in light and cosmic, reduce-motion: the lit edges and core grow with the duration.
- NOT verified: a real phone, Android native, iOS; dark-gray and blue themes; the Settings footer on a phone (should read `0.2.57 / 279007e2`).

## Notes for next session
- Next action: none pending. The owner fully closes and reopens the PWA (never uninstalls); Settings footer should read `0.2.57 / 279007e2`.
- Owner-owed: none.
- Recipe: to see ephemeral rows in the harness, temporarily seed `disappearAfterSeconds`/`expiresAt` on `_ChatListPreview._msg` and the cached messages, add `'disappearingTimer': 3600` to the conversation JSON (without it `?screen=timer` opens in "Off", hero 0.15), and a `?screen=timer` that calls `showDisappearingTimerSheet`; `flutter run -d web-server -t test/preview/glass_preview.dart`, `page.setViewport({deviceScaleFactor: 4})`. Hot restart (`R`) does not apply in web-server mode: relaunch.
- Traps: headless `flutter test` cannot render Inter (google_fonts fetch fails, text is Ahem); use the web harness for any visual check (traps.md, Tests).
- The harness seed can take the timer from the URL (`'disappearingTimer': int.parse(Uri.base.queryParameters['t'] ?? '0')`), which makes a per-duration drive a loop of `goto`s instead of picker taps.
