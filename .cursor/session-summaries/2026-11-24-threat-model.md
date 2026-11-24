# Threat model page written; privacy policy drafts and METADATA corrected against the code

**Date:** 2026-11-24 · **Version:** unchanged (0.2.103) · **Tiers deployed:** none

## What was done
- New `docs/security/threat-model.md`: what is protected, six out-of-scope items in plain words, limits that are not decisions, a nine-row adversary table. It states that Umbra does not protect against a server that lies at first contact (B1/B2 dropped) and that E143g is an accepted risk (owner, 2026-11-24).
- `docs/plans/metadata-privacy-decisions.md` row E143g now records the acceptance.
- `docs/METADATA.md`: backups leave out waiting messages and media since decision 147; the server sees which queues one connection subscribes to; the Account row names the "about" text.
- `docs/legal/privacy-policy.{en,pl}.md` (drafts, owner review still pending), same corrections in both: backups; link previews (receiver contacts no site since 0.2.89; on web the server sees the address and the account); "about" text; recovery data (sealed key copy; old apps sent the phrase); who-sends-to-whom exceptions; failed sign-in keeps username + IP in memory up to an hour; log size.
- `docs/plans/2026-11-24-signal-grade-gap.md`: web keys are in localStorage, not IndexedDB; §3.2 points at the new page; PATCHES line; revoked-device row.
- Out of repo: none.

## Key files
- New: `docs/security/threat-model.md`.
- Edited: the docs named above. No code.
- Read only (load-bearing): `backend/src/key-bundles/key-bundles.service.ts` (`authorizedBy = 'unlocked'`), `backup-db.sh`, `frontend/lib/services/encryption/signal_stores.dart:29-49`.

## Verification
- CI: docs only; last code commit `cd6918b1` is 12/12.
- Two passes against the code: a fact check of 22 claims before writing, then a sentence-by-sentence review of the page and of both policy files. All findings applied.
- Review blocker, applied: the page said an identity reset waits 6 hours. That holds only for an account that has linked a device; an account that never linked one replaces its identity with the password alone, at once (`key-bundles.service.ts`, `multi-device.md` (lxxiii)).
- No device drive, no deploy: no shipped code changed.

## Notes for next session
- **Next action:** CodeQL for TypeScript, then the CI-built APK with a published checksum (gap report §4.4 step 1), then the B7 tail (behavioural, own release).
- Owner-owed: read the two privacy-policy drafts (they changed); a contact address for `SECURITY.md` (the threat model's §5 says none is published); the lawyer on the licence; BE-12; UI-16/UI-17; composer split (UI-28); TD-07.
- Open, not fixed: `docs/design/multi-device.md` invariants I4 and I6 still describe server pushes and per-envelope routing that the box replaced; `docs/proof/e2e-encryption-proof.md` predates the box.
- Worth the owner's attention, not new: an account that never linked a device has no reset delay; an account whose recovery phrase was set on 0.2.89 or earlier stays exposed to an operator who kept the phrase until it sets a new one (B7 tail covers the prompt).
- Not verified: the reviewer's inference that a stolen login-token signing key allows replacing the identity of a never-linked account was not traced.
