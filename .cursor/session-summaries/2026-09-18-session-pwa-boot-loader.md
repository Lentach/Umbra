# PWA cold-start boot loader — makes the multi-MB shell re-download legible

**Date:** 2026-09-18 · **Version:** 0.2.49 → 0.2.50 (rebased onto master's 0.2.49 reaction-tokens release) · **Tiers deployed:** web (LIVE `0.2.50 / d37e2dcc`)

## What was done
- Added `#fp-boot` inert DOM boot loader to `frontend/web/index.html` (CSS in `<head>`; element at end of `<body>`, logic in the external `web/fp_boot.js`): brand shield + determinate fake-progress bar + localized label/hint; theme-accent + locale read from `localStorage`; removed on Flutter's `flutter-first-frame` event (bubbles to `window`). Paints with no Flutter frame, so it shows during the pre-boot blank window.
- Diagnosis: there is NO offline cache — Flutter 3.44's generated `flutter_service_worker.js` self-unregisters on `activate` — and `infra/nginx/fireplace.conf` serves `/` `Cache-Control: no-cache`. So every idle-return / post-deploy launch re-downloads the whole shell (`main.dart.js` 7.6 MB + local `canvaskit.wasm` 6.9 MB + fonts) over the network with a blank screen (~15 s on mobile); daily users stay warm in the HTTP cache and never see it.
- Progress bar decelerates asymptotically toward 99% (never a hard clamp/freeze), finishes to 100% on first frame, then tears the loader down after 180 ms.
- Locale reads `flutter.locale_preference`, defaults Polish to match `settings_provider.dart:94-99`; deliberately NO `navigator.language` sniff (it was showing an English loader then a Polish app on empty/evicted storage).
- Static default `Wczytywanie…` in the label div so text paints even before the script runs (the `defer` 251 KB `jsqr.js` blocks DOMContentLoaded on exactly the slow path this exists for).
- Externalized the loader logic to `web/fp_boot.js` (loaded `<script src>`, same-origin): an INLINE block would need a third CSP `script-src` sha256, but `'self'` covers an external file — `scripts/verify-csp-inline-hashes.mjs` stays green with NO `infra/nginx/security-headers.conf` edit or VM re-apply. Matches that conf's documented enforcement-flip plan (item 2). A literal `<script>` in the surrounding HTML comment tripped the verifier's naive regex — reworded.
- `frontend/CLAUDE.md` §4: bullet documenting the cold-start cause + loader. Version bump `0.2.48 → 0.2.49` in `frontend/pubspec.yaml`.

## Key files
- Edited: `frontend/web/index.html`, `frontend/CLAUDE.md`, `frontend/pubspec.yaml`
- New: `frontend/web/fp_boot.js`, this summary
- Read only (load-bearing): `frontend/docs/passcode-lock.md` (`#fp-curtain` interaction), `infra/nginx/fireplace.conf`, `frontend/build/web/flutter_service_worker.js` + `flutter_bootstrap.js`, `frontend/lib/providers/settings_provider.dart`, `deploy-web.ps1`

## Verification
- `flutter test test/utils/web_document_background_test.dart` → **7/7** (the only automated test that reads index.html; curtain accent map still green).
- Browser drive (headless Chromium, CDP throttle ~200–300 kbit/s): loader paints instantly on `light` + `dark` themes; correct accent (`#C2410C` light / `#5C9EAD` dark) + Polish label; bar creeps 20→39→50→59%; 6 s hint reveals; empty-storage default = Polish `Wczytywanie…`; removed on `flutter-first-frame` (deterministic dispatch → element gone, then un-throttled full boot to Chats). Screenshots in transcript.
- `flutter build web --release --no-web-resources-cdn` succeeded (152 s). `build/web` was hand-patched for the smoke tests only — a **defines-less throwaway**; must NOT be published via `deploy-web.ps1 -SkipBuild` (a real deploy runs `flutter clean` + build with defines).
- `node scripts/verify-csp-inline-hashes.mjs` → OK (2 inline scripts; loader is external, no third hash). **Execution proof** (fresh headless Chromium, served build): `window.__fpBoot` set (fp_boot.js RAN), `#fp-boot` REMOVED after boot, Flutter login screen painted — the external script executes and self-removes, so it cannot brick the app behind an opaque overlay.
- **DEPLOYED.** Merged to master (fast-forward `d37e2dcc`, PR #180), CI **5/5**, `deploy-web.ps1` smoke **7/7** (`/version.json` 0.2.50, `main.dart.js` contains `d37e2dcc`, 7 headers, Flutter view rendered). NOT verified on a real phone / iOS Safari. The loader MASKS the ~15 s; it does not shorten the download.

## Notes for next session
- **Do FIRST — brick risk from externalizing:** if `fp_boot.js` (served `no-cache`, fetched every launch) fails to load while the rest of the shell boots, nothing registers the `flutter-first-frame` listener and the opaque `#fp-boot` (z-index 2147483646) never lifts → app unusable, worse than the blank screen. `script-src-attr 'none'` forbids an `onerror` attr. Fix: a Dart post-first-frame interop that does `document.getElementById('fp-boot')?.remove()` (web-only, stub for native), so teardown never depends on that file. Low probability (same-origin atomic deploy, 4 KB vs 14 MB shell) but severe.
- **Owner-owed, bigger real fix:** nginx has no `gzip_types`/brotli for JS/wasm, so 7.6 MB `main.dart.js` + `canvaskit.wasm` go over the wire uncompressed; add `gzip_types application/javascript application/wasm …` (or `gzip_static`) **and** `Cache-Control: public, max-age=31536000, immutable` on `/canvaskit/` (byte-identical per `engineRevision`) — keep index.html / bootstrap / main.dart.js / version.json on `no-cache`. ~3–4× cold-start cut, far bigger than the loader. Verify: `curl -sI -H 'Accept-Encoding: br' https://fireplace.ignorelist.com/main.dart.js | grep -i content-encoding`.
- Passcode-lock users still see the static `#fp-curtain` (z-index above `#fp-boot`) during boot — no progress bar for them; deliberate for now. Raise `#fp-boot` above the curtain (both opaque, no privacy loss) if the owner wants the bar there too.
- A real offline shell cache (custom SW) is the deep fix; needs owner sign-off in an E2E app.
