import { ConfigService } from '@nestjs/config';

/**
 * Phase 4 step 3 (decision 111; `docs/plans/2026-10-08-friend-row-gap-check.md`):
 * while `LEGACY_WRITES_FROZEN=true` the old path takes no new message, friend
 * request or chat. Existing rows stay readable, editable and deletable, and the
 * list handlers keep serving them: a complete frozen list cannot trigger a
 * client sweep. Unset or any other value means not frozen, so the undo is
 * flipping the flag back.
 */
export const LEGACY_FROZEN = 'legacy_frozen';

export function legacyWritesFrozen(config: ConfigService): boolean {
  return config.get<string>('LEGACY_WRITES_FROZEN') === 'true';
}
