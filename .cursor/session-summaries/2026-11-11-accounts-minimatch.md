# 0.2.82 confirmed by the owner; 16 throwaway prod accounts deleted; minimatch pinned past GHSA-g3hv-75wg-m249

**Date:** 2026-11-11 · **Version:** unchanged (0.2.82 live, owner-confirmed) · **Tiers deployed:** none (prod data write; dev-dependency change only)

## What was done
- The owner confirmed 0.2.82 in his Settings footer ("0.2.82 confirmed").
- Deleted the 16 throwaway prod accounts on the owner's go, ids 138–153:
  - `apk79a/b`, `cold76a ×2`, `cold76b`, `fix80a/b`, `rel80a/b`, `gif80a/b`, `rel81a`, `rel81b ×2`, `rel82a/b`;
  - one transaction with a guard requiring exactly 16 matched ids, `DELETE FROM users`; every user-owned table cascades (as `UsersService.deleteAccount` relies on);
  - none had an avatar (dry run), so no file unlinks were needed;
  - backup `chatdb-20261111T003021Z.dump.gpg` was taken first.
- Their box queues hold no account, so they cannot be targeted. They expire on their own: messages after 30 days, idle queues after 90.
- PR #245: npm `overrides` `"minimatch@>=7.0.0 <11.0.1": "^11.0.7"` in `backend/package.json` and `scripts/smoke/package.json`, for Dependabot alerts 182/183 (GHSA-g3hv-75wg-m249).
  - Dev scope only: eslint, nest cli, jest, artillery.
  - minimatch 3.x is outside the range and stays as is.
  - The lock also moved the nested `brace-expansion` 5.0.9 → 5.0.12.
- Prod read-only check: `contact_messages` and `contact_push_subscriptions` both have 0 rows. They are dormant (no code reads or writes them); dropping them is the owner's call.
- Out-of-repo: the prod DB write above; a fresh `scripts/smoke/node_modules` in the `fireplace-hotfix` worktree.

## Key files
- Edited: `backend/package.json`, `backend/package-lock.json`, `scripts/smoke/package.json`, `scripts/smoke/package-lock.json`.
- Read only: `backend/src/users/users.service.ts` `deleteAccount`, `2026-10-08-account-cull.md` (recipe).
- CI: success 7/7 on `2067d448` (PR #245 head), merged as `b88c3b8a`. Dependabot alerts 182/183 close once GitHub rescans master.
## Verification
- CI: see PR #245 (`2067d448`); the result is recorded in the follow-up line below once known.
- Account delete: `DELETE 16`, users 44 → 28; `devices`, `key_bundles`, `refresh_tokens` for ids 138–153 are all 0; `/health` ok.
- minimatch:
  - `npm ci --dry-run` ok; `nest build` ok; backend unit tests 779/779.
  - ESLint output identical file by file against minimatch 10: 150 files, no message changed. The ratchet's "269 → 259" is a stale floor, not this change.
  - From a fresh smoke install: `post-deploy-smoke.mjs` 8/8 against prod, and `artillery --version` runs.
- Nothing user-facing changed, so there was no device drive.

## Notes for next session
- Next action: none queued; the owner picks the next topic. Release B is due on or after 2026-12-08.
- Owner-owed:
  - do83rman's log ("i dont have logs yet");
  - `backup.pass` off the VM;
  - EN/PL release notes;
  - whether to drop the two dormant contact tables.
- Other open Dependabot alerts remain (undici, handlebars, proxy-addr, multer, …). Their PRs (#186–#240) are open and untouched.
