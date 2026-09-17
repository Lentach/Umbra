-- Blinded-token reactions (docs/design/reaction-privacy.md, owner-picked
-- option B 2026-09-17). `messages.reactions` keeps its TEXT column and its
-- `{key: [userId]}` shape; the KEY becomes a per-conversation HMAC token
-- instead of the emoji itself, so the server keeps doing the merge/toggle
-- bookkeeping while it can no longer read what was reacted with.
--
-- reaction_keys is the pull mailbox for the key that maps token -> emoji
-- (§3.1): one row per (conversation, participant device, epoch), holding
-- Signal ciphertext sealed to exactly that device. Clients read their OWN row;
-- the server never holds the key in the clear.
--
-- senderUserId/senderDeviceId are the UPLOADER, attributed server-side from
-- the authenticated socket. The receiver needs the Signal session with the
-- PRODUCING device to decrypt, and a client-claimed sender would let a hostile
-- client point a victim's device at the wrong session.
CREATE TABLE IF NOT EXISTS public.reaction_keys (
  "conversationId" integer NOT NULL,
  "userId" integer NOT NULL,
  "deviceId" integer NOT NULL,
  epoch integer NOT NULL,
  "senderUserId" integer NOT NULL,
  "senderDeviceId" integer NOT NULL,
  ciphertext text NOT NULL,
  "createdAt" TIMESTAMP NOT NULL DEFAULT now(),
  CONSTRAINT "PK_reaction_keys" PRIMARY KEY ("conversationId", "userId", "deviceId", epoch),
  CONSTRAINT "FK_reaction_keys_conversation" FOREIGN KEY ("conversationId")
    REFERENCES public.conversations (id) ON DELETE CASCADE
);

-- The PK's leading columns already serve the only read (`fetchReactionKey`
-- asks for one exact (conversation, userId, deviceId, epoch) row), so no
-- secondary index is created.

-- Server-assigned epoch truth. An upload is accepted only at
-- `reactionKeyEpoch + 1` (or re-uploaded at the CURRENT epoch by the same
-- uploader, the new-device top-up path); anything else is refused
-- `stale_epoch`. Without this, two clients racing to create the first key both
-- write epoch 1 and one side's tokens become permanently undecodable
-- (design §5 falsification R3). 0 = no key has ever been uploaded.
ALTER TABLE public.conversations
  ADD COLUMN IF NOT EXISTS "reactionKeyEpoch" integer NOT NULL DEFAULT 0;

-- Owner call (design §3.4): DROP the historical plaintext reactions in the
-- same migration that ships the token shape. Deliberate and IRREVERSIBLE —
-- keeping them would leave the server holding readable reaction content, which
-- is the exact thing this change exists to end; re-adding a reaction costs one
-- tap. History served after this point carries `reactions: {}` for old
-- messages.
UPDATE public.messages SET reactions = NULL WHERE reactions IS NOT NULL;
