# Honeycomb boot loader: regular hexagons, and the Flutter restore frame now matches it

**Date:** 2026-10-01 · **Version:** 0.2.54 → 0.2.55 · **Tiers deployed:** web (backend untouched, still 0.2.54 / 80957c7f)

## What was done
- `web/index.html` `#fp-boot`: the squashed hexagon (path was 52×52) is replaced by seven regular hexagons — centre core breathing, six-cell ring chasing at a .13 s step. Geometry is `hexPath`'s (radius 9, pitch √3·9+3.2 in a 64×64 viewBox).
- `#fp-curtain` padlock hexagon fixed to the regular shape (viewBox 48×56, lock re-centred). The two inline `<script>` blocks are untouched; the curtain still takes its colour from the `stroke` attribute.
- `.fp-boot-hint` reserves `min-height: 34px` (two lines) so the slow-path hint at 6 s does not move the centred column.
- New `lib/widgets/boot_honeycomb.dart` (`BootHoneycomb`) replaces the Material spinner at `AuthGate` `isRestoringSession` (`main.dart`). Accent from `RpgTheme.ephemeralAccent`; the bar is indeterminate; label/hint height is reserved (`_belowBar` 74.9) so the honeycomb stays put.
- Reduce-motion (`MediaQuery.disableAnimationsOf`) parks the loop (re-checked on every dependency change).
- Tests: `auth_gate_session_restore_test.dart` asserts `BootHoneycomb` (first test now provides `SettingsProvider`); new `boot_honeycomb_test.dart` (2 tests: animates / reduce-motion settles). Root `CLAUDE.md` count 3053 → 3055. `client-reference.md#cold-start-boot-loader` updated.
- Out-of-repo: none left. Scratch Bun servers (:8765, :3000), the managed browser tab, a Desktop preview HTML and temp videos were removed.

## Key files
- Edited: `frontend/web/index.html`, `frontend/lib/main.dart`, `frontend/test/main/auth_gate_session_restore_test.dart`, `frontend/docs/client-reference.md`, `frontend/pubspec.yaml`, `CLAUDE.md`
- New: `frontend/lib/widgets/boot_honeycomb.dart`, `frontend/test/widgets/boot_honeycomb_test.dart`
- Read only (load-bearing): `frontend/docs/passcode-lock.md`, `docs/design/flutter-ui-playbook.md`, `frontend/web/fp_boot.js`, `frontend/lib/widgets/hex_avatar.dart`

## Verification
- CI: `success on 0bc002d2` — all 8 check-runs green (Flutter analyze and tests, Backend tests, E2E wire harness, Web Lock probe, isolated probes, Analyze, 2× Dependabot).
- `flutter test` full suite via `verify-claude-frontend-test-counts.mjs`: 3055 tests / 14 skipped (count then bumped in `CLAUDE.md`). `dart-lint-ratchet.mjs`: PASS at the 3156 baseline. `flutter analyze` on the two new files: no issues. `verify-csp-inline-hashes.mjs`: OK (2 inline scripts).
- Live drives (release web build, served locally, `main.dart.js` held 4–8.5 s, tokens seeded, `/auth/refresh` stalled): DOM loader → Flutter honeycomb at the same pixel position in light, teal, blue, cosmic, dark, including with the hint visible. A 42 fps recording (normal and 6× CPU throttle) found no `PasscodeCurtain` frame between the two loaders (top-strip `YMIN<200` scan: 0 of 277 and 0 of 430 frames); `flutter-view` exists ~550–770 ms before `#fp-boot` is removed. Positive control: the same scan on a passcode-flag boot (curtain shown) fires on 128 of 130 frames (min YMIN 76), so the metric can see a padlock.
- Deploy: `deploy-web.ps1` at `629b81bb` (CI green on code commit `0bc002d2`; `629b81bb` is docs-only): web 0.2.55 live, post-deploy smoke 8/8 PASS, prod `index.html` serves the honeycomb (`fp-boot-c6`). The Settings footer and the loader were not checked on a phone.
- Not run: the playbook §5 design review (`designer` agent on the captures) — the owner approved the design from the previews; a review is still owed if wanted.
- NOT verified: a real phone, iOS Safari, Android native (the restore frame now shows `BootHoneycomb` there too), a slow phone's `PasscodeCurtain` timing (desktop Chromium only), a cold boot with the passcode ON end to end.

## Notes for next session
- Next action: none pending. The owner fully closes and reopens the PWA (never uninstalls); Settings footer should read `0.2.55 / 629b81bb`.
- The DOM loader and `BootHoneycomb` are a twin pair; the accent map in `fp_boot.js` is still unpinned by any test (existing trap).
- Owner-owed: none.
- Traps: twin pair (traps.md, Deploy); bash `$var` expansion + 300 s async; `edit` line numbers (both Agent tooling).
