#!/usr/bin/env bash
# backup-prod.sh — Backup production database before promotion.
#
# Usage: ./backup-prod.sh <product> [image-sha]
#   product:   wopr | paperclip | holyship | nemoclaw
#   image-sha: (optional) git SHA or image tag to embed in the backup filename
#
# Creates a SQL dump in /opt/<product>/backups/ tagged with the image SHA.
# Filename: <db>-<timestamp>-<sha>.sql.gz
# Keeps last 5 backups, deletes older ones.

set -euo pipefail

PRODUCT="${1:?Usage: $0 <product> [image-sha]}"
IMAGE_SHA="${2:-}"

case "$PRODUCT" in
  wopr)       COMPOSE_DIR=/opt/wopr-platform;     PROD_DB=wopr_platform;     PG_USER=wopr;      API_IMAGE=wopr-platform ;;
  paperclip)  COMPOSE_DIR=/opt/paperclip-platform; PROD_DB=paperclip_platform; PG_USER=paperclip; API_IMAGE=paperclip-platform ;;
  holyship)   COMPOSE_DIR=/opt/holyship;           PROD_DB=holyship;          PG_USER=holyship;  API_IMAGE=holyship ;;
  nemoclaw)   COMPOSE_DIR=/opt/nemoclaw-platform;  PROD_DB=nemoclaw_platform; PG_USER=nemoclaw;  API_IMAGE=nemoclaw-platform ;;
  *) echo "Unknown product: $PRODUCT" >&2; exit 1 ;;
esac

cd "$COMPOSE_DIR"

# If no SHA provided, read it from the currently running API image
if [ -z "$IMAGE_SHA" ]; then
  IMAGE_SHA=$(docker compose exec -T platform-api cat /dev/null 2>/dev/null && \
    docker inspect --format='{{index .Config.Labels "org.opencontainers.image.revision"}}' \
      "$(docker compose ps -q platform-api 2>/dev/null | head -1)" 2>/dev/null || true)
  # Fallback: extract tag from image name
  if [ -z "$IMAGE_SHA" ]; then
    IMAGE_SHA=$(docker inspect --format='{{.Config.Image}}' \
      "$(docker compose ps -q platform-api 2>/dev/null | head -1)" 2>/dev/null | grep -oP ':\K[a-f0-9]{7,}$' || echo "unknown")
  fi
fi
SHORT_SHA="${IMAGE_SHA:0:7}"

BACKUP_DIR="$COMPOSE_DIR/backups"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/${PROD_DB}-${TIMESTAMP}-${SHORT_SHA}.sql.gz"

echo "=== Backing up $PROD_DB (image: $SHORT_SHA) ==="
docker compose exec -T postgres pg_dump -U "$PG_USER" --no-owner --no-acl "$PROD_DB" | \
  gzip > "$BACKUP_FILE"

SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "Backup created: $BACKUP_FILE ($SIZE)"

echo "=== Cleaning old backups (keeping last 5) ==="
ls -t "$BACKUP_DIR"/*.sql.gz 2>/dev/null | tail -n +6 | xargs -r rm -v

echo "=== Current backups ==="
ls -lh "$BACKUP_DIR"/*.sql.gz 2>/dev/null

echo "=== Done ==="
