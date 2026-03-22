#!/bin/bash
# Shared Chain Server — DigitalOcean cloud-init script
#
# Provisions a multi-chain crypto payment server for all 4 products:
#   - bitcoind (mainnet, pruned)
#   - dogecoind (mainnet, pruned)
#   - litecoind (mainnet, pruned)
#   - crypto-key-server (address derivation, charge management, watchers)
#   - postgres (charge DB, payment methods, derived addresses)
#   - 5GB swap, Docker CE + Compose
#
# All UTXO nodes use standardized RPC credentials (user: btcpay).
# Products connect via DO private networking or public IP:3100.
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
rpcpassword=${BTCPAY_BITCOIND_PASSWORD:-btcpay-chain-2026}
rpcallowip=0.0.0.0/0
rpcallowip=::/0
rpcbind=0.0.0.0
fallbackfee=0.0002
prune=5000
walletdir=/data/wallets/mainnet
wallet=watcher
printtoconsole=1
CONFEOF
chown bitcoin:bitcoin /data/bitcoin.conf /data/wallets/mainnet
exec gosu bitcoin bitcoind -datadir=/data
WRAPEOF
chmod +x /opt/chain-server/bitcoind-wrapper.sh

# --- dogecoind wrapper ---
cat > /opt/chain-server/dogecoind-wrapper.sh << 'WRAPEOF'
#!/bin/bash
set -e
cat > /home/dogecoin/.dogecoin/dogecoin.conf << CONFEOF
server=1
rpcuser=btcpay
rpcpassword=${DOGE_RPC_PASSWORD:-btcpay-chain-2026}
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
rpcport=22555
prune=2200
printtoconsole=1
maxconnections=24
txindex=0
addnode=173.212.197.63
addnode=34.50.85.108
addnode=138.201.132.34
addnode=142.132.213.251
CONFEOF
exec dogecoind -datadir=/home/dogecoin/.dogecoin -conf=/home/dogecoin/.dogecoin/dogecoin.conf
WRAPEOF
chmod +x /opt/chain-server/dogecoind-wrapper.sh

# --- litecoind wrapper ---
cat > /opt/chain-server/litecoind-wrapper.sh << 'WRAPEOF'
#!/bin/bash
set -e
mkdir -p /data/.litecoin
cat > /data/.litecoin/litecoin.conf << CONFEOF
server=1
rpcuser=btcpay
rpcpassword=${LTC_RPC_PASSWORD:-btcpay-chain-2026}
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
rpcport=9332
prune=2200
printtoconsole=1
maxconnections=24
txindex=0
CONFEOF
exec litecoind -datadir=/data/.litecoin
WRAPEOF
chmod +x /opt/chain-server/litecoind-wrapper.sh

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
      SERVICE_KEY: ${SERVICE_KEY}
      ADMIN_TOKEN: ${ADMIN_TOKEN}
      BITCOIND_PASSWORD: ${BTCPAY_BITCOIND_PASSWORD}
    ports:
      - "3100:3100"
    restart: unless-stopped

  dogecoind:
    image: blocknetdx/dogecoin:latest
    container_name: chain-dogecoind
    entrypoint: ["/opt/wrapper.sh"]
    ports:
      - "22555:22555"
    environment:
      - DOGE_RPC_PASSWORD=${DOGE_RPC_PASSWORD}
    volumes:
      - doge_data:/home/dogecoin/.dogecoin
      - ./dogecoind-wrapper.sh:/opt/wrapper.sh:ro
    restart: unless-stopped

  litecoind:
    image: uphold/litecoin-core:latest
    container_name: chain-litecoind
    entrypoint: ["/opt/wrapper.sh"]
    ports:
      - "9332:9332"
    environment:
      - LTC_RPC_PASSWORD=${LTC_RPC_PASSWORD}
    volumes:
      - ltc_data:/data
      - ./litecoind-wrapper.sh:/opt/wrapper.sh:ro
    restart: unless-stopped

volumes:
  bitcoin_data:
  postgres_data:
  doge_data:
    external: true
  ltc_data:

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
