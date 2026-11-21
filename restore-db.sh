#!/usr/bin/env bash
# Restore a Fireplace Postgres dump produced by backup-db.sh.
#
# DESTRUCTIVE: --clean drops & recreates objects in the target DB. The backend is
# stopped during the restore and started again afterwards.
#
# Usage:  cd ~/fireplace && ./restore-db.sh ~/fireplace-backups/chatdb-YYYYmmddTHHMMSSZ.dump[.gpg]
#   Encrypted (.gpg) dumps use BACKUP_PASSPHRASE or BACKUP_PASSPHRASE_FILE
#   (default ~/.config/fireplace/backup.pass, chmod 600).
#   Media + .env are restored MANUALLY (see production-vm-deploy rule) — this script is DB-only,
#   so a restore never clobbers a rotated live .env.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <chatdb-*.dump[.gpg]>" >&2; exit 1; }
SRC="$1"
[[ -f "$SRC" ]] || { echo "ERROR: not found: $SRC" >&2; exit 1; }

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"
cd "$REPO_DIR"
COMPOSE_FILE="docker-compose.prod.yml"
ENV_FILE="$REPO_DIR/.env"
DB_NAME="${DB_NAME:-chatdb}"
DB_USER="${DB_USER:-postgres}"

compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

BACKUP_PASSPHRASE_FILE="${BACKUP_PASSPHRASE_FILE:-$HOME/.config/fireplace/backup.pass}"
tmp=""
_PASS_TMP=""
PASS_FILE=""
cleanup() {
  [[ -n "$tmp" ]] && { shred -u "$tmp" 2>/dev/null || rm -f "$tmp"; }
  [[ -n "$_PASS_TMP" ]] && { shred -u "$_PASS_TMP" 2>/dev/null || rm -f "$_PASS_TMP"; }
}
trap cleanup EXIT INT TERM

# Sets global PASS_FILE to a 0600 passphrase file, or "" if none (parent scope; trap-safe).
resolve_pass_file() {
  if [[ -n "${BACKUP_PASSPHRASE:-}" ]]; then
    _PASS_TMP="$(mktemp)"; chmod 600 "$_PASS_TMP"
    printf '%s' "$BACKUP_PASSPHRASE" > "$_PASS_TMP"
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

if [[ "$SRC" == *.gpg ]]; then
  resolve_pass_file || exit 1
  [[ -n "$PASS_FILE" ]] || { echo "ERROR: encrypted dump needs BACKUP_PASSPHRASE or $BACKUP_PASSPHRASE_FILE (chmod 600)" >&2; exit 1; }
  tmp="$(mktemp)"
  gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASS_FILE" -o "$tmp" -d "$SRC"
  SRC="$tmp"
fi

# Guard: never restore from an empty/truncated source.
[[ -s "$SRC" ]] || { echo "ERROR: restore source is empty: $1" >&2; exit 1; }

echo "WARNING: this OVERWRITES data in '$DB_NAME'. Ctrl-C within 5s to abort."
sleep 5

echo "==> stopping backend"
compose stop backend

# Atomic: --single-transaction rolls the ENTIRE restore back on ANY error, so a
# corrupt/partial dump can never leave the DB half-dropped. Capture the status
# WITHOUT letting `set -e` abort, so the backend is ALWAYS brought back up.
echo "==> pg_restore (atomic, single transaction)"
restore_status=0
compose exec -T db pg_restore -U "$DB_USER" -d "$DB_NAME" \
  --clean --if-exists --single-transaction < "$SRC" || restore_status=$?

recount_status=0
if [[ "$restore_status" -eq 0 ]]; then
  # Dumps leave the box's messages and media out (decision 147): count the box
  # again from what the tables hold, or it would refuse sends for messages it
  # no longer has. Rung sizes = BOX_MEDIA_LADDER (backend/src/box/box.constants.ts).
  echo "==> recounting the box (its contents are not in backups)"
  compose exec -T db psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q <<'SQL' || recount_status=$?
BEGIN;
UPDATE public.box_queues q
   SET "msgCount" = (SELECT count(*) FROM public.box_msgs m WHERE m.rid = q.rid);
UPDATE public.box_totals
   SET "msgCount" = (SELECT count(*) FROM public.box_msgs),
       "mediaBytes" = (SELECT coalesce(sum(CASE "sizeBucket"
           WHEN '4k' THEN 4096 WHEN '16k' THEN 16384 WHEN '64k' THEN 65536
           WHEN '256k' THEN 262144 WHEN '1m' THEN 1048576
           WHEN '4m' THEN 4194304 WHEN '16m' THEN 16777216
           WHEN '32m' THEN 33554432 END), 0) FROM public.box_media)
 WHERE id = 1;
COMMIT;
SQL
fi

echo "==> starting backend"
compose up -d backend

if [[ "$restore_status" -ne 0 ]]; then
  echo "ERROR: pg_restore failed (exit $restore_status). The transaction rolled back —" >&2
  echo "       the database is unchanged and the backend is back up on the prior data." >&2
  exit "$restore_status"
fi
if [[ "$recount_status" -ne 0 ]]; then
  echo "ERROR: the data is restored but the box recount failed (exit $recount_status): the box" >&2
  echo "       may refuse sends. Re-run the recount SQL in this script by hand, then restart the backend." >&2
  exit "$recount_status"
fi
echo "==> restore complete. Verify:  curl -fsS http://127.0.0.1:3000/health"
