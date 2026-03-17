#!/bin/bash
# Holy Ship — Full automated provisioning
#
# Creates a DO droplet, waits for cloud-init, updates DNS, sets GitHub secrets.
# Zero manual steps. Run and walk away.
#
# Prerequisites:
#   - DO_API_TOKEN in env or ~/.bashrc
#   - CLOUDFLARE_API_TOKEN in env or ~/.bashrc
#   - gh CLI authenticated with wopr-network org access
#   - vps/holyship/cloud-init.sh in the same directory
#   - vps/holyship/.env.production with real secrets (or edit cloud-init.sh)
#
# Usage:
#   cd wopr-ops && bash vps/holyship/provision.sh
#
# To destroy and recreate:
#   DESTROY_FIRST=true bash vps/holyship/provision.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DO_TOKEN="${DO_API_TOKEN:?Set DO_API_TOKEN}"
CF_TOKEN="${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN}"
CF_ZONE="7f8313ed0ec8e1df1072ba5b49f86880"
DROPLET_NAME="holyship"
REGION="sfo2"
SIZE="s-1vcpu-2gb"
IMAGE="ubuntu-24-04-x64"
SSH_KEY_IDS="54956840,54353584"
DOMAINS=("holyship.wtf" "api.holyship.wtf" "www.holyship.wtf")

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
  EXISTING=$(do_api GET "/droplets?tag_name=holyship" | jq -r '.droplets[] | select(.name=="'"$DROPLET_NAME"'") | .id')
  for id in $EXISTING; do
    echo "    Deleting droplet $id"
    do_api DELETE "/droplets/$id" || true
  done
  sleep 5
fi

# --- Step 1: Create droplet ---
echo "==> Creating droplet..."
ENV_FILE="${SCRIPT_DIR}/.env.production"
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.production.example and fill in secrets."
  exit 1
fi

# Inject .env.production into cloud-init (replaces the marker)
CLOUD_INIT=$(python3 -c "
import sys
ci = open('$SCRIPT_DIR/cloud-init.sh').read()
env = open('$ENV_FILE').read()
heredoc = \"cat > /opt/holyship/.env << 'ENVEOF'\n\" + env.strip() + \"\nENVEOF\"
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
    '{name:$name,region:$region,size:$size,image:$image,ssh_keys:$ssh_keys,user_data:$user_data,tags:["holyship","production"]}'
  )" | jq -r '.droplet.id')

echo "    Droplet ID: $DROPLET_ID"

# --- Step 2: Wait for IP ---
echo "==> Waiting for IP..."
for i in $(seq 1 30); do
  IP=$(do_api GET "/droplets/$DROPLET_ID" | jq -r '.droplet.networks.v4[] | select(.type=="public") | .ip_address' 2>/dev/null || true)
  if [ -n "$IP" ] && [ "$IP" != "null" ]; then
    echo "    IP: $IP"
    break
  fi
  sleep 10
done

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
    [ "$domain" = "holyship.wtf" ] && SUBDOMAIN="@"
    cf_api POST "/dns_records" \
      -d "{\"type\":\"A\",\"name\":\"$SUBDOMAIN\",\"content\":\"$IP\",\"proxied\":false,\"ttl\":1}" > /dev/null
    echo "    $domain → $IP (created)"
  fi
done

# --- Step 4: Wait for cloud-init ---
echo "==> Waiting for cloud-init (this takes 5-8 minutes)..."
sleep 30  # SSH won't be ready immediately
ssh-keygen -R "$IP" 2>/dev/null || true

for i in $(seq 1 40); do
  STATUS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" \
    'cat /var/log/cloud-init-holyship.log 2>/dev/null | head -1' 2>/dev/null || true)
  if [[ "$STATUS" == HOLYSHIP_READY* ]]; then
    echo "    Cloud-init complete!"
    break
  fi
  echo "    Waiting... ($i/40)"
  sleep 15
done

if [[ "$STATUS" != HOLYSHIP_READY* ]]; then
  echo "ERROR: Cloud-init timed out. Check: ssh root@$IP 'tail -20 /var/log/cloud-init-output.log'"
  exit 1
fi

# --- Step 5: Get deploy SSH key ---
echo "==> Extracting deploy SSH key..."
DEPLOY_KEY=$(ssh -o StrictHostKeyChecking=no root@"$IP" 'cat /home/deploy/.ssh/id_ed25519' 2>/dev/null)

# --- Step 6: Set GitHub secrets ---
echo "==> Setting GitHub secrets..."
cd "$SCRIPT_DIR/../.."

echo "$IP" | gh secret set PROD_HOST --repo wopr-network/holyship
echo "$DEPLOY_KEY" | gh secret set PROD_SSH_KEY --repo wopr-network/holyship
echo "$IP" | gh secret set PROD_HOST --repo wopr-network/holyship-platform-ui
echo "$DEPLOY_KEY" | gh secret set SSH_DEPLOY_KEY --repo wopr-network/holyship-platform-ui
echo "    Secrets set on both repos"

# --- Step 7: Verify ---
echo "==> Verifying endpoints..."
sleep 10
for domain in "${DOMAINS[@]}"; do
  CODE=$(curl -sf -o /dev/null -w "%{http_code}" "https://$domain" 2>/dev/null || echo "000")
  echo "    https://$domain → HTTP $CODE"
done

HEALTH=$(curl -sf "https://api.holyship.wtf/health" 2>/dev/null || echo "unreachable")
echo "    Health: $HEALTH"

# --- Done ---
echo ""
echo "=== Holy Ship Deployed ==="
echo "  Droplet: $DROPLET_ID ($IP)"
echo "  DNS:     holyship.wtf, api.holyship.wtf, www.holyship.wtf"
echo "  TLS:     Let's Encrypt via Caddy (DNS-01)"
echo "  SSH:     ssh root@$IP / ssh deploy@$IP"
echo ""
echo "To redeploy from scratch:"
echo "  DESTROY_FIRST=true bash vps/holyship/provision.sh"
