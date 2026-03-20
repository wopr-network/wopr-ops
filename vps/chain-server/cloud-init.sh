#!/bin/bash
# Shared Chain Server — DigitalOcean cloud-init script
#
# Provisions a dedicated Bitcoin node serving all 4 products:
#   - bitcoind (mainnet, pruned)
#   - 5GB swap, Docker CE + Compose
#
# Products connect via DO private networking:
#   holyship, wopr-platform, paperclip-platform, nemoclaw-platform
#
# Usage:
#   cd wopr-ops && bash vps/chain-server/provision.sh

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

# --- Generate deploy SSH keypair ---
ssh-keygen -t ed25519 -f /home/deploy/.ssh/id_ed25519 -N "" -C "deploy@chain-server"
chown deploy:deploy /home/deploy/.ssh/id_ed25519 /home/deploy/.ssh/id_ed25519.pub

# --- Project directory ---
mkdir -p /opt/chain-server
chown -R deploy:deploy /opt/chain-server

# --- bitcoind wrapper (bypasses broken BTCPay entrypoint for mainnet) ---
cat > /opt/chain-server/bitcoind-wrapper.sh << 'WRAPEOF'
#!/bin/bash
set -e
mkdir -p /data/wallets/mainnet
cat > /data/bitcoin.conf << CONFEOF
[main]
server=1
rpcuser=btcpay
rpcpassword=${BTCPAY_BITCOIND_PASSWORD:-changeme}
rpcallowip=0.0.0.0/0
rpcallowip=::/0
rpcbind=0.0.0.0
fallbackfee=0.0002
prune=5000
walletdir=/data/wallets/mainnet
printtoconsole=1
CONFEOF
chown bitcoin:bitcoin /data/bitcoin.conf /data/wallets/mainnet
exec gosu bitcoin bitcoind -datadir=/data
WRAPEOF
chmod +x /opt/chain-server/bitcoind-wrapper.sh

# --- docker-compose.yml ---
cat > /opt/chain-server/docker-compose.yml << 'COMPOSEEOF'
services:
  bitcoind:
    image: btcpayserver/bitcoin:30.2
    entrypoint: ["/opt/wrapper.sh"]
    ports:
      - "8332:8332"
    environment:
      - BTCPAY_BITCOIND_PASSWORD=${BTCPAY_BITCOIND_PASSWORD}
    volumes:
      - bitcoin_data:/data
      - ./bitcoind-wrapper.sh:/opt/wrapper.sh:ro
    restart: unless-stopped

  postgres:
    image: postgres:16-alpine
    container_name: chain-postgres
    volumes:
      - postgres_data:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: platform
      POSTGRES_PASSWORD: ${PLATFORM_DB_PASSWORD}
      POSTGRES_DB: crypto_key_server
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U platform"]
      interval: 5s
      timeout: 3s
      retries: 5
    restart: unless-stopped

  crypto:
    image: ${CRYPTO_IMAGE:-ghcr.io/wopr-network/crypto-key-server:latest}
    container_name: chain-crypto
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql://platform:${PLATFORM_DB_PASSWORD}@postgres:5432/crypto_key_server
      PORT: "3100"
      ADMIN_TOKEN: ${ADMIN_TOKEN}
    ports:
      - "3100:3100"
    restart: unless-stopped

volumes:
  bitcoin_data:
  postgres_data:

networks:
  default:
    name: chain-server
COMPOSEEOF

# --- .env ---
# ENV_INJECT_MARKER

chmod 600 /opt/chain-server/.env
chown deploy:deploy /opt/chain-server/.env

# --- Start the stack ---
cd /opt/chain-server
docker compose --env-file .env up -d

# --- Signal completion ---
echo "CHAIN_SERVER_READY $(date -u +%FT%TZ)" > /var/log/cloud-init-chain-server.log
echo "Deploy SSH public key:" >> /var/log/cloud-init-chain-server.log
cat /home/deploy/.ssh/id_ed25519.pub >> /var/log/cloud-init-chain-server.log
