-- `users.about` stops being a code-point-limited varchar(80) (R12-BE-01).
--
-- An About is limited to 80 characters AS THE USER SEES THEM (grapheme
-- clusters, enforced in `UpdateProfileAboutDto`). A cluster is several code
-- points (a heart + U+FE0F is 2, a family emoji 7), and Postgres counts code
-- points in `varchar(n)`, so 80 hearts failed the INSERT with a 500.
--
-- The column becomes `text`, and a CHECK on `char_length` (code points in a
-- UTF8 database) is the hard backstop: 640 = 80 clusters x 8 code points. The
-- DTO refuses both limits with a 400 before any write.
--
-- varchar(n) -> text is a metadata-only change in Postgres (no table rewrite,
-- no long lock). Adding the CHECK scans the table once; `users` is small and
-- every existing value is at most 80 code points, so it passes. An OLD backend
-- (validator capped at 80 by the isLength count) keeps working against it.
--
-- Idempotent: a dev database whose `synchronize` already created the entity's
-- `@Check` has the constraint, so it is dropped before it is added.
--
-- Inverse: `backend/migrations/down/0032_users_about_text.down.sql` (NOT in
-- this directory, so the runner never executes it; run it by hand with psql).
-- It refuses, without touching data, when any row is over 80 code points.
ALTER TABLE public.users ALTER COLUMN about TYPE text;
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS "CHK_users_about_max_code_points";
ALTER TABLE public.users
  ADD CONSTRAINT "CHK_users_about_max_code_points"
  CHECK (about IS NULL OR char_length(about) <= 640);
