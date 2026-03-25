#!/bin/bash
# WOPR Platform — DigitalOcean cloud-init script
#
# Provisions a production-ready VPS with:
#   - 5GB swap
#   - Docker CE + Compose plugin
#   - deploy user (SSH + Docker access)
#   - /opt/wopr-platform/ with compose stack, Caddyfile, .env
#   - Auto-pulls GHCR images and starts the stack
#
# Usage:
#   doctl compute droplet create wopr-platform \
#     --region sfo2 --size s-1vcpu-1gb --image ubuntu-24-04-x64 \
#     --ssh-keys <KEY_ID> --user-data-file vps/cloud-init.sh \
#     --tag-names wopr,platform,production
#
# After provisioning:
#   1. Get the droplet IP
#   2. Update Cloudflare DNS: wopr.bot, api.wopr.bot, app.wopr.bot → IP (proxy OFF)
#   3. Set GitHub repo secrets: PROD_HOST, PROD_SSH_KEY
#   4. Caddy auto-provisions TLS via Cloudflare DNS challenge
#
# Secrets:
#   Copy vps/.env.production to the droplet at /opt/wopr-platform/.env
#   OR fill in the heredoc below before provisioning.

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
# Resolve VERSION_CODENAME before writing — cloud-init eats $() in heredocs
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
ssh-keygen -t ed25519 -f /home/deploy/.ssh/id_ed25519 -N "" -C "deploy@wopr-platform"
chown deploy:deploy /home/deploy/.ssh/id_ed25519 /home/deploy/.ssh/id_ed25519.pub

# --- Project directory ---
mkdir -p /opt/wopr-platform/caddy
chown -R deploy:deploy /opt/wopr-platform

# --- Caddy Dockerfile (with Cloudflare DNS plugin) ---
cat > /opt/wopr-platform/caddy/Dockerfile << 'CADDYEOF'
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
CADDYEOF

# --- Caddyfile ---
cat > /opt/wopr-platform/Caddyfile << 'CADDYFILEEOF'
{
	email admin@wopr.bot
	acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
}

wopr.bot {
	reverse_proxy platform-ui:3000
}

app.wopr.bot {
	reverse_proxy platform-ui:3000
}

api.wopr.bot {
	reverse_proxy platform-api:3100
}

*.wopr.bot {
	reverse_proxy platform-api:3100
}
CADDYFILEEOF

# --- docker-compose.yml ---
cat > /opt/wopr-platform/docker-compose.yml << 'COMPOSEEOF'
services:
  postgres:
    image: postgres:16-alpine
    volumes:
      - postgres_data:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=wopr
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=wopr_platform
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U wopr"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  caddy:
    build:
      context: ./caddy
      dockerfile: Dockerfile
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
      - DOMAIN=wopr.bot
      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
    restart: unless-stopped

  platform-api:
    image: ghcr.io/wopr-network/wopr-platform:latest
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - platform_data:/data
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - DATABASE_URL=postgresql://wopr:${POSTGRES_PASSWORD}@postgres:5432/wopr_platform
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
      - POSTMARK_API_KEY=${POSTMARK_API_KEY}
      - EMAIL_FROM=noreply@wopr.bot
      - BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
      - BETTER_AUTH_URL=https://api.wopr.bot
      - UI_ORIGIN=https://wopr.bot,https://app.wopr.bot
      - PLATFORM_DOMAIN=wopr.bot
      - COOKIE_DOMAIN=.wopr.bot
      - PLATFORM_SECRET=${PLATFORM_SECRET}
      - PLATFORM_ENCRYPTION_SECRET=${PLATFORM_ENCRYPTION_SECRET}
      - WOPR_BOT_IMAGE=ghcr.io/wopr-network/wopr:latest
      - DO_API_TOKEN=${DO_API_TOKEN}
      - OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
      - TRUSTED_PROXY_IPS=${TRUSTED_PROXY_IPS:-172.16.0.0/12}
      - FLEET_API_TOKEN=${FLEET_API_TOKEN:-wopr_fleet_default}
      - REGISTRY_USERNAME=wopr-network
      - REGISTRY_PASSWORD=${GHCR_TOKEN}
      - REGISTRY_SERVER=ghcr.io
      - NODE_ENV=production
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3100/health"]
      interval: 30s
      timeout: 5s
      retries: 3
    restart: unless-stopped

  platform-ui:
    image: ghcr.io/wopr-network/wopr-platform-ui:latest
    environment:
      - NEXT_PUBLIC_API_URL=https://api.wopr.bot
      - BETTER_AUTH_URL=https://api.wopr.bot
      - NEXT_PUBLIC_APP_DOMAIN=app.wopr.bot
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
    name: wopr-platform
COMPOSEEOF

# --- .env ---
# Injected by provision.sh (replaces this marker with real values).
# If running cloud-init standalone, scp vps/.env.production to
# /opt/wopr-platform/.env before the droplet boots.
# ENV_INJECT_MARKER

chmod 600 /opt/wopr-platform/.env
chown deploy:deploy /opt/wopr-platform/.env

# --- GHCR login (images are private) ---
GHCR_TOKEN=$(grep GHCR_TOKEN /opt/wopr-platform/.env | cut -d= -f2)
if [ -n "$GHCR_TOKEN" ] && [ "$GHCR_TOKEN" != "REPLACE_ME" ]; then
  echo "$GHCR_TOKEN" | docker login ghcr.io -u wopr-network --password-stdin
  # Also set up for deploy user
  su - deploy -c "echo $GHCR_TOKEN | docker login ghcr.io -u wopr-network --password-stdin"
fi

# --- Pull images and start ---
cd /opt/wopr-platform
docker compose --env-file .env pull platform-api platform-ui postgres 2>/dev/null || true
docker compose --env-file .env up -d

# --- Signal completion ---
echo "WOPR_PLATFORM_READY $(date -Iseconds)" > /var/log/cloud-init-wopr.log
echo "Deploy SSH public key:" >> /var/log/cloud-init-wopr.log
cat /home/deploy/.ssh/id_ed25519.pub >> /var/log/cloud-init-wopr.log
