\echo == 1. is pg_stat_statements NORMALIZED, or could it hold message bytes? ==
SELECT count(*) AS total_query_rows,
       count(*) FILTER (WHERE query LIKE '%[encrypted]%')            AS mentions_placeholder,
       count(*) FILTER (WHERE query ~ '[0-9]+:[A-Za-z0-9+/]{40,}')   AS contains_a_ciphertext,
       count(*) FILTER (WHERE query LIKE '%$1%')                     AS normalized_with_params
  FROM pg_stat_statements;

\echo
\echo == 2. the 7 messages carrying BOTH channels: what are they? ==
SELECT m."messageType",
       count(*)                                       AS rows,
       min(m."createdAt")::date                       AS oldest,
       max(m."createdAt")::date                       AS newest,
       count(*) FILTER (WHERE m.content = '[encrypted]') AS placeholder_content,
       count(*) FILTER (WHERE m."encryptedContent" ~ '^[0-9]+:[A-Za-z0-9+/]+=*$') AS legacy_signal_shaped
  FROM messages m
 WHERE m."encryptedContent" IS NOT NULL
   AND EXISTS (SELECT 1 FROM message_envelopes e WHERE e."messageId" = m.id)
 GROUP BY 1 ORDER BY 2 DESC;

\echo
\echo == 3. and the 81 legacy-only rows, for completeness ==
SELECT m."messageType", count(*) AS rows,
       min(m."createdAt")::date AS oldest, max(m."createdAt")::date AS newest
  FROM messages m
 WHERE m."encryptedContent" IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM message_envelopes e WHERE e."messageId" = m.id)
 GROUP BY 1 ORDER BY 2 DESC;
