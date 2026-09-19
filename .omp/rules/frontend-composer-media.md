---
description: Use when touching the chat composer, attachment picker, file_picker/web_file_input, media/video/voice/image messages, the iOS composer viewport pin, or anything keyboard-adjacent in the chat screen.
condition: ".*"
scope: "tool:edit(frontend/lib/widgets/chat_input_bar*), tool:write(frontend/lib/widgets/chat_input_bar*), tool:edit(frontend/lib/widgets/composer*), tool:write(frontend/lib/widgets/composer*), tool:edit(frontend/lib/widgets/chat_action_tiles.dart), tool:write(frontend/lib/widgets/chat_action_tiles.dart), tool:edit(frontend/lib/utils/web_file_input.dart), tool:write(frontend/lib/utils/web_file_input.dart), tool:edit(frontend/lib/widgets/message/**), tool:write(frontend/lib/widgets/message/**), tool:edit(frontend/lib/services/media*), tool:write(frontend/lib/services/media*)"
---

# Composer, media, platform gotchas

Read **`frontend/docs/composer-media.md`** before the first edit (verbatim former `frontend/CLAUDE.md` §7). Keep a repro for behaviour changes here — the 2026-08-19 ship freeze was lifted by the owner 2026-09-19. Dependabot #174 (`file_picker` 11.0.3) stays deliberately open (`web_file_input.dart` depends on 11.0.2 DOM behaviour).
