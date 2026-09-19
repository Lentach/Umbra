---
paths:
  - "frontend/lib/widgets/chat_input_bar*"
  - "frontend/lib/widgets/composer*"
  - "frontend/lib/widgets/chat_action_tiles.dart"
  - "frontend/lib/utils/web_file_input.dart"
  - "frontend/lib/widgets/message/**"
  - "frontend/lib/services/media*"
---
# Composer, media, platform gotchas

Read **`frontend/docs/composer-media.md`** before the first edit (verbatim former `frontend/CLAUDE.md` §7). Keep a repro for behaviour changes here — the 2026-08-19 ship freeze was lifted by the owner 2026-09-19. Dependabot #174 (`file_picker` 11.0.3) stays deliberately open (`web_file_input.dart` depends on 11.0.2 DOM behaviour).
