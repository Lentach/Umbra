---
paths:
  - "frontend/test/**"
  - "frontend/test_e2e/**"
  - "frontend/integration_test/**"
  - "backend/**/*.spec.ts"
  - "backend/**/*.int-spec.ts"
---
# Tests: which skill owns which tier

Dart/Flutter (`frontend/test/**`, `*_test.dart`): read **`.claude/skills/dart-test-fundamentals/SKILL.md`** (structure, `group`, lifecycle, `dart_test.yaml`) and **`.claude/skills/dart-matcher-best-practices/SKILL.md`** (assertion quality) before adding tests; **`.claude/skills/dart-test-coverage/SKILL.md`** when asked what is untested.

Backend (`backend/**/*.spec.ts`, `backend/**/*.int-spec.ts`): read **`.claude/skills/tdd/SKILL.md`** — its `tests.md`/`mocking.md` are Jest-shaped.

Both tiers obey the repo's test bar (root `CLAUDE.md` §3 "Test bar"): a test earns its place only where a plausible bug would fail it. Never add a test so a change "has tests" — use a throwaway script and say so.
