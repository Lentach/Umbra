-- Metadata privacy PR3.1 slice (g) (decision 61, E61a): a `send` with
-- `mode: 'quiet'` (a read/delivered receipt) is stored, capped, expired and
-- delivered exactly like any other blob, but never wakes a device — not at
-- send and not in the socket-gone wake (`BoxService.waitingNids` counts only
-- rows where "quiet" is false).
--
-- One bit per row. Residual (accepted in decision 61): the box learns a blob
-- is a control frame, never which one nor its content. It names no account,
-- device or sender (I2).
--
-- Names match `backend/src/box/entities/box-msg.entity.ts` exactly (dev
-- `synchronize` runs after this file).
--
-- Inverse (add it as the NEXT numbered file, never edit this one):
--   ALTER TABLE public.box_msgs DROP COLUMN "quiet";
ALTER TABLE public.box_msgs
  ADD COLUMN IF NOT EXISTS "quiet" boolean NOT NULL DEFAULT false;
