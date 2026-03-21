# Infrastructure Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Netdata monitoring across all 4 production droplets with custom chain sync collectors and Discord alerts.

**Architecture:** Netdata container per droplet, streaming to Netdata Cloud free tier (5 nodes). Custom shell collector on chain server queries BTC/DOGE/LTC RPC for sync metrics. Discord webhook for alerts.

**Tech Stack:** Netdata (Docker), Netdata Cloud (free), shell script collectors, DO Cloud Firewall API

---

### Task 1: Netdata Cloud Setup (Manual)

**Files:** None — browser task

- [ ] **Step 1: Sign up at app.netdata.cloud**

Create account, create space named "WOPR Infrastructure".

- [ ] **Step 2: Create a room**

Name it "Production". Note the claim token and room ID — needed for all 4 droplets.

```
NETDATA_CLAIM_TOKEN=<from cloud UI>
NETDATA_CLAIM_ROOMS=<from cloud UI>
```

- [ ] **Step 3: Record values**

Save claim token and room ID. They'll be passed as environment variables to each Netdata container.

---

### Task 2: Deploy Netdata on Chain Server (Low Resource Mode)

**Files:**
- Modify: `/opt/chain-server/docker-compose.yml` (on pay.wopr.bot)
- Create: `/opt/chain-server/netdata-collectors/chain-sync.sh` (on pay.wopr.bot)

- [ ] **Step 1: Add netdata service to chain server compose**

SSH into pay.wopr.bot and add the netdata service to docker-compose.yml:

```yaml
  netdata:
    image: netdata/netdata:stable
    container_name: netdata
    hostname: chain-server
    cap_add:
      - SYS_PTRACE
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    ports:
      - "19999:19999"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /etc/os-release:/host/etc/os-release:ro
      - netdata_config:/etc/netdata
      - netdata_lib:/var/lib/netdata
      - netdata_cache:/var/cache/netdata
      - ./netdata-collectors:/opt/netdata-collectors:ro
    environment:
      - NETDATA_CLAIM_TOKEN=${NETDATA_CLAIM_TOKEN}
      - NETDATA_CLAIM_URL=https://app.netdata.cloud
      - NETDATA_CLAIM_ROOMS=${NETDATA_CLAIM_ROOMS}
      - NETDATA_DISABLE_ML=1
      - NETDATA_DISABLE_CLOUD_DURING_AGENT_START=1
    restart: unless-stopped
```

Add to the top-level `volumes:` section:

```yaml
volumes:
  # ... existing volumes ...
  netdata_config:
  netdata_lib:
  netdata_cache:
```

Add to `/opt/chain-server/.env`:

```
NETDATA_CLAIM_TOKEN=<from cloud UI>
NETDATA_CLAIM_ROOMS=<from cloud UI>
```

- [ ] **Step 1b: Verify container names match collector expectations**

```bash
ssh root@pay.wopr.bot 'docker ps --format "{{.Names}}"'
```

Confirm these names exist (used by the collector script):
- `chain-server-bitcoind-1`
- `chain-dogecoind`
- `chain-litecoind`

If names differ, update the collector script in Task 3 accordingly.

- [ ] **Step 2: Start netdata**

```bash
ssh root@pay.wopr.bot 'cd /opt/chain-server && docker compose --env-file .env up -d netdata'
```

- [ ] **Step 3: Verify it appears in Netdata Cloud**

Check app.netdata.cloud — "chain-server" should appear in the Production room within 60 seconds.

- [ ] **Step 4: Verify local dashboard**

```bash
ssh -L 19999:localhost:19999 root@pay.wopr.bot
# Open http://localhost:19999 in browser
```

Confirm: CPU, RAM, disk, network, Docker container metrics all visible.

- [ ] **Step 5: Commit compose change to wopr-ops**

Update `~/wopr-ops/vps/chain-server/cloud-init.sh` with the netdata service for future reprovisioning.

```bash
cd ~/wopr-ops && jj describe -m "infra: add netdata to chain server compose" && jj bookmark set main -r @ && jj git push
```

---

### Task 3: Write Chain Sync Collector

**Files:**
- Create: `/opt/chain-server/netdata-collectors/chain-sync.sh` (on pay.wopr.bot)
- Create: `/opt/chain-server/netdata-collectors/chain-sync.conf` (on pay.wopr.bot)

- [ ] **Step 1: Create collector directory**

```bash
ssh root@pay.wopr.bot 'mkdir -p /opt/chain-server/netdata-collectors'
```

- [ ] **Step 2: Write the collector script**

```bash
ssh root@pay.wopr.bot 'cat > /opt/chain-server/netdata-collectors/chain-sync.sh << '\''COLLEOF'\''
#!/bin/bash
# Netdata custom collector for chain sync metrics
# Outputs in Netdata charts.d format
# Runs every 30 seconds via Netdata user plugin

source /opt/chain-server/.env 2>/dev/null

get_chain_info() {
    local container=$1 cli=$2 user=$3 pass=$4
    local info
    info=$(docker exec "$container" $cli -rpcuser="$user" -rpcpassword="$pass" getblockchaininfo 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "$info" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f\"{d.get('blocks',0)} {d.get('verificationprogress',0)} {d.get('headers',0)}\")
" 2>/dev/null || echo "0 0 0"
    else
        echo "0 0 0"
    fi
}

get_peers() {
    local container=$1 cli=$2 user=$3 pass=$4
    docker exec "$container" $cli -rpcuser="$user" -rpcpassword="$pass" getconnectioncount 2>/dev/null || echo "0"
}

# Output Netdata chart definitions (only on first run)
if [ "$1" = "init" ]; then
cat << 'CHARTS'
CHART chain.sync_progress '' 'Chain Sync Progress' 'progress' chains chain.progress line 20000 30
DIMENSION btc '' absolute 1 10000
DIMENSION doge '' absolute 1 10000
DIMENSION ltc '' absolute 1 10000

CHART chain.block_height '' 'Chain Block Height' 'blocks' chains chain.blocks line 20001 30
DIMENSION btc '' absolute 1 1
DIMENSION doge '' absolute 1 1
DIMENSION ltc '' absolute 1 1

CHART chain.peer_count '' 'Chain Peer Count' 'peers' chains chain.peers line 20002 30
DIMENSION btc '' absolute 1 1
DIMENSION doge '' absolute 1 1
DIMENSION ltc '' absolute 1 1
CHARTS
exit 0
fi

# Collect metrics
read BTC_BLOCKS BTC_PROGRESS BTC_HEADERS <<< $(get_chain_info chain-server-bitcoind-1 bitcoin-cli btcpay "${BTCPAY_BITCOIND_PASSWORD}")
read DOGE_BLOCKS DOGE_PROGRESS DOGE_HEADERS <<< $(get_chain_info chain-dogecoind dogecoin-cli doge "${DOGE_RPC_PASSWORD}")
read LTC_BLOCKS LTC_PROGRESS LTC_HEADERS <<< $(get_chain_info chain-litecoind litecoin-cli ltc "${LTC_RPC_PASSWORD}")

BTC_PEERS=$(get_peers chain-server-bitcoind-1 bitcoin-cli btcpay "${BTCPAY_BITCOIND_PASSWORD}")
DOGE_PEERS=$(get_peers chain-dogecoind dogecoin-cli doge "${DOGE_RPC_PASSWORD}")
LTC_PEERS=$(get_peers chain-litecoind litecoin-cli ltc "${LTC_RPC_PASSWORD}")

# Convert progress to integer (multiply by 10000 for 4 decimal places)
BTC_PROG_INT=$(python3 -c "print(int(float('${BTC_PROGRESS}') * 10000))" 2>/dev/null || echo 0)
DOGE_PROG_INT=$(python3 -c "print(int(float('${DOGE_PROGRESS}') * 10000))" 2>/dev/null || echo 0)
LTC_PROG_INT=$(python3 -c "print(int(float('${LTC_PROGRESS}') * 10000))" 2>/dev/null || echo 0)

# Output metrics
echo "BEGIN chain.sync_progress"
echo "SET btc = $BTC_PROG_INT"
echo "SET doge = $DOGE_PROG_INT"
echo "SET ltc = $LTC_PROG_INT"
echo "END"

echo "BEGIN chain.block_height"
echo "SET btc = ${BTC_BLOCKS:-0}"
echo "SET doge = ${DOGE_BLOCKS:-0}"
echo "SET ltc = ${LTC_BLOCKS:-0}"
echo "END"

echo "BEGIN chain.peer_count"
echo "SET btc = ${BTC_PEERS:-0}"
echo "SET doge = ${DOGE_PEERS:-0}"
echo "SET ltc = ${LTC_PEERS:-0}"
echo "END"
COLLEOF
chmod +x /opt/chain-server/netdata-collectors/chain-sync.sh'
```

- [ ] **Step 3: Configure Netdata to use the collector as a charts.d plugin**

The script uses `charts.d` protocol (CHART/DIMENSION/BEGIN/SET/END). Configure it:

```bash
ssh root@pay.wopr.bot 'docker exec netdata bash -c "
# Enable charts.d plugin
mkdir -p /etc/netdata/charts.d
cat > /etc/netdata/charts.d/chain_sync.conf << EOF
# Enable the chain sync collector
chain_sync_update_every=30
EOF

# Symlink the collector into charts.d
ln -sf /opt/netdata-collectors/chain-sync.sh /usr/libexec/netdata/charts.d/chain_sync.chart.sh

# Restart charts.d plugin
killall -HUP charts.d.plugin 2>/dev/null || true
"'
```

If `charts.d` doesn't pick it up, fall back to the `custom` plugin approach:

```bash
ssh root@pay.wopr.bot 'docker exec netdata bash -c "
mkdir -p /etc/netdata/custom-plugins.d
cat > /etc/netdata/custom-plugins.d/chain-sync.conf << EOF
[plugin:chain-sync]
command = /opt/netdata-collectors/chain-sync.sh
update every = 30
EOF
"'
```

Then restart netdata: `docker restart netdata`

- [ ] **Step 4: Verify chain metrics appear in dashboard**

Check Netdata dashboard (local or Cloud) for `chain.sync_progress`, `chain.block_height`, `chain.peer_count` charts.

- [ ] **Step 5: Copy collector to wopr-ops for version control**

```bash
cp the script content into ~/wopr-ops/vps/chain-server/netdata-collectors/chain-sync.sh
cd ~/wopr-ops && jj describe -m "infra: chain sync collector for netdata" && jj bookmark set main -r @ && jj git push
```

---

### Task 4: Deploy Netdata on Product Droplets

**Files:**
- Modify: `/opt/wopr-platform/docker-compose.yml` (on 138.68.30.247)
- Modify: `/opt/holyship/docker-compose.yml` (on 138.68.46.192)
- Modify: `/opt/nemoclaw-platform/docker-compose.yml` (on 167.172.208.149)

All 3 get the same netdata service (without low-resource mode or collectors).

**Note:** Nemoclaw was reprovisioned on 2026-03-21 at 167.172.208.149 (was 159.89.140.143). Verify IP before deploying.

- [ ] **Step 1: Write the netdata service snippet**

Same for all 3 products (only `hostname` differs):

```yaml
  netdata:
    image: netdata/netdata:stable
    container_name: netdata
    hostname: <PRODUCT_NAME>
    cap_add:
      - SYS_PTRACE
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    ports:
      - "19999:19999"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /etc/os-release:/host/etc/os-release:ro
      - netdata_config:/etc/netdata
      - netdata_lib:/var/lib/netdata
      - netdata_cache:/var/cache/netdata
    environment:
      - NETDATA_CLAIM_TOKEN=${NETDATA_CLAIM_TOKEN}
      - NETDATA_CLAIM_URL=https://app.netdata.cloud
      - NETDATA_CLAIM_ROOMS=${NETDATA_CLAIM_ROOMS}
    restart: unless-stopped
```

Also add to each compose's top-level `volumes:` section:

```yaml
volumes:
  # ... existing volumes ...
  netdata_config:
  netdata_lib:
  netdata_cache:
```

- [ ] **Step 2: Deploy to wopr-platform**

```bash
# Add NETDATA_CLAIM_TOKEN and NETDATA_CLAIM_ROOMS to .env
ssh root@138.68.30.247 'echo "NETDATA_CLAIM_TOKEN=<token>" >> /opt/wopr-platform/.env && echo "NETDATA_CLAIM_ROOMS=<room>" >> /opt/wopr-platform/.env'

# Add netdata service to compose (append before volumes: section)
# Then start:
ssh root@138.68.30.247 'cd /opt/wopr-platform && docker compose --env-file .env up -d netdata'
```

Hostname: `wopr-platform`

- [ ] **Step 3: Deploy to holyship**

```bash
ssh root@138.68.46.192 'echo "NETDATA_CLAIM_TOKEN=<token>" >> /opt/holyship/.env && echo "NETDATA_CLAIM_ROOMS=<room>" >> /opt/holyship/.env'
ssh root@138.68.46.192 'cd /opt/holyship && docker compose --env-file .env up -d netdata'
```

Hostname: `holyship`

- [ ] **Step 4: Deploy to nemoclaw**

```bash
ssh root@167.172.208.149 'echo "NETDATA_CLAIM_TOKEN=<token>" >> /opt/nemoclaw-platform/.env && echo "NETDATA_CLAIM_ROOMS=<room>" >> /opt/nemoclaw-platform/.env'
ssh root@167.172.208.149 'cd /opt/nemoclaw-platform && docker compose --env-file .env up -d netdata'
```

Hostname: `nemoclaw`

- [ ] **Step 5: Verify all 4 nodes in Netdata Cloud**

All 4 should appear in the Production room: chain-server, wopr-platform, holyship, nemoclaw.

- [ ] **Step 6: Commit**

Update compose files in wopr-ops for future reprovisioning.

```bash
cd ~/wopr-ops && jj describe -m "infra: add netdata to all product composes" && jj bookmark set main -r @ && jj git push
```

---

### Task 5: Update DO Cloud Firewall

**Files:** None — API calls

- [ ] **Step 1: List existing firewalls and find or create one**

```bash
export DO_API_TOKEN="$DO_API_TOKEN"  # set in ~/.bashrc or env

# List existing firewalls
curl -s "https://api.digitalocean.com/v2/firewalls" \
  -H "Authorization: Bearer $DO_API_TOKEN" | python3 -c "
import sys,json
for fw in json.load(sys.stdin)['firewalls']:
    print(f\"{fw['id']} {fw['name']} droplets={fw['droplet_ids']}\")
"
```

If no firewall covers all 4 droplets, create one:

```bash
curl -s -X POST "https://api.digitalocean.com/v2/firewalls" \
  -H "Authorization: Bearer $DO_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "netdata-block",
    "droplet_ids": [559531609, 559944950, <wopr-id>, <holyship-id>],
    "inbound_rules": [{
      "protocol": "tcp",
      "ports": "19999",
      "sources": {"addresses": ["<YOUR_ADMIN_IP>/32"]}
    }],
    "outbound_rules": [{
      "protocol": "tcp",
      "ports": "all",
      "destinations": {"addresses": ["0.0.0.0/0","::/0"]}
    }]
  }'
```

Replace `<YOUR_ADMIN_IP>` with your home/office IP. Get droplet IDs from `curl -s "https://api.digitalocean.com/v2/droplets" -H "Authorization: Bearer $DO_API_TOKEN" | python3 -c "import sys,json;[print(f\"{d['id']} {d['name']}\") for d in json.load(sys.stdin)['droplets']]"`

- [ ] **Step 2: Verify port 19999 is not accessible from public internet**

```bash
curl -sf http://pay.wopr.bot:19999 && echo "EXPOSED - FIX THIS" || echo "blocked (good)"
```

---

### Task 6: Configure Discord Alerts

**Files:** None — Netdata Cloud UI

- [ ] **Step 1: Create Discord webhook**

In Discord, create a `#infra-alerts` channel. Go to channel settings → Integrations → Webhooks → New Webhook. Copy the webhook URL.

- [ ] **Step 2: Add webhook to Netdata Cloud**

In Netdata Cloud: Space Settings → Notifications → Add Discord. Paste webhook URL. Set:
- Critical alerts: immediate
- Warning alerts: batched

- [ ] **Step 3: Test the alert**

Force a test alert by temporarily setting a low disk threshold or stopping a container. Verify Discord receives the notification.

- [ ] **Step 4: Configure custom chain alerts**

In Netdata Cloud or via health config on the chain server:

```bash
ssh root@pay.wopr.bot 'docker exec netdata bash -c "cat > /etc/netdata/health.d/chain-alerts.conf << EOF
alarm: chain_btc_peers_zero
on: chain.peer_count
lookup: min -5m unaligned of btc
every: 30s
warn: \$this == 0
info: Bitcoin has zero connected peers for 5+ minutes

alarm: chain_doge_peers_zero
on: chain.peer_count
lookup: min -5m unaligned of doge
every: 30s
warn: \$this == 0
info: Dogecoin has zero connected peers for 5+ minutes

alarm: chain_ltc_peers_zero
on: chain.peer_count
lookup: min -5m unaligned of ltc
every: 30s
warn: \$this == 0
info: Litecoin has zero connected peers for 5+ minutes

alarm: chain_btc_progress_stuck
on: chain.sync_progress
lookup: range -30m unaligned of btc
calc: \$this
every: 60s
crit: \$range == 0 AND \$this < 9999
info: Bitcoin sync progress unchanged for 30+ minutes and not fully synced

alarm: chain_doge_progress_stuck
on: chain.sync_progress
lookup: range -30m unaligned of doge
calc: \$this
every: 60s
crit: \$range == 0 AND \$this < 9999
info: Dogecoin sync progress unchanged for 30+ minutes and not fully synced

alarm: chain_ltc_progress_stuck
on: chain.sync_progress
lookup: range -30m unaligned of ltc
calc: \$this
every: 60s
crit: \$range == 0 AND \$this < 9999
info: Litecoin sync progress unchanged for 30+ minutes and not fully synced

alarm: crypto_key_server_down
on: httpcheck_crypto_key_server.response_time
lookup: max -1m unaligned
every: 30s
crit: \$this == nan
info: Crypto key server health endpoint not responding
EOF
"'

```

For the key server health check, also add an httpcheck config:

```bash
ssh root@pay.wopr.bot 'docker exec netdata bash -c "
mkdir -p /etc/netdata/go.d
cat > /etc/netdata/go.d/httpcheck.conf << EOF
jobs:
  - name: crypto_key_server
    url: http://chain-crypto:3100/chains
    timeout: 5
    update_every: 30
EOF
"'
```

---

### Task 7: Cleanup and Documentation

**Files:**
- Modify: `~/wopr-ops/RUNBOOK.md`
The cron job is a Claude Code session-only CronCreate (job ID c5f01d95) — it dies when the session ends. There is no persistent crontab on any server. No cleanup needed.

- [ ] **Step 1: Verify default Netdata alerts are enabled**

```bash
# Check that default alerts are active on chain server
ssh root@pay.wopr.bot 'docker exec netdata curl -s http://localhost:19999/api/v1/alarms | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f\"Active alarms: {d.get(\"active\",0)}\")
for name, alarm in list(d.get(\"alarms\",{}).items())[:10]:
    print(f\"  {name}: {alarm.get(\"status\",\"unknown\")}\")
"'
```

Confirm alerts exist for: disk_space, ram_usage, cpu_usage. These are Netdata defaults and should be active out of the box.

- [ ] **Step 2: Update RUNBOOK.md with monitoring section**

Add to RUNBOOK.md:

```markdown
### Monitoring (Netdata)

Access: https://app.netdata.cloud (WOPR Infrastructure space)

SSH tunnel fallback (if Cloud is down):
  ssh -L 19999:localhost:19999 root@pay.wopr.bot
  # Open http://localhost:19999

All 4 droplets report to Netdata Cloud:
  chain-server, wopr-platform, holyship, nemoclaw

Custom chain metrics (chain server only):
  chain.sync_progress — BTC/DOGE/LTC sync %
  chain.block_height — current block heights
  chain.peer_count — connected peers per chain

Alerts → Discord #infra-alerts
```

- [ ] **Step 3: Commit final changes**

```bash
cd ~/wopr-ops && jj describe -m "docs: monitoring runbook and final cleanup" && jj bookmark set main -r @ && jj git push
```

- [ ] **Step 4: Verify end-to-end**

Checklist:
- [ ] All 4 nodes visible in Netdata Cloud
- [ ] Chain sync progress charts working
- [ ] Discord alert fires on test
- [ ] Port 19999 blocked from public
- [ ] No cron job running
