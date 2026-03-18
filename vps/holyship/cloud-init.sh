#!/bin/bash
# Holy Ship — DigitalOcean cloud-init script
#
# Provisions a production-ready VPS with:
#   - 5GB swap
#   - Docker CE + Compose plugin
#   - deploy user (SSH + Docker access)
#   - /opt/holyship/ with compose stack, custom Caddy (DNS-01), .env
#   - Auto-pulls GHCR images and starts the stack
#
# Usage:
#   doctl compute droplet create holyship \
#     --region sfo2 --size s-1vcpu-2gb --image ubuntu-24-04-x64 \
#     --ssh-keys <KEY_ID> --user-data-file vps/holyship/cloud-init.sh \
#     --tag-names holyship,production
#
# After provisioning:
#   1. Get the droplet IP
#   2. Update Cloudflare DNS: holyship.wtf, api.holyship.wtf, www.holyship.wtf → IP (proxy OFF)
#   3. Set GitHub repo secrets: PROD_HOST, PROD_SSH_KEY
#   4. Caddy auto-provisions TLS via Cloudflare DNS-01 challenge
#
# Secrets:
#   Copy vps/holyship/.env.production to the droplet at /opt/holyship/.env
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
ssh-keygen -t ed25519 -f /home/deploy/.ssh/id_ed25519 -N "" -C "deploy@holyship"
chown deploy:deploy /home/deploy/.ssh/id_ed25519 /home/deploy/.ssh/id_ed25519.pub

# --- Project directory ---
mkdir -p /opt/holyship/caddy /opt/holyship/scripts
chown -R deploy:deploy /opt/holyship

# --- Caddy Dockerfile (with Cloudflare DNS plugin for DNS-01 TLS) ---
cat > /opt/holyship/caddy/Dockerfile << 'CADDYEOF'
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
CADDYEOF

# --- Caddyfile ---
cat > /opt/holyship/Caddyfile << 'CADDYFILEEOF'
{
	acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
}

holyship.wtf, www.holyship.wtf {
	reverse_proxy ui:3000
}

api.holyship.wtf {
	reverse_proxy api:3001
}
CADDYFILEEOF

# --- Multi-database init script (for nbxplorer + btcpayserver) ---
cat > /opt/holyship/scripts/create-multiple-databases.sh << 'MULTIDBEOF'
#!/bin/bash
set -e; set -u
if [ -n "${POSTGRES_MULTIPLE_DATABASES:-}" ]; then
  echo "Creating additional databases: $POSTGRES_MULTIPLE_DATABASES"
  for db in $(echo "$POSTGRES_MULTIPLE_DATABASES" | tr ',' ' '); do
    echo "  Creating database '$db'"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
      SELECT 'CREATE DATABASE "$(echo "$db" | sed 's/"/""/g')" OWNER "$(echo "$POSTGRES_USER" | sed 's/"/""/g')"'
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$(echo "$db" | sed "s/'/''/g")')\gexec
EOSQL
  done
fi
MULTIDBEOF
chmod +x /opt/holyship/scripts/create-multiple-databases.sh

# --- docker-compose.yml ---
cat > /opt/holyship/docker-compose.yml << 'COMPOSEEOF'
services:
  postgres:
    image: postgres:16-alpine
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./scripts/create-multiple-databases.sh:/docker-entrypoint-initdb.d/create-multiple-databases.sh:ro
    environment:
      - POSTGRES_USER=holyship
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=holyship
      - POSTGRES_MULTIPLE_DATABASES=nbxplorer,btcpayserver
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U holyship"]
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
      api:
        condition: service_healthy
      ui:
        condition: service_healthy
    environment:
      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
    restart: unless-stopped

  api:
    image: ghcr.io/wopr-network/holyship:latest
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - holyship_data:/tmp/fleet
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - DATABASE_URL=postgresql://holyship:${POSTGRES_PASSWORD}@postgres:5432/holyship
      - PORT=3001
      - HOST=0.0.0.0
      - HOLYSHIP_ADMIN_TOKEN=${HOLYSHIP_ADMIN_TOKEN}
      - HOLYSHIP_WORKER_TOKEN=${HOLYSHIP_WORKER_TOKEN}
      - GITHUB_APP_ID=${GITHUB_APP_ID}
      - GITHUB_APP_PRIVATE_KEY=${GITHUB_APP_PRIVATE_KEY}
      - GITHUB_APP_CLIENT_ID=${GITHUB_APP_CLIENT_ID}
      - GITHUB_APP_CLIENT_SECRET=${GITHUB_APP_CLIENT_SECRET}
      - GITHUB_WEBHOOK_SECRET=${GITHUB_WEBHOOK_SECRET}
      - BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
      - BETTER_AUTH_URL=${NEXT_PUBLIC_API_URL:-https://api.holyship.wtf}
      - UI_ORIGIN=${UI_ORIGIN:-https://holyship.wtf}
      - OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
      - STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY}
      - STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET}
      - RESEND_API_KEY=${RESEND_API_KEY}
      - FROM_EMAIL=${FROM_EMAIL:-noreply@holyship.wtf}
      - HOLYSHIP_GATEWAY_KEY=${HOLYSHIP_GATEWAY_KEY}
      - HOLYSHIP_PLATFORM_SERVICE_KEY=${HOLYSHIP_PLATFORM_SERVICE_KEY:-}
      - HOLYSHIP_WORKER_IMAGE=ghcr.io/wopr-network/wopr-holyshipper-coder:latest
      - HOLYSHIP_MODEL_TIER_OVERRIDE=${HOLYSHIP_MODEL_TIER_OVERRIDE:-}
      - DOCKER_NETWORK=holyship_default
      - FLEET_DATA_DIR=/tmp/fleet
      - NODE_ENV=production
      - BTCPAY_API_KEY=${BTCPAY_API_KEY:-}
      - BTCPAY_BASE_URL=http://btcpay:23002
      - BTCPAY_STORE_ID=${BTCPAY_STORE_ID:-}
      - BTCPAY_WEBHOOK_SECRET=${BTCPAY_WEBHOOK_SECRET:-}
      - EVM_XPUB=${EVM_XPUB:-}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3001/health"]
      interval: 30s
      timeout: 5s
      retries: 3
    restart: unless-stopped

  ui:
    image: ghcr.io/wopr-network/holyship-platform-ui:latest
    depends_on:
      api:
        condition: service_healthy
    environment:
      - API_INTERNAL_URL=http://api:3001
      - NEXT_PUBLIC_API_URL=https://api.holyship.wtf
      - BETTER_AUTH_URL=https://api.holyship.wtf
      - NEXT_PUBLIC_BRAND_PRODUCT_NAME=Holy Ship
      - NEXT_PUBLIC_BRAND_DOMAIN=holyship.wtf
      - NEXT_PUBLIC_BRAND_TAGLINE=It's what you'll say when you see the results.
      - NEXT_PUBLIC_BRAND_STORAGE_PREFIX=holyship
      - NEXT_PUBLIC_BRAND_HOME_PATH=/dashboard
      - NEXT_PUBLIC_GITHUB_APP_URL=https://github.com/apps/holy-ship
    healthcheck:
      test: ["CMD-SHELL", "node -e \"require('http').get('http://localhost:3000', (r) => process.exit(r.statusCode === 200 ? 0 : 1))\""]
      interval: 30s
      timeout: 5s
      retries: 3
    restart: unless-stopped

  bitcoind:
    image: btcpayserver/bitcoin:30.2
    environment:
      - BITCOIN_NETWORK=${BITCOIN_NETWORK:-regtest}
      - BITCOIN_WALLETDIR=/data/wallets
      - BITCOIN_EXTRA_ARGS=server=1\nrpcuser=btcpay\nrpcpassword=${BTCPAY_BITCOIND_PASSWORD:-btcpay-local}\nrpcallowip=0.0.0.0/0\nrpcbind=0.0.0.0\nfallbackfee=0.0002\nprune=550
    volumes:
      - bitcoin_data:/data
    restart: unless-stopped

  nbxplorer:
    image: nicolasdorier/nbxplorer:2.6.1
    environment:
      - NBXPLORER_NETWORK=${BITCOIN_NETWORK:-regtest}
      - NBXPLORER_CHAINS=btc
      - NBXPLORER_BTCRPCURL=http://bitcoind:18443/
      - NBXPLORER_BTCRPCUSER=btcpay
      - NBXPLORER_BTCRPCPASSWORD=${BTCPAY_BITCOIND_PASSWORD:-btcpay-local}
      - NBXPLORER_BTCNODEENDPOINT=bitcoind:18444
      - NBXPLORER_POSTGRES=User ID=holyship;Password=${POSTGRES_PASSWORD};Include Error Detail=true;Host=postgres;Port=5432;Database=nbxplorer
      - NBXPLORER_AUTOMIGRATE=1
      - NBXPLORER_BIND=0.0.0.0:32838
      - NBXPLORER_NOAUTH=1
    depends_on:
      postgres:
        condition: service_healthy
      bitcoind:
        condition: service_started
    restart: unless-stopped

  btcpay:
    image: btcpayserver/btcpayserver:2.3.5
    ports:
      - "14142:23002"
    environment:
      - BTCPAY_NETWORK=${BITCOIN_NETWORK:-regtest}
      - BTCPAY_CHAINS=btc
      - BTCPAY_POSTGRES=User ID=holyship;Password=${POSTGRES_PASSWORD};Include Error Detail=true;Host=postgres;Port=5432;Database=btcpayserver
      - BTCPAY_BTCEXPLORERURL=http://nbxplorer:32838/
      - BTCPAY_BIND=0.0.0.0:23002
      - BTCPAY_ALLOW-ADMIN-REGISTRATION=true
      - BTCPAY_DISABLE-REGISTRATION=false
    depends_on:
      - nbxplorer
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:23002/api/v1/health || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 30s
    restart: unless-stopped

volumes:
  caddy_data:
  caddy_config:
  holyship_data:
  postgres_data:
  bitcoin_data:

networks:
  default:
    name: holyship
COMPOSEEOF

# --- .env ---
# Injected by provision.sh (replaces this marker with real values).
# If running cloud-init standalone, scp vps/holyship/.env.production to
# /opt/holyship/.env before the droplet boots.
# ENV_INJECT_MARKER

chmod 600 /opt/holyship/.env
chown deploy:deploy /opt/holyship/.env

# --- GHCR login (images are private) ---
GHCR_USER=$(grep REGISTRY_USERNAME /opt/holyship/.env | cut -d= -f2)
GHCR_TOKEN=$(grep REGISTRY_PASSWORD /opt/holyship/.env | cut -d= -f2)
if [ -n "$GHCR_TOKEN" ] && [ "$GHCR_TOKEN" != "REPLACE_ME" ]; then
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
  # Also set up for deploy user
  su - deploy -c "echo $GHCR_TOKEN | docker login ghcr.io -u $GHCR_USER --password-stdin"
fi

# --- Pull images and start ---
cd /opt/holyship
docker compose --env-file .env pull api ui postgres 2>/dev/null || true
docker compose --env-file .env up -d

# --- Signal completion ---
echo "HOLYSHIP_READY $(date -u +%FT%TZ)" > /var/log/cloud-init-holyship.log
echo "Deploy SSH public key:" >> /var/log/cloud-init-holyship.log
cat /home/deploy/.ssh/id_ed25519.pub >> /var/log/cloud-init-holyship.log
