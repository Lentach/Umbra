---
description: Use when writing, fixing, or judging tests — Dart/Flutter under frontend/test, Jest specs and *.int-spec.ts suites under backend.
condition: ".*"
scope: "tool:edit(frontend/test/**), tool:write(frontend/test/**), tool:edit(frontend/test_e2e/**), tool:write(frontend/test_e2e/**), tool:edit(frontend/integration_test/**), tool:write(frontend/integration_test/**), tool:edit(backend/**/*.spec.ts), tool:write(backend/**/*.spec.ts), tool:edit(backend/**/*.int-spec.ts), tool:write(backend/**/*.int-spec.ts)"
---

# Tests: which skill owns which tier

Dart/Flutter (`frontend/test/**`, `*_test.dart`): read **`skill://dart-test-fundamentals`** (structure, `group`, lifecycle, `dart_test.yaml`) and **`skill://dart-matcher-best-practices`** (assertion quality) before adding tests; **`skill://dart-test-coverage`** when asked what is untested.

Backend (`backend/**/*.spec.ts`, `backend/**/*.int-spec.ts`): read **`skill://tdd`** — its `tests.md`/`mocking.md` are Jest-shaped.

Both tiers obey the repo's test bar (root `CLAUDE.md` §3 "Test bar"): a test earns its place only where a plausible bug would fail it. Never add a test so a change "has tests" — use a throwaway script and say so.
