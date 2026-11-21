#!/usr/bin/env bash
# Nightly Postgres + media (+ encrypted .env) backup for the Fireplace VM.
#
# E2E SAFETY: message bodies are stored ENCRYPTED (Signal ciphertext); the private
# keys that decrypt them live ONLY on devices, never in the DB. A dump therefore
# CANNOT decrypt any message. It DOES contain metadata (usernames, contact graph,
# timestamps), bcrypt password hashes and PUBLIC keys, so treat it as sensitive.
#
# Encryption (gpg AES256) takes its passphrase from either:
#   - BACKUP_PASSPHRASE_FILE (default ~/.config/fireplace/backup.pass, chmod 600), or
#   - BACKUP_PASSPHRASE env (written to a temp 0600 file, shredded on exit).
# It is fed via gpg --passphrase-file, so it NEVER appears in `ps`/argv or the cron line.
# .env (JWT_SECRET, VAPID keys, DB creds) is included ONLY when encryption is active.
# STORE THE PASSPHRASE OFF THE VM (password manager) — an encrypted backup is useless if
# the only copy of the key dies with the machine. Optional offsite (encrypted files only):
#   BACKUP_RCLONE_REMOTE=remote:bucket/prefix   (rclone; credentials in ~/.config/rclone/rclone.conf 0600)
#   BACKUP_GCS_BUCKET=gs://bucket               (legacy GCP-era path; see setup-backup-bucket.sh)
# NOTE: cleartext intermediates are shred'd best-effort; on CoW/journaled/tmpfs
# filesystems shred cannot guarantee erasure — rely on full-disk encryption for the VM.
#
# Usage:  cd ~/fireplace && ./backup-db.sh
# Cron (daily 04:00) — passphrase lives in the file, NOT the cron line:
#   0 4 * * * cd ~/fireplace && BACKUP_RCLONE_REMOTE=fireplace-r2:fireplace-backups/vps ./backup-db.sh >> ~/fireplace-backups/backup.log 2>&1
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"
cd "$REPO_DIR"

COMPOSE_FILE="docker-compose.prod.yml"
ENV_FILE="$REPO_DIR/.env"
DB_NAME="${DB_NAME:-chatdb}"
DB_USER="${DB_USER:-postgres}"
MEDIA_VOLUME="${MEDIA_VOLUME:-fireplace_media_storage}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/fireplace-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

# --- passphrase resolution (parent scope; trap-safe; never on argv) ---
BACKUP_PASSPHRASE_FILE="${BACKUP_PASSPHRASE_FILE:-$HOME/.config/fireplace/backup.pass}"
PASS_FILE=""
_PASS_TMP=""
cleanup_pass() { [[ -n "$_PASS_TMP" ]] && { shred -u "$_PASS_TMP" 2>/dev/null || rm -f "$_PASS_TMP"; }; }
trap cleanup_pass EXIT INT TERM

# Sets global PASS_FILE to a 0600 passphrase file, or "" if no passphrase is available.
resolve_pass_file() {
  if [[ -n "${BACKUP_PASSPHRASE:-}" ]]; then
    _PASS_TMP="$(mktemp)"; chmod 600 "$_PASS_TMP"
    printf '%s' "$BACKUP_PASSPHRASE" > "$_PASS_TMP"
    unset BACKUP_PASSPHRASE  # don't leak via child env / /proc/<pid>/environ
    PASS_FILE="$_PASS_TMP"; return 0
  fi
  if [[ -f "$BACKUP_PASSPHRASE_FILE" ]]; then
    local mode; mode="$(stat -c '%a' "$BACKUP_PASSPHRASE_FILE" 2>/dev/null || stat -f '%Lp' "$BACKUP_PASSPHRASE_FILE")"
    if [[ "$mode" != "600" && "$mode" != "400" ]]; then
      echo "ERROR: $BACKUP_PASSPHRASE_FILE must be chmod 600 (is $mode)" >&2; return 1
    fi
    PASS_FILE="$BACKUP_PASSPHRASE_FILE"; return 0
  fi
  PASS_FILE=""; return 0
}

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# Prevent overlapping runs (cron overlap, or manual + nightly). Degrades gracefully without flock.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$BACKUP_DIR/.backup.lock"
  flock -n 9 || { echo "another backup run is in progress — exiting"; exit 0; }
fi
ts="$(date -u +%Y%m%dT%H%M%SZ)"
db_file="$BACKUP_DIR/chatdb-$ts.dump"
media_file="$BACKUP_DIR/media-$ts.tar.gz"

echo "==> [$ts] pg_dump $DB_NAME (custom/compressed format)"
compose exec -T db pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$db_file"
[[ -s "$db_file" ]] || { echo "ERROR: dump is empty — aborting" >&2; rm -f "$db_file"; exit 1; }

echo "==> tar media volume ($MEDIA_VOLUME)"
if ! docker volume inspect "$MEDIA_VOLUME" >/dev/null 2>&1; then
  echo "WARN: media volume '$MEDIA_VOLUME' not found — SKIPPING media (check: docker volume ls). Not creating an empty one."
elif ! docker run --rm -v "$MEDIA_VOLUME":/data:ro -v "$BACKUP_DIR":/backup alpine \
       tar czf "/backup/$(basename "$media_file")" -C /data . ; then
  echo "WARN: media backup failed — removing partial archive"
  rm -f "$media_file"
fi

# --- encryption at rest (gpg AES256 via --passphrase-file; never on argv) ---
resolve_pass_file || exit 1
if [[ -n "$PASS_FILE" ]]; then
  echo "==> encrypting (gpg AES256)"
  for f in "$db_file" "$media_file"; do
    [[ -f "$f" ]] || continue
    gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASS_FILE" \
      --symmetric --cipher-algo AES256 "$f"
      shred -u "$f" 2>/dev/null || rm -f "$f"
  done
  if [[ -f "$ENV_FILE" ]]; then
    echo "==> backing up .env (encrypted)"
    gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASS_FILE" \
      --symmetric --cipher-algo AES256 -o "$BACKUP_DIR/env-$ts.gpg" "$ENV_FILE"
  fi
else
  echo "WARN: no passphrase (set BACKUP_PASSPHRASE or create $BACKUP_PASSPHRASE_FILE chmod 600)."
  echo "      DB+media are UNENCRYPTED in $BACKUP_DIR; .env is SKIPPED (never written cleartext)."
fi

# Optional offsite copy to a private bucket (BACKUP_GCS_BUCKET=gs://your-bucket).
# Only ENCRYPTED files are uploaded; refuse if encryption is off so cleartext never leaves the VM.
if [[ -n "${BACKUP_GCS_BUCKET:-}" ]]; then
  if [[ -z "$PASS_FILE" ]]; then
    echo "WARN: BACKUP_GCS_BUCKET set but no passphrase — refusing to upload UNENCRYPTED backups offsite."
  else
    shopt -s nullglob
    encrypted=("$BACKUP_DIR"/*"$ts"*.gpg)
    shopt -u nullglob
    if (( ${#encrypted[@]} == 0 )); then
      echo "WARN: no encrypted files for $ts to upload."
    elif command -v gsutil >/dev/null 2>&1; then
      echo "==> uploading ${#encrypted[@]} file(s) to $BACKUP_GCS_BUCKET (gsutil)"
      gsutil -m cp "${encrypted[@]}" "$BACKUP_GCS_BUCKET/" || echo "WARN: gsutil upload failed"
    elif command -v gcloud >/dev/null 2>&1; then
      echo "==> uploading ${#encrypted[@]} file(s) to $BACKUP_GCS_BUCKET (gcloud storage)"
      gcloud storage cp "${encrypted[@]}" "$BACKUP_GCS_BUCKET/" || echo "WARN: gcloud storage upload failed"
    else
      echo "WARN: BACKUP_GCS_BUCKET set but neither gsutil nor gcloud found — offsite upload SKIPPED."
    fi
  fi
fi

# Optional offsite copy via rclone (BACKUP_RCLONE_REMOTE=remote:bucket/prefix; prod: Cloudflare R2
# fireplace-r2:fireplace-backups/vps). Same guard: only ENCRYPTED artifacts ever leave the VM.
# Pruning is the bucket's lifecycle rule (set in the Cloudflare dashboard), never this script.
# The prod R2 token CAN delete objects (probed 2026-11-17); the R2 bucket lock rule on vps/ (30 days,
# verified 2026-11-21) keeps the offsite copy safe from a compromised VM (runbook: production-vm-deploy
# rule, "Backups").
# OFFSITE_OK feeds the dead-man ping below: uploads are verified by listing the
# remote, not trusted from rclone's exit code alone.
OFFSITE_OK=1
if [[ -n "${BACKUP_RCLONE_REMOTE:-}" ]]; then
  OFFSITE_OK=0
  if [[ -z "$PASS_FILE" ]]; then
    echo "WARN: BACKUP_RCLONE_REMOTE set but no passphrase — refusing to upload UNENCRYPTED backups offsite."
  elif ! command -v rclone >/dev/null 2>&1; then
    echo "WARN: BACKUP_RCLONE_REMOTE set but rclone not found — offsite upload SKIPPED."
  else
    shopt -s nullglob
    rc_encrypted=("$BACKUP_DIR"/*"$ts"*.gpg)
    shopt -u nullglob
    if (( ${#rc_encrypted[@]} == 0 )); then
      echo "WARN: no encrypted files for $ts to upload via rclone."
    else
      echo "==> uploading ${#rc_encrypted[@]} file(s) to $BACKUP_RCLONE_REMOTE (rclone)"
      rclone copy "$BACKUP_DIR" "$BACKUP_RCLONE_REMOTE" --include "*${ts}*.gpg" \
        || echo "WARN: rclone upload failed"
      # Trust the listing, not the exit code: count what actually landed.
      # `|| true` on the lsf stage: under set -euo pipefail a broken remote
      # would otherwise abort the whole script here, skipping prune and the
      # ERROR/SKIPPED reporting below (count reads 0 -> verification fails).
      uploaded="$({ rclone lsf "$BACKUP_RCLONE_REMOTE" --include "*${ts}*.gpg" 2>/dev/null || true; } | wc -l)"
      if (( uploaded == ${#rc_encrypted[@]} )); then
        echo "==> offsite verified: ${uploaded}/${#rc_encrypted[@]} objects present"
        OFFSITE_OK=1
      else
        echo "ERROR: offsite verification FAILED: ${uploaded}/${#rc_encrypted[@]} objects present at $BACKUP_RCLONE_REMOTE"
      fi
    fi
  fi
fi

echo "==> pruning local backups older than $RETENTION_DAYS days"
find "$BACKUP_DIR" -type f \( -name 'chatdb-*' -o -name 'media-*' -o -name 'env-*' \) -mtime +"$RETENTION_DAYS" -delete

echo "==> done. Local backups in $BACKUP_DIR:"
ls -lh "$BACKUP_DIR" | grep -E "$ts" || true

# Dead-man's switch (optional): ping ONLY on full success — local backup done AND
# offsite verified (when configured). A healthchecks.io check with a ~26h grace
# period then pages on the FIRST silently-failing night instead of accumulating
# false confidence in a log nobody tails.
if [[ -n "${BACKUP_HEALTHCHECK_URL:-}" ]]; then
  if (( OFFSITE_OK == 1 )); then
    curl -fsS -m 10 --retry 3 "$BACKUP_HEALTHCHECK_URL" >/dev/null \
      && echo "==> healthcheck pinged" \
      || echo "WARN: healthcheck ping failed (monitor will alert)"
  else
    echo "==> healthcheck ping SKIPPED (offsite not verified) — monitor will alert"
  fi
fi
