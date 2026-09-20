-- Metadata privacy PR2.4: the account's sealed contact backup. A PWA whose
-- browser storage is wiped loses the whole contact graph, and the server is
-- not allowed to hold that graph in the clear — so it holds ONE opaque row
-- per account that it can never open.
--
-- What the server can see: that an account has a backup, the BUCKETED byte
-- size of the opaque strings, the `rev` the row is at, and `updatedAt`.
-- `blob` is the sealed contact list; `wraps` is a JSON array of `{kind, ct}`
-- where every `ct` is the content key wrapped under the password or the
-- recovery phrase. Neither is ever parsed here. `salt` and `ckId` are public
-- labels the client needs back verbatim. No contact, no name, no handle and
-- no exact count is visible.
--
-- The size is bucketed, not hidden. AES-GCM is length-preserving, so a raw
-- length(blob) would divide by the per-contact record size into a contact
-- estimate anyone with a pg_dump could read without a key. The client pads
-- the plaintext to whole 4 KiB blocks before sealing, so this column leaks a
-- block count — an upper band, not a count of anything. See docs/METADATA.md.
--
-- `rev` is optimistic concurrency over the WHOLE triple (ckId, wraps, blob):
-- a PUT carries the rev it read, a mismatch is refused, and nothing is
-- written. That makes a fresh blob next to stale wraps — a row nobody can
-- ever open again — structurally impossible. `salt` is minted once by the
-- first client and immutable afterwards; a changed salt would orphan every
-- other device. `updatedAt` moves ONLY when the triple actually changes: an
-- unchanged re-upload writes nothing, so this column can never become the
-- per-account presence clock that `key_bundles.updatedAt` turned into.
--
-- Inverse (add it as the NEXT numbered file, never edit this one):
--   DROP TABLE public.contact_backups;
CREATE TABLE IF NOT EXISTS public.contact_backups (
  "id" SERIAL PRIMARY KEY,
  "userId" integer NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  "version" integer NOT NULL,
  "rev" integer NOT NULL DEFAULT 0,
  "salt" text NOT NULL,
  "ckId" text NOT NULL,
  "wraps" text NOT NULL,
  "blob" text NOT NULL,
  "updatedAt" TIMESTAMP NOT NULL
);
