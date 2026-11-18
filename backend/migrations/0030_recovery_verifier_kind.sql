-- Plan B7 (Option V): the recovery phrase never leaves the device.
--
-- `recovery_keys."verifierHash"` is an Argon2id PHC string either way; this
-- column says WHAT it was computed over, because both look like `$argon2id$`:
--
--   phrase_v1  the plaintext 12-word phrase, sent by clients up to 0.2.88.
--              Verifies ONLY a plaintext `phrase` (old clients keep their
--              recovery during the transition). The client is asked to
--              replace it (`ownKeyBundleStatus.recoveryKeyLegacy`).
--   auth_v2    the client-derived `authSecret`
--              (HKDF-SHA256(phrase, info "umbra/recovery/auth/v1")).
--              Verifies ONLY `authSecret`; a plaintext phrase is refused.
--
-- Every row that exists before this file was enrolled with the plaintext
-- phrase, so the default names them correctly.
--
-- Names match `backend/src/key-bundles/recovery-key.entity.ts` exactly (dev
-- `synchronize` runs after this file).
--
-- Inverse (add it as the NEXT numbered file, never edit this one):
--   ALTER TABLE public.recovery_keys
--     DROP CONSTRAINT IF EXISTS "CHK_recovery_keys_verifierKind";
--   ALTER TABLE public.recovery_keys DROP COLUMN "verifierKind";
-- (an auth_v2 row then verifies nothing an old backend accepts: its owner
-- must enrol again.)
ALTER TABLE public.recovery_keys
  ADD COLUMN IF NOT EXISTS "verifierKind" character varying(16) NOT NULL
  DEFAULT 'phrase_v1';

ALTER TABLE public.recovery_keys
  DROP CONSTRAINT IF EXISTS "CHK_recovery_keys_verifierKind";
ALTER TABLE public.recovery_keys
  ADD CONSTRAINT "CHK_recovery_keys_verifierKind"
  CHECK ("verifierKind" IN ('phrase_v1', 'auth_v2'));
