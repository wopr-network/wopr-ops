#!/bin/bash
# Provision a TEMPORARY droplet for DOGE chain sync.
#
# This droplet downloads bootstrap.dat (~50GB), imports into dogecoind,
# and prunes to ~2GB. After sync, run export-chaindata.sh then destroy.
#
# Usage:
#   cd wopr-ops && bash vps/chain-server/doge-sync/provision.sh
#
# To destroy after export:
#   DESTROY=true bash vps/chain-server/doge-sync/provision.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DO_TOKEN="${DO_API_TOKEN:?Set DO_API_TOKEN}"
DROPLET_NAME="doge-sync-temp"
REGION="sfo2"
SIZE="s-4vcpu-8gb"  # 160GB disk — enough for bootstrap + chain before prune
IMAGE="ubuntu-24-04-x64"
SSH_KEY_IDS="54912818,52980537"

do_api() {
  local method=$1 path=$2; shift 2
  curl -sf -X "$method" "https://api.digitalocean.com/v2$path" \
    -H "Authorization: Bearer $DO_TOKEN" \
    -H "Content-Type: application/json" "$@"
}

# --- Destroy mode ---
if [ "${DESTROY:-}" = "true" ]; then
  echo "==> Destroying doge-sync droplets..."
  EXISTING=$(do_api GET "/droplets?tag_name=doge-sync" | jq -r '.droplets[].id' 2>/dev/null || true)
  for id in $EXISTING; do
    echo "    Deleting droplet $id"
    do_api DELETE "/droplets/$id" || true
  done
  echo "Done. Temp droplet destroyed."
  exit 0
fi

# --- Create droplet ---
echo "==> Creating temp DOGE sync droplet ($SIZE — 160GB disk)..."
CLOUD_INIT=$(cat "$SCRIPT_DIR/cloud-init.sh")

IFS=',' read -ra KEYS <<< "$SSH_KEY_IDS"
KEY_JSON=$(printf '%s\n' "${KEYS[@]}" | jq -R 'tonumber' | jq -s '.')

DROPLET_ID=$(do_api POST "/droplets" \
  -d "$(jq -n \
    --arg name "$DROPLET_NAME" \
    --arg region "$REGION" \
    --arg size "$SIZE" \
    --arg image "$IMAGE" \
    --arg user_data "$CLOUD_INIT" \
    --argjson ssh_keys "$KEY_JSON" \
    '{name:$name,region:$region,size:$size,image:$image,ssh_keys:$ssh_keys,user_data:$user_data,tags:["doge-sync","temp"]}'
  )" | jq -r '.droplet.id')

echo "    Droplet ID: $DROPLET_ID"

# --- Wait for IP ---
echo "==> Waiting for IP..."
IP=""
for i in $(seq 1 30); do
  IP=$(do_api GET "/droplets/$DROPLET_ID" | jq -r '.droplets // [] | .[] | .networks.v4[] | select(.type=="public") | .ip_address' 2>/dev/null || true)
  if [ -z "$IP" ]; then
    IP=$(do_api GET "/droplets/$DROPLET_ID" | jq -r '.droplet.networks.v4[] | select(.type=="public") | .ip_address' 2>/dev/null || true)
  fi
  if [ -n "$IP" ] && [ "$IP" != "null" ]; then
    echo "    Public IP: $IP"
    break
  fi
  sleep 10
done

if [ -z "$IP" ] || [ "$IP" = "null" ]; then
  echo "ERROR: Timed out waiting for IP"
  exit 1
fi

# --- Done ---
echo ""
echo "=== DOGE Sync Droplet Created ==="
echo "  Droplet:  $DROPLET_ID"
echo "  IP:       $IP"
echo "  SSH:      ssh root@$IP"
echo ""
echo "Monitor progress:"
echo "  ssh root@$IP 'cat /var/log/doge-sync-status.log'"
echo "  ssh root@$IP 'tail -20 /var/log/doge-sync.log'"
echo "  ssh root@$IP 'docker logs dogecoind --tail 10'"
echo ""
echo "After sync completes (status shows DOGE_SYNC_COMPLETE):"
echo "  scp $SCRIPT_DIR/export-chaindata.sh root@$IP:/opt/doge-sync/"
echo "  ssh root@$IP 'bash /opt/doge-sync/export-chaindata.sh'"
echo ""
echo "After export, destroy this droplet:"
echo "  DESTROY=true bash $SCRIPT_DIR/provision.sh"
