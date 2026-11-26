-- Inverse of 0032_users_about_text.sql. Run by hand (psql), never by the runner.
--
-- Never truncates: if any About is longer than 80 code points the statement
-- raises and nothing changes (one transaction when run with `psql -1`; the
-- DO block alone already runs first, so a refusal leaves the schema intact).
DO $$
DECLARE
  too_long integer;
BEGIN
  SELECT count(*) INTO too_long
    FROM public.users
   WHERE about IS NOT NULL AND char_length(about) > 80;
  IF too_long > 0 THEN
    RAISE EXCEPTION
      'cannot restore users.about to varchar(80): % row(s) hold more than 80 code points; shorten them first',
      too_long;
  END IF;
END
$$;
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS "CHK_users_about_max_code_points";
ALTER TABLE public.users ALTER COLUMN about TYPE varchar(80);
