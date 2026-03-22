#!/bin/bash
# Paperclip Platform — DigitalOcean cloud-init script
#
# Provisions a production-ready VPS with:
#   - 5GB swap
#   - Docker CE + Compose plugin
#   - deploy user (SSH + Docker access)
#   - /opt/paperclip-platform/ with compose stack, Caddyfile, .env
#   - Auto-pulls GHCR images and starts the stack
#
# Usage:
#   cd wopr-ops && bash vps/paperclip/provision.sh

set -euo pipefail

# --- Swap (5GB) ---
fallocate -l 5G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# --- Docker ---
apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
ARCH=$(dpkg --print-architecture)
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# --- Deploy user ---
useradd -m -s /bin/bash -G docker deploy
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys

# --- Generate deploy SSH keypair (for GitHub Actions) ---
ssh-keygen -t ed25519 -f /home/deploy/.ssh/id_ed25519 -N "" -C "deploy@paperclip-platform"
chown deploy:deploy /home/deploy/.ssh/id_ed25519 /home/deploy/.ssh/id_ed25519.pub

# --- Project directory ---
mkdir -p /opt/paperclip-platform/caddy
chown -R deploy:deploy /opt/paperclip-platform

# --- Caddy Dockerfile removed ---
# Pre-built image at ghcr.io/wopr-network/paperclip-caddy:latest
# (Go compilation OOMs on 1GB droplets — build locally, push to GHCR)

# --- Caddyfile ---
cat > /opt/paperclip-platform/Caddyfile << 'CADDYFILEEOF'
{
	email admin@runpaperclip.com
	acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
}

runpaperclip.com {
	reverse_proxy platform-ui:3000
}

app.runpaperclip.com {
	reverse_proxy platform-ui:3000
}

api.runpaperclip.com {
	reverse_proxy platform-api:3200
}

*.runpaperclip.com {
	reverse_proxy platform-api:3200
}
CADDYFILEEOF

# --- docker-compose.yml ---
cat > /opt/paperclip-platform/docker-compose.yml << 'COMPOSEEOF'
services:
  postgres:
    image: postgres:16-alpine
    volumes:
      - postgres_data:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=paperclip
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=paperclip_platform
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U paperclip"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  caddy:
    image: ghcr.io/wopr-network/paperclip-caddy:latest
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      platform-api:
        condition: service_healthy
      platform-ui:
        condition: service_healthy
    environment:
      - DOMAIN=runpaperclip.com
      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
    restart: unless-stopped

  platform-api:
    image: ghcr.io/wopr-network/paperclip-platform:latest
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - platform_data:/data
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - DATABASE_URL=postgresql://paperclip:${POSTGRES_PASSWORD}@postgres:5432/paperclip_platform
      - METER_WAL_PATH=/data/meter-wal.jsonl
      - METER_DLQ_PATH=/data/meter-dlq.jsonl
      - STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY}
      - STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET}
      - STRIPE_DEFAULT_PRICE_ID=${STRIPE_DEFAULT_PRICE_ID}
      - STRIPE_CREDIT_PRICE_5=${STRIPE_CREDIT_PRICE_5}
      - STRIPE_CREDIT_PRICE_10=${STRIPE_CREDIT_PRICE_10}
      - STRIPE_CREDIT_PRICE_25=${STRIPE_CREDIT_PRICE_25}
      - STRIPE_CREDIT_PRICE_50=${STRIPE_CREDIT_PRICE_50}
      - STRIPE_CREDIT_PRICE_100=${STRIPE_CREDIT_PRICE_100}
      - RESEND_API_KEY=${RESEND_API_KEY}
      - RESEND_FROM_EMAIL=noreply@runpaperclip.com
      - BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
      - BETTER_AUTH_URL=https://api.runpaperclip.com
      - UI_ORIGIN=https://runpaperclip.com,https://app.runpaperclip.com
      - PLATFORM_DOMAIN=runpaperclip.com
      - COOKIE_DOMAIN=.runpaperclip.com
      - PLATFORM_SECRET=${PLATFORM_SECRET}
      - PLATFORM_ENCRYPTION_SECRET=${PLATFORM_ENCRYPTION_SECRET}
      - PAPERCLIP_IMAGE=ghcr.io/wopr-network/paperclip:managed
      - DO_API_TOKEN=${DO_API_TOKEN}
      - OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
      - CRYPTO_SERVICE_URL=${CRYPTO_SERVICE_URL:-http://167.71.118.221:3100}
      - TRUSTED_PROXY_IPS=${TRUSTED_PROXY_IPS:-172.16.0.0/12}
      - FLEET_API_TOKEN=${FLEET_API_TOKEN:-paperclip_fleet_default}
      - PROVISION_SECRET=${PROVISION_SECRET}
      - GATEWAY_URL=${GATEWAY_URL}
      - REGISTRY_USERNAME=wopr-network
      - REGISTRY_PASSWORD=${GHCR_TOKEN}
      - REGISTRY_SERVER=ghcr.io
      - NODE_ENV=production
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3200/health"]
      interval: 30s
      timeout: 5s
      retries: 3
    restart: unless-stopped

  platform-ui:
    image: ghcr.io/wopr-network/paperclip-platform-ui:latest
    environment:
      - NEXT_PUBLIC_API_URL=https://api.runpaperclip.com
      - BETTER_AUTH_URL=https://api.runpaperclip.com
      - NEXT_PUBLIC_APP_DOMAIN=app.runpaperclip.com
    healthcheck:
      test: ["CMD-SHELL", "node -e \"require('http').get('http://localhost:3000', (r) => process.exit(r.statusCode === 200 ? 0 : 1))\""]
      interval: 30s
      timeout: 5s
      retries: 3
    restart: unless-stopped

volumes:
  caddy_data:
  caddy_config:
  platform_data:
  postgres_data:

networks:
  default:
    name: paperclip-platform
COMPOSEEOF

# --- .env ---
# Injected by provision.sh (replaces this marker with real values).
# ENV_INJECT_MARKER

chmod 600 /opt/paperclip-platform/.env
chown deploy:deploy /opt/paperclip-platform/.env

# --- GHCR login (images are private) ---
GHCR_TOKEN=$(grep GHCR_TOKEN /opt/paperclip-platform/.env | cut -d= -f2)
if [ -n "$GHCR_TOKEN" ] && [ "$GHCR_TOKEN" != "REPLACE_ME" ]; then
  echo "$GHCR_TOKEN" | docker login ghcr.io -u wopr-network --password-stdin
  su - deploy -c "echo $GHCR_TOKEN | docker login ghcr.io -u wopr-network --password-stdin"
fi

# --- Netdata (monitoring + Discord alerts + Cloud claim) ---
docker run -d --name=netdata \
  --pid=host \
  --network=host \
  -v netdataconfig:/etc/netdata \
  -v netdatalib:/var/lib/netdata \
  -v netdatacache:/var/cache/netdata \
  -v /:/host/root:ro,rslave \
  -v /etc/passwd:/host/etc/passwd:ro \
  -v /etc/group:/host/etc/group:ro \
  -v /etc/localtime:/etc/localtime:ro \
  -v /proc:/host/proc:ro \
  -v /sys:/host/sys:ro \
  -v /etc/os-release:/host/etc/os-release:ro \
  -v /var/log:/host/var/log:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /run/dbus:/run/dbus:ro \
  --restart unless-stopped \
  --cap-add SYS_PTRACE \
  --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  -e NETDATA_CLAIM_TOKEN="$(grep NETDATA_CLAIM_TOKEN /opt/paperclip-platform/.env | cut -d= -f2)" \
  -e NETDATA_CLAIM_URL=https://app.netdata.cloud \
  -e NETDATA_CLAIM_ROOMS="$(grep NETDATA_CLAIM_ROOMS /opt/paperclip-platform/.env | cut -d= -f2)" \
  netdata/netdata:stable

# --- Pull images and start (caddy pulled separately — no build needed) ---
cd /opt/paperclip-platform
docker compose --env-file .env pull 2>/dev/null || true
docker compose --env-file .env up -d

# --- Signal completion ---
echo "PAPERCLIP_PLATFORM_READY $(date -Iseconds)" > /var/log/cloud-init-paperclip.log
echo "Deploy SSH public key:" >> /var/log/cloud-init-paperclip.log
cat /home/deploy/.ssh/id_ed25519.pub >> /var/log/cloud-init-paperclip.log
