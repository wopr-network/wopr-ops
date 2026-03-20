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

# --- docker-compose.yml ---
cat > /opt/chain-server/docker-compose.yml << 'COMPOSEEOF'
services:
  postgres:
    image: postgres:16-alpine
    volumes:
      - postgres_data:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=chain
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=chain
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U chain"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  bitcoind:
    image: btcpayserver/bitcoin:30.2
    environment:
      - BITCOIN_NETWORK=${BITCOIN_NETWORK:-mainnet}
      - BITCOIN_WALLETDIR=/data/wallets
      - CREATE_WALLET=false
      - BITCOIN_EXTRA_ARGS=server=1\nrpcuser=btcpay\nrpcpassword=${BTCPAY_BITCOIND_PASSWORD}\nrpcallowip=0.0.0.0/0\nrpcbind=0.0.0.0\nfallbackfee=0.0002\nprune=5000
    volumes:
      - bitcoin_data:/data
    restart: unless-stopped

volumes:
  postgres_data:
  bitcoin_data:

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
