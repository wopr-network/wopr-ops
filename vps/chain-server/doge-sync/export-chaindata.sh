#!/bin/bash
# Export pruned DOGE chaindata to GHCR.
#
# Run this ON the temp sync droplet after dogecoind is fully synced.
# The exported image can then be loaded on the chain server to skip sync.
#
# Usage (on the temp droplet):
#   bash /opt/doge-sync/export-chaindata.sh

set -euo pipefail

GHCR_IMAGE="ghcr.io/wopr-network/doge-chaindata:latest"
DATA_DIR="/opt/doge-sync/data"

echo "=== Exporting DOGE chaindata to GHCR ==="

# --- Stop dogecoind gracefully ---
echo "==> Stopping dogecoind..."
docker exec dogecoind dogecoin-cli -rpcuser=doge -rpcpassword=dogesync2026 stop 2>/dev/null || true
sleep 10
docker stop dogecoind 2>/dev/null || true
docker rm dogecoind 2>/dev/null || true

# --- Clean up unneeded files ---
echo "==> Cleaning up..."
rm -f "$DATA_DIR/bootstrap.dat" "$DATA_DIR/bootstrap.dat.old"
rm -f "$DATA_DIR/debug.log"
rm -rf "$DATA_DIR/wallets"
rm -f "$DATA_DIR/.lock" "$DATA_DIR/banlist.dat" "$DATA_DIR/fee_estimates.dat"
rm -f "$DATA_DIR/peers.dat" "$DATA_DIR/mempool.dat"

# Keep: blocks/ chainstate/ dogecoin.conf (will be overridden on chain server)
DISK=$(du -sh "$DATA_DIR" | cut -f1)
echo "    Chaindata size after cleanup: $DISK"

# --- Login to GHCR ---
echo "==> Logging into GHCR..."
# Requires GITHUB_TOKEN or gh CLI auth
if command -v gh &>/dev/null; then
  gh auth token | docker login ghcr.io -u wopr-network --password-stdin
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "$GITHUB_TOKEN" | docker login ghcr.io -u wopr-network --password-stdin
else
  echo "ERROR: Need gh CLI or GITHUB_TOKEN for GHCR auth"
  exit 1
fi

# --- Build minimal image with chaindata ---
echo "==> Building chaindata image..."
cat > /tmp/Dockerfile.doge-chaindata << 'DEOF'
FROM scratch
COPY data/ /chaindata/
DEOF

cd /opt/doge-sync
docker build -f /tmp/Dockerfile.doge-chaindata -t "$GHCR_IMAGE" .

# --- Push to GHCR ---
echo "==> Pushing to GHCR (this may take a while for ~2GB)..."
docker push "$GHCR_IMAGE"

echo ""
echo "=== DOGE chaindata exported ==="
echo "  Image: $GHCR_IMAGE"
echo "  Size:  $DISK"
echo ""
echo "On the chain server, pull and load:"
echo "  docker pull $GHCR_IMAGE"
echo "  # Create a temp container, copy chaindata out"
echo "  docker create --name doge-data $GHCR_IMAGE"
echo "  docker cp doge-data:/chaindata/. /path/to/doge-volume/"
echo "  docker rm doge-data"
echo ""
echo "Now destroy this temp droplet:"
echo "  DESTROY=true bash ~/wopr-ops/vps/chain-server/doge-sync/provision.sh"
