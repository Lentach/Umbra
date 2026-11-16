# CI's Flutter tests run as 4 parallel directory legs; 39 test files and 16 weak tests removed

**Date:** 2026-11-16 · **Version:** unchanged (0.2.85, tests/CI only) · **Tiers deployed:** none

## What was done
- Measured: the single `flutter test` step was 7m14s of an 8m22s CI run; locally 325 files cost 1092s summed, only 400s of it in test bodies (median file 2.5s regardless of test count).
- `.github/workflows/ci.yml`: `frontend` is now analyze + Dart lint ratchet; new matrix `frontend-tests` runs one directory leg per runner (providers+root `*_test.dart`, services, widgets+models+theme, screens+main+utils); new `frontend-test-counts` downloads the 4 leg logs and runs the count gate.
- Not `--total-shards`: it splits test cases, so each shard still compiled all files (1 of 4 shards 165s locally vs 139s for the full suite).
- `scripts/verify-claude-frontend-test-counts.mjs`: `--log` may repeat; counts sum.
- 4 read-only scout audits of `frontend/test`: no test of dead code found; the suite is mostly regression/security pins. Applied only the firm rows: 38 same-unit small files folded into siblings (assertions kept), `web/index_html_viewport_test.dart` deleted, 16 weak tests deleted (constant echoes, bare not-throw, loads whose stored value equals the default, duplicates). 3304 → 3288 tests, 14 skipped.
- Skipped on purpose (audit marked optional/low-confidence/owner): `rpg_theme_golden_test.dart`, `bubble_redesign` 200px-cap negatives, `ping_glyph` wiring, `passcode_autolock` default, `page_load_nonce`, `e2e_lock_revoker` no-op, merges whose setUp differs (`box_sibling_rekey`, `box_withheld`, `encryption_send_race_probe`, …).
- Out-of-repo changes: none.

## Key files
- Edited: `.github/workflows/ci.yml`, `scripts/verify-claude-frontend-test-counts.mjs`, `scripts/dart-lint-baseline.json` (2493 → 2486), `CLAUDE.md` §3, `docs/agents/testing-and-ci.md`, `docs/agents/traps.md`, `frontend/docs/e2e-invariants.md`, `frontend/android/app/src/main/res/values/colors.xml` (comment), ~38 merge targets under `frontend/test/`.
- Deleted: 39 files under `frontend/test/` (list: `git show --stat 6cc3d7e9`).

## Verification
- CI: all 11 checks success on `54f32055`; run wall 3m04s (was 8m22s on `22aa53c`). Legs: providers 1m59s, services 2m55s, widgets 2m03s, screens 1m58s.
- `6cc3d7e9` was red: widgets leg `loading test/web (failed)` — the emptied dir is not in git. Fixed in `54f32055`.
- Local: the 4 legs ran 869 + 1276 (~14) + 622 + 521 = 3288 passed, 14 skipped; verifier with 4 `--log` → OK. Dart lint ratchet PASS 2486.
- Live drives: none — no app code changed (test files, CI, docs, one XML comment).

## Notes for next session
- Next action: none for this task; resume the hardening plan per the previous LATEST entry.
- The services leg is now the critical path (2m55s); split `test/services/box` into its own leg if it grows.
- Billable minutes: 3 more Flutter setups per run (~1 min each); watch the 2000-min free budget noted at the top of `ci.yml`.
- More merge/delete candidates remain (see the "skipped" bullet); each file saves ~2.5s of compile.
- Traps: `--total-shards` splits cases not files; eval `commit` mis-diffs CRLF here (both in traps.md).
