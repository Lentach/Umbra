---
description: Use when writing non-visual Dart in frontend/lib — models, services, providers, utils, constants.
condition: ".*"
scope: "tool:edit(frontend/lib/models/**), tool:write(frontend/lib/models/**), tool:edit(frontend/lib/services/**), tool:write(frontend/lib/services/**), tool:edit(frontend/lib/providers/**), tool:write(frontend/lib/providers/**), tool:edit(frontend/lib/utils/**), tool:write(frontend/lib/utils/**), tool:edit(frontend/lib/constants/**), tool:write(frontend/lib/constants/**), tool:edit(frontend/lib/config/**), tool:write(frontend/lib/config/**), tool:edit(frontend/lib/*.dart), tool:write(frontend/lib/*.dart)"
---

# Dart language idioms

Non-visual Dart under `frontend/lib/`: read **`skill://dart-modern-features`** (records, patterns, switch expressions, class modifiers, extension types) before hand-rolling what Dart 3 already has, and **`skill://dart-seal-type-hierarchies`** when a closed hierarchy — message kinds, key-bundle/device states, decryption verdicts — is switched over: `sealed` is what makes those switches exhaustive at compile time.

Visual work (`widgets/`, `screens/`, `theme/`) is covered by `frontend-flutter-design` instead.
When a file is also owned by a narrower rule, that rule wins on its own subject: `frontend-e2e-invariants` for `services/encryption/**`, device lists/links and the recovery phrase; `frontend-passcode-lock` for passcode/curtain/`content_key_wrap.dart`; `wire-contracts` for `socket_service.dart`, `connection_provider.dart`, `providers/connection/**`, `messaging_provider.dart`, `providers/messaging/**`; `frontend-composer-media` for `services/media*`. Idioms are style, never a licence to restructure those files.

