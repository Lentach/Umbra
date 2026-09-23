-- Metadata privacy PR1.1: the box — transient per-recipient queues that never
-- learn who talks to whom (design `.planning/metadata-privacy/design-candidate.md`
-- §3/§4.1, wire contract `docs/contracts/wire.md` "Box"). Additive; nothing
-- writes here until a client speaks the `/box` namespace (ships DARK).
--
-- What a pg_dump of these four tables shows: random ids, Ed25519 public keys,
-- the UTC DAY a queue was last subscribed, counters, undelivered 16 KiB blobs
-- (≤ 30 d), media files with NO owner (≤ 14 d) and verified push tokens.
-- No column names an account, a device, a sender or a peer (I2), and none may
-- ever be added.
--
-- `claimBy` is the one creation-time trace: set at createQueue, cleared by the
-- first subscribe; a queue still carrying it after that instant is deleted.
--
-- Names match the entities in `backend/src/box/entities/` exactly, because dev
-- `synchronize` runs after this file (the integration suite asserts it would
-- change nothing).
--
-- Inverse (add it as the NEXT numbered file, never edit this one):
--   DROP TABLE public.box_notifiers; DROP TABLE public.box_media;
--   DROP TABLE public.box_msgs; DROP TABLE public.box_queues;
CREATE TABLE IF NOT EXISTS public.box_queues (
  "rid" bytea NOT NULL,
  "sid" bytea NOT NULL,
  "nid" bytea NOT NULL,
  "recipientAuthPub" bytea NOT NULL,
  "kind" character varying(8) NOT NULL,
  "touchedDay" date,
  "claimBy" TIMESTAMP WITH TIME ZONE,
  "msgCount" integer NOT NULL DEFAULT 0,
  "mediaBytesToday" integer NOT NULL DEFAULT 0,
  CONSTRAINT "pk_box_queues" PRIMARY KEY ("rid"),
  CONSTRAINT "uq_box_queues_sid" UNIQUE ("sid"),
  CONSTRAINT "uq_box_queues_nid" UNIQUE ("nid"),
  CONSTRAINT "uq_box_queues_auth_pub" UNIQUE ("recipientAuthPub")
);

CREATE TABLE IF NOT EXISTS public.box_msgs (
  "id" bytea NOT NULL,
  "rid" bytea NOT NULL,
  "blob" bytea NOT NULL,
  "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL,
  "expiresAt" TIMESTAMP WITH TIME ZONE NOT NULL,
  CONSTRAINT "pk_box_msgs" PRIMARY KEY ("id"),
  CONSTRAINT "fk_box_msgs_rid" FOREIGN KEY ("rid")
    REFERENCES public.box_queues ("rid") ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS "idx_box_msgs_rid_created"
  ON public.box_msgs ("rid", "createdAt", "id");
CREATE INDEX IF NOT EXISTS "idx_box_msgs_expires"
  ON public.box_msgs ("expiresAt");

CREATE TABLE IF NOT EXISTS public.box_media (
  "id" bytea NOT NULL,
  "path" text NOT NULL,
  "sizeBucket" character varying(8) NOT NULL,
  "expiresAt" TIMESTAMP WITH TIME ZONE NOT NULL,
  CONSTRAINT "pk_box_media" PRIMARY KEY ("id")
);
CREATE INDEX IF NOT EXISTS "idx_box_media_expires"
  ON public.box_media ("expiresAt");

CREATE TABLE IF NOT EXISTS public.box_notifiers (
  "nid" bytea NOT NULL,
  "token" text NOT NULL,
  "platform" character varying(8) NOT NULL,
  "verifiedAt" TIMESTAMP WITH TIME ZONE NOT NULL,
  CONSTRAINT "pk_box_notifiers" PRIMARY KEY ("nid"),
  CONSTRAINT "fk_box_notifiers_nid" FOREIGN KEY ("nid")
    REFERENCES public.box_queues ("nid") ON DELETE CASCADE
);
