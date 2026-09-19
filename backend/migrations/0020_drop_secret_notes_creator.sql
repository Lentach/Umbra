-- Metadata privacy, step 0 (owner-approved 2026-09-20): a secret note is a
-- random token + ciphertext + expiry and nothing else. `creatorId` tied every
-- note to the account that made it, which no code read; it existed only so
-- account deletion could cascade into notes. A note now simply expires
-- (max TTL 24h), so the link and its FK go.
--
-- Inverse (only if a backend that still writes the column is redeployed; add
-- it as the NEXT numbered file, never edit this one):
--   ALTER TABLE public.secret_notes ADD COLUMN "creatorId" integer;
--   ALTER TABLE public.secret_notes ADD CONSTRAINT fk_secret_notes_creator
--     FOREIGN KEY ("creatorId") REFERENCES public.users(id) ON DELETE CASCADE;
ALTER TABLE public.secret_notes DROP CONSTRAINT IF EXISTS fk_secret_notes_creator;
ALTER TABLE public.secret_notes DROP COLUMN IF EXISTS "creatorId";
