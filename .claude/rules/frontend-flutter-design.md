---
paths:
  - "frontend/lib/widgets/**"
  - "frontend/lib/screens/**"
  - "frontend/lib/theme/**"
---
# Flutter visual work

Read **`.claude/skills/flutter-frontend-design/SKILL.md`** before the first visual edit. It owns the render→screenshot→critique loop, the theme/token rules (no hardcoded `Color(0xFF…)` outside `frontend/lib/theme/`), the motion caps, and the reduce-motion requirement.

Keyboard-adjacent chrome is a documented do-not-animate zone — `frontend/docs/composer-media.md` wins over anything the skill suggests there.
Under `widgets/message/**`, `chat_input_bar*`, `composer*` and `chat_action_tiles*`, `frontend-composer-media` is the owner and wins on every question, not just animation.

