-- Plan D3: the uploader of a box attachment can delete it before the 14-day
-- expiry (delete for everyone).
--
--   deleteHash  SHA-256 of a 32-byte secret the UPLOADING device made and
--               keeps on its own disk (`Box-Delete-Hash` on `POST /box/media`).
--               `DELETE /box/media/:id` with the secret in `Box-Delete-Secret`
--               removes the file, then the row. The server never sees the
--               secret before that request and links it to nothing: the box
--               still knows no account. NULL for every upload made before
--               this file and by clients that send no hash: those rows stay
--               reaper-only (14 days).
--
-- Names match `backend/src/box/entities/box-media.entity.ts` exactly (dev
-- `synchronize` runs after this file).
--
-- Inverse (add it as the NEXT numbered file, never edit this one):
--   ALTER TABLE public.box_media DROP COLUMN "deleteHash";
ALTER TABLE public.box_media
  ADD COLUMN IF NOT EXISTS "deleteHash" bytea NULL;
