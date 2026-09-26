-- Metadata privacy PR3.1 item 9 (decision 30, E12): the box's GLOBAL ceiling.
-- Every other box limit is per IP or per queue, and queues are free to mint,
-- so without this row an open box could fill the one disk Postgres shares.
--
-- ONE row, the running totals of what the box holds: undelivered message
-- blobs ("msgCount", every `box_msgs` row) and media bytes on disk
-- ("mediaBytes", every `box_media` row at its rung size). `enqueue` and
-- `chargeMedia` check and bump it with ONE conditional UPDATE on this
-- primary-key row — never a count over the tables; every path that removes a
-- message or a medium gives its room back in the same statement or
-- transaction (box.service.ts). Counters only: nothing here names a queue.
--
-- Seeded from the rows already stored, so a dev database that held box data
-- before this file starts consistent (prod ships the box OFF: zero rows). The
-- CASE mirrors `BOX_MEDIA_LADDER` (box.constants.ts); the integration suite
-- pins the two against each other.
--
-- Names match `backend/src/box/entities/box-totals.entity.ts` exactly (dev
-- `synchronize` runs after this file).
--
-- Inverse (add it as the NEXT numbered file, never edit this one):
--   DROP TABLE public.box_totals;
CREATE TABLE IF NOT EXISTS public.box_totals (
  "id" smallint NOT NULL,
  "msgCount" integer NOT NULL DEFAULT 0,
  "mediaBytes" bigint NOT NULL DEFAULT 0,
  CONSTRAINT "pk_box_totals" PRIMARY KEY ("id"),
  CONSTRAINT "ck_box_totals_one_row" CHECK ("id" = 1)
);

INSERT INTO public.box_totals ("id", "msgCount", "mediaBytes")
SELECT 1,
       (SELECT count(*) FROM public.box_msgs),
       (SELECT COALESCE(sum(CASE "sizeBucket"
                  WHEN '4k' THEN 4096
                  WHEN '16k' THEN 16384
                  WHEN '64k' THEN 65536
                  WHEN '256k' THEN 262144
                  WHEN '1m' THEN 1048576
                  WHEN '4m' THEN 4194304
                  WHEN '16m' THEN 16777216
                  WHEN '32m' THEN 33554432
                END), 0)
          FROM public.box_media)
ON CONFLICT ("id") DO NOTHING;
