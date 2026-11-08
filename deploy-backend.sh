#!/usr/bin/env bash
# Backend production deploy for the Fireplace VM.
#
# Builds the backend Docker image from source (NODE_ENV=production) with a truthful
# GET /version, then recreates only the backend container. The frontend is deployed
# separately from a dev PC via deploy-web.ps1 (the 2 GB VM cannot build Flutter web).
#
# Usage (on the VM):  cd ~/fireplace && ./deploy-backend.sh
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"
cd "$REPO_DIR"

COMPOSE_FILE="docker-compose.prod.yml"
ENV_FILE="$REPO_DIR/.env"
CONTAINER="fireplace-backend-1"

echo "==> git pull"
git pull --ff-only

# --- version metadata (makes GET /version report the real pubspec semver + commit) ---
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
APP_VERSION="$(grep '^version:' frontend/pubspec.yaml | sed 's/version:[[:space:]]*//' | tr -d ' \r' | cut -d'+' -f1)"
export GIT_COMMIT BUILD_TIME APP_VERSION

# --- preflight: production needs these in ~/fireplace/.env ---
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Production needs it for secrets and origins." >&2
  exit 1
fi
missing=()
# JWT_SECRET must come from ~/fireplace/.env; deploy only checks presence and
# never generates/rotates it. Rotate exposed secrets manually after deploying sticky refresh.
for key in ALLOWED_ORIGINS MEDIA_BASE_URL JWT_SECRET \
           WEB_PUSH_VAPID_PUBLIC_KEY WEB_PUSH_VAPID_PRIVATE_KEY; do
  grep -qE "^${key}=" "$ENV_FILE" || missing+=("$key")
done
if (( ${#missing[@]} > 0 )); then
  {
    echo "ERROR: missing required keys in $ENV_FILE: ${missing[*]}"
    echo "NODE_ENV=production restricts CORS to ALLOWED_ORIGINS and builds media URLs"
    echo "from MEDIA_BASE_URL, so these MUST be set. Example:"
    echo "  ALLOWED_ORIGINS=https://fireplace.ignorelist.com"
    echo "  MEDIA_BASE_URL=https://fireplace.ignorelist.com"
  } >&2
  exit 1
fi

echo "==> deploying backend  version=${APP_VERSION} commit=${GIT_COMMIT} built=${BUILD_TIME}"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" build backend
# The runtime now runs as non-root 'node' (uid 1000). Volumes created by older
# root images keep root ownership, so make the media volume writable. Idempotent
# and cheap (media is small); creates the volume on a first-ever deploy.
docker run --rm -v fireplace_media_storage:/media alpine:3 chown -R 1000:1000 /media
# 'up -d' (both) so the version env applies to backend AND the db restart policy lands;
# never run a bare 'docker compose up -d' yourself — it would lack APP_VERSION (-> 0.0.1).
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d

# --- verify ---
echo "==> waiting for backend health"
status="unknown"
for i in $(seq 1 24); do
  sleep 5
  status="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo unknown)"
  echo "   [$((i*5))s] health=$status"
  [[ "$status" == "healthy" ]] && break
done

echo "==> GET /version"
curl -fsS http://127.0.0.1:3000/version && echo
echo "==> GET /health"
curl -fsS http://127.0.0.1:3000/health && echo

if [[ "$status" != "healthy" ]]; then
  echo "WARNING: backend not healthy after wait — check: docker compose -f $COMPOSE_FILE logs --tail=80 backend" >&2
  exit 1
fi

# Build cache grows with every deploy and nothing else removes it (~10 GB in
# five weeks, 2026-11-08). Only after a healthy deploy, and keep the last
# 3 days so a quick redeploy still builds from cache. A prune failure never
# fails the deploy.
echo "==> pruning Docker build cache older than 72h"
docker builder prune -f --filter until=72h | tail -n 1 || echo "WARNING: build cache prune failed (deploy itself is fine)" >&2
echo "Done. Public check: curl https://fireplace.ignorelist.com/version  (expect version=${APP_VERSION} commit=${GIT_COMMIT})"
