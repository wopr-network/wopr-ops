#!/usr/bin/env bash
# deploy-staging.sh — Deploy staging environment alongside prod on the same VPS.
#
# Usage: ./deploy-staging.sh <product>
#   product: wopr | paperclip | holyship | nemoclaw
#
# What it does:
#   1. Stops staging API (prevents DB connections during restore)
#   2. Pulls :staging image tags
#   3. Drops and recreates staging DB schema
#   4. Copies prod postgres DB into staging postgres
#   5. Starts staging containers via compose overlay
#
# Prerequisites:
#   - Run from the VPS (or SSH in first)
#   - docker-compose.staging.yml must exist alongside docker-compose.yml
#   - .env must have STAGING_BETTER_AUTH_SECRET set

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

COMPOSE="docker compose -f docker-compose.yml -f docker-compose.staging.yml"

echo "=== Stopping staging API ==="
$COMPOSE stop staging-api 2>/dev/null || true

echo "=== Pulling staging images ==="
$COMPOSE pull staging-api staging-ui 2>/dev/null || $COMPOSE pull staging-api

echo "=== Ensuring staging postgres is running ==="
$COMPOSE up -d staging-postgres
echo "Waiting for staging postgres to be healthy..."
for i in $(seq 1 30); do
  if $COMPOSE exec -T staging-postgres pg_isready -U "$PG_USER" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "=== Copying prod DB → staging DB ==="
# Drop and recreate schema for a clean restore
$COMPOSE exec -T staging-postgres psql -U "$PG_USER" -d "$PROD_DB" -c \
  "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" 2>/dev/null || true

# Pipe prod dump directly into staging
docker compose exec -T postgres pg_dump -U "$PG_USER" --no-owner --no-acl "$PROD_DB" | \
  $COMPOSE exec -T staging-postgres psql -U "$PG_USER" -d "$PROD_DB" -q

echo "=== Starting staging services ==="
$COMPOSE up -d staging-api staging-ui 2>/dev/null || $COMPOSE up -d staging-api

echo "=== Reloading Caddy ==="
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || \
  docker compose restart caddy

echo "=== Waiting for staging API health ==="
for i in $(seq 1 60); do
  if $COMPOSE exec -T staging-api curl -sf http://localhost:3100/health >/dev/null 2>&1; then
    echo "Staging API is healthy!"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: Staging API did not become healthy within 60s"
    $COMPOSE logs --tail 20 staging-api
    exit 1
  fi
  sleep 1
done

echo "=== Done ==="
echo "Staging deployed for $PRODUCT."
