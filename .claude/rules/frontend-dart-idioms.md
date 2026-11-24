---
paths:
  - "frontend/lib/models/**"
  - "frontend/lib/services/**"
  - "frontend/lib/providers/**"
  - "frontend/lib/utils/**"
  - "frontend/lib/constants/**"
  - "frontend/lib/config/**"
  - "frontend/lib/*.dart"
---
# Dart language idioms

Non-visual Dart under `frontend/lib/`: read **`.claude/skills/dart-modern-features/SKILL.md`** (records, patterns, switch expressions, class modifiers, extension types) before hand-rolling what Dart 3 already has, and **`.claude/skills/dart-seal-type-hierarchies/SKILL.md`** when a closed hierarchy — message kinds, key-bundle/device states, decryption verdicts — is switched over: `sealed` is what makes those switches exhaustive at compile time.

Visual work (`widgets/`, `screens/`, `theme/`) is covered by `frontend-flutter-design` instead.
When a file is also owned by a narrower rule, that rule wins on its own subject: `frontend-e2e-invariants` for `services/encryption/**`, device lists/links and the recovery phrase; `frontend-passcode-lock` for passcode/curtain/`content_key_wrap.dart`; `wire-contracts` for `socket_service.dart`, `connection_provider.dart`, `providers/connection/**`, `messaging_provider.dart`, `providers/messaging/**`; `frontend-composer-media` for `services/media*`. Idioms are style, never a licence to restructure those files.

