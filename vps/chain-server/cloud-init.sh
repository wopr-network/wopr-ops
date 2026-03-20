#!/bin/bash
# Shared Chain Server — DigitalOcean cloud-init script
#
# Provisions a dedicated blockchain node serving all 4 products:
#   - bitcoind (mainnet, pruned, assumeutxo fast-sync)
#   - nbxplorer (blockchain indexer)
#   - BTCPay Server (payment processing, multi-store)
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
mkdir -p /opt/chain-server/scripts
chown -R deploy:deploy /opt/chain-server

# --- Multi-database init script ---
cat > /opt/chain-server/scripts/create-multiple-databases.sh << 'MULTIDBEOF'
#!/bin/bash
set -e; set -u
if [ -n "${POSTGRES_MULTIPLE_DATABASES:-}" ]; then
  echo "Creating additional databases: $POSTGRES_MULTIPLE_DATABASES"
  for db in $(echo "$POSTGRES_MULTIPLE_DATABASES" | tr ',' ' '); do
    echo "  Creating database '$db'"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -c "CREATE DATABASE \"$db\" OWNER \"$POSTGRES_USER\"" 2>/dev/null || true
  done
fi
MULTIDBEOF
chmod +x /opt/chain-server/scripts/create-multiple-databases.sh

# --- docker-compose.yml ---
cat > /opt/chain-server/docker-compose.yml << 'COMPOSEEOF'
services:
  postgres:
    image: postgres:16-alpine
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./scripts/create-multiple-databases.sh:/docker-entrypoint-initdb.d/create-multiple-databases.sh:ro
    environment:
      - POSTGRES_USER=chain
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=chain
      - POSTGRES_MULTIPLE_DATABASES=nbxplorer,btcpayserver
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

  nbxplorer:
    image: nicolasdorier/nbxplorer:2.6.1
    environment:
      - NBXPLORER_NETWORK=${BITCOIN_NETWORK:-mainnet}
      - NBXPLORER_CHAINS=btc
      - NBXPLORER_BTCRPCURL=http://bitcoind:8332/
      - NBXPLORER_BTCRPCUSER=btcpay
      - NBXPLORER_BTCRPCPASSWORD=${BTCPAY_BITCOIND_PASSWORD}
      - NBXPLORER_BTCNODEENDPOINT=bitcoind:8333
      - NBXPLORER_POSTGRES=User ID=chain;Password=${POSTGRES_PASSWORD};Include Error Detail=true;Host=postgres;Port=5432;Database=nbxplorer
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
      - "23002:23002"
    environment:
      - BTCPAY_NETWORK=${BITCOIN_NETWORK:-mainnet}
      - BTCPAY_CHAINS=btc
      - BTCPAY_POSTGRES=User ID=chain;Password=${POSTGRES_PASSWORD};Include Error Detail=true;Host=postgres;Port=5432;Database=btcpayserver
      - BTCPAY_BTCEXPLORERURL=http://nbxplorer:32838/
      - BTCPAY_BIND=0.0.0.0:23002
      - BTCPAY_ALLOW-ADMIN-REGISTRATION=true
      - BTCPAY_DISABLE-REGISTRATION=false
      - BTCPAY_ROOTPATH=/
    depends_on:
      - nbxplorer
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:23002/api/v1/health || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 60s
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

# --- UTXO snapshot fast-sync ---
# Download the assumeutxo snapshot for block 867,690 (~7GB)
# This lets bitcoind sync to tip in minutes instead of days
echo "Downloading UTXO snapshot (block 867,690)..."
docker run --rm -v chain-server_bitcoin_data:/data ubuntu:24.04 bash -c "
  apt-get update -qq && apt-get install -y -qq curl > /dev/null 2>&1
  mkdir -p /data
  curl -L --progress-bar -o /data/utxo-snapshot-867690.tar \
    'https://utxo-sets.btcpayserver.org/utxo-snapshot-bitcoin-mainnet-867690.tar' || echo 'snapshot download failed (non-fatal)'
  ls -lh /data/utxo-snapshot-867690.tar 2>/dev/null || echo 'no snapshot'
"

# --- Start the stack ---
cd /opt/chain-server
docker compose --env-file .env up -d

# --- Load UTXO snapshot after bitcoind starts ---
sleep 30
if docker exec chain-server-bitcoind-1 ls /data/utxo-snapshot-867690.tar 2>/dev/null; then
  echo "Loading UTXO snapshot into bitcoind..."
  docker exec chain-server-bitcoind-1 bitcoin-cli \
    -rpcuser=btcpay -rpcpassword="${BTCPAY_BITCOIND_PASSWORD}" \
    -rpcclienttimeout=0 \
    loadtxoutset /data/utxo-snapshot-867690.tar 2>&1 || echo "loadtxoutset failed (will fall back to IBD)"
fi

# --- Signal completion ---
echo "CHAIN_SERVER_READY $(date -u +%FT%TZ)" > /var/log/cloud-init-chain-server.log
echo "Deploy SSH public key:" >> /var/log/cloud-init-chain-server.log
cat /home/deploy/.ssh/id_ed25519.pub >> /var/log/cloud-init-chain-server.log
