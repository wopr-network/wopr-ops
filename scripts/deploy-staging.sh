#!/usr/bin/env bash
# deploy-staging.sh — Deploy staging environment alongside prod on the same VPS.
#
# Usage: ./deploy-staging.sh <product>
#   product: wopr | paperclip | holyship | nemoclaw
#
# What it does:
#   1. Copies prod postgres DB into staging postgres
#   2. Pulls :staging image tags
#   3. Starts staging containers via compose overlay
#
# Prerequisites:
#   - Run from the VPS (or SSH in first)
#   - docker-compose.staging.yml must exist alongside docker-compose.yml
#   - .env must have STAGING_BETTER_AUTH_SECRET set

set -euo pipefail

PRODUCT="${1:?Usage: $0 <product>}"

case "$PRODUCT" in
  wopr)       COMPOSE_DIR=/opt/wopr-platform;     PROD_DB=wopr_platform;     PROD_PG=postgres;     STAGING_PG=staging-postgres; PG_USER=wopr ;;
  paperclip)  COMPOSE_DIR=/opt/paperclip-platform; PROD_DB=paperclip;         PROD_PG=postgres;     STAGING_PG=staging-postgres; PG_USER=paperclip ;;
  holyship)   COMPOSE_DIR=/opt/holyship;           PROD_DB=holyship;          PROD_PG=postgres;     STAGING_PG=staging-postgres; PG_USER=holyship ;;
  nemoclaw)   COMPOSE_DIR=/opt/nemoclaw-platform;  PROD_DB=nemoclaw;          PROD_PG=postgres;     STAGING_PG=staging-postgres; PG_USER=nemoclaw ;;
  *) echo "Unknown product: $PRODUCT" >&2; exit 1 ;;
esac

cd "$COMPOSE_DIR"

COMPOSE="docker compose -f docker-compose.yml -f docker-compose.staging.yml"

echo "=== Pulling staging images ==="
$COMPOSE pull staging-api staging-ui 2>/dev/null || $COMPOSE pull staging-api

echo "=== Starting staging postgres ==="
$COMPOSE up -d staging-postgres
sleep 3

echo "=== Copying prod DB → staging DB ==="
# Dump prod, restore into staging postgres
docker compose exec -T "$PROD_PG" pg_dump -U "$PG_USER" "$PROD_DB" | \
  $COMPOSE exec -T "$STAGING_PG" psql -U "$PG_USER" -d "$PROD_DB" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" 2>/dev/null
docker compose exec -T "$PROD_PG" pg_dump -U "$PG_USER" "$PROD_DB" | \
  $COMPOSE exec -T "$STAGING_PG" psql -U "$PG_USER" "$PROD_DB"

echo "=== Starting staging services ==="
$COMPOSE up -d staging-api staging-ui 2>/dev/null || $COMPOSE up -d staging-api

echo "=== Reloading Caddy ==="
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || \
  docker compose restart caddy

echo "=== Done ==="
echo "Staging is live. Watchtower will auto-update on new :staging pushes."
