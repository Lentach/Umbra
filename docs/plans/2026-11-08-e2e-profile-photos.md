# E2E profile photos over the box (decision 138)

Owner, 2026-11-08: replaces R84's "avatar signed URLs". Signed or login-gated avatar
fetches would show the server who looks at whose photo (the friend graph decisions 53
and 114 keep from it). Instead the photo travels end-to-end over the box, the server
keeps no viewable copy, and search shows no photo. One profile photo per account (the
3-photo gallery goes). Existing server photos migrate automatically; the server deletes
every avatar file about 30 days after the release.

## Release A (this work)

### Wire (client ↔ client, inside the E2E envelope; the server sees box media only)
- **Photo file.** The device scales the photo to at most 256×256, JPEG, encrypts it with
  a fresh AES-GCM key (the existing `MediaCryptoService` path), pads to a box media rung
  (`frameMediaToRung`, 64 KiB expected) and uploads it ONCE via `POST /box/media`.
- **Reference** `av = {m: <box media id b64>, k: <key b64>, i: <iv b64>, r: <rev int>}`.
  `r` is a per-account counter that only grows; a receiver keeps the highest `r` it saw
  and ignores a frame that does not exceed it. A cleared photo is `{r, x: 1}`. Who
  mints `r` decides what outranks what:
  - a change the user makes (a new photo, a removal): `max(last + 1, now in ms)`, so it
    outranks everything the account sent before, from any device, even one that lost
    its row;
  - the weekly refresh (same photo, new file and key): `last + 1`, never the clock. A
    refresh is not news: a laptop offline for 8 days must not outrank the photo the
    phone set meanwhile. It commits only if the own reference is still the one it
    started from, and changes of the own photo run one at a time;
  - the migrated server photo: `1`, so every real change, and a restore, outranks it.
- **New envelope type `profile`** `{t:'profile', av}`: sent `quiet` (no wake push) to
  every device of every friend with a box route and to every sibling, the same fan-out
  as `announceOwnList` (E50d). Sent on: a photo change; the first launch of this version
  (migration, below); and when the last upload is older than 7 days (box media lives
  14 d, D8), checked at connect.
- **First contact.** `friend_request` / `friend_accepted` profile `p` carries `av` in
  place of the server path `a`. Before sending either, an upload older than 7 days is
  refreshed first. Decision 53 holds: the requests screen shows no photo before accept;
  the photo is taken from the frame only at accept.
- **Old field.** A received `a` (server path, decision 55) is still read during release A
  so friends on older builds keep their photo until the server copy is deleted.

### Device
- `ContactRecord.avatar` (the reference) beside `avatarUrl` (legacy, read-only, removed in
  release B). The self record holds our own reference. The contact backup carries the
  reference (≈100 B), never bytes; a restore after the box copy expired shows initials
  until the friend's next weekly re-send.
- On a `profile` frame / an accept: download at once through `BoxMediaFetcher` (same
  retries; `gone` after 14 d), keep the ciphertext in `BoxMediaStore`, show from there.
- Avatar widgets (`HexAvatar`, `AvatarCircle`, user card) decide by the reference alone
  when a contact has one: decrypted bytes (`MemoryImage`), else initials, never the
  legacy URL (a cleared photo must not come back from the server copy, and a fetch of
  `/media/avatars` is the signal this removes). A contact with no reference (a friend on
  an older build) shows the legacy URL until release B, else initials.

### Migration (release A, client)
- First launch with this version: if the account has a server photo
  (`/users/me` `profilePictureUrl`) and NO reference of any kind (a removal counts) and
  the move was not made, the device downloads it, uploads it with `r = 1`, and stops.
  Siblings learn it by the same frame. The move commits only if nothing else landed
  while it ran.
- Removing the photo before the move writes a cleared reference (`{r, x: 1}`), owed to
  friends, and settles the move: the server photo is never published afterwards.
- A backup restore applies the backup's own reference when it outranks the one held
  (the login fills the self row first, so "only when empty" is not enough) and marks
  the move made; friends are owed it only when a lower one was published meanwhile.
- A friend's reference naming a media id this device already holds for the own account
  or another contact is refused, and a file a held reference still names is never
  deleted.

### Server (release A)
- `searchUsers` returns no `profilePictureUrl` / `profilePhotos`.
- Photo upload and gallery routes are removed (`POST /users/profile-picture`,
  `/users/profile-photos/*`). An older build that tries to change a photo gets an error.
- `GET /media/avatars/:file` and `/users/me` `profilePictureUrl` stay, for the migration
  window only.

## Release B (≥ 30 days after A)
- Delete every file under `MEDIA_DIR/avatars/`, drop `users.profilePictureUrl`,
  `profilePicturePublicId` and `user_profile_photos`, remove `GET /media/avatars/*`, the
  client's `avatarUrl` fallback and the `a` field reader.

## Accepted
- Friends on builds older than release A keep the server photo until release B, then
  show initials.
- A device offline for more than 14 days, or restored from backup, shows initials for a
  friend until that friend's next weekly re-send.
- About 64 KiB of box media per user per week.
