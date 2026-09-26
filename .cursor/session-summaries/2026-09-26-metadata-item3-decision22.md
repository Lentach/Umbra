# Item 3 (decision-22 slice): pings, replies, disappearing timers and attachments go over the box

**Date:** 2026-09-26 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only)

## What was done
- Owner answered O8–O12 (decisions 40–44): each device downloads box attachments on arrival and keeps a local copy; the Signal countdown; the timer setting stays a server column; pings move now; ONE upload per attachment with a shared id. The questions, the engineering calls E17a–E18d and the residuals are in `2026-09-25-metadata-pr31-remainder.md` § Item 3.
- `E2eEnvelope`: `ttl`, `re {w?, s, k, x}`, `boxMedia`. `_encryptAndSend` routes TEXT, PING, replies, timers and media over the box for a covered peer (`b2a3d74c`).
- Countdown (`_startBoxCountdowns`): the sender counts from the send; a receiver stamps send + 1 d at receipt and overwrites it once, at first show, with show + `ttl`. The payload key `ttlFrom` records that the countdown started.
- Quotes resolve by `(s, w)` in the same chat and show OUR copy's words. A quote of a timed message carries no words, on the wire or in the sender's own row.
- Media: `box_media_frame`, `BoxMediaStore` (io files / web IndexedDB `umbra-box-media`), `BoxMediaFetcher` and `BoxOutbox.uploadMedia/downloadMedia`. `_sendMediaOverBox` decides the route before the upload and uploads once to `route.targets.first`. Widgets read `box:<id>` through `boxMediaSourceFor`, and a purge forgets the copy (`e0f17fc4`).
- Review fixes (`5bd09775`): quote and ttl are captured before the upload; the body is held when the route check throws; the voice recording is deleted after upload; `box:` is refused on the old path; the forget-vs-put race is closed.
- Docs: `wire.md` Item 3 bullet, `e2e-invariants.md` (three bullets), `composer-media.md`, and six traps. Root `CLAUDE.md` count 2635 → 2730; Dart ratchet 3163 → 3160.
- Out of repo: local DB holds drive users 292/293, conversation 88 and one `box_media` row. Screenshots are in `%TEMP%/i3drive-shots`. `frontend/build/web` (built with the scaffold) was deleted.

## Key files
- Edited: `frontend/lib/providers/messaging/messaging_provider{.box,.send,.decrypt,.actions,}.dart`, `connection_provider.dart`, `encryption_provider.dart`, `services/encryption_service.dart`, `utils/e2e_envelope.dart`, `services/box/{box_envelope,box_outbox,box_session}.dart`, `utils/encrypted_media_loader.dart`, the 5 media widgets, `video_playback_session.dart`, `video_fullscreen_view.dart`, `playback_controller.dart`, `shared_media_section.dart`, `local_data_files_io.dart`, `origin_storage_wipe_web.dart`.
- New: `services/box/box_media_{frame,store,store_io,store_web,fetcher,url}.dart`, `widgets/message/box_media_source.dart`, tests `box_media_{frame,store,fetcher}_test.dart`, `messaging_provider_box_media_test.dart`.

## Verification
- CI: 7/7 on `e0f17fc4`. Check `5bd09775` (review fixes) before building on it.
- Full `flutter test`: 2730 passed, 14 skipped (on `5bd09775`'s tree). Ratchet PASS at 3160. Every rule was red first (the helper reports list each failing assertion).
- Mutants on `e0f17fc4` (scratch worktree): 10 of 12 killed. M6b (upload retry used the chat's timer), M7 (prefetch before a proven store) and M8 (old path mapped `boxMedia`) survived and now have tests. M3 and M3b are equivalent (reasons in the mutant report). The survivor tests were NOT re-run against their mutants on top of the fixes.
- Two reviews: `b2a3d74c` (P1 quote words kept, P2 forged snippet, P2 countdown reset, P3 re-download loop) and `e0f17fc4` (2 P2, 3 P3). All fixed. The fixes in `5bd09775` have had no third review.
- Live drive on release web of `e0f17fc4` plus the `BOX_DRIVE` scaffold, with 292 ↔ 293:
  - ping: one `/box send`, no `sendMessage`;
  - reply: the quote survived a reload;
  - 30 s timer: A's row was gone by send+53 s; B's copy was kept until B opened the chat and was gone at open+34 s;
  - image: one `POST /box/media`, B prefetched once, and after a reload both showed it with no `/box/media` request;
  - `messages` for conv 88 stayed 0.
- NOT verified:
  - the review fixes, driven live;
  - a ~17 MiB file driven live (unit test only);
  - multi-device sibling copies of media;
  - Android and iOS;
  - the real `MediaCryptoService` decrypt of box media (a stand-in cipher in tests; the drive used a 26 KB PNG);
  - the ping sound (headless).

## Notes for next session
- Next: check CI on `5bd09775`. Then plan item 4 (reactions, pin, edit, delete-for-everyone over E2E) test-first, and batch its OWNER questions in one note (S8). Item 4 also owes clearing a delivered quote snippet `re.x` when its original is deleted for everyone.
- Open gaps:
  - Logout keeps plaintext records and box copies.
  - The Privacy screen's "clear local history" leaves the copies.
  - The history-backup FILE (PR2.3) carries no box media: after a restore, attachments older than 14 days are gone.
  - Native erase covers `box_media` on Android only (as for the SQLCipher store).
  - A pre-upload retry is lost on restart.
- Drive recipe: rebuild the `BOX_DRIVE` scaffold as in `2026-09-25-metadata-sibling-queues-b.md` Notes. Serve `frontend/build/web` on 8080, use two raw-CDP Chromes, and feed images with CDP file-chooser interception. Delete `frontend/build/web` afterwards.
- Traps: helper splits named "slice A/B" confused the owner; mutants in a shared worktree; the unframed-size cap; `MediaCryptoService` takes no caller key; a receipt stamp is needed for unread timers; quote words come from our copy (all in `traps.md`).
