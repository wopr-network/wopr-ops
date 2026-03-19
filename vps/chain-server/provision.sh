#!/bin/bash
# Shared Chain Server — Full automated provisioning
#
# Creates a DO droplet with 4GB RAM for chain sync, updates DNS,
# downloads UTXO snapshot for fast-sync, starts BTCPay stack.
#
# After sync completes (~1hr with snapshot), all product VPSes
# connect to this server via DO private networking.
#
# Prerequisites:
#   - DO_API_TOKEN in env or ~/.bashrc
#   - CLOUDFLARE_API_TOKEN in env or ~/.bashrc
#   - gh CLI authenticated
#   - vps/chain-server/.env.production with secrets
#
# Usage:
#   cd wopr-ops && bash vps/chain-server/provision.sh
#
# To destroy and recreate:
#   DESTROY_FIRST=true bash vps/chain-server/provision.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DO_TOKEN="${DO_API_TOKEN:?Set DO_API_TOKEN}"
CF_TOKEN="${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN}"
# wopr.bot zone — pay.wopr.bot will be the BTCPay admin URL
CF_ZONE="c1dc2cc96846e1d7bf8606009f9a6f9e"
DROPLET_NAME="chain-server"
REGION="sfo2"
# 4GB RAM needed for Bitcoin IBD + UTXO snapshot loading
SIZE="s-2vcpu-4gb"
IMAGE="ubuntu-24-04-x64"
SSH_KEY_IDS="54912818,52980537"
DOMAINS=("pay.wopr.bot")

do_api() {
  local method=$1 path=$2; shift 2
  curl -sf -X "$method" "https://api.digitalocean.com/v2$path" \
    -H "Authorization: Bearer $DO_TOKEN" \
    -H "Content-Type: application/json" "$@"
}

cf_api() {
  local method=$1 path=$2; shift 2
  curl -sf -X "$method" "https://api.cloudflare.com/client/v4/zones/$CF_ZONE$path" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" "$@"
}

# --- Step 0: Destroy existing droplet if requested ---
if [ "${DESTROY_FIRST:-}" = "true" ]; then
  echo "==> Destroying existing droplets named '$DROPLET_NAME'..."
  EXISTING=$(do_api GET "/droplets?tag_name=chain" | jq -r '.droplets[] | select(.name=="'"$DROPLET_NAME"'") | .id')
  for id in $EXISTING; do
    echo "    Deleting droplet $id"
    do_api DELETE "/droplets/$id" || true
  done
  sleep 5
fi

# --- Step 1: Create droplet ---
echo "==> Creating droplet ($SIZE — 4GB RAM for chain sync)..."
ENV_FILE="${SCRIPT_DIR}/.env.production"
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found."
  exit 1
fi

CLOUD_INIT=$(python3 -c "
import sys
ci = open('$SCRIPT_DIR/cloud-init.sh').read()
env = open('$ENV_FILE').read()
heredoc = \"cat > /opt/chain-server/.env << 'ENVEOF'\n\" + env.strip() + \"\nENVEOF\"
print(ci.replace('# ENV_INJECT_MARKER', heredoc))
")
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
    '{name:$name,region:$region,size:$size,image:$image,ssh_keys:$ssh_keys,user_data:$user_data,tags:["chain","production"],vpc_uuid:"'"${VPC_UUID:-}"'"}'
  )" | jq -r '.droplet.id')

echo "    Droplet ID: $DROPLET_ID"

# --- Step 2: Wait for IP ---
echo "==> Waiting for IP..."
for i in $(seq 1 30); do
  IP=$(do_api GET "/droplets/$DROPLET_ID" | jq -r '.droplet.networks.v4[] | select(.type=="public") | .ip_address' 2>/dev/null || true)
  if [ -n "$IP" ] && [ "$IP" != "null" ]; then
    echo "    Public IP: $IP"
    break
  fi
  sleep 10
done

# Also get private IP for inter-droplet communication
PRIVATE_IP=$(do_api GET "/droplets/$DROPLET_ID" | jq -r '.droplet.networks.v4[] | select(.type=="private") | .ip_address' 2>/dev/null || true)
echo "    Private IP: ${PRIVATE_IP:-none (enable VPC)}"

if [ -z "$IP" ] || [ "$IP" = "null" ]; then
  echo "ERROR: Timed out waiting for IP"
  exit 1
fi

# --- Step 3: Update Cloudflare DNS ---
echo "==> Updating DNS records..."
RECORDS=$(cf_api GET "/dns_records?type=A" | jq -r '.result[] | "\(.id) \(.name)"')

for domain in "${DOMAINS[@]}"; do
  RECORD_ID=$(echo "$RECORDS" | awk -v d="$domain" '$2==d {print $1}')
  if [ -n "$RECORD_ID" ]; then
    cf_api PATCH "/dns_records/$RECORD_ID" \
      -d "{\"content\":\"$IP\",\"proxied\":false}" > /dev/null
    echo "    $domain → $IP (updated)"
  else
    SUBDOMAIN="${domain%%.*}"
    cf_api POST "/dns_records" \
      -d "{\"type\":\"A\",\"name\":\"$SUBDOMAIN\",\"content\":\"$IP\",\"proxied\":false,\"ttl\":1}" > /dev/null
    echo "    $domain → $IP (created)"
  fi
done

# --- Step 4: Wait for cloud-init ---
echo "==> Waiting for cloud-init (UTXO download takes 10-30 min on 4GB)..."
sleep 60
ssh-keygen -R "$IP" 2>/dev/null || true

for i in $(seq 1 60); do
  STATUS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" \
    'cat /var/log/cloud-init-chain-server.log 2>/dev/null | head -1' 2>/dev/null || true)
  if [[ "$STATUS" == CHAIN_SERVER_READY* ]]; then
    echo "    Cloud-init complete!"
    break
  fi
  echo "    Waiting... ($i/60)"
  sleep 30
done

if [[ "$STATUS" != CHAIN_SERVER_READY* ]]; then
  echo "WARNING: Cloud-init not signaled yet. Check: ssh root@$IP 'tail -30 /var/log/cloud-init-output.log'"
  echo "UTXO snapshot download may still be in progress."
fi

# --- Step 5: Verify ---
echo "==> Verifying..."
sleep 5
HEALTH=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
  'curl -sf http://localhost:23002/api/v1/health 2>/dev/null' || echo "not ready yet")
echo "    BTCPay health: $HEALTH"

BLOCKS=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
  'docker exec chain-server-bitcoind-1 bitcoin-cli -rpcuser=btcpay -rpcpassword=$(grep BTCPAY_BITCOIND_PASSWORD /opt/chain-server/.env | cut -d= -f2) getblockchaininfo 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(f\"{d[\"blocks\"]:,} blocks, {d[\"verificationprogress\"]:.1%}\")"' 2>/dev/null || echo "not synced yet")
echo "    Bitcoin: $BLOCKS"

# --- Done ---
echo ""
echo "=== Chain Server Deployed ==="
echo "  Droplet:    $DROPLET_ID"
echo "  Public IP:  $IP"
echo "  Private IP: ${PRIVATE_IP:-N/A}"
echo "  BTCPay:     http://$IP:23002 (admin setup needed)"
echo "  DNS:        pay.wopr.bot → $IP"
echo "  SSH:        ssh root@$IP / ssh deploy@$IP"
echo ""
echo "Next steps:"
echo "  1. Wait for UTXO snapshot to load (check: ssh root@$IP 'docker logs chain-server-bitcoind-1 --tail 5')"
echo "  2. Set up BTCPay admin at http://$IP:23002"
echo "  3. Create stores for each product (holyship, wopr, paperclip, nemoclaw)"
echo "  4. Update each product's .env with BTCPAY_BASE_URL=http://${PRIVATE_IP:-$IP}:23002"
echo "  5. After sync, resize droplet to s-1vcpu-2gb (\$12/mo) to save costs"
echo ""
echo "To redeploy from scratch:"
echo "  DESTROY_FIRST=true bash vps/chain-server/provision.sh"
