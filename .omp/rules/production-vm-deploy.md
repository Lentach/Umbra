---
description: Use when deploying to the production OVH VPS (51.68.138.13), SSH ubuntu@51.68.138.13, ~/fireplace paths, deploy-backend.sh / deploy-web.ps1, docker-compose.prod.yml, nginx frontend-build, curl /version or /version.json or /health, PWA prod verification, or fireplace.ignorelist.com ops.
---

# Production server deploy (OVH VPS)

**URL:** https://fireplace.ignorelist.com
**Server:** OVH VPS-1 `vps-53b896a3` @ `51.68.138.13` (Warszawa, 2 vCore/4 GB + 2G swap, Ubuntu 24.04). SSH: `ssh ubuntu@51.68.138.13` (ed25519 key, key-only, passwordless sudo). Migrated from GCP 2026-07-08; the GCP project is **fully decommissioned** (2026-07-14: instance, disk, 14 snapshots, static IP `fireplace-ip` all deleted; project `fireplace-489903` empty) — `gcloud` paths in older docs are historical.

Deploy is **split**: small servers cannot build the Flutter web bundle (dart2js OOMs), so
the **frontend is built on a dev PC** and published to the server; the **backend is built on
the server** from a production Docker image.

**Before EITHER half: CI on `master` must be green** (root `CLAUDE.md` §3 — there is no merge gate, so this
is the gate). Check with the commit-scoped API, never `gh run list --branch master` (it returned weeks-old
rows twice, 2026-09-08):

```bash
gh api repos/Lentach/Umbra/commits/master/check-runs --jq '.check_runs[] | [.name, .conclusion] | @tsv'
```

Every row `success` (or `skipped` for opt-in probes). Any `failure` → do not deploy.

## Paths (do not guess `~/Fireplace`)

| What | Path |
|------|------|
| Git repo | `~/fireplace` (lowercase) |
| Backend deploy (run on VM) | `~/fireplace/deploy-backend.sh` → builds prod image via `docker-compose.prod.yml` |
| Frontend deploy (run on PC) | `deploy-web.ps1` → builds web on PC, publishes to VM `frontend-build/` |
| Nginx static root (what users load) | `~/fireplace/frontend-build/` |
| Host nginx config | `/etc/nginx/sites-enabled/fireplace` |
| Prod compose (VM) | `~/fireplace/docker-compose.prod.yml` → `fireplace-backend-1`, `fireplace-db-1` |
| Dev compose | `~/fireplace/docker-compose.yml` — **LOCAL DEV ONLY**, never on the VM |

**Wrong on the VM:** `cd ~/Fireplace`; `docker compose up` against the **dev** `docker-compose.yml`
(runs backend bind-mounted in watch mode: `NODE_ENV=development`, relaxed CORS, TypeORM auto-DDL).

## Backend deploy (on the VM)

```bash
cd ~/fireplace
./deploy-backend.sh          # git pull → build prod image → recreate backend → verify /version+/health
```

What it does: `git pull` → computes `APP_VERSION` (from `frontend/pubspec.yaml`), `GIT_COMMIT`,
`BUILD_TIME` → `docker compose -f docker-compose.prod.yml build backend` → `up -d backend` →
waits for `(healthy)` → curls `/version` + `/health`.

Preflight aborts if `~/fireplace/.env` is missing any of: `ALLOWED_ORIGINS`, `MEDIA_BASE_URL`,
`JWT_SECRET`, `WEB_PUSH_VAPID_PUBLIC_KEY`, `WEB_PUSH_VAPID_PRIVATE_KEY` (compose also fails fast
via `${VAR:?}`). This is intentional — see NODE_ENV note below.

## Frontend deploy (on the dev PC)

```powershell
cd C:\Users\Lentach\Desktop\fireplace ; git pull ; .\deploy-web.ps1
```

`deploy-web.ps1` builds `flutter build web --release` with `BASE_URL`, `GIT_COMMIT`, `BUILD_TIME`,
`WEB_PUSH_VAPID_PUBLIC_KEY` dart-defines, scp's the bundle to a VM staging dir, then atomic-swaps it
into `~/fireplace/frontend-build/`. No nginx reload needed for an app-code-only change.
**`WEB_PUSH_VAPID_PUBLIC_KEY`** in the PC build must match the backend VAPID public key or PWA push
subscribe fails (`push service error` / delivery `400`).

**⚠️ exit-21 silent publish halt = KASPERSKY (identified 2026-08-29 after 12 recurrences since 07-08).**
Symptom: build succeeds, log dies at the `=== Publish via ssh/scp ===` banner, exit code 21, nothing
published, no error. Cause: Kaspersky targets the deploy scripts themselves (a .ps1 doing ssh/scp
trips its heuristic) — it DELETED `deploy-web.ps1` twice (08-20, 08-29) and `deploy-landing.ps1`
once (08-29, in the landing repo); restore with `git checkout -- <script>`. It also killed
`deploy-landing.ps1` mid-run the same way (exit-21 at the swap banner). **Durable fix: add
Kaspersky exclusions for BOTH repo directories (`fireplace`, `fireplace-landing`), or at minimum
both .ps1 files + powershell.exe launched from them — owner action.**
Until excluded: on exit-21 run the manual staged publish (identical to the script's else-branch):
`ssh VM "rm -rf ~/web-staging && mkdir -p ~/web-staging"` → `scp -r frontend/build/web VM:web-staging`
→ `ssh VM 'test -f ~/web-staging/web/version.json && cd ~/fireplace && rm -rf frontend-build &&
mv ~/web-staging/web frontend-build && chmod -R a+rX frontend-build && echo PUBLISHED_OK'` →
`cd scripts/smoke && node post-deploy-smoke.mjs`. Never pipe the script to `tail` (swallows the failure).

**Stale-page trap (fixed 2026-08-30 for `/welcome/`, 2026-09-02 for the app shell):** both the
landing block and the Flutter `location /` block in `/etc/nginx/sites-enabled/fireplace` send
`Cache-Control: no-cache` — without it browsers used heuristic freshness and replayed cached
pre-deploy HTML for hours without revalidating (owner kept seeing the old brand after the Umbra
deploy; the app settings footer links there). Flutter web output is NOT content-hashed, so
`immutable` would be wrong; `no-cache` = revalidate via ETag, cost is one RTT/304. Verify after any
nginx edit: `curl -sI https://fireplace.ignorelist.com/{,index.html,flutter.js,version.json,main.dart.js}`
must show `cache-control: no-cache`. The file has no server-level `add_header`; if one is ever added,
remember nginx `add_header` in a location REPLACES the inherited set — repeat the server-level ones
in both blocks. Also removed `fireplace.bak.1784434246` from `sites-enabled/` (a July config backup
nginx was loading as live config — caused "conflicting server name" warns; never leave backups in
that dir, they are live). Backups of the config: `/home/ubuntu/nginx-fireplace.bak.<epoch>`.

**Static security headers (2026-09-17) — and the config is TRACKED now.** `infra/nginx/` is the
source of truth for the two VM files: `fireplace.conf` → `/etc/nginx/sites-available/fireplace`
and `security-headers.conf` → `/etc/nginx/snippets/fireplace-security-headers.conf`. Keeping the
vhost untracked is why the app document served ZERO security headers for months while every
proxied API response carried helmet's full set (`backend/src/main.ts:30`) — nothing in the repo
described the origin users actually load. **`frontend/nginx.conf` is NOT that file**: it is the
container nginx for `docker-compose.yml`/`.staging.yml` only, and editing it changes nothing in
production.

The header set is scoped to the two STATIC document blocks (`location /`, `^~ /welcome/`) on
purpose — adding it at the server level would emit a second, conflicting `X-Frame-Options`/CSP on
top of helmet's on every API response. HSTS mirrors helmet's `max-age=31536000; includeSubDomains`
(no `preload`: one-way door). `Permissions-Policy` keeps `camera=(self)` (QR link scanner) and
`microphone=(self)` (voice messages) — denying them breaks both. COEP is deliberately absent: it
would block `fonts.gstatic.com`, which `google_fonts` fetches at runtime because the fonts are not
bundled.

**The CSP is REPORT-ONLY by design.** It is the exact intended enforcing policy, so the reports are
the truth about what would break; flipping it needs (1) one logged-in pass in DESKTOP Chrome (chat,
GIF picker, voice, media, QR scan — a phone PWA has no console), (2) `frame-ancestors 'none'` added
(report-only ignores it; `X-Frame-Options: DENY` is what protects framing today), and (3) the two
pre-paint inline `<script>` blocks in `frontend/web/index.html` moved to a blocking same-origin
file so the two `sha256-` tokens can go. Until then, `node scripts/verify-csp-inline-hashes.mjs`
fails if index.html and the CSP disagree — a stale hash is a phantom report today and a dead
privacy curtain the moment it is enforced.

**Do the logged-in pass LOCALLY, not on prod or the owner's phone (recipe, proven 2026-09-17).**
The report stream only says something once you are past the login screen, and the surfaces that
matter are the ones no anonymous load touches. Serve the real bundle behind the real snippet:

1. Own compose project on ports nobody else uses — the dev stack (`:3000`/`:5433`) and the staging
   stack (`:3100`/`:5533`) may both be live in other sessions:
   `docker compose -p fireplace-csp --env-file <own> -f docker-compose.prod.yml -f <override> up -d`
   with `NODE_ENV: development` (TypeORM creates the schema in a fresh volume), `ALLOWED_ORIGINS`
   and `MEDIA_BASE_URL` set to the nginx origin, and `build: !reset null` + `image:` to reuse an
   already-built backend image instead of rebuilding.
2. Build the bundle in a THROWAWAY WORKTREE (`git worktree add`), never the shared checkout — a
   concurrent `flutter test` and your `flutter build web` fight over `.dart_tool`/`build/`.
   `--no-web-resources-cdn` so CanvasKit stays local, `--dart-define=BASE_URL=<nginx origin>`.
3. `nginx:alpine` with the bundle as root, the API proxied to `host.docker.internal:<backend port>`,
   and `include snippets/fireplace-security-headers.conf` **mounted from `infra/nginx/`** — mount
   the real file so the rehearsal cannot drift from what prod serves.
4. Seed two accounts by `POST /auth/register`, then one `conversations` row and one accepted
   `friend_requests` row by SQL (columns are snake_case: `user_one_id`/`user_two_id`,
   `sender_id`/`receiver_id`).
5. Drive it with CDP: **portrait viewport** (the app shows "rotate your device" and eats every tap
   otherwise), pixel clicks from screenshots, `Input.insertText` for the login fields,
   `overridePermissions` for mic/camera, and read violations from the `Log` domain — NOT from a
   `securitypolicyviolation` listener installed via `evaluateOnNewDocument` (it did not survive
   into the page context). Use a FRESH tab per verification: `Log.enable` replays entries from the
   previous policy and reads as a failure you already fixed.

What that pass found, and would not have been found any other way: under CanvasKit
`Image.network` XHRs image bytes, so **`connect-src` — not `img-src` — governs every remote
image**, including Giphy thumbnails (`media0..4.giphy.com`) and `google_fonts` webfonts. Enforcing
the first draft would have shipped an empty GIF picker. The remaining arbitrary-host need is the
link-preview `og:image`; preview HTML is already same-origin on web
(`POST /messages/link-preview`), so proxying that image is clause 3 of the do-not-enforce list.

Apply/rollback commands live in the header comment of `infra/nginx/fireplace.conf`. Always
`sudo nginx -t` before `sudo systemctl reload nginx`, and never edit via `ssh … sed` (mangles
`$host`).

## Contact inbox service (standalone, VM-only)

The landing contact form + owner push inbox is a **separate** service — repo
`Lentach/fireplace-inbox` (PRIVATE), NOT part of this monorepo/compose. It owns
all of `/contact*`. Fastify + SQLite + web-push, one Docker container.

- **Location:** `~/fireplace-inbox` on the VM (its own git clone). No dev-PC clone.
- **Deploy / update:** `cd ~/fireplace-inbox && git pull && docker compose up -d --build`.
  Listens on `127.0.0.1:3001`; SQLite persists in the `inbox-data` docker volume.
- **Auth to clone:** repo-scoped read-only deploy key `~/.ssh/fireplace_inbox`
  (`Host github-inbox` alias in `~/.ssh/config`). The main `id_ed25519` is locked
  to `Fireplace` — GitHub forbids reusing one key across repos.
- **`.env`** (`~/fireplace-inbox/.env`, gitignored, chmod 600): `PORT=3001`,
  `DB_PATH=/app/data/inbox.db`, `CONTACT_INBOX_KEY`, and the **same**
  `WEB_PUSH_VAPID_PUBLIC_KEY`/`_PRIVATE_KEY`/`_SUBJECT` as `~/fireplace/.env`
  (reused so subscriptions + the landing form stay valid).
- **nginx:** host `location /contact` in `/etc/nginx/sites-enabled/fireplace`
  `proxy_pass http://127.0.0.1:3001;` (+ `X-Forwarded-For` for the per-IP throttle).
  Edit config via a python replace, NEVER ssh-sed (mangles `$host`); `sudo nginx -t`
  before `sudo systemctl reload nginx`.
- **Verify:** `curl -o /dev/null -w '%{http_code}' https://fireplace.ignorelist.com/contact/inbox?key=<CONTACT_INBOX_KEY>` → 200 (bad key → 404);
  `docker inspect -f '{{.State.Health.Status}}' fireplace-inbox` → healthy;
  messages: `docker exec fireplace-inbox node -e "const D=require('better-sqlite3');console.log(new D('/app/data/inbox.db').prepare('select * from contact_messages order by id desc').all())"`.
- **NOT in `backup-db.sh`** — that backs up the Fireplace Postgres/media only. The
  inbox SQLite volume (`inbox-data`) is separate; back it up if messages matter.

## Verify production

| Check | Expected |
|-------|----------|
| `curl https://fireplace.ignorelist.com/health` | `{"status":"ok","db":"ok"}` |
| `curl https://fireplace.ignorelist.com/version.json` | **frontend** semver, e.g. `{"version":"0.0.60",...}` — the real served app version |
| `curl https://fireplace.ignorelist.com/version` | **backend** `{ version, gitCommit, buildTime }` — after `deploy-backend.sh`, `version`=pubspec semver, `gitCommit`=short SHA (NOT `0.0.2`/`dev`) |
| `curl http://127.0.0.1:3000/version` on VM | Same backend JSON (OK even if nginx broken) |
| `docker inspect -f '{{.State.Health.Status}}' fireplace-backend-1` | `healthy` |
| App **Settings** footer | `semver · shortSha · buildTime` (label: App version / Wersja aplikacji) |

- `/version` returns Flutter HTML → nginx missing `location = /version` proxy to `127.0.0.1:3000`;
  fix config, `sudo nginx -t && sudo systemctl reload nginx`. Template in repo `frontend/nginx.conf`
  (host uses `127.0.0.1`, not `backend:`).
- `/version` shows `0.0.2 / dev / ""` → backend was started with the **dev** compose (or plain
  `docker compose build/up` with no version env). Use `./deploy-backend.sh`.
- Settings shows `· dev` → PWA/browser cache; hard refresh.
- Container `(unhealthy)` but `/health` ok externally → healthcheck must hit `127.0.0.1`, not
  `localhost` (busybox resolves `localhost`→`::1`; Nest listens IPv4-only). Already set in compose.

## Version surfaces (do not confuse)

- **`/version.json`** — frontend (Flutter) version from `pubspec.yaml`. The authoritative "what's live" signal.
- **`/version`** — backend env (`APP_VERSION` / `GIT_COMMIT` / `BUILD_TIME`), injected by `deploy-backend.sh`.
- Semver: `frontend/pubspec.yaml` (`0.0.1`, `0.0.2`, … +1 PATCH per release; never a `+N` suffix).

## NODE_ENV / .env / DB caveats

- **`docker-compose.prod.yml` runs `NODE_ENV=production`:** CORS is restricted to `ALLOWED_ORIGINS`
  (must include `https://fireplace.ignorelist.com`); media URLs use `MEDIA_BASE_URL`; **TypeORM
  `synchronize` is OFF** — schema changes ship as numbered SQL files in `backend/migrations/`,
  applied automatically at backend boot (tracked in `schema_migrations`; a failed migration keeps
  the container unhealthy and fails the deploy). The dev compose (`NODE_ENV=development`) also
  auto-DDLs via TypeORM; prod does not.
- **`.env`** in `~/fireplace/.env` is gitignored / not overwritten by `git pull`; it supplies all
  secrets + origins for compose interpolation. Re-run `deploy-backend.sh` (or restart backend) after edits.
- **Postgres:** DB name is **`chatdb`**: `docker compose -f docker-compose.prod.yml exec db psql -U postgres -d chatdb`.
  `pg_stat_statements` is preloaded (compose `command:`, since 2026-09-12; extension created in `chatdb`):
  `SELECT calls, mean_exec_time, left(query,80) FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;`
  A db recreate (`up -d --no-deps db`) drops the backend's pool — `docker restart fireplace-backend-1` after it.

## Backups & monitoring

- **DB + media + .env backup:** `./backup-db.sh` (VM) → `pg_dump -Fc` of `chatdb` + tar of the
  `fireplace_media_storage` volume → `~/fireplace-backups/` (0700), prunes >`RETENTION_DAYS` (14).
- **Encryption:** gpg AES256, keyed by `BACKUP_PASSPHRASE_FILE` (default
  `~/.config/fireplace/backup.pass`, **chmod 600** — refused otherwise) or `BACKUP_PASSPHRASE` env.
  Fed via `--passphrase-file` → never in `ps`/argv or the cron line. **`.env` is included in the set
  but ONLY when encryption is on** (no passphrase → `.env` skipped, never written cleartext).
  **Store the passphrase OFF the VM** (password manager) — an encrypted backup is useless if the only
  copy of the key dies with the machine.
  Cron (no secret in the line): `0 4 * * * cd ~/fireplace && BACKUP_RCLONE_REMOTE=fireplace-b2:BUCKET/vps BACKUP_HEALTHCHECK_URL=https://hc-ping.com/<uuid> ./backup-db.sh >> ~/fireplace-backups/backup.log 2>&1`.
- **Offsite (rclone, current path):** `BACKUP_RCLONE_REMOTE=remote:bucket/prefix` uploads each run's
  encrypted artifacts and VERIFIES them by listing the remote (`offsite verified: N/N`), not by rclone's
  exit code. Target is Backblaze B2 with an **application key WITHOUT `deleteFiles`** (append-only: a
  compromised VM can upload but never destroy history) + a bucket lifecycle rule (~30 days) for pruning —
  never the script. Credentials in `~/.config/rclone/rclone.conf` (0600). Cleartext NEVER leaves the VM:
  no passphrase → upload refused.
- **Dead-man's switch:** `BACKUP_HEALTHCHECK_URL` (healthchecks.io, ~26h grace) is pinged ONLY when the
  backup AND the offsite verification both succeeded — a silently failing night pages by missing ping
  instead of rotting in `backup.log`.
- **Offsite (legacy GCS):** `BACKUP_GCS_BUCKET=gs://…` (gsutil/gcloud) still works but was built for the
  GCP-era VM; on OVH it would need a service-account key on disk. Prefer rclone/B2.
- **E2E-safe:** dumps hold only ciphertext messages + PUBLIC keys + metadata + bcrypt hashes;
  Signal private keys are device-only, never in the DB — a dump cannot decrypt messages. Still
  sensitive (metadata + hashes) → keep private / encrypt / lock down the bucket.
- **Restore (DB):** `./restore-db.sh ~/fireplace-backups/chatdb-<ts>.dump[.gpg]` (stops backend,
  `pg_restore --clean`, restarts; uses the same passphrase file). DB-only by design.
- **Cross-version restore trap (seen in staging 2026-07-09):** `pg_restore --clean` only drops
  objects the DUMP knows about. Restoring a pre-FK-migration dump onto a post-migration DB fails
  (`cannot drop constraint PK_… because fk_… depends on it`). Fix: wipe first —
  `DROP SCHEMA public CASCADE; CREATE SCHEMA public;` — then restore; the backend re-runs
  migrations on next boot (it stamps the baseline and re-applies the rest against the restored data).
- **Restore (media):** `gpg -d media-<ts>.tar.gz.gpg > /tmp/m.tgz` then
  `docker run --rm -v fireplace_media_storage:/data -v /tmp:/b alpine sh -c 'cd /data && tar xzf /b/m.tgz'`.
- **Restore (.env):** MANUAL (never auto-clobbered): `gpg -d env-<ts>.gpg > /tmp/env.restored`, review,
  then place at `~/fireplace/.env` and `./deploy-backend.sh`.
- **Restart policy:** `docker-compose.prod.yml` sets `restart: unless-stopped` on backend + db
  (survives VM reboot). `deploy-backend.sh` runs `up -d` (both services) with the version env set,
  so it applies automatically. **NEVER run a bare `docker compose -f docker-compose.prod.yml up -d`
  by hand** — without the exported `APP_VERSION`/`GIT_COMMIT` it recreates the backend at the
  Dockerfile default (`0.0.1 / unknown`). Always go through `./deploy-backend.sh`.
- **Media volume ownership:** the backend runs as non-root `node` (uid 1000); `deploy-backend.sh`
  chowns `fireplace_media_storage` idempotently before `up -d`. If media uploads ever 500 with
  EACCES, re-run `./deploy-backend.sh` (or the chown line from it) rather than widening permissions.
- **Uptime monitor (external):** point UptimeRobot / healthchecks.io at
  `https://fireplace.ignorelist.com/health` (expect `{"status":"ok","db":"ok"}`) so an outage pages
  you instead of being noticed by hand.

## Agent checklist after a production-related PR

1. User pushed `master` (agent does not SSH unless asked).
2. Backend change → remind `./deploy-backend.sh` on the VM. Frontend change → remind `deploy-web.ps1` on the PC.
3. Mention new `pubspec` version if bumped.
4. Do not claim prod is updated until confirmed via `curl /version.json` (frontend) / `curl /version` (backend) / Settings line.

---

## Moved here from root `CLAUDE.md` (2026-07-27)

Root `CLAUDE.md` is loaded by every agent AND every subagent, so deploy-only detail was
costing ~1.2k tokens on every spawn for something ~90% of sessions never touch. It lives
here now. The irreversible footguns stayed inline in `CLAUDE.md` §4–§6 on purpose.

### One-shot deploy verification

```bash
cd scripts/smoke && node post-deploy-smoke.mjs      # one-time: npm install && npx playwright install chromium
```

Checks `/health`, both version surfaces, that the served `main.dart.js` literally contains
the expected git short-sha (**the definitive stale-build detector** — semver can be bumped
while Flutter serves cached code), and boots the app in a fresh headless browser. Defaults
to local HEAD; `--commit <sha>` checks an older deploy.

### Frontend deploy detail

`.\deploy-web.ps1` runs `flutter clean`, then `flutter build web --release --no-wasm-dry-run`
with `BASE_URL`, `GIT_COMMIT`, `BUILD_TIME`, `WEB_PUSH_VAPID_PUBLIC_KEY`, and publishes by
staging + atomic swap into `~/fireplace/frontend-build/`.

Change not taking effect → `cd frontend && flutter clean` before re-running, then hard-bust
the PWA service-worker cache (an incognito tab proves whether the bundle actually changed).

### Staging dress rehearsal (a GATE for risky deploys, not routine)

`.\staging.ps1` boots the real prod compose isolated as `fireplace-staging` — backend `:3100`,
db `:5533`, its own volumes, dummy secrets in gitignored `.env.staging` (**NEVER the real
`JWT_SECRET`**).

Rehearse BEFORE deploying anything touching `*.entity.ts`, manual SQL, `docker-compose.prod.yml`,
`backend/Dockerfile`, or bootstrap/config code. Skip it for UI work.
Flow: `up` → `restore <dump>` (or `seed-schema` for entity-fresh) → `sql <migration>` (runs with
`lock_timeout=10s`) → `harness` (wire harness against the prod-mode stack).
It does NOT rehearse nginx/TLS, host permissions, or real devices.

### Backup setup

`./setup-backup-cron.sh` on the VM stores the gpg passphrase in a 0600 file (never on the cron
line or argv) and installs the daily cron. Without it there are effectively no backups, or
unencrypted ones — `backup-db.sh` skips `.env` and warns when no passphrase is configured.
Store the passphrase OFF the VM, and decrypt-test one dump before trusting any of them.

Offsite: `BACKUP_RCLONE_REMOTE=remote:bucket/prefix` on the cron line uploads encrypted
artifacts (verify by listing the remote) — B2 with an append-only application key (no
`deleteFiles`), pruning via bucket lifecycle. `BACKUP_HEALTHCHECK_URL` pings a dead-man
monitor ONLY on full success.

`./restore-db.sh <dump>` is DB-only, destructive, and wraps `pg_restore` in one transaction.
Media and `.env` restore are manual.

### Core env vars

| Area | Vars |
|---|---|
| DB | `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASS`, `DB_NAME` |
| Auth/CORS | `JWT_SECRET` (>=32 chars, generated once and persisted — do NOT rotate during normal deploys or host moves; if exposed, rotate only after sticky-session refresh is deployed, since valid refresh tokens mint new access JWTs without re-login), `ALLOWED_ORIGINS` |
| Media | `MEDIA_BASE_URL`, `MEDIA_DIR`, `MEDIA_CLEANUP_GRACE_MS`, `MEDIA_X_ACCEL_REDIRECT` |
| Push | `FIREBASE_SERVICE_ACCOUNT`, `WEB_PUSH_VAPID_PUBLIC_KEY`, `WEB_PUSH_VAPID_PRIVATE_KEY`, `WEB_PUSH_VAPID_SUBJECT` |
| Frontend dart-defines | `BASE_URL`, `GIPHY_API_KEY`, `WEB_PUSH_VAPID_PUBLIC_KEY`, `GIT_COMMIT`, `BUILD_TIME` |
| Deploy metadata | `APP_VERSION`, `GIT_COMMIT`, `BUILD_TIME` |

The VAPID public key in the frontend build MUST match the backend VAPID keys. A mismatch
silently breaks web-push subscribe/delivery — a stupidly easy footgun.

### Branch testing before merge

Frontend: check the branch out on the PC, `cd frontend && flutter clean && cd .. && .\deploy-web.ps1`,
confirm the Settings `gitCommit` matches the branch commit, smoke-test on device.
Backend: on the VPS, `git fetch origin && git checkout <branch> && ./deploy-backend.sh`, verify
`/version` + `/health`. Production becomes permanent only after PR merge to `master` + a normal deploy.

### VM logs

```bash
cd ~/fireplace && docker compose -f docker-compose.prod.yml logs -f --since 1m backend
```

Filter instrumentation with `| grep --line-buffered "<tag>"`. NestJS `this.logger.log` goes to
stdout → docker logs.
