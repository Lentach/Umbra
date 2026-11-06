# Phase 4 step 5 deploy: archive, drop, release

One-off runbook for the release that drops the old server path (migration `0027`, PR #210). Authority: `docs/plans/metadata-privacy-decisions.md` 126–131. General deploy mechanics: `.omp/rules/production-vm-deploy.md`; APK: `docs/runbooks/android-release.md`.

## Gates (all before the owner is asked for the go)

1. #208 shipped (0.2.74), master merged into `feat/phase4-step5`, PR #210 mergeable, CI green on its head sha (`gh api repos/Lentach/Umbra/commits/<sha>/check-runs`). Code merged 11-05 (`e86da5f9`, CI 7/7); 0.2.74 (live 11-05 02:05Z) merged in `42b45233` — docs and version only. The 0.2.75 web hotfix (#211, #212; live 11-05 ~14:55Z) merged 11-06 with the bump to 0.2.76: the restore hook keeps this branch's store re-read (#212's `rewriteStore`/`refreshLocalChats` do not exist here), #212's server-list test dropped (no server lists after step 5).
2. The Android revoke path driven on a device (decision 130). PASSED 11-05 on `cfc968db` (evidence: decisions log E130a). Repeated on the merged release APK 11-05 (`e86da5f9`): PASSED both ways. Repeat it only if the merge brings code, not just the version bump: once on the merged release APK (the shipped binary is the merge with #208, which touches `main.dart`, where `onBackgroundMessage` is wired): revoked + closed → `[wake-up] revoked-device check: stopped` and the notifier gone on the next send; live + closed → `notRevoked`. Recipe in `.cursor/session-summaries/2026-11-04-phase4-step5-built.md` (Verification, Android drive). Delete the drive APK from BOTH `build/app/outputs/flutter-apk/` and `apk/release/` afterwards: it is throwaway-signed and points at `127.0.0.1:3100`.
   11-06 merge (0.2.75 hotfix): its only code is web-only (`DualStorage._openWeb`, behind `kIsWeb`; the restore hook kept this branch's side), nothing on the Android wake path, so the Android drive was not repeated; the merged build was driven on web instead (passcode boot-locked → unlock → chats + both ways). The owner may still ask for the Android rerun before the go.
3. The decision 86 count re-run read-only and shown to the owner (query below).
4. The owner's explicit go (decision 129), no sooner than 24 h after the 0.2.75 web hotfix is verified on prod (decisions 132, 136). Not bundled with any other release.

## Decision 86 count (read-only)

```bash
ssh ubuntu@51.68.138.13 'cd ~/fireplace && docker compose -f docker-compose.prod.yml exec -T db psql -U postgres -d chatdb -At -c "BEGIN READ ONLY" -f - -c ROLLBACK' <<'SQL'
with p as (select sender_id a, receiver_id b from friend_requests where status='accepted'),
u as (select a id from p union select b from p)
select 'pairs='||(select count(*) from p)||' accounts='||(select count(*) from u)
  ||' no_backup='||(select count(*) from u where id not in (select "userId" from contact_backups));
SQL
```

11-04: 25 pairs, 23 accounts, 2 without a contact backup (benz93, jarekk: waived by 119). `blocked_users` 0 rows, `msgs/` 4.6 MB (2 files).

## Release

Version `0.2.76` (one past the 0.2.75 web hotfix; re-check `frontend/pubspec.yaml` on master), APK versionCode `20076`. Bump `pubspec.yaml` on the branch before the merge; CI must be green on the bumped sha.

### 1. Archive (VM, old backend still running; decision 128)

Two passes, so the archive restores without the rest of the database: the DDL of the whole schema (no rows; it carries the three enums the tables need) and the ROWS of the nine tables only. Proven on a scratch Postgres 16 (11-04): schema, then data with `--disable-triggers`, restores the rows and their enum values.

```bash
cd ~/fireplace
ts=$(date -u +%Y%m%dT%H%M%SZ); A=~/fireplace-backups/step5-archive-$ts; mkdir -m 700 "$A"
DC="docker compose -f docker-compose.prod.yml exec -T db pg_dump -U postgres -d chatdb -Fc"
$DC --schema-only > "$A/schema.dump"
$DC --data-only -t public.message_envelopes -t public.reaction_keys \
  -t public.conversation_notification_preferences -t public.messages -t public.conversations \
  -t public.friend_requests -t public.blocked_users -t public.web_push_subscription \
  -t public.fcm_token > "$A/old-tables-data.dump"
docker run --rm -v fireplace_media_storage:/m:ro -v "$A":/out alpine tar czf /out/msgs.tar.gz -C /m msgs
for f in schema.dump old-tables-data.dump msgs.tar.gz; do
  gpg --batch --yes --pinentry-mode loopback --passphrase-file ~/.config/fireplace/backup.pass \
    --symmetric --cipher-algo AES256 -o "$A/$f.gpg" "$A/$f" && shred -u "$A/$f"
done
sha256sum "$A"/*.gpg
```

On the PC (decision 134): `scp ubuntu@51.68.138.13:fireplace-backups/step5-archive-<ts>/*.gpg "$USERPROFILE/Desktop/umbra-archive-step5/"`, save the VM's `sha256sum` output there as `SHA256SUMS`, and compare it with a local `sha256sum`. `backup.pass` is NOT copied with it (kept apart, as for every backup). Restore later: decrypt, `createdb`, `pg_restore --exit-on-error schema.dump`, then `pg_restore --disable-triggers old-tables-data.dump`.

### 2. Backup + backend (VM)

```bash
cd ~/fireplace && ./backup-db.sh        # the rollback point; note the chatdb-<ts> name
./deploy-backend.sh                     # git pull, build, 0027 at boot (lock_timeout 10 s)
```

Not during the 04:00 backup cron or with a psql session open (0027 needs its locks). Expected: `/health` gap about 8 s, 0027 in ~0.2 s. Check `docker logs fireplace-backend-1` for `0027` applied and no ERROR, `/version` = `0.2.76 / <sha>`.

### 3. Web (PC, main checkout after it pulls master), then smoke

`.\deploy-web.ps1`, then `cd scripts/smoke && node post-deploy-smoke.mjs`. Old 0.2.75 pages keep working until they reload (rehearsed with 0.2.73).

### 4. APK

Build per `android-release.md` (release keystore), publish `umbra-0.2.76.apk`, set `ANDROID_APK_*` in `~/fireplace/.env`, re-run `./deploy-backend.sh`, check `/version`'s `android` block.

### 5. After 10 minutes with 0 backend ERROR lines

```bash
docker run --rm -v fireplace_media_storage:/m alpine rm -rf /m/msgs
```

### Release notes (decisions 118, 127; approved as written, 133)

EN: "This update removes the old message system from the server. Pictures, videos and files sent with app versions from before mid-October are deleted from the server and can no longer be opened. Older text messages from that time disappear on their own within 30 days. Blocks are now kept only on your device."

PL: "Ta aktualizacja usuwa z serwera stary system wiadomości. Zdjęcia, filmy i pliki wysłane w wersjach aplikacji sprzed połowy października zostały usunięte z serwera i nie da się ich już otworzyć. Starsze wiadomości tekstowe z tamtego okresu znikną same w ciągu 30 dni. Blokady są teraz zapisywane tylko na Twoim urządzeniu."

## Rollback (~35 s, rehearsed 11-04)

`./restore-db.sh ~/fireplace-backups/chatdb-<ts>.dump.gpg` (the step 2 backup; `--clean --if-exists --single-transaction`), then check out the previous master sha on the VM and `./deploy-backend.sh`, and `deploy-web.ps1` from that sha. After step 5 (`msgs/` removed) the media comes back from the step 1 archive (`msgs.tar.gz`). Cost: the restore puts the box tables back to the backup's moment, so box messages sent after it and not yet fetched are lost. Roll back only for a blocker under release rule 123.
