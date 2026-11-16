-- Plan B4: refresh tokens rotate, and the reuse of an old one ends the session.
--
-- A row stays ONE session (a token family). Its id is the family id that
-- every token it issues from now on carries (`<id>.<secret>`), and the row
-- follows the family's current token as it rotates
-- (`RefreshTokensService.redeem`):
--
--   prev_token_hash  SHA-256 hex of the token the current one replaced; NULL
--                    until the first rotation. A rotating client presenting
--                    it again lost the response that carried the current
--                    token, and gets that same token back. Any OTHER old
--                    token of the family is reuse: the row is deleted.
--
-- One hash per session, no history: the row keeps no per-refresh trace
-- (created_at and the sliding expires_at are what it already held). Rows that
-- exist before this file are sessions whose token has no family prefix yet;
-- their first rotation gives them one.
--
-- Names match `backend/src/auth/refresh-token.entity.ts` exactly (dev
-- `synchronize` runs after this file).
--
-- Inverse (add it as the NEXT numbered file, never edit this one):
--   DROP INDEX public.idx_refresh_tokens_prev_token_hash;
--   ALTER TABLE public.refresh_tokens DROP COLUMN prev_token_hash;
ALTER TABLE public.refresh_tokens
  ADD COLUMN IF NOT EXISTS prev_token_hash character varying(64) NULL;

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_prev_token_hash
  ON public.refresh_tokens USING btree (prev_token_hash);
