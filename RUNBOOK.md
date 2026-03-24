# WOPR Production Runbook

> Updated by the DevOps agent after every operation. Never edit manually outside of agent sessions.

## Current State

**Status:** PRODUCTION — all 4 products live. Chain server: BTC synced (snapshot chainstate, bg validation removed), LTC synced (migrated to main disk), DOGE syncing (~9%, on external volume). Disk 60%.
**Last Updated:** 2026-03-23
**Last Operation:** Chain server resize + LTC migration + disk cleanup (95%→60%). DOGE moved to external volume to sync.

## 2026-03-22 — Holy Ship E2E: Marketing Site + OAuth + Pipeline Dashboard

### What shipped (15 PRs + server fixes)

**holyship-ui PRs:** #26-#39 (OAuth fixes, marketing site, dashboard, rename, pipeline ordering)
**holyship engine PR:** #249 (GET /api/flows endpoint)
**platform-ui-core PRs:** #52-#53 (shorthand hex color fix)

### Deploy (pull latest + restart)

```bash
# Engine (API)
cd /home/tsavo/wopr-ops/local/holyship
docker compose pull api && docker compose up -d api

# UI (after new image build via GitHub Actions docker.yml)
docker compose pull ui && docker compose up -d ui

# Full stack
docker compose pull && docker compose up -d
```

### Auth troubleshooting

**"State not found undefined" on OAuth callback:**
- `COOKIE_DOMAIN=.holyship.wtf` must be set on the API container
- The leading dot is required for subdomain cookie sharing between `api.holyship.wtf` and `holyship.wtf`
- After changing compose env, must `docker compose up -d --force-recreate` (restart doesn't re-read compose)

**"Provider did not return email" after GitHub OAuth:**
- GitHub App must have Email addresses permission set to Read-only
- Configure at: Settings → Developer Settings → GitHub Apps → Holy Ship → Permissions → Account permissions → Email addresses → Read-only
- Requires passkey/2FA to enter sudo mode in GitHub settings

**Login redirects back to /login instead of /dashboard:**
- `BETTER_AUTH_URL` on API must point to the API origin (`https://api.holyship.wtf`), not UI
- Auth client in UI must explicitly set `baseURL` to the API origin — `NEXT_PUBLIC_API_URL` is baked at build time, not at runtime from node_modules
- Session cookie domain must cover both UI and API subdomains

**Dashboard shows "OFFLINE" status:**
- WebSocket URL not configured — set `NEXT_PUBLIC_HOLYSHIP_WS_URL=wss://api.holyship.wtf` as build arg
- REST polling works as fallback (10s interval), so data still loads

### Key env vars (UI container)

| Var | Where | Purpose |
|-----|-------|---------|
| `HOLYSHIP_API_URL` | runtime env | Server-side API calls (container-to-container: `http://api:3001`) |
| `HOLYSHIP_API_TOKEN` | runtime env | Worker token for engine auth (same as `HOLYSHIP_WORKER_TOKEN`) |
| `API_INTERNAL_URL` | runtime env | Internal API URL for SSR |
| `NEXT_PUBLIC_API_URL` | build arg | Client-side API calls (public: `https://api.holyship.wtf`) |
| `NEXT_PUBLIC_HOLYSHIP_WS_URL` | build arg | WebSocket URL for live updates |
| `NEXT_PUBLIC_GITHUB_APP_URL` | build arg | GitHub App install URL |
| `NEXT_PUBLIC_BRAND_HOME_PATH` | build arg | Post-login redirect (`/dashboard`) |

### Key env vars (API container)

| Var | Where | Purpose |
|-----|-------|---------|
| `COOKIE_DOMAIN` | runtime env | `.holyship.wtf` — session cookies shared across subdomains |
| `BETTER_AUTH_URL` | runtime env | OAuth callback base URL (`https://api.holyship.wtf`) |
| `UI_ORIGIN` | runtime env | CORS origin + OAuth redirect target (`https://holyship.wtf`) |
| `HOLYSHIP_WORKER_TOKEN` | runtime env | Bearer token for engine REST API (claim, report, entities, flows) |
| `HOLYSHIP_ADMIN_TOKEN` | runtime env | Admin API auth (flow management, admin routes) |

### Routes

| URL | What |
|-----|------|
| `holyship.wtf` | Landing page (marketing) |
| `holyship.wtf/how-it-works` | Marketing: How It Works |
| `holyship.wtf/the-real-cost` | Marketing: The Real Cost |
| `holyship.wtf/the-learning-loop` | Marketing: The Learning Loop |
| `holyship.wtf/vibe-coding-vs-engineering` | Marketing: Vibe vs Engineering |
| `holyship.wtf/pricing` | Marketing: Pricing (free) |
| `holyship.wtf/login` | GitHub OAuth login |
| `holyship.wtf/dashboard` | Pipeline board (main authenticated route) |
| `holyship.wtf/workers` | Worker pool status (detection & dispatch) |
| `api.holyship.wtf/api/status` | Engine status (flow counts, active invocations) |
| `api.holyship.wtf/api/flows` | Flow definitions with states + transitions |
| `api.holyship.wtf/api/entities` | Entity listing (query by flow/state) |
| `api.holyship.wtf/api/claim` | Worker claim endpoint |

---

## 2026-03-22 — Paperclip Platform Production Deploy

### What shipped

- **DO droplet provisioned** — `paperclip-platform`, s-1vcpu-1gb, sfo2, 68.183.160.201
- **DNS configured** — runpaperclip.com + app.runpaperclip.com + api.runpaperclip.com + *.runpaperclip.com → 68.183.160.201 (Cloudflare zone c2ac899c5e55d3ac150197a18effadf2, proxy OFF)
- **TLS provisioned** — Let's Encrypt via pre-built Caddy + Cloudflare DNS-01 challenge
- **Full stack running** — Postgres, platform-api (3200), platform-ui (3000), Caddy (TLS), Netdata
- **Instance provisioning working** — Dashboard creates instances, tenant containers spawn on paperclip-platform network
- **Subdomain cookie auth** — BETTER_AUTH_SECRET shared between platform and instances, COOKIE_DOMAIN=.runpaperclip.com

### Stack location

- Droplet: `root@68.183.160.201`
- Compose: `/opt/paperclip-platform/docker-compose.yml`
- Env: `/opt/paperclip-platform/.env`

### SSH access

```bash
ssh root@68.183.160.201
```

### Deploy (pull latest + restart)

```bash
ssh root@68.183.160.201 'cd /opt/paperclip-platform && docker compose pull && docker compose up -d'
```

### Create instances

Instances are created via the dashboard at https://app.runpaperclip.com or via tRPC. The platform's FleetManager pulls `PAPERCLIP_IMAGE` and starts a container on the `FLEET_DOCKER_NETWORK`.

### Manual provision (if health check times out)

First boot runs 29 Drizzle migrations, which can exceed the health check window (30 retries x 2s = 60s). If the instance comes up but the platform marks it unhealthy:

```bash
# Get the instance name from the dashboard or docker ps
docker ps --filter "name=wopr-" --format '{{.Names}}'

# Manually trigger provisioning
curl -X POST http://wopr-<name>:3200/internal/provision \
  -H "Authorization: Bearer $PROVISION_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"gatewayUrl": "https://api.runpaperclip.com/v1"}'
```

The `PROVISION_SECRET` value is in `/opt/paperclip-platform/.env`.

### Docker socket permissions

The platform-api container needs Docker socket access to spawn tenant containers. Default socket permissions (660, root:docker) block access from inside the container. A systemd oneshot service fixes this persistently:

```bash
# Already installed via cloud-init. To verify:
systemctl status docker-socket-perms.service

# The service runs: chmod 666 /var/run/docker.sock
# It fires after docker.service on every boot
```

If socket permissions break (container logs show EACCES on /var/run/docker.sock):

```bash
chmod 666 /var/run/docker.sock
```

### Stale fleet profiles

If instances fail to provision due to stale fleet state:

```bash
ssh root@68.183.160.201 'rm /data/fleet/*.yaml'
ssh root@68.183.160.201 'cd /opt/paperclip-platform && docker compose restart platform-api'
```

### Wildcard DNS

All `*.runpaperclip.com` subdomains resolve to 68.183.160.201 via Cloudflare wildcard A record (zone c2ac899c5e55d3ac150197a18effadf2). Tenant subdomains (e.g., `my-bot.runpaperclip.com`) are routed by Caddy to platform-api, which proxies to the matching tenant container.

### Health check URLs

- https://api.runpaperclip.com/health
- https://app.runpaperclip.com
- https://runpaperclip.com

### Key env vars (on droplet in /opt/paperclip-platform/.env)

| Var | Purpose |
|-----|---------|
| `FLEET_DOCKER_NETWORK` | Network tenant containers join (must match compose network name) |
| `COOKIE_DOMAIN` | `.runpaperclip.com` — session cookies shared across subdomains |
| `PAPERCLIP_IMAGE` | `ghcr.io/wopr-network/paperclip:managed` — tenant container image |
| `PROVISION_SECRET` | Bearer token for `/internal/provision` on tenant containers |
| `BETTER_AUTH_SECRET` | Shared between platform + instances for cookie auth |
| `GATEWAY_URL` | Inference gateway URL passed to tenant containers |
| `OPENROUTER_API_KEY` | Upstream LLM provider |
| `CLOUDFLARE_API_TOKEN` | DNS-01 TLS challenge for Caddy |
| `STRIPE_SECRET_KEY` | Payment processing (test-mode) |
| `GHCR_TOKEN` | GitHub Container Registry pull auth |
| `TRUSTED_PROXY_IPS` | CIDR for hosted_proxy mode (`172.16.0.0/12`) |

### Gotchas

- **Pre-built Caddy image required** — Go compilation OOMs on 1GB droplets. Use `ghcr.io/wopr-network/paperclip-caddy:latest` (built locally with xcaddy + caddy-dns/cloudflare, pushed to GHCR).
- **Docker socket permissions** — `docker-socket-perms.service` runs `chmod 666 /var/run/docker.sock` after Docker starts. Without it, platform-api can't spawn containers.
- **Health check timeout on first boot** — Instance containers run 29 Drizzle migrations on first start. The 60s health check window (30x2s) can be tight. Use manual `/internal/provision` if it times out.
- **Provision routes are at /internal** — must be wired in app.ts manually, not auto-discovered by the router.
- **COOKIE_DOMAIN must include leading dot** — `.runpaperclip.com` (not `runpaperclip.com`) for subdomain sharing.
- **FLEET_DOCKER_NETWORK must match compose network** — if compose creates `paperclip-platform` as the default network, that's what this var must be.
- **Stale fleet profiles** — `/data/fleet/*.yaml` files can get stale after failed provisions. Delete them and restart platform-api.

---

## 2026-03-21 — Crypto Key Server + DOGE Node Deployment

### What shipped
- **platform-core v1.44.0** — BTCPay completely removed. Crypto key server routes, CryptoServiceClient, watcher service, Chainlink oracle, webhook outbox, partial payments, native amount tracking.
- **All 4 products bumped to v1.44.0** — wopr-platform, holyship, paperclip-platform, nemoclaw-platform. BTCPayClient → CryptoServiceClient across all products.
- **DOGE node syncing** — temp droplet downloading GitHub blockchain snapshot (Blockchains-Download/Dogecoin, Dec 2025), will export pruned volume to GHCR.

### Chain Server Operations

```bash
# SSH to chain server (use direct IP — DNS slow under CPU load)
ssh root@167.71.118.221

# Check crypto key server
curl http://167.71.118.221:3100/chains

# Check bitcoind sync
ssh root@167.71.118.221 'docker exec chain-server-bitcoind-1 bitcoin-cli -rpcuser=btcpay -rpcpassword=btcpay-chain-2026 getblockchaininfo'

# Check dogecoind (all nodes use rpcuser=btcpay, standardized 2026-03-22)
ssh root@167.71.118.221 'docker exec chain-dogecoind dogecoin-cli -rpcuser=btcpay -rpcpassword=btcpay-chain-2026 getblockchaininfo'

# Check litecoind
ssh root@167.71.118.221 'docker exec chain-litecoind litecoin-cli -rpcuser=btcpay -rpcpassword=btcpay-chain-2026 getblockchaininfo'

# Check all 3 chains at once
ssh root@167.71.118.221 'for c in "chain-server-bitcoind-1 bitcoin-cli" "chain-dogecoind dogecoin-cli" "chain-litecoind litecoin-cli"; do set -- $c; echo "=== $1 ==="; docker exec $@ -rpcuser=btcpay -rpcpassword=btcpay-chain-2026 getblockchaininfo 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(f\"blocks={d[\"blocks\"]} progress={d[\"verificationprogress\"]:.4f} pruned={d[\"pruned\"]} conn={d.get(\"connections\",0)}\")" 2>/dev/null || echo "not ready"; done'

# Deploy new key server image (after PR merge → GHCR build)
ssh root@167.71.118.221 'docker pull ghcr.io/wopr-network/crypto-key-server:latest && cd /opt/chain-server && docker compose up -d crypto'

# Restart crypto key server (without pulling new image)
ssh root@167.71.118.221 'cd /opt/chain-server && docker compose restart crypto'

# Restart all chain services
ssh root@167.71.118.221 'cd /opt/chain-server && docker compose --env-file .env up -d'

# View webhook delivery failures
ssh root@167.71.118.221 'docker exec chain-postgres psql -U platform crypto_key_server -c "SELECT charge_id, status, attempts, last_error FROM webhook_deliveries WHERE status = '\''failed'\''"'

# Check payment methods and derivation state
ssh root@167.71.118.221 'docker exec chain-postgres psql -U platform crypto_key_server -c "SELECT id, chain, address_type, next_index FROM payment_methods ORDER BY id"'

# Re-add DOGE peers (drop after restart — hostnames don't resolve in container)
ssh root@167.71.118.221 'for ip in 173.212.197.63 34.50.85.108 138.201.132.34 142.132.213.251; do docker exec chain-dogecoind dogecoin-cli -rpcuser=btcpay -rpcpassword=btcpay-chain-2026 addnode "$ip" "onetry"; done'

# Fix DNS on chain server (reverts after reboot)
ssh root@167.71.118.221 'echo "nameserver 1.1.1.1" > /etc/resolv.conf; echo "nameserver 8.8.8.8" >> /etc/resolv.conf'
```

### LTC Sync Volume (temporary)

```bash
# LTC syncs on attached DO block storage volume (100GB, $10/mo)
# Mounted at /mnt/ltc_sync on chain server
# After LTC fully synced + pruned (~3GB):

# 1. Stop litecoind
ssh root@pay.wopr.bot 'docker stop chain-litecoind && docker rm chain-litecoind'

# 2. Create Docker volume and copy pruned data
ssh root@pay.wopr.bot 'docker volume create ltc_data && cp -a /mnt/ltc_sync/.litecoin/* /var/lib/docker/volumes/ltc_data/_data/'

# 3. Update compose: change /mnt/ltc_sync to ltc_data volume, restart
# 4. Verify litecoind loads and syncs
# 5. Detach and delete volume via DO API to stop $10/mo charge
```

### DOGE GHCR Backup (disaster recovery)

```bash
# Block files backed up at ghcr.io/wopr-network/doge-chaindata:latest
# NOTE: Only blocks/ are useful — chainstate has per-instance obfuscation keys
# To restore blocks from backup:
docker pull ghcr.io/wopr-network/doge-chaindata:latest
docker create --name doge-tmp ghcr.io/wopr-network/doge-chaindata:latest ""
docker export doge-tmp | tar x -C /var/lib/docker/volumes/doge_data/_data/ --strip-components=1 chaindata
docker rm doge-tmp && docker rmi ghcr.io/wopr-network/doge-chaindata:latest
# dogecoind will rebuild chainstate from blocks (~hours)
```

### Gotchas
- DOGE/LTC minimum prune is **2200 MB** (not 2048 like BTC)
- **Never** use `-reindex` with prune — destroys existing block files
- **LevelDB chainstate doesn't survive across containers** — obfuscation key is per-instance. Only back up blocks/.
- `blocknetdx/dogecoin` injects `-txindex=1` by default — use wrapper entrypoint to override
- `uphold/litecoin-core` is clean — no default flag issues, DNS works
- DOGE hostnames don't resolve inside Docker — use IP addresses for `addnode`
- `FROM scratch` images need dummy command: `docker create --name x image ""`
- DO can't resize disk independently — use block storage volumes ($0.10/GB/mo)
- Chain server DNS reverts to broken systemd-resolved on reboot — fix in cloud-init

### Key env vars (chain server /opt/chain-server/.env)
| Var | Purpose |
|-----|---------|
| `BTCPAY_BITCOIND_PASSWORD` | bitcoind RPC auth (`btcpay-chain-2026`) |
| `PLATFORM_DB_PASSWORD` | postgres for crypto_key_server DB |
| `SERVICE_KEY` | product auth for key server |
| `ADMIN_TOKEN` | admin route auth for key server |
| `DOGE_RPC_PASSWORD` | dogecoind RPC auth (`doge-chain-2026`) |
| `LTC_RPC_PASSWORD` | litecoind RPC auth (`ltc-chain-2026`) |

---

## Monitoring (Netdata)

### Access

- **Dashboard:** https://app.netdata.cloud (WOPR Infrastructure space, Production room)
- **SSH tunnel fallback:** `ssh -L 19999:localhost:19999 root@<IP>` then http://localhost:19999

### Nodes

| Node | IP | Containers |
|------|-----|------------|
| chain-server | 167.71.118.221 (pay.wopr.bot) | btc, doge, ltc, postgres, crypto, netdata |
| wopr-platform | 138.68.30.247 | api, ui, caddy, postgres, netdata |
| holyship | 138.68.46.192 | api, ui, caddy, postgres, netdata |
| nemoclaw | 167.172.208.149 | api, ui, caddy, postgres, netdata |
| paperclip-platform | 68.183.160.201 (runpaperclip.com) | api, ui, caddy, postgres, netdata + tenant containers |

### Netdata Compose (all nodes)

Each node runs Netdata from `/tmp/netdata-compose.yml` with `network_mode: host`, Docker socket access, and Netdata Cloud claim token. Started independently from the product compose.

```bash
# Restart netdata on any node
ssh root@<IP> 'docker restart netdata'

# Check netdata health
ssh root@<IP> 'docker logs netdata --tail 5'
```

### Custom Chain Metrics (chain server only)

**Systemd service:** `chain-monitor.service` on host, pushes to Netdata statsd (UDP 8125).
**Script:** `/opt/chain-server/chain-monitor.sh`
**State file:** `/opt/chain-server/.chain-monitor-state` (persists across restarts)
**Statsd config:** `/etc/netdata/statsd.d/chain.conf` (inside netdata container)

Charts:
- `chain_btc_sync` — BTC blocks vs headers (2 lines)
- `chain_ltc_sync` — LTC blocks vs headers (2 lines)
- `chain_doge_sync` — DOGE blocks vs headers (2 lines)
- `chain_progress` — all chains sync % + BTC validation (4 lines)
- `chain_btc_validation` — BTC background IBD progress vs target (2 lines)
- `chain_eta` — estimated time to sync in minutes (3 lines)
- `chain_sync_rate` — blocks/sec for LTC and DOGE (2 lines)

```bash
# Restart chain monitor
ssh root@pay.wopr.bot 'systemctl restart chain-monitor'

# Check state
ssh root@pay.wopr.bot 'cat /opt/chain-server/.chain-monitor-state'

# Update statsd config (edit locally, scp, restart)
scp /tmp/chain.conf root@pay.wopr.bot:/tmp/chain.conf
ssh root@pay.wopr.bot 'docker cp /tmp/chain.conf netdata:/etc/netdata/statsd.d/chain.conf && docker restart netdata'
```

### Gotchas
- Netdata runs with `network_mode: host` — no port mapping, listens on host 19999
- Chain monitor parses `docker logs --tail 200 | grep UpdateTip` — no RPC (too slow under load)
- BTC logs include `[background validation] UpdateTip` lines — must `grep -v "background validation"` to get tip blocks
- ETA uses exponential moving average (alpha=0.1) with spike filter (>5x EMA discarded)
- State file persists EMA rates across restarts — delete it to reset smoothing
- `docker restart netdata` wipes in-memory statsd — charts refill within 10 seconds from monitor
- Wiping `/var/cache/netdata/dbengine/` resets ALL historical data — use with caution

### Nemoclaw Resize (2026-03-21)

Reprovisioned nemoclaw from s-2vcpu-4gb ($24/mo) to s-1vcpu-1gb ($6/mo). Old droplet 159.89.140.143 destroyed. New droplet 167.172.208.149. BTCPay/bitcoind/nbxplorer removed. DNS updated. Savings: $18/mo.

### Holyship BTCPay Cleanup (2026-03-21)

Removed bitcoind + btcpay + nbxplorer from holyship compose. Was using 406MB RAM and 13% CPU on a 1GB box. Now 5 containers (api, ui, caddy, postgres, netdata).

---

## 2026-03-18 — NemoClaw Platform Production

### What shipped
- Stripe webhook → credit grant working (fixed null `session.customer` bug in platform-core v1.42.2)
- Inference gateway: `GATEWAY_URL=https://api.nemopod.com/v1` + `OPENROUTER_API_KEY` — provisioned NemoClaw containers route through platform for per-tenant metered billing
- Per-tenant gateway service keys auto-provisioned at container creation
- Domain: all `runnemo.com` references replaced with `nemopod.com` (we own nemopod.com)
- DNS wildcard `*.nemopod.com → 159.89.140.143` added to Cloudflare
- Deploy SSH key provisioned for nemoclaw-platform-ui → droplet
- CI green on both repos; auto-deploy wired (CI pass → SSH → docker compose pull + up)
- E2E Playwright test for checkout flow (skipped in CI, `RUN_E2E=1` to run locally)

### Stack location
- Droplet: `deploy@159.89.140.143`
- Compose: `/opt/nemoclaw-platform/docker-compose.yml`

### SSH access
```bash
ssh deploy@159.89.140.143
```

### Compose operations
```bash
# Restart all
ssh deploy@159.89.140.143 "cd /opt/nemoclaw-platform && docker compose up -d"

# Pull latest and restart
ssh deploy@159.89.140.143 "cd /opt/nemoclaw-platform && docker compose pull && docker compose up -d"

# Check health
ssh deploy@159.89.140.143 "cd /opt/nemoclaw-platform && docker compose ps"
```

### Health check URLs
- https://api.nemopod.com/health
- https://app.nemopod.com
- https://nemopod.com

### E2E Stripe webhook test (run locally)
```bash
cd ~/nemoclaw-platform
STRIPE_WEBHOOK_SECRET=<from .env> RUN_E2E=1 npx vitest run src/routes/stripe-webhook.e2e.test.ts
```

### Key env vars (on droplet in /opt/nemoclaw-platform/.env)
| Var | Value |
|-----|-------|
| `PLATFORM_DOMAIN` | `nemopod.com` |
| `GATEWAY_URL` | `https://api.nemopod.com/v1` |
| `BETTER_AUTH_URL` | `https://api.nemopod.com` |
| `UI_ORIGIN` | `https://nemopod.com,https://app.nemopod.com` |
| `PLATFORM_UI_URL` | `https://app.nemopod.com` |
| `OPENROUTER_API_KEY` | set |
| `STRIPE_SECRET_KEY` | set (test-mode) |
| `STRIPE_WEBHOOK_SECRET` | set (test-mode) |

### Gotchas
- E2E test requires `RUN_E2E=1` — skipped in CI (no SSH access to prod from runner)
- Tenant subdomain proxy: any `*.nemopod.com` request routes to the matching container
- Per-tenant gateway keys created automatically at fleet provision time — no manual step

## 2026-03-17 — WOPR Platform Production Launch

### What shipped

- **DO droplet provisioned** — `wopr-platform`, s-1vcpu-1gb, sfo2, 206.189.173.166
- **DNS configured** — wopr.bot + api.wopr.bot + app.wopr.bot → 206.189.173.166 (Cloudflare, proxy OFF)
- **TLS provisioned** — Let's Encrypt via Caddy + Cloudflare DNS-01 challenge
- **Full stack running** — Postgres (healthy), platform-api (healthy), platform-ui (healthy), Caddy (TLS)
- **Dockerfile fixes** — npm→pnpm, alpine→bookworm-slim (both repos)
- **BetterAuth init fix** — `initBetterAuth()` must be called before `getEmailVerifier()` (platform-core v1.39 requirement)
- **Missing env vars** — PLATFORM_SECRET, PLATFORM_ENCRYPTION_SECRET, STRIPE_CREDIT_PRICE_*, DO_API_TOKEN added to docker-compose.yml
- **Deploy workflow fix** — platform-ui deploy now uses shared compose at /opt/wopr-platform/ instead of standalone /opt/wopr-platform-ui/
- **Cloud-init script** — `wopr-ops/vps/cloud-init.sh` for reproducible droplet provisioning
- **GitHub secrets configured** — PROD_HOST, PROD_SSH_KEY (wopr-platform); STAGING_HOST, SSH_DEPLOY_KEY, SSH_DEPLOY_USER, STAGING_API_URL (wopr-platform-ui)
- **GHCR auth** — deploy user on droplet logged into ghcr.io for image pulls

### Verification

```
https://wopr.bot         → 200 OK
https://api.wopr.bot/health → {"status":"ok","service":"wopr-platform"}
https://app.wopr.bot     → 200 OK
```

### SSH access

```bash
ssh root@206.189.173.166      # admin
ssh deploy@206.189.173.166    # deploy user (used by GitHub Actions)
```

### Compose stack location

`/opt/wopr-platform/` — docker-compose.yml, Caddyfile, caddy/Dockerfile, .env

## 2026-03-16 — Holy Ship: Platform-Core Integration + OpenCode SDK + Gateway

### What shipped

- **Platform-core integration** — holyship is now a thin shell on `@wopr-network/platform-core`. Deleted 14,146 lines of standalone infrastructure (MCP server, CLI, config, seed, ingestion, hono-server, winston logger). Boot follows paperclip-platform pattern: DB → migrations → auth → credits → gateway → tRPC → engine → serve().
- **Inference gateway** — metered OpenRouter proxy mounted at `/v1/chat/completions`. Per-tenant service keys (DB-backed, SHA-256 hashed). Budget check → upstream proxy → metering → credit debit. Tested end-to-end with GPT-4o-mini.
- **Double-entry credit ledger** — platform-core's `DrizzleLedger` with `journal_entries` + `journal_lines` + `account_balances` tables. `grantSignupCredits()` grants $5 on user creation. Credits are nanodollars, integer math only.
- **BetterAuth** — sessions, signup, login at `/api/auth/*`. GitHub OAuth social provider.
- **Org/tenant support** — `DrizzleOrgMemberRepository` + `setTrpcOrgMemberRepo()` for multi-tenant isolation.
- **Notification pipeline** — Resend email via `NotificationWorker`, polls every 30s, 29 templates seeded.
- **Crypto payments** — BTCPay webhook at `/api/webhooks/crypto`. `DrizzleCryptoChargeRepository` + `DrizzleWebhookSeenRepository` for charge tracking + replay guard.
- **tRPC router** — platform-core router at `/trpc/*` with BetterAuth session context.
- **OpenCode SDK swap** — holyshipper replaces `@anthropic-ai/claude-agent-sdk` + `claude-code` CLI with `@opencode-ai/sdk` + `opencode` CLI. All inference routed through holyship gateway (metered, billed). Every SSE event logged with winston.
- **Gateway usage sanitization** — platform-core 1.36.3 strips non-standard OpenRouter fields (`cost`, `cost_details`, `is_byok`, `prompt_tokens_details`, `completion_tokens_details`) from `usage` object. Fixes `DecimalError` in OpenCode's `@ai-sdk/openai-compatible` parser.
- **Auto-pull cron** — `auto-pull.sh` runs every minute via cron, compares Docker image digests for api + ui, auto-restarts on new GHCR images. Replaces manual `docker compose pull`.
- **Transitive deps** — added `winston`, `lru-cache`, `@noble/hashes`, `@scure/base`, `@scure/bip32`, `@scure/bip39`, `js-yaml`, `viem`, `yaml` as production deps (required by platform-core internally).

### Docker Compose changes (`wopr-ops/local/holyship/`)

New env vars added to API service:

| Var | Purpose |
|-----|---------|
| `OPENROUTER_API_KEY` | Metered inference gateway (OpenRouter proxy) |
| `FLEET_DATA_DIR=/tmp/fleet` | Writable path for meter WAL/DLQ (non-root container) |
| `BETTER_AUTH_SECRET` | BetterAuth session signing |
| `BETTER_AUTH_URL` | BetterAuth callback URL resolution |

### Auto-pull cron

```bash
# Runs every minute — detects new GHCR images, auto-restarts containers
* * * * * /home/tsavo/wopr-ops/local/holyship/auto-pull.sh >> /tmp/holyship-auto-pull.log 2>&1
```

### OpenCode SDK integration (holyshipper)

Provider config written to `opencode.json` at container startup:
```json
{
  "provider": {
    "holyship": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Holy Ship Gateway",
      "env": ["HOLYSHIP_GATEWAY_KEY"],
      "options": { "baseURL": "http://api:3001/v1" },
      "models": {
        "anthropic/claude-sonnet-4-6": { "name": "Claude Sonnet" },
        "openai/gpt-4o-mini": { "name": "GPT-4o Mini" }
      }
    }
  }
}
```

**Gotchas:**
- Provider config MUST be in `opencode.json` on disk — Go server doesn't read SDK config param
- Models MUST be declared explicitly or server returns `ProviderModelNotFoundError`
- Body fields `providerID`/`modelID` are flat (not nested in `model` object)
- `env: ["HOLYSHIP_GATEWAY_KEY"]` tells OpenCode which env var holds the API key
- OpenCode server runs on port 4096 — kill stale processes before reinit
- Permission auto-accept: `POST /session/:id/permissions/:permissionID` with `{ response: "always" }`

### Gateway testing

```bash
# Create a service key for testing
docker compose exec api node -e "
import('@wopr-network/platform-core/credits').then(async ({ DrizzleLedger, grantSignupCredits }) => {
  const { getPlatformDb } = await import('./dist/db/index.js');
  const ledger = new DrizzleLedger(getPlatformDb());
  await grantSignupCredits(ledger, 'default');
  const bal = await ledger.balance('default');
  console.log('Balance cents:', bal.toCents());
  process.exit(0);
});"

# Insert service key (generate key + SHA-256 hash)
node -e "const c=require('crypto');const k='sk-hs-'+c.randomBytes(24).toString('hex');console.log('Key:',k);console.log('Hash:',c.createHash('sha256').update(k).digest('hex'))"
# Then INSERT INTO gateway_service_keys (id, key_hash, tenant_id, instance_id, created_at) VALUES (...)

# Test gateway
curl -s http://localhost:3001/v1/chat/completions \
  -H "Authorization: Bearer sk-hs-<key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-4o-mini","messages":[{"role":"user","content":"Say Holy Ship"}],"max_tokens":10}'
```

### E2E verified

```
OpenCode SDK → OpenCode server (Go, port 4096) → holyship gateway (:3001/v1) → OpenRouter → GPT-4o-mini
Response: "Holy Ship"
Events streamed: server.connected → message.updated → step-start → text("Holy") → text("Holy Ship") → session.idle
```

### Open PRs at session end (earlier session)

All merged by follow-up session (see below).

## 2026-03-16 (session 2) — tRPC Routers + Reactive Worker Pool + GHCR Publish

### What shipped (8 PRs)

| # | Repo | PR | What |
|---|------|-----|------|
| 1 | platform-core | #83 | Export `FleetManager` from fleet index (published as 1.37.0) |
| 2 | holyship | #201 | tRPC billing/org/profile/settings routers for UI |
| 3 | holyship | #202 | Ephemeral fleet lifecycle (`EntityLifecycleManager`) |
| 4 | holyship | #203 | Runner URL persisted to DB (not in-memory Map) |
| 5 | holyship | #204 | Reactive worker pool replaces lifecycle manager |
| 6 | holyshipper | #13 | OpenCode SDK swap (replaces Claude Code) |
| 7 | holyshipper | #14 | Multi-stage Dockerfiles for CI publish |
| 8 | wopr-ops | (direct) | Docker compose: worker pool env vars + Docker socket mount |

### tRPC routers (holyship #201)

Full billing/org/profile/settings router suite for the holyship-ui dashboard:

- **billing** — 30+ procedures: credits balance/history, Stripe checkout, crypto checkout, auto-topup, spending limits, plans, usage, dividends, affiliates, coupons
- **org** — CRUD, member invites/roles, org-scoped billing
- **profile** — get/update, password change
- **settings** — health, tenant config, notification prefs

Pattern: `set*RouterDeps()` at boot → lazy singleton injection. Same as paperclip-platform.

### Reactive worker pool (holyship #204)

Replaced event-driven `EntityLifecycleManager` + polling dispatcher with a single reactive `WorkerPool` that implements `IEventBusAdapter`:

```
invocation.created event
  → WorkerPool.emit()
  → slot available? → worker takes it
    → HolyshipperFleetManager.provision() → FleetManager.create() → Docker
    → POST /credentials (gateway key, GH token)
    → POST /checkout (clone repo)
    → POST /dispatch (prompt via OpenCode → gateway → OpenRouter)
    → parse SSE result → signal + artifacts
    → engine.processSignal() → gate eval via POST /gate to same container
    → FleetManager.remove() → teardown
    → slot freed → next queued event drains
```

- No polling, no sleep loops — purely reactive off engine events
- Bounded concurrency (4 slots), overflow queues and drains
- Runner URL written to `holyshipper_containers` DB table (survives restarts)
- Each container is ephemeral: one invocation cycle, then torn down
- Gate failure = transition + teardown + new container for next invocation

### Docker compose changes

New env vars in API service:

| Var | Purpose |
|-----|---------|
| `HOLYSHIP_WORKER_IMAGE` | GHCR image for holyshipper workers (default: `ghcr.io/wopr-network/wopr-holyshipper-coder:latest`) |
| `HOLYSHIP_GATEWAY_KEY` | Gateway service key for container auth |
| `DOCKER_NETWORK` | Docker network for container connectivity (`holyship_holyship`) |

New volume mount: `/var/run/docker.sock:/var/run/docker.sock` (API needs Docker socket to provision containers)

### Multi-stage Dockerfiles (holyshipper #14)

Worker Dockerfiles now have a build stage that compiles TypeScript:
```dockerfile
FROM node:24-slim AS build
RUN npm install -g pnpm
COPY ... && pnpm install && pnpm -C packages/worker-runtime run build

FROM node:24-slim
COPY --from=build /build/packages/worker-runtime/dist ...
```

CI publish was failing because `dist/` doesn't exist in the repo.

### platform-core 1.37.0

Added `FleetManager` to the barrel export at `@wopr-network/platform-core/fleet`. Was only importable via direct file path. Holyship needs it for ephemeral container provisioning.

## 2026-03-16 (session 3) — E2E Smoke Test + Instance Abstraction

### What shipped (19 PRs across 3 repos)

| # | Repo | PR | What |
|---|------|-----|------|
| 1 | holyshipper | #16 | OpenCode install fix (curl script, not npm) |
| 2 | holyshipper | #17 | Test model tier (free Gemma 27B) |
| 3 | holyshipper | #18 | OpenCode binary copy to /usr/local/bin |
| 4 | holyshipper | #19 | Bare-word signal patterns for engineering flow |
| 5 | holyship | #205 | Dead code removal (entity-lifecycle, resolve-runner-url) |
| 6 | holyship | #206 | HOLYSHIP_MODEL_TIER_OVERRIDE env var |
| 7 | holyship | #208 | Admin entity creation endpoint (POST /api/entities) |
| 8 | holyship | #209 | Worker pool claims on entity.created |
| 9 | holyship | #210 | Comprehensive worker pool logging |
| 10 | holyship | #211 | EventEmitter structured logging + pino injection |
| 11 | holyship | #212 | Direct schedule after claimWork (root cause fix) |
| 12 | holyship | #213 | runner_url Drizzle migration |
| 13 | holyship | #214 | UUID profile ID for FleetManager |
| 14 | holyship | #215 | createAndStart + network + ephemeral (platform-core 1.38) |
| 15 | holyship | #217 | Use Instance abstraction (platform-core 1.39) |
| 16 | holyship | #218 | Clearer signal instructions in flow prompts |
| 17 | platform-core | #84 | createAndStart, network, ephemeral in FleetManager (1.38) |
| 18 | platform-core | #85 | Instance abstraction — lifecycle off FleetManager (1.39) |
| 19 | wopr-ops | (direct) | Docker compose group_add + model tier override |

### Instance abstraction (platform-core 1.39)

**The key architectural change.** `FleetManager.create()` now returns an `Instance` — a runtime handle to a container:

```typescript
const instance = await fleet.create({ ...profile, ephemeral: true, network: "holyship_holyship" });
await instance.start();
// instance.url — resolved from Docker inspection, no naming convention leaks
// instance.status() — "running" | "stopped" | "gone"
await instance.remove(); // teardown
```

- **BotProfile** = spec (what to create)
- **BotInstance** = billing DB record (long-lived bots only)
- **Instance** = runtime handle (ephemeral or persistent)
- Ephemeral containers skip billing + proxy — bill per-token at gateway
- `Instance.setupBilling()` / `Instance.setupProxy()` for non-ephemeral
- Events: `bot.created`, `bot.started`, `bot.stopped`, `bot.removed`
- `FleetManager.start()` / `stop()` removed — lifecycle on Instance

### E2E smoke test — verified working

Full pipeline confirmed end-to-end on local stack:

```
entity.created → claimWork → invocation.created → worker starts
  → FleetManager.create() → docker pull → container created
  → instance.start() → container started on holyship_holyship network
  → health check passes (instance.url from Docker inspection)
  → POST /credentials (gateway key + GitHub token)
  → POST /dispatch (prompt, modelTier: "test")
  → OpenCode SDK → opencode serve (Go binary) → holyship gateway → OpenRouter → Gemma 27B (free)
  → SSE stream: session → text → result (costUsd: 0, isError: false, stopReason: "end_turn")
  → parseSignal() → signal extracted
  → engine.processSignal() → gate evaluation
  → instance.remove() → container torn down
  → worker finished
```

Timing: provision 2.1s, dispatch 1.8s, total ~10s including image pull cache hit.

### Smoke test procedure

```bash
# 1. Ensure stack is running
cd ~/wopr-ops/local/holyship
docker compose up -d

# 2. Verify API health
curl -s http://localhost:3001/health
# → {"status":"ok"}

# 3. Check worker pool initialized
docker logs holyship-api --tail 5 | grep "worker-pool"
# → [worker-pool] initialized {"poolSize":4,"tierOverride":"test"}

# 4. Create entity (requires HOLYSHIP_WORKER_TOKEN from .env)
curl -s -X POST http://localhost:3001/api/entities \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $(grep HOLYSHIP_WORKER_TOKEN .env | cut -d= -f2)" \
  -d '{
    "flow": "engineering",
    "refs": {
      "repoFullName": "wopr-network/holyship",
      "issueNumber": 1,
      "issueTitle": "Test entity",
      "issueBody": "Smoke test."
    }
  }'

# 5. Watch logs (entity → claim → provision → dispatch → signal → teardown)
docker logs holyship-api -f --since 30s | grep -E 'worker-pool|worker-1|fleet|EventEmitter'

# 6. Check container lifecycle
docker ps --filter "name=wopr-hs"  # Should appear then disappear
```

### Debugging guide

| Symptom | Cause | Fix |
|---------|-------|-----|
| No logs after entity creation | Worker pool not registered | Check `Reactive worker pool registered` in startup logs |
| `entity.created` but no `claimWork` | Worker pool not listening | Check `eventEmitter.register(workerPool)` in index.ts |
| `claimWork returned no work` | No unclaimed entities | Check entity state via GET /api/entities |
| `claimWork succeeded` but no worker starts | Missing direct schedule | PR #212 — claimWork doesn't emit invocation.created |
| `provision FAILED: Invalid profile ID` | Non-UUID bot ID | Use crypto.randomUUID() for profile ID |
| `provision FAILED: EACCES docker.sock` | Socket permissions | group_add in docker-compose.yml |
| `Container did not become ready` | Wrong DNS name / not started | Instance abstraction (PR #217) fixes this |
| `spawn opencode ENOENT` | Binary not on PATH | cp to /usr/local/bin (PR #18) |
| `SSE error events` / `no result` | OpenCode SDK config issue | Check opencode.json, gateway URL, HOLYSHIP_GATEWAY_KEY |
| `signal: "unknown"` | Model didn't output signal format | Check prompt template + parseSignal patterns |
| `No transition on signal "unknown"` | Signal not in flow | Add bare-word pattern to parseSignal (PR #19) |

### Docker compose changes (session 3)

```yaml
# API service additions:
group_add:
  - "${DOCKER_GID:-1001}"        # Docker socket access for non-root
environment:
  HOLYSHIP_MODEL_TIER_OVERRIDE: ${HOLYSHIP_MODEL_TIER_OVERRIDE:-}  # "test" for free models
```

### .env additions

```bash
HOLYSHIP_GATEWAY_KEY=sk-hs-...   # Gateway service key (from session 1)
HOLYSHIP_MODEL_TIER_OVERRIDE=test # Force free model for smoke testing (unset for production)
```

### Remaining for production

1. Close PR #216 (superseded by Instance abstraction)
2. Clean up stale test entities in DB
3. Deploy to DO droplet
4. DNS: api.holyship.wtf + holyship.wtf A records → droplet IP
5. Remove `HOLYSHIP_MODEL_TIER_OVERRIDE=test` for production (use real models)

## 2026-03-15 — Holy Ship: Auth Flow + Dashboard Issue Feed

### What shipped

- **Auth-first CTA flow** — Marketing CTAs route to `/login` (not `/connect`). Users authenticate via GitHub OAuth, land on dashboard, connect repos from there.
- **GitHub OAuth working** — better-auth GitHub social provider wired via platform-core. Requires `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `BETTER_AUTH_SECRET`, `BETTER_AUTH_URL` in API container.
- **OAuth callback fix** — `callbackURL` must be absolute (`window.location.origin + path`) or better-auth resolves relative paths against `BETTER_AUTH_URL` (API domain, not UI domain).
- **API proxy rewrite** — `next.config.ts` rewrites `/api/*` to holyship backend. Uses `API_INTERNAL_URL` (Docker: `http://api:3001`) at build time. Avoids CORS/TLS issues for server-side proxying.
- **`/api/github/repos` endpoint** — Lists repos from GitHub App installations. Auto-syncs installations from GitHub API when DB is empty (no webhook dependency).
- **`/api/github/issues` endpoint** — Lists open issues for a repo. Filters out PRs.
- **`/api/github/sync-installations` endpoint** — Explicit sync trigger for installations (POST).
- **Route ordering fix** — GitHub UI endpoints mounted BEFORE engine routes to avoid worker token auth middleware catching them.
- **Dashboard issue feed** — Fetches issues across ALL connected repos in parallel. Shows issue title, labels, age, repo name. Ship It button per issue. "Holy Ship!" on success. No repo picker gate.
- **Login page cleanup** — Removed stale "Install the GitHub App" copy, removed `isPending` button disable.

### Docker Compose changes (`wopr-ops/local/holyship/`)

New env vars in `docker-compose.yml`:

| Service | Var | Value | Purpose |
|---------|-----|-------|---------|
| api | `GITHUB_APP_CLIENT_ID` | `${GITHUB_APP_CLIENT_ID}` | GitHub App OAuth (for token-generator) |
| api | `GITHUB_APP_CLIENT_SECRET` | `${GITHUB_APP_CLIENT_SECRET}` | GitHub App OAuth secret |
| api | `GITHUB_CLIENT_ID` | `${GITHUB_APP_CLIENT_ID}` | better-auth social provider (different name!) |
| api | `GITHUB_CLIENT_SECRET` | `${GITHUB_APP_CLIENT_SECRET}` | better-auth social provider |
| api | `BETTER_AUTH_SECRET` | `${BETTER_AUTH_SECRET}` | Session signing key |
| api | `BETTER_AUTH_URL` | `${NEXT_PUBLIC_API_URL}` | Public URL for OAuth redirect_uri construction |
| ui | `API_INTERNAL_URL` | `http://api:3001` | Docker-internal URL for Next.js rewrite proxy |
| ui (build arg) | `API_INTERNAL_URL` | `http://api:3001` | Baked into standalone build |

New env vars in `.env`:

| Var | Purpose |
|-----|---------|
| `GITHUB_APP_CLIENT_ID` | From GitHub App settings → Client ID |
| `GITHUB_APP_CLIENT_SECRET` | From GitHub App settings → Generate client secret |
| `BETTER_AUTH_SECRET` | Random 64-char hex for session signing |

### Caddyfile (local dev)

Changed to `tls internal` for local development. Accept cert warnings in browser on first visit.

```
holyship.wtf, www.holyship.wtf {
    tls internal
    reverse_proxy ui:3000
}
api.holyship.wtf {
    tls internal
    reverse_proxy api:3001
}
```

### Windows hosts file

Add to `C:\Windows\System32\drivers\etc\hosts`:
```
127.0.0.1 holyship.wtf api.holyship.wtf
```

### GitHub App setup

| Setting | Value |
|---------|-------|
| Callback URL | `https://api.holyship.wtf/api/auth/callback/github` |
| Webhook URL | `https://api.holyship.wtf/api/github/webhook` |

### Local test results

| Route | Status |
|-------|--------|
| `/` | 200 — Landing page with rotating taglines |
| `/login` | 200 — GitHub OAuth button (redirects to GitHub) |
| `/how-it-works` | 200 — "Get Started" CTA → `/login` |
| `/dashboard` | 200 — Issue feed across all repos + Ship It buttons |
| `/ship` | 200 — Repo picker + issue shipper |
| `/approvals` | 200 |
| `/connect` | 307 → GitHub App install (dashboard-only action) |

### Gotchas

- **CORS**: `UI_ORIGIN` must include `http://localhost:3002` for local browser dev. Production: just `https://holyship.wtf`.
- **BETTER_AUTH_URL default**: platform-core defaults to `http://localhost:3100` if `BETTER_AUTH_URL` is unset — causes wrong `redirect_uri` in OAuth flow.
- **GITHUB_CLIENT_ID vs GITHUB_APP_CLIENT_ID**: platform-core reads `GITHUB_CLIENT_ID`/`GITHUB_CLIENT_SECRET`. The `.env` stores them as `GITHUB_APP_CLIENT_ID`/`GITHUB_APP_CLIENT_SECRET`. Docker-compose maps both names.
- **Engine auth middleware**: Engine routes at `/api/*` have a `/*` worker token middleware. Any new UI-facing `/api/` endpoints MUST be mounted BEFORE `app.route("/api", createEngineRoutes(...))` or they'll 401.
- **Next.js standalone rewrites**: `NEXT_PUBLIC_*` and `API_INTERNAL_URL` are baked at build time. Runtime env vars don't override. Must rebuild UI image to change API URL.
- **GitHub webhook unreachable locally**: Installations auto-sync from GitHub API on first `/api/github/repos` call when DB is empty. No webhook needed for local dev.

### Open PRs

| Repo | PR | Status |
|------|----|--------|
| holyship | #197 | In merge queue — repos, issues, sync endpoints |
| holyship-platform-ui | #42 | Auto-merge — dashboard issue feed |
| holyship-platform-ui | #43 | Auto-merge — Dockerfile API_INTERNAL_URL |

---

## 2026-03-15 — Holy Ship: Full Platform Build + Local Stack Verified

### What shipped

- **Baked-in engineering flow** — 11 states, 3 gates, 13 transitions. Opinionated: spec→code→review→fix→docs→learning→merge→done. Gates: spec-posted, ci-green, pr-mergeable. 29 integration tests covering full transition graph including review/fix loops and terminal paths.
- **boot.ts fully wired** — provisions engineering flow on startup, mounts createHonoApp (all engine routes), Ship It endpoint (/api/ship-it), GitHub webhook handler (/api/github/webhook). Primitive gate handler connected to GitHub API ops via installation tokens.
- **Dockerfile for holyship** — multi-stage (deps→build→runtime), node:22-alpine, health check at /health, CMD boots via platform/boot.js.
- **Dockerfile for holyship-platform-ui** — multi-stage, standalone Next.js output, 7 NEXT_PUBLIC_* build args for brand config.
- **Docker Compose stack** in wopr-ops/local/holyship/ — postgres:16, holyship-api:3001, holyship-platform-ui:3000 (mapped to 3002 locally), caddy:2 with auto-TLS.
- **21 dead test files deleted**, 5 stale tests updated. 68 test files, 962 tests, 0 failures.
- **GitHub App** — "Holy Ship" (App ID 3099979), installed on wopr-network. Webhook: api.holyship.wtf/api/github/webhook.
- **DNS** — holyship.wtf (CF Pages landing page), api.holyship.wtf (A record, placeholder until DO), holyship.dev (301→holyship.wtf via CF redirect rule).
- **Landing page** — deployed to CF Pages, serves on holyship.wtf + www.holyship.wtf.
- **Backup scripts** — sync-tsavo-g.sh (183 personal repos, hourly at :37), sync-orgs-g.sh (NeuralLog+MCPLookup+MediaConduit, 38 repos, hourly at :47). All backed up to Google Drive.

### Local test results

| Container | Status | Port |
|-----------|--------|------|
| holyship-postgres | healthy | 5432 (internal) |
| holyship-api | healthy | 3001 |
| holyship-platform-ui | healthy | 3002 (maps to 3000 internal) |
| holyship-caddy | running | 80, 443 |

| Route | Status |
|-------|--------|
| `/` | 200 — "Holy Ship — Guaranteed Code Shipping" |
| `/login` | 200 |
| `/connect` | 307 → github.com/apps/holyship/installations/new |
| `/ship` | 200 |
| `/approvals` | 200 |
| `/settings/pipeline` | 200 |

### Open PRs

| Repo | PR | Status |
|------|----|--------|
| holyship | #192 | Open — engine, tests, boot wiring, Dockerfile, gates |

### Next: DO deployment

Plan: s-1vcpu-1gb ($6/mo) sfo2, Ubuntu 24.04 LTS, 5GB swap. Cloud-init: Docker + swap. Then point api.holyship.wtf A record at droplet IP, Caddy handles TLS.

## 2026-03-14 — Paperclip Platform: Org Integration + Fleet Auto-Update + Email Notifications

~25 PRs merged across platform-core, paperclip-platform, platform-ui-core, and paperclip. Three design specs fully implemented end-to-end.

### New Env Vars (paperclip-platform)

| Var | Default | Purpose |
|-----|---------|---------|
| `APP_BASE_URL` | `https://app.paperclip.bot` | Base URL for links in notification emails |
| `FROM_EMAIL` | `noreply@paperclip.bot` | Sender address for notification emails (distinct from `RESEND_FROM_EMAIL` used by better-auth verification emails) |
| `FLEET_SNAPSHOT_DIR` | `/data/fleet/snapshots` | Volume snapshot storage for nuclear rollback |

`RESEND_API_KEY` and `RESEND_FROM_EMAIL` were already documented. Without `RESEND_API_KEY`, the notification pipeline is silently skipped (non-fatal).

### New DB Tables (auto-migrated on boot)

| Table | Source |
|-------|--------|
| `notification_queue` | Email notification queue (pending/sent/failed) |
| `notification_preferences` | Per-tenant notification toggles (incl. `fleet_updates`) |
| `notification_templates` | Handlebars email templates (seeded with 30 defaults on first boot) |
| `tenant_update_configs` | Per-tenant auto/manual update mode + preferred maintenance hour |

All tables are created by Drizzle migrations that run automatically on startup. The template seed is idempotent (INSERT OR IGNORE — admin edits are never overwritten).

### Behavioral Changes

- **Billing mutations require admin/owner role** — `creditsCheckout`, `changePlan`, `portalSession`, `setInferenceMode`, `updateSpendingLimits`, `removePaymentMethod`, `updateBillingEmail`, `updateAutoTopupSettings`, `applyCoupon`. Members get FORBIDDEN. Personal tenants (no org) are unaffected.
- **Health check timeout increased to 120s** (was 60s) for fleet container updates.
- **Fleet auto-update pipeline**: ImagePoller → RolloutOrchestrator (rolling wave) → VolumeSnapshotManager → ContainerUpdater → FleetEventEmitter → 60s debounce → NotificationWorker → Resend.
- **Manual-mode tenants** get "update available" emails when a new image is detected.
- **Auto-mode tenants** get "update complete" summary emails after rollout.
- **Admin fleet management**: `adminFleetUpdate.rolloutStatus`, `forceRollout`, `listTenantConfigs`, `setTenantConfig`.
- **Admin email template editor** at `/admin/email-templates` — edit Handlebars templates with live preview.
- **Org member provisioning**: acceptInvite/changeRole/removeMember propagate to Paperclip containers via `/internal/members/*` endpoints (best-effort, fire-and-forget).
- **ROLE_PERMISSIONS map**: owner/admin/member → Paperclip permission keys. Enforced during member provisioning.
- **hostedMode UI guards**: CompanySwitcher hides dropdown in hosted_proxy mode.

## Production Blockers (must resolve before go-live)

All blockers resolved. No CRITICAL or HIGH blockers outstanding.

| Issue | Severity | Description | Status |
|-------|----------|-------------|--------|
| WOP-990 | CRITICAL | Migration 0031 drops `tenant_customers` + `stripe_usage_reports` — PR #309 | **Done** — merged 2026-02-27 |
| WOP-991 | HIGH | Fleet pullImage fails for private ghcr.io — no authconfig in Dockerode call — PR #310 | **Done** — merged 2026-02-25 |
| WOP-992 | HIGH | Session-cookie users get 401 on fleet REST API — PR #311 | **Done** — merged 2026-02-25 |

## Go-Live Checklist

- [x] WOP-990 merged and verified
- [x] WOP-991 merged and verified
- [x] WOP-992 resolved
- [ ] DO droplet provisioned
- [ ] DNS: wopr.bot A record → droplet IP (Cloudflare proxy OFF)
- [ ] DNS: api.wopr.bot A record → droplet IP (Cloudflare proxy OFF)
- [ ] .env deployed to droplet with absolute paths
- [ ] drizzle-kit migrate run on droplet before server start
- [ ] docker compose up -d — all services healthy
- [ ] Stripe switched to live mode keys + price IDs updated
- [ ] Resend wopr.bot domain verified
- [ ] Happy path smoke test passes (sign-up → pay → bot created)

## Stack

| Service | Image | Port | Status |
|---------|-------|------|--------|
| caddy | caddy:2-alpine | 80, 443 | Not yet deployed |
| platform-api | ghcr.io/wopr-network/wopr-platform:latest | 3100 | Not yet deployed |
| platform-ui | ghcr.io/wopr-network/wopr-platform-ui:latest | 3000 | Not yet deployed |

## VPS

| Field | Value |
|-------|-------|
| Provider | DigitalOcean |
| Status | Not yet provisioned |
| Region | TBD |
| Size | TBD |
| IP | TBD |

## GPU Node

| Field | Value |
|-------|-------|
| Status | Not yet provisioned |
| Design | GPU Inference Infrastructure doc in Linear |

## Secrets Inventory

All secrets live on VPS at `/root/wopr-platform/.env` — never committed anywhere.

| Secret | Purpose | Notes |
|--------|---------|-------|
| STRIPE_SECRET_KEY | Payments | Switch to live key before go-live |
| STRIPE_WEBHOOK_SECRET | Webhook validation | Regenerate for live endpoint |
| STRIPE_DEFAULT_PRICE_ID | $5/mo subscription | Update to live price ID |
| CLOUDFLARE_API_TOKEN | Caddy DNS-01 TLS challenge | Zone:DNS:Edit on wopr.bot |
| DO_API_TOKEN | Fleet droplet provisioning | Droplet write access |
| RESEND_API_KEY | Transactional email | wopr.bot domain must be verified first |
| BETTER_AUTH_SECRET | Session signing | Generated — never rotate without migration plan |
| PLATFORM_SECRET | Internal service-to-service auth | Generated |
| REGISTRY_USERNAME/PASSWORD | ghcr.io pull auth for fleet containers | GitHub PAT |
| GPU_NODE_SECRET | GPU cloud-init self-registration | Static — rotate after first provision |

## Known Gotchas

- `docker compose restart` does NOT re-read env_file — always use `--force-recreate` or `down && up`
- DB paths must be absolute in prod (relative breaks in Docker volume context)
- Caddy DNS-01 requires Cloudflare proxy OFF on A records — Caddy must own TLS
- `drizzle-kit migrate` must run BEFORE the server starts
- `BETTER_AUTH_URL` must be `https://api.wopr.bot` in prod
- `COOKIE_DOMAIN` must be `.wopr.bot` in prod
- Stripe webhook HMAC key = full `whsec_XXX` string — do not strip the prefix
- `checkout.session.completed` silently ignores events where `session.customer` is null
- Dockerode `docker.pull()` needs explicit `authconfig` param for private GHCR images — fixed in WOP-991 (PR #310), now reads `REGISTRY_USERNAME`/`REGISTRY_PASSWORD`/`REGISTRY_SERVER` env vars
- Migration 0031 was dangerous (dropped `tenant_customers` + `stripe_usage_reports`) — fixed in WOP-990 (PR #309), migration 0032 recreates both tables. Safe to run as of 2026-02-27.
- `drizzle-kit migrate` runs ALL pending migrations in sequence — migration 0031 + 0032 are both in the queue and are now safe to run.

## Rollback Procedure

If a deploy is bad:

1. SSH to VPS
2. `cd /root/wopr-platform`
3. Edit `docker-compose.yml` — pin image tags to previous known-good SHA (find in DEPLOYMENTS.md)
4. `docker compose up -d --force-recreate`
5. `curl https://api.wopr.bot/health` — verify recovery
6. Log the incident in INCIDENTS.md and append rollback entry to DEPLOYMENTS.md

To find the previous image SHA: check DEPLOYMENTS.md for last successful deploy entry.

## Health Check URLs (when live)

- API: `https://api.wopr.bot/health` → `{"status":"ok"}`
- UI: `https://wopr.bot` → 200 with valid TLS

---

## Local Development

Two approaches available. Use the DinD topology when testing multi-machine behavior. Use the flat approach for rapid single-service iteration.

### Approach A — Two-Machine DinD (recommended for topology testing)

**Verified working: 2026-02-28.** CD via Watchtower fully operational.

Files: `local/` directory.

Replicates exact production topology: two Docker-in-Docker containers (`wopr-vps`, `wopr-gpu`) on a `wopr-dev` bridge network. Platform-api reaches GPU services via `wopr-gpu` hostname, exactly as prod reaches the DO GPU droplet by IP.

#### CD — how images get updated automatically

On every merge to `main`:
- `wopr-platform`: CI pushes `:latest` + `:<sha>` to GHCR
- `wopr-platform-ui`: CI pushes `:staging`/`:latest`/`:<sha>` (staging URL baked in) AND `:local` (localhost:3100 baked in)

Watchtower inside the VPS inner stack polls GHCR every 60s. When it sees a new digest on `:latest` (platform-api) or `:local` (platform-ui), it pulls and restarts the container automatically. **Total lag: ~5 minutes from merge to running locally.**

#### First-time setup (fresh clone or after WSL restart wipes ~/wopr-ops)

```bash
# 1. Clone wopr-ops if missing (never use /tmp — wiped on WSL restart)
git clone https://github.com/wopr-network/wopr-ops.git ~/wopr-ops

# 2. Create local/vps/.env from ~/wopr-platform-backend/.env on the host
#    (gitignored — must recreate after fresh clone)
grep -v '^#' ~/wopr-platform-backend/.env | grep -v '^$' | \
  grep -v 'DOMAIN=' | grep -v '_DB_PATH=' | grep -v 'METER_' | \
  grep -v 'SNAPSHOT_' | grep -v 'TENANT_KEYS_' > ~/wopr-ops/local/vps/.env
echo "POSTGRES_PASSWORD=wopr_local_dev" >> ~/wopr-ops/local/vps/.env
echo "GPU_NODE_SECRET=wopr_local_gpu_secret" >> ~/wopr-ops/local/vps/.env
echo "COOKIE_DOMAIN=localhost" >> ~/wopr-ops/local/vps/.env

# 3. Start the VPS container only (GPU requires NVIDIA — skip on WSL2 without GPU)
export PATH="$PATH:/mnt/c/Program Files/Docker/Docker/resources/bin"
docker compose -f ~/wopr-ops/local/docker-compose.yml up -d vps

# 4. Wait for VPS inner daemon (~30s). VPS entrypoint will fail to pull (credential helper
#    not in DinD PATH). Proceed to manual pull steps below.
docker logs -f wopr-vps   # watch for "==> VPS stack started." then Ctrl-C

# 5. Set up GHCR auth inside the container (ephemeral — repeat after each container restart)
REGISTRY_PASSWORD=$(grep REGISTRY_PASSWORD ~/wopr-ops/local/vps/.env | cut -d= -f2-)
AUTH=$(printf 'tsavo:%s' "$REGISTRY_PASSWORD" | base64 -w 0)
docker exec wopr-vps /bin/sh -c "mkdir -p /tmp/dockercfg && printf '{\"auths\":{\"ghcr.io\":{\"auth\":\"%s\"}}}' '$AUTH' > /tmp/dockercfg/config.json"

# 6. Pull inner images (platform-api, platform-ui, caddy, postgres, watchtower)
docker exec wopr-vps /bin/sh -c 'cd /workspace/vps && set -a && . ./.env && set +a && DOCKER_CONFIG=/tmp/dockercfg docker compose pull'

# 7. Build platform-ui:local and push to GHCR (required because :local uses standalone output
#    and PLAYWRIGHT_TESTING bypass — only exists if built from fix/wop-1187-local-image config)
cd ~/wopr-platform-ui
git checkout origin/fix/wop-1187-local-image -- next.config.ts
docker build --build-arg NEXT_PUBLIC_API_URL=http://localhost:3100 -t ghcr.io/wopr-network/wopr-platform-ui:local .
git restore next.config.ts
docker push ghcr.io/wopr-network/wopr-platform-ui:local
docker exec wopr-vps /bin/sh -c 'DOCKER_CONFIG=/tmp/dockercfg docker pull ghcr.io/wopr-network/wopr-platform-ui:local'

# 8. Start inner stack
docker exec wopr-vps /bin/sh -c 'cd /workspace/vps && set -a && . ./.env && set +a && DOCKER_CONFIG=/tmp/dockercfg docker compose up -d'

# 9. Seed GPU node registration (optional — only needed if testing GPU/inference features)
bash ~/wopr-ops/local/gpu-seeder.sh
```

**Note:** `local/vps/docker-compose.yml` must have `PLAYWRIGHT_TESTING: "true"` under `platform-ui.environment` to bypass the localhost URL validation at SSR runtime (see DinD gotchas). This is already in the committed file as of 2026-03-05.

#### Normal usage (stack already running)

```bash
# Check inner stack status
docker exec wopr-vps docker ps

# Watch Watchtower CD activity
docker exec wopr-vps docker logs -f wopr-vps-watchtower

# Teardown (preserves volumes)
docker compose -f ~/wopr-ops/local/docker-compose.yml down

# Teardown and wipe all data
docker compose -f ~/wopr-ops/local/docker-compose.yml down -v
```

**First boot note:** GPU container installs Docker + NVIDIA Container Toolkit on first boot (~90s). Subsequent boots reuse the `gpu-docker-data` volume (~15s). VPS startup takes 60-120s for inner dockerd to initialize against existing volume state.

#### DinD Platform Image Workflow

GHCR carries no usable tag for local dev (`:latest` for platform-api is stale; `:local` doesn't exist remotely). Build locally and pipe into the inner VPS daemon:

```bash
# After any platform-api code change:
cd /path/to/wopr-platform
docker build -t ghcr.io/wopr-network/wopr-platform:local .
docker save ghcr.io/wopr-network/wopr-platform:local | docker exec -i wopr-vps docker load
docker exec wopr-vps docker restart wopr-vps-platform-api
```

#### DinD GPU Seeder

The seeder (`local/gpu-seeder.sh`) resolves the `wopr-gpu` container IP, then runs psql **inside the inner postgres container** (the VPS DinD container has no psql client):

```bash
bash local/gpu-seeder.sh
```

After seeding, platform-api is automatically restarted. The InferenceWatchdog polls every 30s and updates `service_health` in `gpu_nodes`.

To verify:
```bash
docker exec wopr-vps docker exec -e PGPASSWORD=wopr_local_dev wopr-vps-postgres \
  psql -U wopr -d wopr_platform -c "SELECT id, host, status, service_health FROM gpu_nodes;"
```

#### DinD Gotchas (hard-won)

- **`nvidia-smi` is at `/usr/lib/wsl/lib/nvidia-smi` on this WSL2 host** — not in PATH by default. Confirmed GPU: RTX 3070 8GB, driver 581.08, CUDA 13.0. Docker has `nvidia` runtime registered (`docker info | grep -i nvidia`). Device nodes `/dev/nvidia*` are not pre-created but the NVIDIA Container Toolkit creates them on demand. GPU container starts fine without them.

- **Inner DinD GPU layer-lock errors are normal on first pull** — the containerd `(*service).Write failed ... locked for Xs` errors spam the log while a large layer (>1 GB) is being extracted. This is a DinD containerd concurrency issue and resolves itself. Do not restart the container. Wait; the pull completes and the stack starts. Subsequent boots use the `gpu-docker-data` volume and skip pulls entirely.

- **`DO_API_TOKEN` required even for InferenceWatchdog** — `getDOClient()` is called from `getInferenceWatchdog()`, not just from the provisioner. Without it, platform-api crashes on startup. Set to any non-empty value for local dev (`local-dev-fake` is fine). The outer compose passes `DO_API_TOKEN=local-dev-fake` automatically.

- **Platform images must be piped in via `docker save | docker load`** — the VPS inner daemon has no access to the host's image cache. Run the load command after every rebuild.

- **GHCR auth inside DinD** — the outer VPS and GPU containers mount `~/.docker/config.json` read-only for pulling public images. For private GHCR images, run `docker login ghcr.io` inside the container: `docker exec wopr-vps docker login ghcr.io -u <user> -p <token>`.

- **VPS workspace is read-only** — `local/vps/` is mounted `:ro` inside the container. To apply compose file changes without rebuilding the container, copy to `/tmp/vps/` inside the container and run compose from there.

- **VPS dockerd startup timeout** — the startup script waits up to 120s for the inner dockerd. On warm restart with an existing `vps-docker-data` volume, this can take 90s+. Do not set the timeout below 120s.

- **GPU entrypoint keep-alive** — use `tail -f /dev/null` to keep the container alive after the inner stack starts. `wait $DOCKERD_PID` caused a bash syntax error in the nvidia/cuda base image and caused the container to exit (taking port mappings 8080-8083 with it).

- **`--flash-attn` requires a value** — newer llama.cpp requires `--flash-attn on|off|auto`. Passing `--flash-attn` bare is a parse error. Local dev uses `--flash-attn off`.

- **CUDA passthrough in DinD is unsupported** — nested virtualization of GPU resources doesn't work (CUDA runtime version mismatch). GPU services run in CPU mode locally (`--n-gpu-layers 0`). This is slow for llama but functional for testing.

- **psql inside DinD** — `docker:27-dind` has no psql client. Run psql inside the inner postgres container: `docker exec wopr-vps docker exec -e PGPASSWORD=... wopr-vps-postgres psql ...`

- **WOP-1186: GPU cloud-init missing docker login** — production `gpu-cloud-init.ts` now includes `docker login` before `docker compose up`. PR #440 on wopr-platform. Without this, GPU node pulls hit Docker Hub anonymous rate limits (100 pulls/6h per IP).

- **`docker-credential-desktop.exe` not in WSL PATH** — Docker Desktop WSL integration mounts `~/.docker/config.json` with `"credsStore": "desktop.exe"`. The inner VPS DinD daemon sees this file but `docker-credential-desktop.exe` is not in its PATH. Workaround: before pulling inside the container, create a plain-auth config at `/tmp/dockercfg/config.json` and prefix commands with `DOCKER_CONFIG=/tmp/dockercfg`. To set it up: `REGISTRY_PASSWORD=$(grep REGISTRY_PASSWORD ~/wopr-ops/local/vps/.env | cut -d= -f2-) && AUTH=$(printf 'tsavo:%s' "$REGISTRY_PASSWORD" | base64 -w 0) && docker exec wopr-vps /bin/sh -c "mkdir -p /tmp/dockercfg && printf '{\"auths\":{\"ghcr.io\":{\"auth\":\"%s\"}}}' '$AUTH' > /tmp/dockercfg/config.json"`. Then pull: `docker exec wopr-vps /bin/sh -c 'DOCKER_CONFIG=/tmp/dockercfg docker pull <image>'`. **This `/tmp/dockercfg` is ephemeral** — recreate after every container restart.

- **`docker save | docker exec -i` fails in WSL with Docker Desktop** — piping `docker save` output into `docker exec -i` fails with `/usr/bin/env: 'sh': No such file or directory`. The Docker Desktop CLI intercepts stdin in a way that breaks piped exec. Workaround: save to a tar file on the host, then use `docker cp` — but `docker cp` also silently fails for files in `/tmp`. Use `~/` instead: `docker save <image> -o ~/image.tar && docker cp ~/image.tar wopr-vps:/tmp/image.tar && docker exec wopr-vps docker load -i /tmp/image.tar`. If `docker cp` still fails, push the image to GHCR and pull from inside the container.

- **`platform-ui:local` requires building from `fix/wop-1187-local-image` branch** — `main` does not have `output: "standalone"` in `next.config.ts` but the Dockerfile copies `.next/standalone`. Build image by checking out `next.config.ts` from `origin/fix/wop-1187-local-image` before running `docker build`. Restore after build: `git restore next.config.ts`.

- **`platform-ui` hostname validation in production mode** — `src/lib/api-config.ts` validates `NEXT_PUBLIC_API_URL` at SSR startup and throws if it contains `localhost` or an internal IP when `NODE_ENV=production`. Next.js Turbopack inlines `NODE_ENV` at build time, so setting `NODE_ENV=development` on the container at runtime does NOT bypass it. Use `PLAYWRIGHT_TESTING=true` as the runtime bypass env var. Add to `local/vps/docker-compose.yml` under `platform-ui.environment`.

- **`platform-ui` default image on inner compose is `:local`** — GHCR carries `:latest` (stale staging build) and `:local` (built from `fix/wop-1187-local-image`). Build locally, push to GHCR as `:local`, then pull inside the container. Alternatively, build locally, push with `docker push ghcr.io/wopr-network/wopr-platform-ui:local`, then `DOCKER_CONFIG=/tmp/dockercfg docker pull ghcr.io/wopr-network/wopr-platform-ui:local` inside the container.

#### DinD Health Check Commands

```bash
# Outer containers
docker ps --format "table {{.Names}}\t{{.Status}}" | grep wopr

# VPS inner stack
docker exec wopr-vps docker ps --format "table {{.Names}}\t{{.Status}}"

# GPU inner stack
docker exec wopr-gpu docker ps --format "table {{.Names}}\t{{.Status}}"

# Platform API
curl http://localhost:3100/health

# GPU services
curl http://localhost:8080/health  # llama-cpp
curl http://localhost:8081/health  # chatterbox
curl http://localhost:8082/health  # whisper
curl http://localhost:8083/health  # qwen-embeddings

# GPU node registration in DB
docker exec wopr-vps docker exec -e PGPASSWORD=wopr_local_dev wopr-vps-postgres \
  psql -U wopr -d wopr_platform -c "SELECT id, host, status, service_health FROM gpu_nodes;"
```

### Approach B — Flat single-host compose (rapid iteration)

Files: `docker-compose.local.yml`, `Caddyfile.local`, `.env.local.example` (all in wopr-ops root).

This stack simulates the full production topology on a single host with GPU pass-through. Two logical nodes run on one machine: a VPS node (postgres, platform-api, platform-ui, Caddy) and a GPU node (llama-cpp, qwen-embeddings, chatterbox, whisper). Both share the `wopr-local` Docker network so platform-api can reach GPU services by container name.

**Last validated:** 2026-02-28. Full VPS node stack confirmed healthy. Voice GPU profile confirmed running. GPU node seeder updated to use direct DB insert (see seeding section).

### Current Running State — Approach B flat compose (2026-02-28)

| Container | Status | Notes |
|-----------|--------|-------|
| wopr-ops-postgres-1 | healthy | |
| wopr-ops-platform-api-1 | healthy | port 3100 inside network |
| wopr-ops-platform-ui-1 | healthy | port 3000 inside network |
| wopr-ops-caddy-1 | running | port 80 → ui, api.localhost → api |
| wopr-local-chatterbox | running | port 8081, `--profile voice` |
| wopr-local-whisper | running | port 8082, `--profile voice` |

GPU profile (`--profile llm`: llama-cpp port 8080, qwen-embeddings port 8083) not yet started. Run `gpu-seeder` then restart platform-api to register node.

### GPU Service Images (Validated — do not substitute)

| Service | Image | Port | Notes |
|---------|-------|------|-------|
| chatterbox | `travisvn/chatterbox-tts-api:gpu` | 8081:5123 | DEVICE=cuda. **`:v1.0.1` is CPU-only** — do NOT use that tag |
| whisper | `fedirz/faster-whisper-server:0.6.0-rc.3-cuda` | 8082:8000 | |
| llama-cpp | `ghcr.io/ggml-org/llama.cpp:server-cuda` | 8080 | Repo moved — **NOT `ggerganov`**, use `ggml-org` |
| qwen-embeddings | `ghcr.io/ggml-org/llama.cpp:server-cuda` | 8083 | Same image, `--embedding --pooling mean`, model at `/opt/models/qwen2-0_5b-instruct-q8_0.gguf` |

### Compose Profiles

`docker-compose.local.yml` uses two profiles — only bring up what you need:

```bash
# VPS node only (postgres, platform-api, platform-ui, caddy)
docker compose -f docker-compose.local.yml --env-file .env.local up -d

# VPS node + voice GPU services (chatterbox + whisper)
docker compose -f docker-compose.local.yml --env-file .env.local --profile voice up -d

# VPS node + LLM GPU services (llama-cpp + qwen-embeddings)
docker compose -f docker-compose.local.yml --env-file .env.local --profile llm up -d

# Everything
docker compose -f docker-compose.local.yml --env-file .env.local --profile voice --profile llm up -d
```

### Prerequisites

1. **NVIDIA Container Toolkit** — install from https://github.com/NVIDIA/nvidia-container-toolkit. Verify with `nvidia-smi` and `docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi`.

2. **Model weights at `/opt/models/`** on the host — the compose file bind-mounts this path read-only into the GPU containers. Required files:
   - `llama.gguf` — symlink or rename of your llama GGUF model (Q4_K_M recommended for RTX 3070, ~5 GB VRAM)
   - `qwen2-0_5b-instruct-q8_0.gguf` (~1 GB VRAM)
   - Whisper model is auto-downloaded from HuggingFace on first start
   - Chatterbox downloads weights on first start

   Download with huggingface-cli or llama.cpp's `tools/download.py`.

3. **GHCR login** — required to pull private platform images. Use a GitHub PAT with `read:packages` scope:
   ```bash
   echo <token> | docker login ghcr.io -u <github-username> --password-stdin
   ```
   Token for this environment stored in `~/github-runners/.env`.

4. **Platform images: build locally** — GHCR only carries `latest` for platform-api and `staging` for platform-ui. Both tags are stale. Build from source:
   ```bash
   # platform-api
   cd /path/to/wopr-platform && docker build -t ghcr.io/wopr-network/wopr-platform:local .

   # platform-ui
   cd /path/to/wopr-platform-ui && docker build -t ghcr.io/wopr-network/wopr-platform-ui:local .
   ```
   Update `docker-compose.local.yml` image references to `:local` tags when running from source.

5. **`.env.local`** — copy from `.env.local.example` and fill in secrets:
   ```bash
   cp .env.local.example .env.local
   # Edit .env.local — generate secrets with: openssl rand -hex 32
   ```

### Starting the flat stack (Approach B)

```bash
# From wopr-ops directory — VPS node + voice profile (current validated config)
docker compose -f docker-compose.local.yml --env-file .env.local --profile voice up -d
```

Watch logs until healthy:

```bash
docker compose -f docker-compose.local.yml logs -f platform-api
```

### Accessing services from WSL2

From inside WSL2:

```bash
curl -H "Host: localhost" http://127.0.0.1/               # UI via Caddy (200)
curl -H "Host: api.localhost" http://127.0.0.1/health     # API via Caddy
curl http://127.0.0.1:3100/health                         # API direct
```

From Windows browser: use the WSL2 IP (e.g. `http://172.23.176.117/`). The IP changes on WSL2 restart — check with `ip addr show eth0` from inside WSL2.

To use Caddy subdomains by name, add to `/etc/hosts` (WSL2) or `C:\Windows\System32\drivers\etc\hosts` (Windows):
```
127.0.0.1 api.localhost app.localhost
```

### Seeding the GPU node registration

**How it works (and why direct DB insert is required):**

Production GPU nodes self-register via cloud-init: `GpuNodeProvisioner.provision()` calls the DO API and INSERTs the row, then cloud-init POSTs to `/internal/gpu/register` to advance the `provision_stage`. In local dev, `GpuNodeProvisioner` is unavailable (no real droplet), and `/internal/gpu/register` can only UPDATE an existing row — it cannot INSERT a new one. The correct local dev approach is to INSERT the row directly into postgres.

**Using the compose seeder (recommended):**

```bash
docker compose -f docker-compose.local.yml --env-file .env.local \
  run --rm gpu-seeder
```

The seeder is a one-shot postgres:16-alpine container that inserts (or upserts) the `gpu_nodes` row directly. It depends only on `postgres` being healthy — not on `platform-api`. It is idempotent and safe to re-run.

After the seeder exits, restart platform-api so the InferenceWatchdog picks up the new row on its next 30s poll:

```bash
docker compose -f docker-compose.local.yml --env-file .env.local restart platform-api
```

**Manual equivalent (if needed outside compose):**

```bash
docker exec wopr-ops-postgres-1 psql -U wopr -d wopr_platform -c "
INSERT INTO gpu_nodes (id, host, region, size, status, provision_stage, service_health, monthly_cost_cents)
VALUES (
  'local-gpu-node-001',
  'host.docker.internal',
  'local',
  'rtx-3070',
  'active',
  'done',
  '{\"llama\":true,\"chatterbox\":true,\"whisper\":true,\"qwen\":true}',
  0
) ON CONFLICT (id) DO UPDATE SET
  host = 'host.docker.internal',
  status = 'active',
  provision_stage = 'done',
  service_health = '{\"llama\":true,\"chatterbox\":true,\"whisper\":true,\"qwen\":true}',
  updated_at = EXTRACT(epoch FROM now())::bigint;
"
```

**Verification:**

```bash
# Confirm row is present
docker exec wopr-ops-postgres-1 psql -U wopr -d wopr_platform -c \
  "SELECT id, host, status, service_health FROM gpu_nodes;"

# Then restart platform-api
docker compose -f docker-compose.local.yml --env-file .env.local restart platform-api
```

Expected `service_health` after InferenceWatchdog runs (voice profile, no llm profile):
- `chatterbox`: ok, `whisper`: ok
- `llama`: down, `qwen`: down (not running on voice-only profile — expected)

The `GPU_NODE_ID` in `.env.local` is the stable node identity — must match across runs.

### Health checks

```bash
curl http://localhost:3100/health           # platform-api → {"status":"ok"}
curl -I http://localhost                    # Caddy → 200
curl http://localhost:8081/health           # chatterbox (voice profile)
curl http://localhost:8082/health           # whisper (voice profile)
curl http://localhost:8080/health           # llama-cpp (llm profile)
curl http://localhost:8083/health           # qwen-embeddings (llm profile)
```

### Known limitations vs production (both local dev approaches)

| Area | Production | Local Dev |
|------|-----------|-----------|
| TLS | Caddy DNS-01 via Cloudflare, HTTPS everywhere | Plain HTTP, no TLS |
| Domain | `wopr.bot`, `api.wopr.bot` | `localhost`, `api.localhost` |
| GPU node network | Separate DO droplet on private IP | DinD: `wopr-gpu` hostname on bridge. Flat: `host.docker.internal` |
| GPU node registration | Cloud-init self-registers via DO API + `/internal/gpu/register` | Direct DB insert via gpu-seeder |
| GPU node reboot | InferenceWatchdog reboots DO droplet | Watchdog runs but reboot fails (no droplet) — harmless |
| BETTER_AUTH_URL | `https://api.wopr.bot` | `http://localhost:3100` |
| COOKIE_DOMAIN | `.wopr.bot` | `localhost` |
| Platform images | Built by CI, pushed to GHCR | Build from source — GHCR tags are stale |
| VRAM | A100 80 GB or similar | RTX 3070 8 GB — use Q4 quantization for llama |
| Stripe | Live keys, real payments | Test keys, no real charges |
| Email | Resend with verified domain | Disabled (placeholder API key) |
| First boot (DinD GPU) | N/A | ~90s to install Docker + NVIDIA toolkit inside container |

### Local dev gotchas

- **chatterbox `:v1.0.1` is CPU-only** — always use `:gpu` tag. The CPU tag will pull and start but inference will be unusably slow.
- **llama.cpp image moved** — `ghcr.io/ggerganov/llama.cpp` no longer exists. The correct registry path is `ghcr.io/ggml-org/llama.cpp`.
- **Caddyfile bare `localhost {}` triggers HTTPS** — Caddy interprets a bare hostname as a production domain and tries to obtain a certificate, binding port 443 only. Use `http://localhost {}` (explicit scheme) to bind port 80 for plain HTTP.
- **`docker compose restart` does not re-read env_file** — use `--force-recreate` or `down && up` after any `.env.local` change.
- **GHCR login required for private images** — platform-api and platform-ui images are in a private GHCR namespace. Token in `~/github-runners/.env`.
- **Build platform images locally** — do not trust GHCR `:latest` or `:staging` tags; both are stale as of 2026-02-28.

### Teardown

```bash
docker compose -f docker-compose.local.yml --env-file .env.local --profile voice --profile llm down -v
```

The `-v` flag removes volumes including the postgres database. Omit it to preserve data across restarts.

---

## Paperclip Platform (runpaperclip.com)

White-label deployment of the WOPR platform stack for Paperclip AI. Uses `@wopr-network/platform-core` for shared DB schema, auth, and billing. The dashboard is `platform-ui-core` with `NEXT_PUBLIC_BRAND_*` env vars for Paperclip branding.

### Current State

**Status:** LOCAL DEV — full happy path E2E verified (2026-03-14)
**Last Updated:** 2026-03-14
**Last Verified:** Signup → $5 credits → create instance → tenant subdomain proxy — all green through `runpaperclip.com` domain via `/etc/hosts`.

### Dependency Graph (CRITICAL — read this first)

We own everything except Node, Docker, Hono, Next.js, and third-party libs. Every bug gets fixed at source, published, and updated downstream. **Never work around our own code.**

```
platform-core (npm @wopr-network/platform-core, v1.14.4, semantic-release)
  ↓ consumed by
paperclip-platform (Hono API)         platform-ui-core (npm @wopr-network/platform-ui-core, v1.1.4, semantic-release)
                                        ↓ consumed by
                                      paperclip-platform-ui (thin Next.js shell, pnpm)

paperclip (managed bot image, Docker Hub tsavo/paperclip-managed:local)
  ↓ pulled by fleet at container create time (docker pull, NOT local cache)
paperclip-platform fleet (Docker containers per tenant)
```

**Fix → Publish → Update downstream:**

| Owning Repo | How to Publish | Downstream Update |
|-------------|---------------|-------------------|
| platform-core | Merge to main → semantic-release auto-publishes | `cd ~/paperclip-platform && npm update @wopr-network/platform-core && docker compose up --build platform` |
| platform-ui-core | Merge to main → semantic-release auto-publishes | `cd ~/paperclip-platform-ui && pnpm update @wopr-network/platform-ui-core && cd ~/paperclip-platform && docker compose up --build dashboard` |
| paperclip (managed image) | `cd ~/paperclip && docker build -t tsavo/paperclip-managed:local -f Dockerfile.managed . && docker push tsavo/paperclip-managed:local` | `cd ~/paperclip-platform && docker compose down -v && docker compose up --build` (fleet pulls on create) |
| paperclip-platform | Rebuild Docker: `docker compose up --build platform` | N/A (leaf node) |
| paperclip-platform-ui | Rebuild Docker: `docker compose up --build dashboard` | N/A (leaf node) |

### Repositories

| Repo | Local Path | npm Package | Purpose |
|------|-----------|-------------|---------|
| wopr-network/platform-core | ~/platform-core | @wopr-network/platform-core (v1.14.4) | Shared backend: DB, auth, billing, fleet, gateway |
| wopr-network/platform-ui-core | ~/platform-ui-core | @wopr-network/platform-ui-core (v1.1.4) | Brand-agnostic Next.js UI (dashboard, auth pages) |
| wopr-network/paperclip-platform | ~/paperclip-platform | — | Hono API — fleet, billing, auth, tenant proxy |
| wopr-network/paperclip-platform-ui | ~/paperclip-platform-ui | — | Paperclip dashboard — thin shell on platform-ui-core |
| wopr-network/paperclip | ~/paperclip | — | Managed bot image (Docker Hub: tsavo/paperclip-managed) |

### Stack (local dev)

| Service | Image | Port | URL |
|---------|-------|------|-----|
| postgres | postgres:16-alpine | 5433 (mapped from 5432) | localhost:5433 |
| platform (API) | Built from ~/paperclip-platform | 3200 | http://api.runpaperclip.com:8080/health |
| dashboard | Built from ~/paperclip-platform-ui | 3000 (via Caddy at 8080) | http://app.runpaperclip.com:8080 |
| caddy | caddy:2-alpine | 8080 | Wildcard reverse proxy |
| bitcoind | btcpayserver/bitcoin:30.2 | — (internal) | Bitcoin regtest node |
| nbxplorer | nicolasdorier/nbxplorer:2.6.1 | — (internal) | Blockchain indexer |
| btcpay | btcpayserver/btcpayserver:2.3.5 | 14142 | http://localhost:14142 (admin UI + API) |
| seed | paperclip-managed:local | 3100 (internal) | N/A |
| op-geth | oplabs op-geth:latest | 8545, 8546 | Base L2 node (JSON-RPC + WebSocket) |
| op-node | oplabs op-node:latest | 9545 (internal) | Base L2 derivation pipe (reads from L1) |

### Caddy routing (local)

| URL Pattern | Destination | Purpose |
|-------------|-------------|---------|
| http://app.runpaperclip.com:8080 | dashboard:3000 | Dashboard UI |
| http://api.runpaperclip.com:8080 | platform:3200 | Platform API |
| http://runpaperclip.com:8080 | redirect → app | Root domain redirect |
| http://*.runpaperclip.com:8080 | platform:3200 | Tenant subdomain → platform auth proxy → container |

### /etc/hosts (REQUIRED for local dev)

```
# Paperclip local dev — real domain, real cookie sharing
127.0.0.1 runpaperclip.com app.runpaperclip.com api.runpaperclip.com
# Add per-instance as you create them:
127.0.0.1 my-org.runpaperclip.com
```

**Why not `*.localhost`?** Browser cookies with `Domain=localhost` do NOT share to `*.localhost` subdomains. Using the real domain with `/etc/hosts` enables `Domain=.runpaperclip.com` cookies to share across `app.`, `api.`, and tenant subdomains — exactly like production.

### Prerequisites

1. **Docker + Docker Compose** — verify with `docker compose version`
2. **All repos cloned as siblings** — `~/paperclip-platform`, `~/paperclip-platform-ui`, `~/platform-ui-core`, `~/paperclip`
3. **Stripe test keys** — copy `sk_test_*` and `whsec_*` from `~/wopr-platform/.env`
5. **Resend API key** — `RESEND_API_KEY` and `RESEND_FROM_EMAIL=noreply@runpaperclip.com`
4. **/etc/hosts entries** — see above

### First-time setup

```bash
cd ~/paperclip-platform

# 1. Create .env.local from the template
cp .env.local.example .env.local

# 2. Fill in secrets
#    - Copy STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET from ~/wopr-platform/.env
#    - Generate auth secret:
openssl rand -hex 32   # paste as BETTER_AUTH_SECRET
openssl rand -hex 32   # paste as PROVISION_SECRET (or keep the default for local)

# 3. Key .env.local settings for runpaperclip.com local dev:
#    PLATFORM_DOMAIN=runpaperclip.com
#    COOKIE_DOMAIN=.runpaperclip.com
#    UI_ORIGIN=http://app.runpaperclip.com:8080
#    BETTER_AUTH_URL=http://api.runpaperclip.com:8080
#    NEXT_PUBLIC_API_URL=http://api.runpaperclip.com:8080
#    NEXT_PUBLIC_BRAND_DOMAIN=runpaperclip.com
#    NEXT_PUBLIC_BRAND_APP_DOMAIN=app.runpaperclip.com:8080
#    PAPERCLIP_IMAGE=tsavo/paperclip-managed:local

# 4. Build the managed Paperclip image (MUST build from ~/paperclip context)
cd ~/paperclip
docker build --provenance=false --sbom=false -f Dockerfile.managed -t tsavo/paperclip-managed:local .
# Push to Docker Hub (fleet's pullImage() pulls on every container create)
docker push tsavo/paperclip-managed:local

# 5. Start the stack
cd ~/paperclip-platform
docker compose -f docker-compose.local.yml up --build
```

### Starting the stack (after first-time setup)

```bash
cd ~/paperclip-platform
docker compose -f docker-compose.local.yml up --build
```

Or use the convenience script which also runs preflight checks:

```bash
bash scripts/local-test.sh
```

### What happens on startup

The platform API (`src/index.ts`) runs this sequence **BEFORE calling `serve()`**:

1. Check `DATABASE_URL` is set (provided by docker-compose)
2. Create Postgres pool + Drizzle DB instance
3. Run platform-core Drizzle migrations (`src/db/migrate.ts`)
4. Wire `DrizzleLedger` → `setCreditLedger()` (double-entry credit ledger)
5. Initialize BetterAuth with `initBetterAuth({ pool, db, onUserCreated })` — `onUserCreated` grants $5 signup credits via `grantSignupCredits()`
6. Run BetterAuth migrations
7. Wire `DrizzleUserRoleRepository` → `setUserRoleRepo()` (admin auth)
8. **Mount inference gateway** (`mountGateway(app, ...)`) — adds `/v1/*` routes, creates `MeterEmitter` + `BudgetChecker` + `DrizzleServiceKeyRepository`
9. Wire tRPC router dependencies (billing, settings, profile, page-context, org)
10. Initialize Stripe SDK if `STRIPE_SECRET_KEY` is set
11. **THEN call `serve()`** — HTTP server starts accepting connections
12. Start ProxyManager → Caddy sync
13. Hydrate proxy routes from running Docker containers
14. Start health monitor

**CRITICAL: steps 1-10 MUST complete before `serve()`.** If `mountGateway()` is called after `serve()`, Hono's lazy matcher build races with incoming requests (Docker healthcheck hits the server during async init) and throws "Can not add a route since the matcher is already built." This was the root cause of the fleet listing bug fixed 2026-03-14.

### Credit system rules (INVARIANT)

- **1 credit = 1 nanodollar** — the atomic internal unit. 10M nanodollars = 1 cent. 1B nanodollars = $1.
- **Integer math only** — never floating point for money.
- **Balanced journal entries** — every mutation posts `sum(debits) === sum(credits)`.
- **API boundary** — `toCentsRounded()` converts nanodollars → cents. Fields named `balance_cents`, `daily_burn_cents` — named for the unit, NEVER `balance_credits`.
- **UI** — divides cents by 100 to show dollars.
- **Idempotent grants** — `grantSignupCredits` uses `referenceId` dedup.
- **Any violation is a bug** — fix immediately.

### Verified E2E Happy Path (2026-03-14)

Tested via curl through Caddy at `runpaperclip.com:8080`:

| Step | Endpoint | Result |
|------|----------|--------|
| Landing page | `GET app.runpaperclip.com:8080` | PASS — Paperclip branding |
| Signup | `POST api.runpaperclip.com:8080/api/auth/sign-up/email` | PASS — user created, `Domain=.runpaperclip.com` cookie |
| $5 credits | `GET .../trpc/billing.creditsBalance` | PASS — `balance_cents: 500` ($5.00) |
| Stripe checkout | `POST .../trpc/billing.creditsCheckout` | PASS — returns `checkout.stripe.com` URL |
| Crypto checkout | `POST .../trpc/billing.checkout` | PASS — deposit address returned, charge stored (`amount_usd_cents=1000`) |
| Payment methods | `GET .../trpc/billing.supportedPaymentMethods` | PASS — returns enabled methods from DB |
| Fleet list | `GET .../trpc/fleet.listInstances` | PASS — `{"bots":[]}` |
| Create instance | `POST .../trpc/fleet.createInstance?batch=1` | PASS — container running, healthy |
| Tenant subdomain | `GET my-org.runpaperclip.com:8080` | PASS — Caddy → platform proxy → container UI |

### Health checks

```bash
# Platform API
curl http://localhost:3200/health

# Dashboard (via Caddy)
curl -I http://app.runpaperclip.com:8080

# Postgres (from host — mapped to 5433)
PGPASSWORD=paperclip-local psql -h localhost -p 5433 -U paperclip -d paperclip_platform -c "SELECT 1;"

# Caddy admin
curl http://localhost:2019/config/

# Seed container
docker compose -f docker-compose.local.yml logs seed

# Inference gateway (requires a valid per-tenant service key)
# Quick smoke test — should return 401 "Unauthorized" (no key)
curl http://localhost:3200/v1/chat/completions
# With a service key (obtained from createInstance response or fleet profile YAML):
curl http://localhost:3200/v1/chat/completions \
  -H "Authorization: Bearer <PAPERCLIP_GATEWAY_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"openrouter/auto","messages":[{"role":"user","content":"ping"}]}'
```

### Common operations

```bash
# View logs for a specific service
docker compose -f docker-compose.local.yml logs -f platform

# Rebuild only the platform API (after code changes)
docker compose -f docker-compose.local.yml up --build platform

# Rebuild only the dashboard (after platform-ui-core changes)
docker compose -f docker-compose.local.yml up --build dashboard

# Reset database (wipe all data, re-run migrations on next start)
docker compose -f docker-compose.local.yml down -v
docker compose -f docker-compose.local.yml up --build

# Rebuild the managed Paperclip image (after ~/paperclip changes)
cd ~/paperclip && docker build --provenance=false --sbom=false -f Dockerfile.managed -t tsavo/paperclip-managed:local .
docker push tsavo/paperclip-managed:local
# Destroy + recreate any running instances to pick up the new image

# Connect to Postgres directly
docker compose -f docker-compose.local.yml exec postgres psql -U paperclip -d paperclip_platform
```

### .env.local required keys

Beyond the obvious Stripe/DB/auth keys, these are easy to miss:

| Key | Source | Why |
|-----|--------|-----|
| `RESEND_API_KEY` | Copy from `~/wopr-platform/.env` | Verification emails. Without it: signup works but logs "RESEND_API_KEY environment variable is required" on every account creation. |
| `RESEND_FROM_EMAIL` | `noreply@runpaperclip.com` | Sender address. Must match a verified domain in Resend. For local dev, the shared WOPR key works. Production needs its own key with `runpaperclip.com` verified. |
| `STRIPE_DEFAULT_PRICE_ID` | Copy from `~/wopr-platform/.env` | Default subscription price. Without it: plan upgrade flow fails. |
| `STRIPE_CREDIT_PRICE_*` (5 vars) | Copy from `~/wopr-platform/.env` | Credit tiers ($5-$100). Without them: `creditOptions` returns empty, checkout unavailable. |
| `EXTRA_ALLOWED_REDIRECT_ORIGINS` | `http://app.runpaperclip.com:8080` | Stripe checkout return URL allowlist. Without it: checkout returns "Invalid redirect URL". |
| `CADDY_ADMIN_URL` | Set empty (`""`) | Prevents ProxyManager from overwriting the Caddyfile wildcard. |
| `UI_ORIGIN` | `http://app.runpaperclip.com:8080,http://localhost:3000,http://127.0.0.1:3000` | CORS allowlist. Missing origins = signup/login fails silently. |

### /etc/hosts — per-instance entries

Each new tenant instance needs a manual `/etc/hosts` entry for local dev:

```bash
# After creating instance "smoke-org":
echo "127.0.0.1 smoke-org.runpaperclip.com" | sudo tee -a /etc/hosts
```

There's no wildcard in `/etc/hosts`. Production uses real DNS (wildcard A record).

### Tenant proxy security

The tenant proxy (`src/proxy/tenant-proxy.ts`) forwards a curated set of headers to upstream containers. **`authorization` is NOT forwarded** — platform auth tokens must never leak to tenant containers. The proxy injects `x-paperclip-user-id` and `x-paperclip-tenant` headers instead.

### Error handling on startup

The init catch block (lines 79-84 of `src/index.ts`) covers DB, auth, AND gateway mounting. If any of these fail, the server starts in degraded mode — billing, auth, and gateway routes may be unavailable. Both the catch block and the `main().catch` handler log full stack traces.

### Review bot gotchas

- **Greptile** has stale WOPR conventions in its custom context. It will flag `_cents` naming as wrong ("should be `_credits`") — **ignore this**. At the API display boundary, fields are named for their unit (cents), not the domain concept. This convention was established explicitly.
- **CodeRabbit** auto-pauses after too many commits. `@coderabbitai review` to trigger manually.
- After force-pushing, all reviewer comments may reference the OLD diff. Verify findings in the actual file before acting.

### WSL2 headless Chrome limitation (test tooling)

Headless Chromium in WSL2 can navigate pages but `fetch()` from JS context fails universally — even with `--host-resolver-rules`. This means:
- Browser smoke tests can verify page structure/routing via screenshots
- Client-side tRPC queries won't fire (dashboard stays in loading state)
- Use **curl** for API flow verification, browser only for visual checks
- This is NOT a product bug — real browsers work fine

### Stripe integration

- **Test keys:** `sk_test_*` from `~/wopr-platform/.env` — no real charges
- **SDK initialized** when `STRIPE_SECRET_KEY` is set in `.env.local`
- **Checkout flow:** `creditsCheckout` tRPC mutation creates a Stripe Checkout Session — returns `checkout.stripe.com` URL
- **Webhook routes:** Stripe webhooks not yet wired — credits can be manually granted via admin API for now
- **Same Stripe account** for WOPR and Paperclip is fine (key is account-scoped, not domain-scoped). Production needs separate price IDs (Paperclip branding) and a separate webhook endpoint (`whsec_*` is endpoint-specific).

### Unified crypto checkout API

**Single endpoint for all crypto payments.** The old per-method endpoints (`cryptoCheckout`, `stablecoinCheckout`, `ethCheckout`) have been replaced by a unified `billing.checkout` tRPC mutation.

**API:**
```typescript
// Client call:
createCheckout(methodId: string, amountUsd: number) → CheckoutResult

// tRPC mutation:
billing.checkout({ methodId: "usdc:base", amountUsd: 50 })
```

**Response shape:**
```typescript
{
  depositAddress: "0x23Edd02...",  // HD-derived deposit address
  displayAmount: "50.000000 USDC", // human-readable amount to send
  token: "USDC",
  chain: "base",
  priceCents?: 350000,            // only for oracle-priced assets (ETH, BTC)
}
```

**Routing by method type:**
| Method type | Example | Price source | Amount logic |
|-------------|---------|-------------|--------------|
| `erc20` | USDC, USDT, DAI | 1:1 USD (stablecoins) | `amountUsd * 10^decimals` raw units |
| `native` (ETH) | ETH on Base | Chainlink on-chain oracle | `centsToNative(amountCents, priceCents, 18)` |
| `native` (BTC) | BTC | Chainlink on-chain oracle | `centsToNative(amountCents, priceCents, 8)` |

**Credit flow (CRITICAL — read this):**
1. User calls `billing.checkout` with `{ methodId, amountUsd }`
2. Platform looks up method in `payment_methods` table (DB-driven, not hardcoded)
3. For oracle-priced assets: fetches price from Chainlink on-chain feed
4. Derives HD deposit address from xpub (per-charge, indexed by charge row ID)
   - **Each deployment uses its own account-level xpub** — see TOPOLOGY.md § Crypto Payment Wallet Hierarchy
   - nemoclaw: `m/44'/60'/0'`, holyship: `m/44'/60'/1'`, paperclip: `m/44'/60'/2'`, wopr: `m/44'/60'/3'`
   - Encrypted master seed: `G:\My Drive\paperclip-wallet.enc` (decrypt: `openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -pass pass:<passphrase> -in paperclip-wallet.enc`)
5. Stores charge in `crypto_charges` table: `amount_usd_cents` (integer, **NOT nanodollars**)
6. Returns deposit address + expected amount to UI (no redirect — address shown inline)
7. Watcher detects incoming transfer (see Watcher Architecture below)
8. Settler calls `Credit.fromCents(charge.amountUsdCents)` — converts cents → nanodollars
9. Double-entry journal entry posted to ledger (balanced debit/credit)
10. Charge marked as credited (idempotency flag prevents double-crediting)

### Payment method registry (admin-managed)

Payment methods are stored in the `payment_methods` DB table — no deploys needed to add or disable tokens.

**Schema:**
| Column | Type | Purpose |
|--------|------|---------|
| `id` | text PK | e.g. `usdc:base`, `eth:base`, `btc:bitcoin` |
| `type` | text | `erc20` or `native` |
| `token` | text | Display name: `USDC`, `ETH`, `BTC` |
| `chain` | text | `base`, `bitcoin`, etc. |
| `contract_address` | text (nullable) | ERC-20 contract. Null for native assets. |
| `decimals` | integer | Token decimals (6 for USDC, 18 for ETH, 8 for BTC) |
| `enabled` | boolean | Toggle without removing |
| `display_order` | integer | UI sort order |
| `confirmations` | integer | Required block confirmations |

**Seeded methods (15 total, 12 of top 30 by market cap):**

| Token | Type | Chain | Contract |
|-------|------|-------|----------|
| USDC | erc20 | base | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| USDT | erc20 | base | `0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2` |
| DAI | erc20 | base | `0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb` |
| WETH | erc20 | base | `0x4200000000000000000000000000000000000006` |
| cbBTC | erc20 | base | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` |
| AERO | erc20 | base | `0x940181a94A35A4569E4529A3CDfB74e38FD98631` |
| LINK | erc20 | base | `0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196` |
| UNI | erc20 | base | `0xc3De830EA07524a0761646a6a4e4be0e114a3C83` |
| PEPE | erc20 | base | `0xb4fBF271143F4FBf7B91A5ded31805e42b2208d6` |
| SHIB | erc20 | base | `0x2dE81E7E4cE120C85E1e846C326004A87cC0B168` |
| RENDER | erc20 | base | `0x5765F016ECb0e498EaF996085e09907B9e8045c0` |
| ETH | native | base | — |
| BTC | native | bitcoin | — |
| LTC | native | litecoin | — |
| DOGE | native | dogecoin | — |

**Admin API (tRPC):**
- `billing.adminListPaymentMethods` — list all methods (enabled + disabled)
- `billing.adminUpsertPaymentMethod` — add or update a method
- `billing.adminTogglePaymentMethod` — enable/disable by ID

**Admin UI:** `/admin/payment-methods` page in platform-ui-core. Table view with enable/disable toggles and add-new form.

**Public API:**
- `billing.supportedPaymentMethods` — list only enabled methods (used by checkout UI)

### Chainlink on-chain price oracle

**No API keys. No vendor accounts.** Reads `latestRoundData()` from Chainlink aggregator contracts via `eth_call` on Base.

**Feeds (Base mainnet):**
| Pair | Contract | Decimals |
|------|----------|----------|
| ETH/USD | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` | 8 |
| BTC/USD | `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F` | 8 |

**Conversion:** `answer / 10^6` = USD cents (integer). Staleness guard: rejects prices older than 1 hour.

**Conversion functions (platform-core):**
- `centsToNative(amountCents, priceCents, decimals)` → BigInt raw amount
- `nativeToCents(rawAmount, priceCents, decimals)` → integer cents

### Watcher architecture

Three watcher types poll their respective chains for incoming payments. All use DB-persisted cursors — no in-memory state survives restart.

| Watcher | Class | What it watches | Cursor |
|---------|-------|----------------|--------|
| EVM (ERC-20) | `EvmWatcher` | `eth_getLogs` for ERC-20 Transfer events | Block number in `watcher_cursors` |
| ETH (native) | `EthWatcher` | `eth_getBlockByNumber` scanning tx `to` + `value` | Block number in `watcher_cursors` |
| BTC | `BtcWatcher` | bitcoind `listreceivedbyaddress` RPC | txid dedup in `watcher_processed` |

**Cursor persistence tables:**
- `watcher_cursors`: `(watcher_id TEXT PK, cursor TEXT, updated_at)` — stores block number/hash per watcher
- `watcher_processed`: `(watcher_id TEXT, tx_id TEXT, PK(watcher_id, tx_id))` — BTC txid dedup (prevents double-credit on restart)

**EVM watcher saves cursor per-block** (groups logs by block number, checkpoints after each block). If it crashes mid-range, it re-scans only from the last checkpointed block.

**Settler pattern:** All three settlers share the same idempotency model:
1. Look up charge by deposit address (lowercased) → if not found, return `status: "Invalid"`
2. Update charge status to "Settled"
3. Check `creditRef` uniqueness (e.g. `evm:base:txHash:logIndex`, `eth:base:txHash`, `btc:txid`)
4. Underpayment check — 2% tolerance for oracle price drift (native assets only)
5. Call `Credit.fromCents()` → nanodollars → double-entry journal
6. Mark charge as credited (`creditedAt` timestamp)

**BTC watcher uses `importdescriptors`** (bitcoind v24+) to add watch-only addresses. Falls back to legacy `importaddress` for older versions. Creates a `paperclip-watcher` watch-only descriptor wallet on first startup.

**Error isolation:** One unsupported token (e.g. WETH without proper watcher mapping) does NOT block other watchers — `createWatcher` failures are caught per-method and logged.

### Crypto shipping gaps — ALL CLOSED (2026-03-15)

All gaps identified on 2026-03-14 are resolved:
- ~~Watcher startup loop~~ → `initCryptoWatchers()` in `paperclip-platform/src/crypto/init-watchers.ts`
- ~~Settler wiring~~ → `onPayment` callbacks wire to `settleEvmPayment`/`settleEthPayment`/`settleBtcPayment`
- ~~Payment status polling~~ → `billing.chargeStatus` tRPC query + UI polling in `buy-crypto-credits-panel.tsx`
- ~~Address case mismatch~~ → `createStablecoinCharge` lowercases deposit addresses (platform-core 1.35.0)
- ~~ETH referenceId mismatch~~ → unified-checkout uses `${method.type}:chain:addr` consistently (1.35.2)
- ~~Oracle price drift rejection~~ → 2% underpayment tolerance in ETH+BTC settlers (1.35.2)
- ~~UTXO network hardcoded~~ → auto-detect from `getblockchaininfo` RPC (1.36.0)
- ~~`importaddress` removed in bitcoind v30~~ → `importdescriptors` with fallback (1.36.1)

### BTCPay Server (REPLACED — reference only)

> **BTCPay has been replaced by native watchers.** The native BTC watcher talks to bitcoind directly — eliminates nbxplorer and btcpayserver containers (3 → 1). Same xpub, same mnemonic, same ledger. BTCPay docs below are kept for historical reference only.
  -H "Authorization: token <apiKey>" \
  -d '{"name":"Paperclip Credits"}'
# → save id from response as BTCPAY_STORE_ID

# 4. Generate regtest wallet (needs admin basic auth for hot wallet)
curl -s -X POST "http://localhost:14142/api/v1/stores/<storeId>/payment-methods/onchain/BTC/generate" \
  -H "Content-Type: application/json" \
  -u "admin@runpaperclip.com:<password>" \
  -d '{"savePrivateKeys":true,"wordCount":12}'

# 5. Register webhook (points to platform's docker internal URL)
curl -s -X POST "http://localhost:14142/api/v1/stores/<storeId>/webhooks" \
  -H "Content-Type: application/json" \
  -H "Authorization: token <apiKey>" \
  -d '{"url":"http://platform:3200/api/webhooks/crypto","authorizedEvents":{"everything":false,"specificEvents":["InvoiceSettled","InvoiceProcessing","InvoiceExpired","InvoiceInvalid"]}}'
# → save secret from response as BTCPAY_WEBHOOK_SECRET

# 6. Add to .env.local
echo 'BTCPAY_API_KEY=<apiKey>' >> .env.local
echo 'BTCPAY_STORE_ID=<storeId>' >> .env.local
echo 'BTCPAY_WEBHOOK_SECRET=<secret>' >> .env.local

# 7. Recreate platform to pick up new env vars
docker compose -f docker-compose.local.yml up -d --force-recreate platform
# Look for: "BTCPay crypto payments configured (webhook + checkout)"
```

**BTCPay Docker gotchas (hard-won, do NOT ignore):**

- **bitcoind regtest ports are 18443 (RPC) and 18444 (P2P)** — the btcpayserver/docker repo uses non-standard ports (43782/39388) in their compose fragments. The raw `btcpayserver/bitcoin` image uses Bitcoin Core defaults. If nbxplorer can't connect, check the ports.
- **nbxplorer binds to `127.0.0.1` by default** — set `NBXPLORER_BIND=0.0.0.0:32838` so other containers can reach it.
- **BTCPay env var is `BTCPAY_BTCEXPLORERURL`** — NOT `BTCPAY_EXPLORERURL`. The chain prefix matters. Without it, BTCPay tries `127.0.0.1:24446` (the regtest default).
- **BTCPay listens on port 23002** — NOT 49392. Set `BTCPAY_BIND=0.0.0.0:23002` and map `14142:23002` in compose.
- **`environment:` overrides `env_file:`** — if you set `BTCPAY_API_KEY: ${BTCPAY_API_KEY:-}` in compose `environment:`, it reads from the shell env (empty), overriding `.env.local`. Let `env_file:` handle it. Only override `BTCPAY_BASE_URL` in compose (docker internal URL vs localhost).
- **Postgres initdb scripts run only on first startup** — `scripts/create-multiple-databases.sh` creates `nbxplorer` and `btcpayserver` databases. If postgres volume already exists from before, wipe it: `docker volume rm paperclip-platform_postgres-data`.
- **Hot wallet generation needs admin basic auth** — API key auth gets "This instance forbids non-admins from having a hot wallet". Use `-u admin@runpaperclip.com:<password>` instead.
- **nbxplorer auto-mines 101 blocks on regtest** — first startup takes ~10 seconds while it mines blocks and syncs. BTCPay will show `synchronized: false` until nbxplorer is ready.
- **BTCPay checkout URL is the internal docker URL** — `http://btcpay:23002/i/<invoiceId>` is only reachable from inside the docker network. For local dev, access the checkout page at `http://localhost:14142/i/<invoiceId>`. Production needs a public BTCPay URL.

**Production BTCPay deployment:**

- Self-hosted on the same DO droplet or a separate one
- Connect a real BTC wallet (xpub key, NOT hot wallet)
- Register webhook to `https://api.runpaperclip.com/api/webhooks/crypto`
- `BTCPAY_BASE_URL` points to the public BTCPay URL
- No Bitcoin Core needed if using a pruned node or external source
- Zero transaction fees (you own the server)

### Self-hosted Base node (EVM payments — ERC-20 + native ETH)

**Architecture decision:** We run our own Base L2 node from day one. No Alchemy, no Infura, no API keys, no rate limits, no vendor to rip out later. Same philosophy as the native BTC watcher — we own the stack.

**What it does:** Two watchers poll `op-geth`: the EVM watcher scans `eth_getLogs` for ERC-20 Transfer events (USDC, USDT, DAI — any enabled ERC-20 from the payment method registry). The ETH watcher scans `eth_getBlockByNumber` for native ETH transfers to deposit addresses. Both credit the double-entry ledger via `Credit.fromCents()`.

**Stack:** op-geth (Base execution client) + op-node (Base derivation pipe, reads from L1 Ethereum)

**Docker compose services:**

```yaml
op-geth:
  image: us-docker.pkg.dev/oplabs-tools-artifacts/images/op-geth:latest
  volumes:
    - base-geth-data:/data
  ports:
    - "8545:8545"
    - "8546:8546"
  command: >
    --datadir=/data
    --http --http.addr=0.0.0.0 --http.port=8545
    --http.api=eth,net,web3
    --ws --ws.addr=0.0.0.0 --ws.port=8546
    --ws.api=eth,net,web3
    --rollup.sequencerhttp=https://mainnet-sequencer.base.org
    --rollup.historicalrpc=https://mainnet.base.org
    --syncmode=snap
  restart: unless-stopped

op-node:
  image: us-docker.pkg.dev/oplabs-tools-artifacts/images/op-node:latest
  depends_on: [op-geth]
  command: >
    --l1=ws://geth:8546
    --l2=http://op-geth:8551
    --network=base-mainnet
    --rpc.addr=0.0.0.0 --rpc.port=9545
  restart: unless-stopped
```

**Disk requirements:** ~50GB for Base state, grows slowly. Much lighter than Ethereum mainnet (~1TB+).

**Initial sync:** 2-6 hours depending on disk speed. After that, stays current within seconds.

**Check sync status:**

```bash
curl -s http://localhost:8545 -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_syncing","id":1}' | jq .result
# Returns false when fully synced, or sync progress object
```

**Check latest block (compare with https://basescan.org):**

```bash
curl -s http://localhost:8545 -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}' | jq -r '.result' | xargs printf "%d\n"
```

**L1 dependency:** op-node needs an L1 Ethereum RPC endpoint for the derivation pipe. For production, this should be our own geth instance. For initial deployment, a public L1 endpoint or Alchemy free tier is acceptable as a bootstrap — the L1 connection is read-only and low-volume (block headers only, not full transaction data).

**EVM env vars (in platform `.env.local`):**

| Key | Value | Purpose |
|-----|-------|---------|
| `EVM_RPC_BASE` | `http://op-geth:8545` | Base node RPC (docker internal) |
| `EVM_XPUB` | Extended public key | HD wallet for deposit address derivation (xpub, NOT xprv) |

**Troubleshooting:**
- **op-geth falls behind:** restart the container, it will catch up from peers
- **Disk full:** prune with `--gcmode=archive` disabled or increase disk
- **op-node can't connect to L1:** check L1 RPC endpoint is reachable and not rate-limited
- **No Transfer events detected:** verify USDC contract address matches Base mainnet (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`), check watcher `fromBlock` cursor

**For local dev / CI:** Use Anvil (Foundry) with a Base mainnet fork instead of running the full node stack. Lighter, faster, no sync required.

**GHCR auth required for Docker:** The Anvil image is on `ghcr.io/foundry-rs/foundry`. GHCR denies anonymous pulls even for public images. Login first:

```bash
gh auth token | docker login ghcr.io -u tsavo --password-stdin
```

This only needs to be done once — Docker caches the credential in `~/.docker/config.json`.

**Install Foundry (for local use without Docker):**

```bash
curl -L https://foundry.paradigm.xyz | bash
~/.foundry/bin/foundryup
```

**Run Anvil (Base fork):**

```bash
~/.foundry/bin/anvil --fork-url https://mainnet.base.org --host 0.0.0.0 --port 8545 --chain-id 8453
```

Or via docker-compose (paperclip-platform already has this service defined — but note `ghcr.io/foundry-rs/foundry` requires auth. Use local Foundry install instead).

**Test stablecoin payment on Anvil:**

```bash
CAST=~/.foundry/bin/cast
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
DEPOSIT=0x23Edd02dDeec8396319722c8fAd47F044310D254  # our index-0 address
WHALE=0x3304E22DDaa22bCdC5fCa2269b418046aE7b566A    # has ~951 USDC on Base

# Impersonate whale, send 10 USDC to deposit
$CAST rpc anvil_impersonateAccount $WHALE --rpc-url http://localhost:8545
$CAST send $USDC "transfer(address,uint256)(bool)" $DEPOSIT 10000000 --from $WHALE --rpc-url http://localhost:8545 --unlocked
$CAST rpc anvil_stopImpersonatingAccount $WHALE --rpc-url http://localhost:8545

# Verify
$CAST call $USDC "balanceOf(address)(uint256)" $DEPOSIT --rpc-url http://localhost:8545
# Expected: 10000000 (10 USDC)
```

**E2E test script:** `wopr-ops/scripts/test-payments-e2e.sh` (tests both BTC regtest + stablecoin Anvil fork)

### E2E crypto payment testing (verified 2026-03-15)

**All three chains verified end-to-end:** USDC (ERC-20), ETH (native), BTC (regtest).

**Automated test script:**

```bash
# Run all chains
bash scripts/e2e-crypto-test.sh

# Run single chain
bash scripts/e2e-crypto-test.sh --chain usdc
bash scripts/e2e-crypto-test.sh --chain eth
bash scripts/e2e-crypto-test.sh --chain btc
```

The script handles: auth signup → checkout → simulate payment → wait for watcher → verify charge credited.

**Prerequisites:**

1. `docker compose -f docker-compose.local.yml up --build` (full stack running)
2. `/etc/hosts` has `127.0.0.1 runpaperclip.com app.runpaperclip.com api.runpaperclip.com`
3. Disable unsupported ERC-20 tokens (WETH, cbBTC, etc.) if they error during watcher refresh

**Critical setup steps (the script does NOT do these):**

1. **Seed watcher cursors at current Anvil block** — watchers start from cursor 0 but the Base fork is at block 43M+. Querying `eth_getLogs` across 43M blocks hits the 10k range limit.

```sql
-- Get current block: curl -sf http://localhost:8545 -X POST -H 'Content-Type: application/json' \
--   -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq -r '.result'
-- Convert hex to decimal: python3 -c "print(int('0xHEX', 16))"
DELETE FROM watcher_cursors;
INSERT INTO watcher_cursors (watcher_id, cursor_block, updated_at) VALUES
  ('evm:base:USDC', <BLOCK-1>, NOW()),
  ('evm:base:USDT', <BLOCK-1>, NOW()),
  ('evm:base:DAI', <BLOCK-1>, NOW()),
  ('eth:base', <BLOCK-1>, NOW());
```

2. **Restart Anvil for fresh Chainlink feeds** — after ~1hr the BTC/USD feed goes stale (>3600s). Restart Anvil to get a fresh fork: `docker compose -f docker-compose.local.yml up -d --force-recreate --no-deps anvil`

3. **Restart platform after cursor seed** — watchers read cursors on startup, not dynamically.

**How each chain is tested:**

| Chain | Simulate payment | How |
|-------|-----------------|-----|
| USDC | `anvil_setStorageAt` to mint, then `eth_sendTransaction` transfer | Auto-discovers USDC balance storage slot (tried slots 0-51), sets 1000 USDC to Anvil test account |
| ETH | `eth_sendTransaction` from Anvil test account 0 | Anvil accounts have 10000 ETH each |
| BTC | `createwallet` + `generatetoaddress` + `sendtoaddress` on regtest | Creates e2e-test wallet, mines 101 blocks for maturity, sends exact BTC amount |

**Gotchas:**

- **USDC storage slot varies by fork block** — the script auto-discovers it by trying slots 0-51
- **Anvil fork loses config on restart** — verify with `anvil_nodeInfo` → `forkConfig.forkUrl` should not be null
- **BTC needs regtest addresses** — watcher auto-detects network from `getblockchaininfo` and derives `bcrt1q...` addresses
- **BTC watcher creates `paperclip-watcher` wallet** — watch-only descriptor wallet for `importdescriptors` (bitcoind v30+ removed `importaddress`)
- **Auth rate limits** — script creates a fresh user each run to avoid rate limits on signin
- **`eth_getLogs` 10k range limit** — if cursors aren't seeded near current block, EVM watchers fail with `413 eth_getLogs is limited to a 10,000 range`

### Unified HD wallet (BTC + ERC-20 + ETH)

**One mnemonic, two derivation paths.** A single 24-word BIP-39 mnemonic backs up BTC, ERC-20 (stablecoins), and native ETH wallets. Server has only xpubs (public keys). Private keys never touch the server.

**Derivation paths:**

| Asset | BIP-44 Path | xpub env var | Where used |
|-------|-------------|-------------|------------|
| BTC | `m/44'/0'/0'` | BTCPay store config / native BTC watcher | BTC deposit addresses |
| EVM (ERC-20 + ETH) | `m/44'/60'/0'` | `EVM_XPUB` | EVM + ETH watcher deposit addresses (shared path) |

**Current xpubs:**
- **BTC**: `xpub6BuGg4sQuvoA7q545ZoStxU7QP24qmZNMo39FxRjLwbBCQ77sjsHGcpxeNVboGZQNdbeANHVK1GJx7ECMfjohkpLqoGLVP9SCQM4bR1F5vh`
- **EVM**: `xpub6DSVkV7mgEZrnBEmZEq412Cx9sYYZtFvGSb6W9bRDDSikYdpmUiJoNeuechuir63ZjdHQuWBLwchQQnh2GD6DJP6bPKUa1bey1X6XvH9jvM`
- First EVM deposit address (index 0): `0x23Edd02dDeec8396319722c8fAd47F044310D254`

**BTCPay xpub setup (replace hot wallet with our xpub):**

```bash
# After BTCPay is running and store is created, set the derivation scheme to our xpub:
curl -s -X PUT "http://localhost:14142/api/v1/stores/<storeId>/payment-methods/onchain/BTC" \
  -H "Content-Type: application/json" \
  -u "admin@runpaperclip.com:<password>" \
  -d '{"derivationScheme":"xpub6BuGg4sQuvoA7q545ZoStxU7QP24qmZNMo39FxRjLwbBCQ77sjsHGcpxeNVboGZQNdbeANHVK1GJx7ECMfjohkpLqoGLVP9SCQM4bR1F5vh"}'
```

This replaces the hot wallet with our xpub — BTCPay derives deposit addresses from it but cannot sign (no private keys). Same security model as the EVM watcher.

**Recovery protocol:**

1. Encrypted mnemonic backup: `G:\My Drive\paperclip-wallet.enc`
2. Decrypt: `openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -pass pass:<passphrase> -in paperclip-wallet.enc`
3. Import the 24-word mnemonic into any BIP-39 compatible wallet (MetaMask, Electrum, Rabby, etc.)
4. BTC funds: derivation path `m/44'/0'/0'` — use Electrum or any BIP-44 BTC wallet
5. EVM funds (stablecoins + ETH): derivation path `m/44'/60'/0'` — use MetaMask/Rabby
6. Re-derive xpubs if needed:
   - BTC: `HDKey.fromMasterSeed(mnemonicToSeedSync(mnemonic)).derive("m/44'/0'/0'").publicExtendedKey`
   - EVM: `HDKey.fromMasterSeed(mnemonicToSeedSync(mnemonic)).derive("m/44'/60'/0'").publicExtendedKey`

**Treasury addresses (sweep destination):**

Derived from the same mnemonic on the internal chain (BIP-44 chain index 1), separate from deposit addresses (external chain, index 0). No collision.

| Asset | Path | Address |
|-------|------|---------|
| EVM (ERC-20 + ETH) | `m/44'/60'/0'/1/0` | `0x1965410B83e59490f88d63196dE2B6C2DED121a2` |
| BTC | First internal address from xpub | (derived from the BTC xpub) |

> **IMPORTANT: Address `0x6cEff0F47d5d918e50Fd40f7611f673a13edA06d` was previously listed here.
> That address was derived from COMPRESSED public keys (buggy, pre platform-core 1.60.0).
> The correct treasury is `0x1965...` derived via `privateKeyToAccount` (uncompressed).
> Any funds sent to the old address are unrecoverable.**

**Sweep protocol:**

EVM sweep script: `wopr-ops/scripts/sweep-stablecoins.ts` (handles ETH + all ERC-20s on any EVM chain)

The script fetches token config from the chain server — no hardcoded contracts. Add a new token to the chain server → it's automatically swept.

```bash
# Dry run (default — scans balances, no transactions):
openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d \
  -pass pass:<passphrase> -in "/mnt/g/My Drive/paperclip-wallet.enc" \
  | CRYPTO_SERVICE_URL=http://167.71.118.221:3100 \
    CRYPTO_SERVICE_KEY=sk-chain-2026 \
    EVM_RPC=https://mainnet.base.org \
    EVM_CHAIN=base \
    npx tsx scripts/sweep-stablecoins.ts

# Real sweep (broadcasts transactions):
openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d \
  -pass pass:<passphrase> -in "/mnt/g/My Drive/paperclip-wallet.enc" \
  | CRYPTO_SERVICE_URL=http://167.71.118.221:3100 \
    CRYPTO_SERVICE_KEY=sk-chain-2026 \
    EVM_RPC=https://mainnet.base.org \
    EVM_CHAIN=base \
    SWEEP_DRY_RUN=false \
    npx tsx scripts/sweep-stablecoins.ts

# Sepolia testnet sweep:
# EVM_RPC=https://ethereum-sepolia-rpc.publicnode.com EVM_CHAIN=sepolia
```

**Required env vars:**
| Var | Description |
|-----|-------------|
| `CRYPTO_SERVICE_URL` | Chain server URL (e.g. `http://167.71.118.221:3100`) |
| `CRYPTO_SERVICE_KEY` | Chain server service key (Bearer auth) |
| `EVM_RPC` | RPC endpoint for the chain to sweep |
| `EVM_CHAIN` | Chain ID matching chain server (e.g. `base`, `sepolia`) |
| `SWEEP_DRY_RUN` | Set to `false` to broadcast (default: `true`) |
| `MAX_ADDRESSES` | Deposit addresses to scan (default: `200`) |

**3-phase sweep (solves chicken-and-egg gas problem):**
1. **Phase 1 — Sweep ETH deposits** (self-funded gas). Native ETH transfers cost 21k gas. The deposit address pays its own gas from its ETH balance. No treasury funding needed.
2. **Phase 2 — Fund gas from treasury.** Treasury now has ETH from phase 1. Script tops up each ERC-20 deposit address with just enough ETH for one `transfer()` call (~65k gas, ~$0.004 on Base L2).
3. **Phase 3 — Sweep all ERC-20s** (USDC, USDT, DAI, LINK, etc.). Each deposit address now has gas. Script signs `transfer()` from each deposit to treasury.

**Why ETH-first:** If the treasury starts empty (no ETH for gas), you can't fund ERC-20 deposit addresses. But ETH deposits self-fund their own sweep. Sweeping ETH first fills the treasury, then you can fund gas for ERC-20 sweeps.

**Gas costs on Base L2:** ~$0.0013 per ETH transfer, ~$0.004 per ERC-20 transfer. 200 addresses ≈ $0.27 total. Gas price volatility is not a real failure mode on L2 (~0.01 gwei).

**BTC sweep:** Manual via wallet software (Electrum). Import xpub, sweep all to cold storage.

**After sweep:** move funds from treasury to exchange or cold storage as needed.

**E2E verified (2026-03-24, Sepolia testnet):**
```
Checkout → deposit 0xA8eD...766e (index 11, 1.1 LINK)
Chain server → detected → confirmed (1/1) → webhook delivered
Paperclip → webhook received → charge settled → $10 credited
Sweep script → found deposit → funded gas → swept 1.1 LINK to treasury
Treasury → sent 1.1 LINK to 0x...dEaD (tx 0x4e859...347a0, success)
```
Full chain of custody: pay → detect → credit → sweep → spend. Bulletproof.

**Known issues:**
- `polygon-rpc.com` returns 401 — polygon payment methods disabled. Chain server crashes if any watcher RPC fails auth (needs resilient startup).
- Old deposit addresses (pre platform-core PR #144) used compressed-key derivation and are unrecoverable.
- Product config requires DB seed row (`INSERT INTO products ...`) — not yet in migrations.

**Critical bug fixed (platform-core PR #144, 2026-03-24):**

EVM deposit addresses were derived from SEC1 compressed public keys. `viem.publicKeyToAddress()` expects uncompressed (65 bytes, `04` prefix) but received compressed (33 bytes, `02`/`03` prefix). It strips the first byte and keccak256-hashes the rest — for compressed keys this hashes 32 bytes (just X coordinate) instead of 64 bytes (X+Y), producing a completely different address. No private key can sign for a compressed-key-derived address because Ethereum's ECDSA recovery always uses uncompressed public keys. Funds sent to these addresses are **permanently unrecoverable**.

Fix: decompress via `secp256k1.Point.fromHex().toBytes(false)` in `address-gen.ts` before passing to `publicKeyToAddress`. All deposit addresses created after this fix are standard Ethereum addresses that can be swept.

**Security rules:**
- xpubs are public — safe in env vars, repos, logs
- Mnemonic is the master key — NEVER on the server, NEVER in a repo, NEVER in plaintext on disk
- If the server is compromised, funds in deposit addresses are safe (attacker can see addresses but can't sign)
- If the mnemonic is compromised, ALL funds in ALL derived addresses (BTC + ERC-20 + ETH) are at risk — sweep immediately

### Differences from WOPR local dev

| Area | WOPR (Approach B flat) | Paperclip |
|------|----------------------|-----------|
| API port | 3100 | 3200 |
| Dashboard | wopr-platform-ui | platform-ui-core (brand-agnostic) |
| Compose file | wopr-ops/docker-compose.local.yml | paperclip-platform/docker-compose.local.yml |
| Caddy port | 80 | 8080 |
| Domain | localhost / api.localhost | app.localhost:8080 / *.localhost:8080 |
| GPU services | llama, chatterbox, whisper, qwen | None (not needed for Paperclip) |
| DB name | wopr_platform | paperclip_platform |
| DB user | wopr | paperclip |
| DB password | from .env.local | paperclip-local (default) |
| Shared library | @wopr-network/platform-core | Same — shared |
| Branding | Hardcoded WOPR | NEXT_PUBLIC_BRAND_* env vars |

### Paperclip local dev gotchas

- **CRITICAL: CSP `upgrade-insecure-requests` breaks all CSS/JS/API in Docker** — The dashboard Dockerfile sets `NODE_ENV=production` (correct for Next.js optimizations), but the middleware in `platform-ui-core/src/proxy.ts` used `NODE_ENV === "production"` to decide whether to add `upgrade-insecure-requests` to the CSP header. In Docker over HTTP (local dev), this tells the browser to silently upgrade ALL subresource fetches to HTTPS — which doesn't exist. CSS won't load, JS won't execute, API calls fail, page renders as unstyled HTML. **Fixed in platform-ui-core PR #18** — now checks `request.url` protocol instead of `NODE_ENV`. If the dashboard looks completely unstyled, this is the first thing to check.
- **Headless Chrome `fetch()` is broken in WSL2** — Chromium's async DNS resolver bypasses `/etc/hosts`. Page navigation works (browser process), but `fetch()` from JS context fails (renderer process). This affects ALL headless Chrome: Playwright, chromedp, alpine-chrome, Docker containers. NOT a production bug — real browsers work fine. Workaround: use dnsmasq for DNS resolution or test with Windows Chrome via `--remote-debugging-port=9222` + `--user-data-dir=C:\temp\chrome-debug` and connect with `agent-browser --cdp 9222`.
- **Windows Chrome for smoke testing** — Kill all Chrome instances first, launch with `--remote-debugging-port=9222 --user-data-dir=C:\temp\chrome-debug`, connect from WSL2 with `agent-browser --cdp 9222`. Mirrored networking mode means WSL2 can reach Windows localhost. Port must not be taken by Docker containers (stop the `chrome` compose service first).
- **`docker compose restart` does not re-read env_file** — use `--force-recreate` or `down && up` after `.env.local` changes.
- **Dashboard builds from `../platform-ui-core`** — the compose file uses a relative context path. The platform-ui-core repo must be cloned at `~/platform-ui-core` (sibling to `~/paperclip-platform`).
- **`NEXT_PUBLIC_*` vars are baked at build time** — changing brand vars requires `docker compose up --build dashboard`, not just a restart.
- **Postgres mapped to port 5433** — not 5432, to avoid conflicts with any host Postgres. Connect with `-p 5433`.
- **BetterAuth migrations run on every startup** — this is idempotent and safe. Drizzle migrations also run on every startup.
- **Stripe without webhook routes** — the Stripe SDK initializes but no webhook endpoint is wired yet. Use the admin API to manually grant credits for testing billing flows.
- **Seed container** — the `wopr-seed` container runs a Paperclip instance for testing the provision flow. It needs the managed image built first (`paperclip-managed:local`).
- **`*.localhost` subdomains** — Chrome/Firefox resolve these to 127.0.0.1 natively. Safari does NOT. Use Chrome or Firefox for local testing.
- **CRITICAL: Build context must be `~/paperclip`, NOT `~/paperclip-platform`** — the Dockerfile.managed lives in `~/paperclip/` and `COPY . .` copies the build context. If you `cd ~/paperclip-platform && docker build -f ~/paperclip/Dockerfile.managed .`, the context is the platform repo, not the paperclip app repo. The build will succeed (wrong source gets compiled) but the resulting image will have stale code. Always `cd ~/paperclip` first.
- **FleetManager pulls image from Docker Hub on every `create()`** — `@wopr-network/platform-core`'s `FleetManager.pullImage()` calls `docker.pull()` before creating the container. For `tsavo/paperclip-managed:local`, this pulls from Docker Hub, overwriting any local-only build. You MUST `docker push` after every rebuild. If you skip the push, new instances will use the old Docker Hub image.
- **Docker buildx attestation manifests** — buildx generates OCI manifest lists with provenance attestations. Use `--provenance=false --sbom=false` to produce a flat image that `docker push` sends correctly. Without these flags, `docker push` may push only the attestation manifest, leaving the real amd64 image unchanged on Docker Hub.
- **`tsc -b` in UI build compiles server as project reference** — `Dockerfile.managed` builds the UI first (`pnpm --filter @paperclipai/ui build` which runs `tsc -b`), then the server. The UI's `tsc -b` compiles the server as a referenced project, producing `server/dist/`. The Dockerfile has `rm -rf server/dist` before the server build to ensure fresh compilation. Without this, the server's `tsc` sees the stale `server/dist/` and may skip recompilation.
- **`CADDY_ADMIN_URL` must be empty in `.env.local`** — the platform's ProxyManager POSTs to Caddy's `/load` endpoint on startup, which overwrites the Caddyfile wildcard routing with a dynamic HTTPS config (port 443). This kills the HTTP port 8080 listener. The compose `environment:` block must NOT set `CADDY_ADMIN_URL` — let `.env.local`'s empty value take effect. If Caddy stops accepting connections on port 8080, this is probably why.
- **Stale fleet profile YAML files** — fleet profiles are stored as YAML files in `/data/fleet/` inside the platform container. Failed or destroyed instances may leave stale profiles. When hitting "Instance limit reached" (max 5 per tenant), check for stale profiles: `docker exec paperclip-platform-platform-1 ls /data/fleet/`. Remove stale ones manually. Gateway service keys are now DB-backed and independent of these YAML files.
- **Credit ledger blocks instance creation** — new users start with 0 credits. If `DATABASE_URL` is configured (which it is in the compose stack), the credit ledger is active and blocks provisioning with "Insufficient credits". Grant credits via SQL (units are NANODOLLARS — 10B ≈ $10): `INSERT INTO credit_balances (tenant_id, balance_credits, last_updated) VALUES ('<tenant_id>', 10000000000, now()::text) ON CONFLICT (tenant_id) DO UPDATE SET balance_credits = 10000000000;`
- **BetterAuth password hash format** — BetterAuth uses `{hexSalt}:{hexKey}` format (scrypt N=16384, r=16, p=1, dkLen=64 via `@noble/hashes`). NOT the `$s0$` format from Node's `scryptSync`. The provision adapter uses `hashPassword` from `better-auth/crypto` directly. Default password for provisioned admin users = their email address.
- **No BYOK** — hosted Paperclip instances use the platform's metered inference gateway. Users don't bring their own API keys. The onboarding wizard's adapter/key configuration step is skipped entirely in hosted mode (`hostedMode: true` in health response → UI hides wizard).
- **`OPENROUTER_API_KEY` required for gateway** — without this env var, the gateway is silently disabled on startup (log: "OPENROUTER_API_KEY not set — inference gateway disabled"). No `/v1/*` routes will be mounted. Get a key at https://openrouter.ai/settings/keys.
- **Per-instance service keys are DB-backed** — each provisioned instance gets a unique gateway key (`PAPERCLIP_GATEWAY_KEY` in the container env). Generated by `DrizzleServiceKeyRepository.generate()` during `fleet.createInstance`, stored as a SHA-256 hash in the `gateway_service_keys` table. Keys survive process restarts — no hydration step needed. Revoked automatically on `fleet.removeInstance` (soft revocation via `revoked_at` timestamp).
- **`lru-cache` dependency required** — platform-core's `BudgetChecker` imports `lru-cache`. If missing from `paperclip-platform/package.json`, you get `Cannot find module 'lru-cache'` at startup. Already added; don't remove it.
- **MeterEmitter WAL/DLQ paths** — the `MeterEmitter` writes WAL (write-ahead log) and DLQ (dead-letter queue) files. Paths are `${FLEET_DATA_DIR}/meter-wal` and `${FLEET_DATA_DIR}/meter-dlq`. If the container user lacks write access to these paths, startup fails with `EACCES: permission denied, mkdir './data'`. The docker-compose volume must map `/data/fleet` to a writable host directory.
- **`@sentry/node` required by platform-core 1.28+** — platform-core's observability module imports `@sentry/node`. If missing from `paperclip-platform/package.json`, startup crashes with `ERR_MODULE_NOT_FOUND`. Add it: `pnpm add @sentry/node`.
- **Anvil fork mode hangs on `eth_getLogs` with topic filters from Docker** — when Anvil forks Base mainnet, `eth_getLogs` queries go upstream to Base RPC for historical blocks. From inside Docker this hangs indefinitely. For E2E testing, remove `--fork-url` from the Anvil service and deploy a mock ERC-20 instead.
- **Host `anvil` process blocks compose port 8545** — if you previously ran `anvil` directly (outside Docker), it holds port 8545 and prevents the compose Anvil from publishing its port. The compose container starts but with no port mapping (`8545/tcp` without `0.0.0.0:8545->`). Kill the host process: `kill $(lsof -ti:8545)`, then `docker compose up -d --force-recreate anvil`.
- **`forge create` needs `--broadcast` flag** — without `--broadcast`, forge does a dry run and logs "Dry run enabled, not broadcasting transaction". The contract is NOT deployed. Always pass `--broadcast`.
- **Deposit addresses are stored lowercase** — `createStablecoinCharge` lowercases the address before INSERT. The settler looks up by lowercased address (from EVM log topics). If you have checksummed addresses in the DB from before this fix, run: `UPDATE crypto_charges SET deposit_address = LOWER(deposit_address) WHERE deposit_address IS NOT NULL`.
- **Migration journal timestamps must be monotonically increasing** — Drizzle determines applied migrations by comparing `max(created_at)` in the `drizzle.__drizzle_migrations` table against each journal entry's `when` field. If early migrations have future timestamps (higher than later migrations), Drizzle skips the later ones. Fixed in platform-core PR #71.
- **Crypto watcher sees block 0 but host sees block N** — if the compose Anvil container and the host are hitting different Anvil instances (e.g., host has a stale `anvil` process), the watcher inside Docker sees block 0 (compose Anvil) while `cast` on the host sees block N (host Anvil). Symptom: cursor never advances, poll completes silently. Fix: kill host `anvil`, restart compose Anvil.
- **Credit units are nanodollars** — `credit_balances.balance_credits` is in raw nanodollar units. 1,000,000 raw = 0.1 cents. 10,000,000,000 raw ≈ $10. When granting credits for testing, use `10000000000` (10 billion) for ~$10, not `10000`.
- **`revokeByInstance()` on destroy** — when an instance is destroyed via `fleet.removeInstance`, its service keys are soft-revoked in the DB (`revoked_at` timestamp set). The tenant's gateway calls will immediately start returning 401. This is intentional — only that instance's keys are revoked, not the tenant's other instances.
- **Free OpenRouter models** — `openrouter/auto` routes to free models when available. The `x-openrouter-cost` response header returns `null` for free models, so no credits are debited. Good for testing without burning credits.
- **Gateway routes mount at `/v1/*`** — `mountGateway(app, config)` from platform-core registers OpenAI-compatible routes: `POST /v1/chat/completions`, `GET /v1/models`, etc. The middleware chain: service key auth → budget check → upstream proxy → metering → credit debit.
- **`AuthUser` has no email/name** — `platform-core`'s `AuthUser` interface is `{ id: string; roles: string[] }` only. The fleet router's `ctx.user` has no email or name. Fixed in `fleet.ts` by importing `getUserEmail()` from `@wopr-network/platform-core/email` and querying the DB directly. Without this fix, provisioned users get fallback email `${instanceName}@runpaperclip.com` and can't sign in with their real email.
- **Provisioned user default password = their email** — `provision.ts` line 70: `hashPassword(user.email)`. Users must change it on first sign-in (no password change UI yet). For testing, sign in with email/password where both are the user's email address.
- **Tenant proxy requires platform auth** — `tenantProxyMiddleware` (line 104) rejects unauthenticated requests with 401. To access `testbot.localhost:8080`, the user must first sign in to the platform (at `localhost:3200` or `app.localhost:8080`). The session cookie must be valid for the `*.localhost` domain. In Chrome this works automatically; in curl you must pass the cookie header manually because `localhost` domain cookies don't match `testbot.localhost`.
- **tRPC context is session-only** — `createTRPCContext()` in `app.ts` only resolves `AuthUser` from BetterAuth session cookies. The admin API key (`ADMIN_API_KEY`/`local-admin-key`) does NOT work for tRPC calls — only for Hono REST routes that use `dualAuth()` middleware. To call tRPC fleet mutations from curl, sign in first and pass the session cookie.
- **tRPC v11 POST body format** — mutations accept raw JSON body (`{"name":"testbot"}`), NOT the tRPC v10 `{"json":{...}}` wrapper. The `{"json":{...}}` format causes "Invalid input: expected string, received undefined" because tRPC v11 doesn't unwrap the `json` key.
- **BetterAuth column naming varies** — platform DB uses camelCase columns (`userId`, `providerId`, `accountId`) while testbot DB uses snake_case (`user_id`, `provider_id`, `account_id`). This is likely a BetterAuth version difference between platform-core and the managed Paperclip image. When querying account tables, check column names first: `SELECT column_name FROM information_schema.columns WHERE table_name = 'account';`

### Testing the fleet provisioning flow (e2e)

After the stack is running and healthy:

```bash
# 1. Sign in to the platform (creates session cookie)
curl -X POST http://localhost:3200/api/auth/sign-in/email \
  -H "Content-Type: application/json" \
  -d '{"email":"<your-email>","password":"<your-password>"}' \
  -c /tmp/paperclip-cookies.txt
# Note: save the session token from the response

# 2. Grant credits to your tenant (required — billing gate blocks with 0 credits)
# Find your user ID from the sign-in response, then:
# NOTE: balance_credits is in NANODOLLARS. 10,000,000,000 ≈ $10. NOT 10000.
docker exec paperclip-platform-postgres-1 psql -U paperclip -d paperclip_platform -c \
  "INSERT INTO credit_balances (tenant_id, balance_credits, last_updated) VALUES ('<user-id>', 10000000000, now()::text) ON CONFLICT (tenant_id) DO UPDATE SET balance_credits = 10000000000;"

# 3. Create an instance via tRPC (raw JSON body — tRPC v11 format)
curl -X POST http://localhost:3200/trpc/fleet.createInstance \
  -H "Content-Type: application/json" \
  -b /tmp/paperclip-cookies.txt \
  -d '{"name":"testbot"}'
# Response: {"result":{"data":{"id":"...","name":"testbot","state":"running"}}}

# 4. Verify testbot health (from inside the platform container — direct Docker network)
docker exec paperclip-platform-platform-1 curl -sf http://wopr-testbot:3100/api/health
# Expected: {"status":"ok",...,"hostedMode":true,...}

# 5. Verify provisioned user email
docker exec paperclip-platform-postgres-1 psql -U paperclip -d paperclip_testbot -c \
  "SELECT id, email, name FROM \"user\";"
# Should show the platform user's actual email, NOT testbot@runpaperclip.com

# 6. Sign in to testbot as provisioned admin (password = email)
docker exec paperclip-platform-platform-1 curl -sf -X POST http://wopr-testbot:3100/api/auth/sign-in/email \
  -H "Content-Type: application/json" \
  -d '{"email":"<your-email>","password":"<your-email>"}'
# Response: token + user object

# 7. Access testbot via tenant proxy (requires platform session)
curl http://testbot.localhost:8080/api/health \
  -H "Cookie: better-auth.session_token=<token-from-step-1>"
# Expected: {"status":"ok",...,"hostedMode":true,...}

# 8. Test inference gateway (per-tenant metered proxy)
# The createInstance response includes a `gatewayKey` field — save it.
# Or query it from inside the testbot container:
docker exec wopr-testbot printenv PAPERCLIP_GATEWAY_KEY
# Then call the gateway:
curl -X POST http://localhost:3200/v1/chat/completions \
  -H "Authorization: Bearer <PAPERCLIP_GATEWAY_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"openrouter/auto","messages":[{"role":"user","content":"Hello"}]}'
# Expected: OpenAI-compatible JSON response with choices[0].message.content
# Verify credit debit:
docker exec paperclip-platform-postgres-1 psql -U paperclip -d paperclip_platform -c \
  "SELECT balance_credits FROM credit_balances WHERE tenant_id = '<user-id>';"
# Balance should be lower than the 10000000000 you seeded (unless free model was used)

# 9. Destroy the instance when done
curl -X POST http://localhost:3200/trpc/fleet.controlInstance \
  -H "Content-Type: application/json" \
  -b /tmp/paperclip-cookies.txt \
  -d '{"instanceId":"<id-from-step-3>","action":"destroy"}'
```

### Teardown

```bash
# Stop all services (preserve data)
docker compose -f docker-compose.local.yml down

# Stop and wipe all data (DB, Caddy config, fleet data)
docker compose -f docker-compose.local.yml down -v
```

### Production deployment (TBD)

Not yet deployed. Checklist for go-live:

- [ ] DO droplet provisioned
- [ ] DNS: runpaperclip.com, app.runpaperclip.com, *.runpaperclip.com → droplet IP (Cloudflare)
- [ ] Production Caddyfile with TLS (DNS-01 via Cloudflare)
- [ ] .env with production secrets deployed to droplet
- [ ] `OPENROUTER_API_KEY` set in production env (metered inference gateway)
- [ ] `/data/fleet/meter-wal` and `/data/fleet/meter-dlq` directories writable
- [ ] Stripe switched to live keys + Paperclip-branded price IDs created
- [ ] Stripe webhook endpoint registered (`https://api.runpaperclip.com/api/billing/webhook`) + new `whsec_*`
- [ ] BTCPay Server deployed (same droplet or separate)
- [ ] BTC watcher: xpub configured (same mnemonic, `m/44'/0'/0'` path)
- [ ] EVM watcher: `EVM_XPUB` set + Base node synced
- [ ] Payment methods seeded in DB (USDC, USDT, DAI, ETH, BTC)
- [ ] BTCPay: `BTCPAY_API_KEY`, `BTCPAY_BASE_URL`, `BTCPAY_STORE_ID`, `BTCPAY_WEBHOOK_SECRET` in production env
- [ ] BetterAuth URL set to https://api.runpaperclip.com
- [ ] Resend: separate account with `runpaperclip.com` domain verified (don't share WOPR key in prod)
- [ ] GHCR CI/CD pipeline for paperclip-platform + paperclip images
- [ ] Smoke test: sign-up → Stripe pay → credits → instance provisioned → subdomain accessible
- [ ] Smoke test: sign-up → crypto pay → watcher detects transfer → credits → instance provisioned

---

## Chain Server Operations

Dedicated Bitcoin chain server at pay.wopr.bot. All 4 products share this single bitcoind instance. No BTCPay, no nbxplorer.

### SSH access

```bash
ssh root@pay.wopr.bot
# or by IP: ssh root@167.71.118.221
```

### Check sync progress

```bash
docker logs chain-server-bitcoind-1 --tail 5
```

### Check current block count

```bash
docker exec chain-server-bitcoind-1 bitcoin-cli -rpcuser=btcpay -rpcpassword=btcpay-chain-2026 getblockcount
```

### RPC test from external host

```bash
curl -sf -X POST http://pay.wopr.bot:8332 \
  -H "Content-Type: application/json" \
  -u "btcpay:btcpay-chain-2026" \
  -d '{"jsonrpc":"1.0","method":"getblockcount","params":[],"id":1}'
```

### Firewall

DO Cloud Firewall: `chain-server-fw`
- SSH: admin IP only
- TCP 8332 (RPC): product VPS IPs only (10.120.0.x DO private network range)

### assumeutxo snapshot

Sync bootstrapped from a UTXO snapshot at block 910,000 (9GB) loaded via torrent:

```
magnet:?xt=urn:btih:7019437a2b1530624b100c0795cfc5f90b8322ca&dn=utxo-910000.dat
```

After snapshot load, bitcoind syncs remaining blocks forward from 910,000. At ~23 blocks/min this completes in hours rather than weeks.

### Prune config

```
prune=5000   # 5GB, ~17 days of block history
```

### Wrapper entrypoint

The chain server uses a custom wrapper entrypoint script that bypasses the stock BTCPay entrypoint entirely. It writes a proper `bitcoin.conf` file and execs `bitcoind` directly. This avoids:
- The `-mainnet` flag bug in `btcpayserver/bitcoin:30.2`
- `BITCOIN_EXTRA_ARGS` `\n` expansion not working in Docker Compose env vars

### Resize after sync

Once fully synced to chain tip, resize the droplet:

```bash
# Via DO console or doctl:
doctl compute droplet-action resize <droplet-id> --size s-1vcpu-2gb --wait
# Saves ~$12/mo (from $24 to $12)
```

---

## Caddy Gotchas

### Must use custom build for DNS-01 TLS

Stock `caddy:2-alpine` does not include the Cloudflare DNS plugin. Any VPS using DNS-01 TLS challenges (all of ours) requires a custom-built Caddy image with `github.com/caddy-dns/cloudflare`.

Build lives in `caddy/Dockerfile` (xcaddy):

```dockerfile
FROM caddy:builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare
FROM caddy:latest
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

If you see `module not registered: dns.providers.cloudflare` in Caddy logs: wrong image — rebuild with the custom Dockerfile.

### Must be on the same Docker network as API/UI

Caddy resolves upstream service names (e.g., `api:3001`, `ui:3000`) via Docker's internal DNS. If Caddy is on a different network, name resolution fails and all upstream requests return 502.

When a compose file defines a named network (e.g., `holyship`), Docker creates it as `<project>_holyship`. Every service that needs to communicate must explicitly declare:

```yaml
networks:
  - holyship
```

### Diagnosing 502 errors

```bash
# Test if Caddy can reach the API container by name:
docker exec holyship-caddy wget -qO- http://api:3001/health

# If output is "wget: bad address 'api'": network isolation issue
# If output is JSON: upstream is reachable, issue is elsewhere
```

### After editing a bind-mounted Caddyfile

`caddy reload` reloads from running process state, not the file. After editing a bind-mounted Caddyfile:

```bash
docker restart holyship-caddy   # (or the appropriate project prefix)
```

### TODO: Resize chain-server after background IBD completes

**When:** Background IBD reaches 100% (check: `docker logs chain-server-bitcoind-1 --tail 1` shows no more `[background validation]` lines)
**Action:** Resize droplet from s-2vcpu-4gb ($24/mo) to s-1vcpu-2gb ($12/mo) via DO console or API
**Why:** 4GB RAM only needed during IBD. Post-sync, tip chain uses ~300MB. 2GB + swap is plenty.
**Check IBD progress:** `ssh root@pay.wopr.bot 'docker exec chain-server-bitcoind-1 bitcoin-cli -rpcuser=btcpay -rpcpassword=btcpay-chain-2026 getchainstates'` — when only 1 chainstate remains, IBD is done.

## AWS SES Email Operations

### Verify a new domain

```bash
# Requires: aws CLI configured, CF_API_TOKEN env var, Cloudflare zone ID
cd ~/wopr-ops
./scripts/ses-verify-domain.sh <domain> <cloudflare-zone-id>

# Verify DNS propagation (may take 5-30 minutes)
aws ses get-identity-verification-attributes \
  --identities <domain> --region us-east-1

# Check DKIM status
aws ses get-identity-dkim-attributes \
  --identities <domain> --region us-east-1
```

### Check SES sending status

```bash
# Check if still in sandbox
aws ses get-account --region us-east-1
# Look for: "ProductionAccessEnabled": true

# Check verified domains
aws ses list-identities --identity-type Domain --region us-east-1

# Check send quota and usage
aws ses get-send-quota --region us-east-1
```

### Troubleshoot email delivery

```bash
# Check bounce/complaint rates (must stay under 5% bounce, 0.1% complaint)
aws ses get-send-statistics --region us-east-1

# Check specific domain verification status
aws ses get-identity-verification-attributes \
  --identities runpaperclip.com wopr.bot holyship.wtf --region us-east-1

# Test sending (sandbox: recipient must be verified)
aws ses send-email --region us-east-1 \
  --from "noreply@runpaperclip.com" \
  --destination "ToAddresses=tsavo@wopr.bot" \
  --message "Subject={Data=Test},Body={Text={Data=SES test from CLI}}"

# Check suppression list (addresses that bounced)
aws sesv2 list-suppressed-destinations --region us-east-1
```

### SES sandbox limitations

While in sandbox mode:
- Can only send to **verified email addresses** (not just verified domains)
- Max 200 emails/day, 1 email/second
- Verify individual test recipients: `aws ses verify-email-identity --email-address user@example.com --region us-east-1`

After production access approved:
- 50,000 emails/day (soft limit, can request increase)
- 14 emails/second
- Can send to any recipient

### Switch a product from Resend to SES

Add these env vars to the product's `.env` / docker-compose:

```bash
AWS_SES_REGION=us-east-1
AWS_ACCESS_KEY_ID=<ses-admin key>
AWS_SECRET_ACCESS_KEY=<ses-admin secret>
EMAIL_FROM=noreply@<domain>
EMAIL_REPLY_TO=support@<domain>
```

`platform-core` v1.51.0+ auto-detects `AWS_SES_REGION` and uses SES. If absent, falls back to Resend (`RESEND_API_KEY`). Keep `RESEND_API_KEY` during transition as a safety net.

### SES Gotchas

- **DKIM propagation takes up to 72 hours** — usually 5-30 minutes, but AWS docs say up to 72h. Don't panic.
- **SPF record conflicts** — if the domain already has an SPF record, merge `include:amazonses.com` into the existing record. Two SPF TXT records on the same domain = both fail.
- **Sandbox mode is per-region** — production access in `us-east-1` doesn't apply to `eu-west-1`.
- **Bounce rate over 5% triggers automatic sending pause** — monitor via `aws ses get-send-statistics`.
- **`EMAIL_FROM` must match a verified domain** — sending from an unverified domain returns `MessageRejected`.
- **IAM user `ses-admin` has full SES access** — scope down to `ses:SendEmail` + `ses:SendRawEmail` after rollout stabilizes.
