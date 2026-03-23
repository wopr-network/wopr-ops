#!/bin/bash
# Migrate LTC chaindata from external volume (/mnt/ltc_sync) to Docker named volume (main disk)
# Then backup to GHCR as OCI artifact
#
# PREREQUISITES:
#   - LTC fully synced
#   - Run on chain-server (167.71.118.221) as root
#   - Enough free disk space on main disk (check with: df -h /)
#
# PLAN:
#   1. Stop litecoind (clean shutdown)
#   2. Backup to GHCR (ghcr.io/wopr-network/ltc-chaindata:latest)
#   3. Copy data to Docker named volume on main disk
#   4. Update docker-compose.yml to use named volume
#   5. Start litecoind, verify sync resumes
#   6. Only after verification: detach + delete ltc-sync DO volume
#
# Each step is idempotent and safe to re-run.
set -euo pipefail

COMPOSE_DIR="/opt/chain-server"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
SRC_DIR="/mnt/ltc_sync"
VOLUME_NAME="ltc_data"
GHCR_IMAGE="ghcr.io/wopr-network/ltc-chaindata:latest"

echo "=== LTC Migration Script ==="
echo ""

# Preflight checks
echo "[preflight] Checking disk space..."
SRC_SIZE=$(du -sh "$SRC_DIR" 2>/dev/null | cut -f1)
MAIN_FREE=$(df -h / | awk 'NR==2{print $4}')
echo "  Source size: $SRC_SIZE"
echo "  Main disk free: $MAIN_FREE"
echo ""
echo "  ⚠️  Ensure main disk has enough free space before proceeding!"
echo ""

read -p "Continue? [y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 1

# Step 1: Stop litecoind cleanly
echo ""
echo "[step 1/6] Stopping litecoind (clean shutdown)..."
cd "$COMPOSE_DIR"
docker compose stop litecoind
echo "  ✓ litecoind stopped"

# Step 2: Backup to GHCR
echo ""
echo "[step 2/6] Creating GHCR backup..."
echo "  Tarring chaindata (this may take a while)..."
tar -czf /tmp/ltc-chaindata.tar.gz -C "$SRC_DIR" .
echo "  Tar size: $(du -sh /tmp/ltc-chaindata.tar.gz | cut -f1)"

echo "  Pushing to GHCR as OCI artifact..."
# Use ORAS or docker buildx to push as OCI artifact
# Fallback: build a minimal image with the data
cat > /tmp/Dockerfile.ltc-chaindata <<'EOF'
FROM scratch
COPY ltc-chaindata.tar.gz /ltc-chaindata.tar.gz
EOF
cp /tmp/ltc-chaindata.tar.gz /tmp/
docker build -t "$GHCR_IMAGE" -f /tmp/Dockerfile.ltc-chaindata /tmp/
docker push "$GHCR_IMAGE"
echo "  ✓ Backup pushed to $GHCR_IMAGE"

# Cleanup temp files
rm -f /tmp/ltc-chaindata.tar.gz /tmp/Dockerfile.ltc-chaindata

# Step 3: Copy to Docker named volume
echo ""
echo "[step 3/6] Creating Docker volume and copying data..."
docker volume create "$VOLUME_NAME" 2>/dev/null || true
echo "  Copying $SRC_DIR → $VOLUME_NAME (this may take a while)..."

# Use a temp container to copy data into the named volume
docker run --rm \
  -v "$SRC_DIR":/src:ro \
  -v "$VOLUME_NAME":/dst \
  alpine sh -c "cp -a /src/. /dst/"

echo "  ✓ Data copied to volume $VOLUME_NAME"

# Step 4: Update docker-compose.yml
echo ""
echo "[step 4/6] Updating docker-compose.yml..."

# Backup compose file
cp "$COMPOSE_FILE" "$COMPOSE_FILE.bak.$(date +%s)"

# Replace the bind mount with the named volume
sed -i 's|- /mnt/ltc_sync:/data|- ltc_data:/data|' "$COMPOSE_FILE"

# Add ltc_data to volumes section if not already there
if ! grep -q "ltc_data:" "$COMPOSE_FILE"; then
  sed -i '/^volumes:/a\  ltc_data:' "$COMPOSE_FILE"
fi

echo "  ✓ docker-compose.yml updated (backup saved)"

# Step 5: Start and verify
echo ""
echo "[step 5/6] Starting litecoind on main disk..."
cd "$COMPOSE_DIR"
docker compose up -d litecoind

echo "  Waiting 30s for litecoind to start..."
sleep 30

echo "  Checking if sync resumed..."
LATEST_LOG=$(docker logs chain-litecoind --tail 3 2>&1)
echo "$LATEST_LOG"

if echo "$LATEST_LOG" | grep -q "UpdateTip"; then
  echo ""
  echo "  ✓ litecoind is syncing from the named volume!"
else
  echo ""
  echo "  ⚠️  No UpdateTip in recent logs. Check manually:"
  echo "     docker logs chain-litecoind --tail 20"
  echo ""
  echo "  To rollback:"
  echo "     docker compose stop litecoind"
  echo "     cp $COMPOSE_FILE.bak.* $COMPOSE_FILE"
  echo "     docker compose up -d litecoind"
  exit 1
fi

# Step 6: Manual verification reminder
echo ""
echo "[step 6/6] MANUAL STEP — Do NOT run until verified!"
echo ""
echo "  After confirming litecoind is syncing correctly for 10+ minutes:"
echo ""
echo "  # Detach the external volume"
echo "  doctl compute volume-action detach 559531609 --wait"
echo ""
echo "  # Delete the volume (\$10/mo savings)"
echo "  doctl compute volume delete ltc-sync --force"
echo ""
echo "  # Update wopr-ops repo"
echo "  # Remove the 'ltc-sync volume' note from TOPOLOGY.md"
echo ""
echo "=== Migration complete (pending manual volume deletion) ==="
