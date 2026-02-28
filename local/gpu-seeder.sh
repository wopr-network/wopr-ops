#!/bin/bash
# Seed the GPU node registration row into platform-api's postgres.
#
# Run AFTER both containers are up and healthy:
#   docker compose -f local/docker-compose.yml up -d
#   bash local/gpu-seeder.sh
#
# What this does:
#   1. Gets the wopr-gpu container's IP on the wopr-dev bridge
#   2. Connects to postgres running INSIDE the wopr-vps container
#   3. Upserts a gpu_nodes row with host=<wopr-gpu IP>
#
# Why we use the container IP and not the hostname "wopr-gpu":
#   The InferenceWatchdog in platform-api constructs HTTP requests using the
#   host field from the gpu_nodes row. Platform-api runs inside the vps DinD
#   container's inner Docker network. It reaches wopr-gpu via extra_hosts
#   (host-gateway) which resolves to the outer container's default route.
#   Storing the literal IP is more reliable than depending on hostname
#   resolution through two layers of Docker networking.
#
# After seeding, restart platform-api so InferenceWatchdog picks up the row:
#   docker exec wopr-vps sh -c "cd /workspace/vps && docker compose restart platform-api"

set -e

# ---------------------------------------------------------------------------
# Resolve wopr-gpu's IP on the wopr-dev bridge
# ---------------------------------------------------------------------------
GPU_IP=$(docker inspect wopr-gpu \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
  2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -1)

if [ -z "$GPU_IP" ]; then
  echo "ERROR: Could not determine wopr-gpu IP. Is the container running?"
  echo "  Run: docker compose -f local/docker-compose.yml up -d"
  exit 1
fi

echo "==> wopr-gpu IP on wopr-dev: $GPU_IP"

# ---------------------------------------------------------------------------
# Load GPU_NODE_ID and POSTGRES_PASSWORD from env file if present
# ---------------------------------------------------------------------------
GPU_NODE_ID="${GPU_NODE_ID:-local-gpu-node-001}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-wopr_local_dev}"

# Try to read from vps .env if not set in environment
if [ -f "$(dirname "$0")/vps/.env" ]; then
  GPU_NODE_ID_FROM_FILE=$(grep '^GPU_NODE_ID=' "$(dirname "$0")/vps/.env" 2>/dev/null | cut -d= -f2)
  PG_PASS_FROM_FILE=$(grep '^POSTGRES_PASSWORD=' "$(dirname "$0")/vps/.env" 2>/dev/null | cut -d= -f2)
  [ -n "$GPU_NODE_ID_FROM_FILE" ] && GPU_NODE_ID="$GPU_NODE_ID_FROM_FILE"
  [ -n "$PG_PASS_FROM_FILE" ] && POSTGRES_PASSWORD="$PG_PASS_FROM_FILE"
fi

echo "==> GPU_NODE_ID: $GPU_NODE_ID"
echo "==> Seeding gpu_nodes row into wopr-vps postgres..."

# ---------------------------------------------------------------------------
# Run psql inside the vps container targeting its inner postgres
# ---------------------------------------------------------------------------
docker exec wopr-vps sh -c "
  PGPASSWORD='$POSTGRES_PASSWORD' psql -h localhost -p 5432 -U wopr -d wopr_platform -c \"
    INSERT INTO gpu_nodes (id, host, region, size, status, provision_stage, service_health, monthly_cost_cents)
    VALUES (
      '$GPU_NODE_ID',
      '$GPU_IP',
      'local',
      'rtx-3070',
      'active',
      'done',
      '{\\\"llama\\\":true,\\\"chatterbox\\\":true,\\\"whisper\\\":true,\\\"qwen\\\":true}',
      0
    )
    ON CONFLICT (id) DO UPDATE SET
      host             = EXCLUDED.host,
      status           = 'active',
      provision_stage  = 'done',
      service_health   = '{\\\"llama\\\":true,\\\"chatterbox\\\":true,\\\"whisper\\\":true,\\\"qwen\\\":true}',
      updated_at       = EXTRACT(EPOCH FROM NOW())::bigint;
  \"
"

echo "==> GPU node row upserted (host=$GPU_IP)."
echo ""
echo "==> Restarting platform-api so InferenceWatchdog picks up the new row..."
docker exec wopr-vps sh -c "cd /workspace/vps && docker compose restart platform-api" 2>/dev/null || \
  echo "  NOTE: Could not restart platform-api automatically. Run manually:"
echo "  docker exec wopr-vps sh -c 'cd /workspace/vps && docker compose restart platform-api'"
echo ""
echo "==> Done. Verify with:"
echo "  docker exec wopr-vps sh -c \"PGPASSWORD=\$POSTGRES_PASSWORD psql -h localhost -U wopr -d wopr_platform -c 'SELECT id, host, status, service_health FROM gpu_nodes;'\""
