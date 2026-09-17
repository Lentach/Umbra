-- Read-only. Reports COUNTS and column names only, never row contents.
-- For every text-typed column of every table in production, how many rows
-- look like human prose: longer than 25 chars AND containing a space AND not
-- base64-shaped. If message plaintext were leaking into any column anywhere,
-- it would show up here.
CREATE TEMP TABLE _prose(tbl text, col text, prose_rows bigint, total_rows bigint);
DO $do$
DECLARE r record; n bigint; t bigint; scanned int := 0;
BEGIN
  FOR r IN
    SELECT table_name AS tname, column_name AS cname
      FROM information_schema.columns
     WHERE table_schema='public'
       AND data_type IN ('text','character varying','character','json','jsonb')
     ORDER BY table_name, column_name
  LOOP
    scanned := scanned + 1;
    EXECUTE format(
      'SELECT count(*) FILTER (WHERE length(%I::text) > 25 AND %I::text LIKE %L '
      '  AND %I::text !~ ''^[0-9]+:[A-Za-z0-9+/=]+$''), count(*) FROM public.%I',
      r.cname, r.cname, '% %', r.cname, r.tname) INTO n, t;
    IF n > 0 THEN INSERT INTO _prose VALUES (r.tname, r.cname, n, t); END IF;
  END LOOP;
  INSERT INTO _prose VALUES ('__columns_scanned__','-',scanned,scanned);
END
$do$;
SELECT tbl, col, prose_rows, total_rows FROM _prose ORDER BY prose_rows DESC, tbl, col;
