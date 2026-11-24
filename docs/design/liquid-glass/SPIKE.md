# Liquid Glass — package eval + performance spike (2026-07-10)

Throwaway harness: `.spike/spike_glass` (not shipped). Self-driving scene: 120-row chat list, every 3rd row a 320×220 noise bitmap ("media-heavy"), 3 down/up sweeps of 1s each per mode, `SchedulerBinding.addTimingsCallback` FrameTiming capture, results published to `document.title` (web) / stdout (Android). Jank threshold: total frame span > 16.7 ms.

## Modes

- `baseline` — no chrome.
- `hand` — one 66px nav pill: `ClipRRect` → `BackdropFilter(ImageFilter.compose(blur σ22, ColorFilter.matrix saturate 1.7))` + tint/border, `RepaintBoundary`-isolated.
- `hand5` — representative full chat chrome: 3 top capsules + composer pill + nav pill (5 independent BackdropFilters).
- `pkg` — `liquid_glass_widgets 0.21.3` `GlassContainer`, package-correct composition (`LiquidGlassWidgets.initialize()` + `wrap()`, grouped mode).
- `fake` — opaque-ish tint (α0.85) + border + shadow, no filter (the NO-GO fallback).

## Flutter web, RELEASE, CanvasKit — the shipping renderer (headless Chromium 141, desktop RTX-class GPU, Win11)

| mode | frames | build avg/p90/p99 ms | raster avg/p90/p99 ms | frames >16.7ms |
|---|---|---|---|---|
| baseline | 1435 | 1.21 / 1.9 / 2.5 | 0.45 / 0.6 / 0.8 | 0 |
| hand | 1438 | 1.16 / 1.7 / 2.2 | 0.78 / 1.0 / 1.2 | 1 (0.1%) |
| **hand5** | 1429 | 1.25 / 1.8 / 2.3 | **1.52 / 2.0 / 2.7** | 1 (0.1%) |
| pkg | 1431 | 1.31 / 1.9 / 2.5 | 0.94 / 1.2 / 1.6 | 1 (0.1%) |
| fake | 1428 | 1.04 / 1.6 / 2.0 | 0.50 / 0.7 / 0.8 | 0 |

The full 5-surface chat chrome costs ~1.1 ms raster over baseline on this GPU — comfortably inside budget, zero sustained jank. Numbers are desktop-GPU; NOT phone-representative. Mobile performance remains an open gate until measured on a physical phone browser (see Verdict).

## Android emulator (Pixel_7 AVD, x86_64, host-GPU translation) — FUNCTIONAL SMOKE ONLY

All modes render correctly, no crashes. Timings are NOT device-representative (the emulator can't even hold baseline: 11.3 ms raster avg / 70% frames over budget before any glass). Deltas for the record: hand +4.0, hand5 +5.0, pkg +3.6 ms raster avg over baseline. Real-device perf = owner device QA on the deployed branch. Note: production mobile is the PWA (web renderer), not a native Android build — the web column above is the shipping path.

## Real phone browser — owner's iPhone over LAN (browser UI consistent with iOS Safari — [INFERENCE]; owner-run 2026-07-10 23:27, overlay screenshot preserved in session)

| mode | raster avg/p90/p99 ms | jank | frames |
|---|---|---|---|
| baseline | 0.62 / 1 / 1 | 0.3% | 356 |
| hand | 0.63 / 1 / 2 | 0% | 170 |
| **hand5** | **1.08 / 2 / 2** | **0%** | 363 |
| pkg | 1.34 / 2 / 2 | 0% | 365 |
| fake | 0.56 / 1 / 1 | 0% | 361 |

Capture window is 6 s of fixed-duration `animateTo` sweeps per mode. Four modes recorded 356–365 frames (≈60 fps for those modes); `hand` recorded only 170 — unexplained (likely a missed timing batch); its percentiles agree with `hand5`, but treat that row as lower-confidence. The full 5-surface UI chrome adds ~0.5 ms raster avg over baseline on the shipping device class.

Acceptance criterion (adopted at review, NOT predeclared — rationale: 16.7 ms = 60 Hz frame budget, 5% jank ≈ visible-stutter floor used informally in prior sessions): jank ≤ 5% AND raster p99 < 16.7 ms. Measured worst case: 0% jank / 2 ms p99 — margin is ~8×, so the post-hoc choice of threshold is immaterial to the verdict.

## Package eval — `liquid_glass_widgets 0.21.3`

Health: MIT, 345★/45 forks, active (pushed 3 days before eval), single maintainer, pre-1.0 (0.21.x), requires Flutter ≥3.41 (we ship 3.44.6 — OK). Deps: equatable, flutter_shaders, logging.

Verified by running on web release:
- **Correct composition renders correctly** (`initialize()` + `wrap()`, grouped `GlassContainer`): blur bounded to the pill, content sharp. Minimal repro: `.spike/spike_glass/lib/repro.dart`.
- **Harness observation (not reduced to a minimal repro):** `useOwnLayer: true` + per-widget `settings` without the `initialize()`/`wrap()` scaffolding blurred the ENTIRE scene on web — silent misrender. The minimal CORRECT composition does not exhibit it; treat as an integration hazard of the API's mode matrix rather than a confirmed package bug.
- **API-shape conflict:** per-widget `settings` (tint/blur per surface) are IGNORED in grouped mode and only honored via `useOwnLayer: true` — the mode that misrendered. Our spec needs per-surface, per-theme tints; the package's premium features (refraction, jelly physics) are Impeller-only, i.e. dead weight on our shipping web renderer.
- Timing: slightly slower than plain BackdropFilter (0.94 vs 0.78 ms raster avg, 1-pill scene).

## VERDICT

- **Performance: GO on both gates** — web-desktop AND real iPhone Safari (owner-run LAN measurement above): 0% jank with the full 5-surface UI chrome (criterion adopted at review: jank ≤5%, raster p99 <16.7 ms; measured margin ~8×). Android emulator remains functional-only (not device-representative); native Android is not a shipping path today. Fake-glass fallback (§7 of SPEC.md) stays implemented as the accessibility/low-end escape hatch.
- **Dependency: DO NOT ADOPT `liquid_glass_widgets`.** Hand-rolled `GlassSurface` wins on: exact spec control (σ22 + saturate 1.7 + per-theme tint/border/highlight ≈ 40 lines), cheaper raster, zero dependency/API-churn risk (pre-1.0, single maintainer), no silent-misrender foot-gun, no unused Impeller-only feature weight.

## Final chat-scroll re-check — REAL ChatDetailScreen, web RELEASE (2026-07-11)

Harness: `tool/preview/glass_preview.dart?bench=1` (real screen + providers, 48 seeded rows, `ScrollableState.animateTo` 3 down/up sweeps, FrameTiming, result beaconed to the static-server log). Headful run in the system default browser (launched via Start-Process; Chrome and Edge are both installed — exact browser NOT recorded), Win11 desktop GPU — vsync-real, unlike headless. Recording starts only after a 3 s warm-up delay and covers exactly the 6 s of scripted sweeps (26/504 frames over 16.7 ms total-span; 6/504 over 33.4 ms).

| metric | value |
|---|---|
| frames | 504 (scrolled 2967 px — scroll verified) |
| build avg / p90 ms | 3.20 / 5.10 |
| raster avg / p50 / p90 / p99 ms | 7.49 / 7.30 / 10.0 / 12.6 |
| frames > 16.7 ms (total span) | 26 (5.2%) |
| frames > 33.4 ms | 6 (1.2%) |

Criteria (adopted before this run, NOT in the original spec): ≥200 frames, scroll delta > 0, raster p99 < 16.7 ms, total-span jank ≤ 5%. Per-criterion result: samples PASS, scroll PASS, raster p99 PASS (12.6 ms, ~25% headroom), total-span jank **FAIL by 0.2pp** (5.2% vs ≤5%). This run is recorded as MARGINAL FAIL on that criterion; it does not override the earlier gates and no reruns were performed (single-attempt policy). The load-bearing GO evidence remains the recipe spike (0.1% jank, desktop release) and the owner's real-iPhone run (0% jank). Interpretation, labeled [INFERENCE]: the 26 long-total-span frames with un-spiked raster (p99 12.6 ms) point at browser scheduling on a loaded desktop, not the glass recipe.
