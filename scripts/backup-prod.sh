#!/usr/bin/env bash
# backup-prod.sh — Backup production database before promotion.
#
# Usage: ./backup-prod.sh <product>
#   product: wopr | paperclip | holyship | nemoclaw
#
# Creates a timestamped SQL dump in /opt/<product>/backups/
# Keeps last 5 backups, deletes older ones.

set -euo pipefail

PRODUCT="${1:?Usage: $0 <product>}"

case "$PRODUCT" in
  wopr)       COMPOSE_DIR=/opt/wopr-platform;     PROD_DB=wopr_platform;     PG_USER=wopr ;;
  paperclip)  COMPOSE_DIR=/opt/paperclip-platform; PROD_DB=paperclip_platform; PG_USER=paperclip ;;
  holyship)   COMPOSE_DIR=/opt/holyship;           PROD_DB=holyship;          PG_USER=holyship ;;
  nemoclaw)   COMPOSE_DIR=/opt/nemoclaw-platform;  PROD_DB=nemoclaw_platform; PG_USER=nemoclaw ;;
  *) echo "Unknown product: $PRODUCT" >&2; exit 1 ;;
esac

cd "$COMPOSE_DIR"

BACKUP_DIR="$COMPOSE_DIR/backups"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/${PROD_DB}-${TIMESTAMP}.sql.gz"

echo "=== Backing up $PROD_DB ==="
docker compose exec -T postgres pg_dump -U "$PG_USER" --no-owner --no-acl "$PROD_DB" | \
  gzip > "$BACKUP_FILE"

SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "Backup created: $BACKUP_FILE ($SIZE)"

echo "=== Cleaning old backups (keeping last 5) ==="
ls -t "$BACKUP_DIR"/*.sql.gz 2>/dev/null | tail -n +6 | xargs -r rm -v

echo "=== Current backups ==="
ls -lh "$BACKUP_DIR"/*.sql.gz 2>/dev/null

echo "=== Done ==="
