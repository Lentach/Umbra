-- Metadata privacy, Phase 4 step 5 (decisions 86, 115, 125, 127, 128; owner's go
-- 11-04): the old server path is gone for good. After this release nothing
-- reads or writes these tables: the old-path chat gateway handlers, the
-- friend/conversation/block services, the account push senders and the
-- `msgs/` attachment routes were removed from the code in the SAME release.
--
-- Dropped, in dependency order (every FK points from the earlier table to a
-- later one, or to `users`), each WITHOUT `CASCADE` so that an unexpected
-- dependent (a view, an FK from a table this file does not know) aborts the
-- boot instead of being dropped silently:
--   message_envelopes                       -> messages
--   reaction_keys                           -> conversations
--   conversation_notification_preferences   -> conversations, users
--   messages                                -> conversations (and itself, reply)
--   conversations                           -> users
--   friend_requests, blocked_users          -> users
--   web_push_subscription, fcm_token        -> users (account push, decision 115)
-- No other table references any of them (checked against every migration and
-- entity): the box tables, `contact_backups`, `devices`, `key_bundles`,
-- `one_time_pre_keys`, `user_profile_photos` and the identity/recovery tables
-- stay. The three enum types that only `messages` / `friend_requests` used go
-- with them. Owned sequences (`*_id_seq`) go with their tables.
--
-- NOT REVERSIBLE BY DDL (decision 127). The archive is the safety net: before
-- this ships, the gpg-encrypted pg_dump of these tables and the `msgs/`
-- attachment directory are copied off the VM (scp) to the owner's PC; the VM's
-- 14-day backup rotation is NOT the archive. Restoring means loading rows from
-- that archive, never an inverse DDL here: the old code that could read them is
-- gone, so a bare `CREATE TABLE` would restore nothing a running app uses.
--
-- IF EXISTS keeps a fresh or partly-built dev database bootable: the dev
-- stack's TypeORM `synchronize` no longer creates these tables (their entities
-- were removed), so there the files may already be absent.
DROP TABLE IF EXISTS public.message_envelopes;
DROP TABLE IF EXISTS public.reaction_keys;
DROP TABLE IF EXISTS public.conversation_notification_preferences;
DROP TABLE IF EXISTS public.messages;
DROP TABLE IF EXISTS public.conversations;
DROP TABLE IF EXISTS public.friend_requests;
DROP TABLE IF EXISTS public.blocked_users;
DROP TABLE IF EXISTS public.web_push_subscription;
DROP TABLE IF EXISTS public.fcm_token;
DROP TYPE IF EXISTS public.messages_messagetype_enum;
DROP TYPE IF EXISTS public.messages_deliverystatus_enum;
DROP TYPE IF EXISTS public.friend_requests_status_enum;
