
\echo == MESSAGE CENSUS (whole production DB) ==
SELECT count(*) AS total_messages,
       count(*) FILTER (WHERE content = '[encrypted]')  AS content_is_placeholder,
       count(*) FILTER (WHERE content <> '[encrypted]') AS content_is_readable,
       count(*) FILTER (WHERE "encryptedContent" IS NOT NULL) AS has_legacy_ciphertext,
       min("createdAt")::date AS oldest,
       max("createdAt")::date AS newest
  FROM messages;

\echo == ANY readable content at all? (grouped, no content shown) ==
SELECT content AS distinct_readable_content, count(*)
  FROM messages WHERE content <> '[encrypted]'
 GROUP BY 1 ORDER BY 2 DESC LIMIT 20;

\echo == CIPHERTEXT SHAPE: legacy column ==
SELECT count(*) AS legacy_rows,
       count(*) FILTER (WHERE "encryptedContent" ~ '^[0-9]+:[A-Za-z0-9+/]+=*$') AS signal_shaped
  FROM messages WHERE "encryptedContent" IS NOT NULL;

\echo == CIPHERTEXT SHAPE: per-device envelopes ==
SELECT count(*) AS envelope_rows,
       count(*) FILTER (WHERE ciphertext ~ '^[0-9]+:[A-Za-z0-9+/]+=*$') AS signal_shaped,
       count(DISTINCT "messageId") AS distinct_messages
  FROM message_envelopes;

\echo == COLUMNS THAT COULD HOLD A PRIVATE KEY (by name) ==
SELECT table_name || '.' || column_name
  FROM information_schema.columns
 WHERE table_schema='public'
   AND (lower(column_name) LIKE '%private%' OR lower(column_name) LIKE '%secret%'
        OR lower(column_name) LIKE '%privkey%');

\echo == KEY MATERIAL COLUMNS ACTUALLY PRESENT ==
SELECT table_name || '.' || column_name
  FROM information_schema.columns
 WHERE table_schema='public'
   AND table_name IN ('key_bundles','one_time_pre_keys','account_authorizations','recovery_keys','devices')
 ORDER BY 1;
