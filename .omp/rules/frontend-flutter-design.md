---
description: Use when building or restyling anything visual in the Flutter app — a widget, screen, dialog, list, animation, or theme — including "polish this" / "add a loading state" requests.
condition: ".*"
scope: "tool:edit(frontend/lib/widgets/**), tool:write(frontend/lib/widgets/**), tool:edit(frontend/lib/screens/**), tool:write(frontend/lib/screens/**), tool:edit(frontend/lib/theme/**), tool:write(frontend/lib/theme/**)"
---

# Flutter visual work

Read **`skill://flutter-frontend-design`** before the first visual edit (file: `.claude/skills/flutter-frontend-design/SKILL.md`). It owns the render→screenshot→critique loop, the theme/token rules (no hardcoded `Color(0xFF…)` outside `frontend/lib/theme/`), the motion caps, and the reduce-motion requirement.

Keyboard-adjacent chrome is a documented do-not-animate zone — `frontend/docs/composer-media.md` wins over anything the skill suggests there.
Under `widgets/message/**`, `chat_input_bar*`, `composer*` and `chat_action_tiles*`, `frontend-composer-media` is the owner and wins on every question, not just animation.

