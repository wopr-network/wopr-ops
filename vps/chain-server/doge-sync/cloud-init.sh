#!/bin/bash
# Temp DOGE Sync Droplet — cloud-init
#
# Downloads pre-synced blockchain snapshot from GitHub (Blockchains-Download/Dogecoin),
# extracts into dogecoind data dir, starts dogecoind with prune to catch up.
# After sync, run export-chaindata.sh to push pruned data to GHCR, then destroy droplet.
#
# Snapshot: 2025-12-07 (~10GB compressed, ~60GB extracted)
# Expected timeline: ~5min download + ~20min extract + ~2-4hr sync to tip
#
# LESSONS LEARNED:
#   - bootstrap.sochain.com is dead (DNS doesn't resolve) — use GitHub snapshots
#   - DOGE minimum prune is 2200 MB (not 2048 like BTC)
#   - Do NOT use -reindex with prune — it wipes snapshot blocks
#   - DO fresh droplets need DNS fix (systemd-resolved broken)
#   - Add seed nodes manually (DNS seeds sometimes return 0)

set -euo pipefail

# Fix DNS immediately (DO droplets sometimes have broken systemd-resolved)
echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf

exec > >(tee -a /var/log/doge-sync.log) 2>&1

echo "=== DOGE Sync Started $(date -u +%FT%TZ) ==="

# --- Swap (4GB — reindex is memory-hungry) ---
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# --- Install deps ---
apt-get update
apt-get install -y ca-certificates curl gnupg p7zip-full docker.io

# Docker via apt (faster than Docker CE repo for cloud-init)
systemctl enable --now docker

# --- Create data directory ---
mkdir -p /opt/doge-sync/data /opt/doge-sync/snapshot

# --- dogecoin.conf (prune enabled) ---
cat > /opt/doge-sync/dogecoin.conf << 'CONFEOF'
server=1
rpcuser=doge
rpcpassword=dogesync2026
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
rpcport=22555
prune=2200
printtoconsole=1
maxconnections=24
addnode=seed.multidoge.org
addnode=seed2.multidoge.org
addnode=seed.dogecoin.com
addnode=seed.dogechain.info
addnode=seed.mophides.com
CONFEOF

# --- Download snapshot parts from GitHub ---
echo "=== Downloading snapshot $(date -u +%FT%TZ) ==="
echo "DOGE_SYNC_DOWNLOADING $(date -u +%FT%TZ)" > /var/log/doge-sync-status.log
cd /opt/doge-sync/snapshot

BASE_URL="https://github.com/Blockchains-Download/Dogecoin/releases/download/2025.12.07"
PARTS=(
  "Dogecoin-Blockchain-2025-12-07.7z.001"
  "Dogecoin-Blockchain-2025-12-07.7z.002"
  "Dogecoin-Blockchain-2025-12-07.7z.003"
  "Dogecoin-Blockchain-2025-12-07.7z.004"
  "Dogecoin-Blockchain-2025-12-07.7z.005"
)

for part in "${PARTS[@]}"; do
  echo "  Downloading $part ..."
  curl -fSL --retry 3 --retry-delay 10 -o "$part" "$BASE_URL/$part" || {
    echo "ERROR: Failed to download $part"
    echo "DOGE_SYNC_FAILED download_$part $(date -u +%FT%TZ)" > /var/log/doge-sync-status.log
    exit 1
  }
  SIZE=$(du -sh "$part" | cut -f1)
  echo "    $part: $SIZE"
done

echo "=== All parts downloaded $(date -u +%FT%TZ) ==="
echo "DOGE_SYNC_EXTRACTING $(date -u +%FT%TZ)" > /var/log/doge-sync-status.log

# --- Extract snapshot into data dir ---
echo "=== Extracting snapshot $(date -u +%FT%TZ) ==="
7z x -o/opt/doge-sync/data "Dogecoin-Blockchain-2025-12-07.7z.001" -y || {
  echo "ERROR: 7z extraction failed"
  echo "DOGE_SYNC_FAILED extract $(date -u +%FT%TZ)" > /var/log/doge-sync-status.log
  exit 1
}

# The snapshot may extract into a subdirectory — flatten if needed
if [ -d /opt/doge-sync/data/Dogecoin ] && [ ! -d /opt/doge-sync/data/blocks ]; then
  mv /opt/doge-sync/data/Dogecoin/* /opt/doge-sync/data/ 2>/dev/null || true
  rmdir /opt/doge-sync/data/Dogecoin 2>/dev/null || true
fi
if [ -d /opt/doge-sync/data/blocks ]; then
  echo "  Snapshot extracted — blocks/ directory found"
else
  # List what we got for debugging
  ls -la /opt/doge-sync/data/
  echo "WARNING: blocks/ not found — check extraction output"
fi

DISK=$(du -sh /opt/doge-sync/data/ | cut -f1)
echo "  Extracted size: $DISK"

# Delete compressed parts to free disk
rm -rf /opt/doge-sync/snapshot
echo "  Snapshot archives deleted"

echo "=== Extraction complete $(date -u +%FT%TZ) ==="

# --- Start dogecoind with reindex to validate + prune ---
echo "=== Starting dogecoind (reindex + prune) $(date -u +%FT%TZ) ==="
echo "DOGE_SYNC_REINDEXING $(date -u +%FT%TZ)" > /var/log/doge-sync-status.log

docker run -d --name dogecoind \
  --restart unless-stopped \
  -v /opt/doge-sync/data:/home/dogecoin/.dogecoin \
  -v /opt/doge-sync/dogecoin.conf:/home/dogecoin/.dogecoin/dogecoin.conf:ro \
  -p 22555:22555 \
  blocknetdx/dogecoin:latest \
  dogecoind -conf=/home/dogecoin/.dogecoin/dogecoin.conf -datadir=/home/dogecoin/.dogecoin

echo "=== dogecoind started — syncing from snapshot to tip ==="

# --- Monitor sync progress ---
while true; do
  sleep 300  # Check every 5 minutes
  INFO=$(docker exec dogecoind dogecoin-cli -rpcuser=doge -rpcpassword=dogesync2026 getblockchaininfo 2>/dev/null || echo '{}')
  BLOCKS=$(echo "$INFO" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('blocks',0))" 2>/dev/null || echo 0)
  PROGRESS=$(echo "$INFO" | python3 -c "import sys,json;d=json.load(sys.stdin);print(f\"{d.get('verificationprogress',0):.4f}\")" 2>/dev/null || echo 0)
  PRUNED=$(echo "$INFO" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('pruned',False))" 2>/dev/null || echo unknown)
  DISK=$(du -sh /opt/doge-sync/data/ 2>/dev/null | cut -f1)

  echo "  Blocks: $BLOCKS | Progress: $PROGRESS | Pruned: $PRUNED | Disk: $DISK | $(date -u +%H:%M)"
  echo "DOGE_SYNC_PROGRESS blocks=$BLOCKS progress=$PROGRESS pruned=$PRUNED disk=$DISK $(date -u +%FT%TZ)" > /var/log/doge-sync-status.log

  # Check if fully synced (progress > 0.9999)
  SYNCED=$(python3 -c "print('yes' if float('$PROGRESS') > 0.9999 else 'no')" 2>/dev/null || echo no)
  if [ "$SYNCED" = "yes" ]; then
    echo "=== DOGE fully synced! Blocks: $BLOCKS | Disk: $DISK ==="
    echo "DOGE_SYNC_COMPLETE blocks=$BLOCKS size=$DISK $(date -u +%FT%TZ)" > /var/log/doge-sync-status.log
    break
  fi
done

echo "=== DOGE sync complete. Run export-chaindata.sh to push to GHCR ==="
