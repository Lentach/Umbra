-- Metadata privacy PR3.2 (design §4.4, first contact): each device publishes
-- ONE box request queue on the identity side, so `searchUsers` can hand a
-- stranger everything a first contact needs in one answer.
--
--   "requestSid"     the queue's send capability (32 bytes, canonical unpadded
--                    base64url, the box's id spelling). Public BY DESIGN: it
--                    is served to anyone who can search the handle, which is
--                    why a request queue drops its oldest instead of refusing
--                    and carries no media (box.constants.ts).
--   "requestSealPub" the raw X25519 key a first-contact blob is sealed to
--                    (32 bytes, same spelling). The private half never leaves
--                    the device.
--
-- Written only by the device the session's JWT names (`setRequestQueue`),
-- never from a payload device id. NULL until a client that speaks the box
-- publishes one. Residual (design §5): identity now knows each device's
-- request sid — the request queue's `rid`/`nid` stay box-only.
--
-- Inverse (add it as the NEXT numbered file, never edit this one):
--   ALTER TABLE public.devices DROP COLUMN "requestSid", DROP COLUMN "requestSealPub";
ALTER TABLE public.devices
  ADD COLUMN IF NOT EXISTS "requestSid" text NULL,
  ADD COLUMN IF NOT EXISTS "requestSealPub" text NULL;
