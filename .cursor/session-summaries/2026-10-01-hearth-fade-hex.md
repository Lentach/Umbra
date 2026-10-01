# Disappearing-message indicator: the cut-circle arc is now a hex ember

**Date:** 2026-10-01 · **Version:** unchanged (0.2.55) · **Tiers deployed:** none

## What was done
- `lib/widgets/hearth_fade_hex.dart` (was `hearth_fade_arc.dart`): `HearthFadeHexPainter` draws a pointy-top hexagon — accent frame, six edge bars that burn out clockwise from the top vertex (gap at each corner), and a centre hex coal whose alpha is `0.22 + 0.78 * progress`. `preRead` (was `dotted`) = bright frame + full core, no bars.
- Frame and bars share ONE stroke width (1.5 px small, 2.5 px ≥16 px, 4 px hero) so a lit bar recolours its edge. Frame colour is the accent at 0.24 (0.55 pre-read).
- `trackColor` removed from painter, `HearthFadeHexIndicator`, `HearthFadeHexHero` and all five callers (conversation tile, metadata row, voice row, composer banner, timer sheet). `_buildEphemeralPrefix` lost its `secondaryColor` param.
- Renamed `HearthFadeArc*` → `HearthFadeHex*` in lib + 4 tests; test names and `arcProgress` say "hex". Size boxes are `size × kHexWidthRatio` by `size`.
- Chats list glyph is 14 px (was 12) for sharpness; bubble/voice metadata stay 12 px so ephemeral bubbles keep their height; the banner stays 14×14.
- `scripts/dart-lint-baseline.json` 3156 → 3154 (floor lowered).
- Out-of-repo: none left (render server stopped, browser tab closed, throwaway harness edits reverted).

## Key files
- Edited: `conversation_tile.dart`, `disappearing_timer_sheet.dart`, `input/chat_input_bar.dart` (import + 2 lines), `message/message_metadata_row.dart`, `message/voice_message_content.dart`, 4 widget tests, `scripts/dart-lint-baseline.json`
- New: `frontend/lib/widgets/hearth_fade_hex.dart` (rename of `hearth_fade_arc.dart`)
- Read only (load-bearing): `hex_avatar.dart` (`kHexWidthRatio`, `hexPath`), `docs/composer-media.md`, `test/preview/glass_preview.dart`

## Verification
- CI: `success on 6311e5e1` — all 6 check-runs green (Flutter analyze and tests, Backend tests, E2E wire harness, Web Lock probe, isolated probes, Analyze). The handoff commit that carries this file is docs-only.
- `flutter test` on the 4 touched files: 30 passed. `dart-lint-ratchet.mjs`: PASS, IMPROVED 3156 → 3154 (baseline updated). `flutter analyze lib`: no errors/warnings. Full suite not run locally (no test added or removed, so the CLAUDE.md count is unchanged).
- Live drive: real `ConversationTile`, `ChatDetailScreen` bubbles, composer banner and timer sheet in a browser via `test/preview/glass_preview.dart` with a TEMPORARY `?ephemeral=1` seeding patch (reverted), Inter, light/teal/cosmic, 4× DPR; timer sheet with prefers-reduced-motion. Hero at a 1 h timer = progress 0.2 (`_heroProgress` floor) = one full lit edge plus a short stub.
- NOT verified: a real phone, Android native, iOS; dark-gray and blue themes; any size other than the three drawn.

## Notes for next session
- Next action: none pending. Not deployed — a web deploy needs a PATCH bump (`0.2.56`) and CI green first (`production-vm-deploy`).
- Owner-owed: whether the 1 h timer-sheet hero (0.2 = sparse) should show a fuller default.
- Recipe: to see ephemeral rows in the harness, temporarily seed `disappearAfterSeconds`/`expiresAt` on `_ChatListPreview._msg` and the cached messages, add `disappearingTimer` to the conversation JSON, and a `?screen=timer` that calls `showDisappearingTimerSheet`; `flutter run -d web-server -t test/preview/glass_preview.dart`, `page.setViewport({deviceScaleFactor: 4})`.
- Traps: headless `flutter test` cannot render Inter (google_fonts fetch fails, text is Ahem); use the web harness for any visual check (traps.md, Tests).
