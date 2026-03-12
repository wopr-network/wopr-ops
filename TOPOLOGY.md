# WOPR Production Topology

## Repositories

| Repo | Purpose | Registry Image |
|------|---------|----------------|
| wopr-network/wopr-platform | Hono API, Drizzle/Postgres, tRPC, fleet, billing, auth | ghcr.io/wopr-network/wopr-platform |
| wopr-network/wopr-platform-ui | Next.js dashboard | ghcr.io/wopr-network/wopr-platform-ui |
| wopr-network/wopr | WOPR bot core — one container per tenant | ghcr.io/wopr-network/wopr |
| wopr-network/wopr-ops | This logbook | N/A |
| wopr-network/paperclip-platform | Paperclip Hono API — fleet, billing, auth (white-label of wopr-platform) | TBD |
| wopr-network/platform-ui-core | Brand-agnostic Next.js dashboard (shared by WOPR + Paperclip) | TBD |
| wopr-network/paperclip | Paperclip managed bot — one container per tenant | TBD |

## CI/CD Pipeline

```
push to main (any repo)
  → GitHub Actions: lint + test + build
  → docker build → push ghcr.io/wopr-network/<repo>:latest
  → SSH to VPS
  → docker compose pull && docker compose up -d
```

## Production Architecture

```
Internet
  └─ Cloudflare DNS (proxy OFF — required for Caddy DNS-01)
       ├─ wopr.bot        → VPS IP
       └─ api.wopr.bot    → VPS IP

VPS (DigitalOcean)
  └─ docker-compose.yml
       ├─ caddy:2-alpine                (80, 443)
       │    ├─ wopr.bot/            → platform-ui:3000
       │    ├─ api.wopr.bot/api     → platform-api:3100
       │    ├─ api.wopr.bot/trpc    → platform-api:3100
       │    └─ api.wopr.bot/fleet   → platform-api:3100
       ├─ platform-api               (3100 — internal)
       │    └─ Docker socket → spawns tenant containers
       └─ platform-ui                (3000 — internal)

Tenant Containers (dynamic, managed by platform-api via Dockerode)
  └─ ghcr.io/wopr-network/wopr:latest
       └─ one per user, named volume /data for persistence

GPU Node (DigitalOcean — separate droplet, not yet provisioned)
  └─ docker-compose.gpu.yml
       ├─ llama.cpp    :8080
       ├─ chatterbox   :8081
       ├─ whisper      :8082
       └─ qwen         :8083
```

## Paperclip Platform Architecture (runpaperclip.com)

White-label deployment of the WOPR platform stack for Paperclip AI. Uses `@wopr-network/platform-core` for shared DB schema, auth, and billing logic.

```
Internet
  └─ Cloudflare DNS
       ├─ runpaperclip.com       → VPS IP (TBD)
       ├─ app.runpaperclip.com   → VPS IP (dashboard)
       └─ *.runpaperclip.com     → VPS IP (tenant subdomains)

Production VPS (TBD)
  └─ docker-compose.yml
       ├─ caddy:2-alpine                (80, 443)
       │    ├─ app.runpaperclip.com  → dashboard:3000
       │    ├─ runpaperclip.com/api  → platform:3200
       │    └─ *.runpaperclip.com    → platform:3200 (tenant proxy)
       ├─ paperclip-platform         (3200 — internal)
       │    └─ Docker socket → spawns tenant containers
       ├─ platform-ui-core          (3000 — internal, .env.paperclip branding)
       └─ postgres:16-alpine        (5432 — internal)

Tenant Containers (dynamic, managed by paperclip-platform via Dockerode)
  └─ paperclip-managed:latest
       └─ one per tenant, named volume /data for persistence
```

### Paperclip Local Dev Stack

Run from `~/paperclip-platform`:
```bash
cp .env.local.example .env.local   # fill in Stripe test keys from ~/wopr-platform/.env
docker build -t paperclip-managed:local -f ~/paperclip/Dockerfile.managed ~/paperclip
bash scripts/local-test.sh         # or: docker compose -f docker-compose.local.yml up --build
```

| Service | Port | URL |
|---------|------|-----|
| Dashboard | 8080 (via Caddy) | http://app.localhost:8080 |
| API | 3200 | http://localhost:3200/health |
| Tenant proxy | 8080 (via Caddy) | http://{subdomain}.localhost:8080 |
| Postgres | 5433 (mapped) | localhost:5433 (paperclip/paperclip-local) |
| Caddy admin | 2019 | http://localhost:2019 |

### Shared Dependencies

| Package | Used By | Purpose |
|---------|---------|---------|
| @wopr-network/platform-core | wopr-platform, paperclip-platform | DB schema, Drizzle migrations, BetterAuth, CreditLedger, UserRoleRepo |
| platform-ui-core | wopr-platform-ui (brand shell), paperclip dashboard | Brand-agnostic Next.js UI, configured via NEXT_PUBLIC_BRAND_* env vars |

## Hard Constraints

- NO Kubernetes — ever
- NO Fly.io — ever (removed WOP-370)
- NO secrets in any file committed to git
- NO unversioned images — always pull :latest after CI builds
- Cloudflare proxy must be OFF on A records (Caddy DNS-01 requires it)

## MCP Tools Available

| Tool | Provider | Capability |
|------|----------|-----------|
| DO MCP | DigitalOcean | Provision/destroy/reboot droplets, manage SSH keys |
| Cloudflare MCP | Cloudflare | Create/update/delete DNS records on wopr.bot zone |

## Port Reference

| Service | Internal Port | External Access |
|---------|--------------|-----------------|
| platform-api | 3100 | Via Caddy at api.wopr.bot |
| platform-ui | 3000 | Via Caddy at wopr.bot |
| caddy | 80, 443 | Direct |
| llama (GPU) | 8080 | GPU node internal only |
| chatterbox (GPU) | 8081 | GPU node internal only |
| whisper (GPU) | 8082 | GPU node internal only |
| qwen (GPU) | 8083 | GPU node internal only |

## GPU Node Connectivity

The GPU node is a separate DO droplet. `platform-api` reaches it via public IP using a shared secret.

| Item | Value |
|------|-------|
| Access model | HTTP over public IP, authenticated via `GPU_NODE_SECRET` env var |
| Env var in platform-api | `GPU_NODE_HOST` — set to GPU droplet public IP after provisioning |
| Firewall | GPU droplet should restrict ports 8080-8083 to VPS IP only (DO firewall rule) |
| Self-registration | Cloud-init POSTs to `POST /internal/gpu/register` on platform-api to signal boot stages |

After GPU provisioning: update `GPU_NODE_HOST` in VPS `.env` and `--force-recreate` platform-api.

## Time Synchronization

All WOPR infrastructure uses a shared NTP source to ensure consistent timestamps across logs, event ordering, timeouts, and replay protection.

| Layer | Mechanism |
|-------|-----------|
| Production VPS (DO) | `systemd-timesyncd` → Cloudflare NTS (`time.cloudflare.com`) |
| Runner stack | `cturra/ntp` chrony container → runners sync on startup via `SYS_TIME` cap |
| Local dev stack | `cturra/ntp` chrony container on `wopr-local` network |

**Why this matters:** defcon and norad store all timestamps as Unix ms integers. If the host clock drifts (especially in WSL2 after sleep/wake), gate timeouts, event ordering, and replay-protection nonce windows all silently break.

**Upstream NTP chain:**
```
time.cloudflare.com (NTS — authenticated)
time.google.com     (fallback)
pool.ntp.org        (fallback)
  → wopr-ntp container (chrony, stratum 2)
    → runner containers (sync at startup, SYS_TIME cap)
    → app containers (share host kernel clock — already synced)
```

**Production VPS upgrade path:** swap `systemd-timesyncd` for `chrony` for faster convergence after network interruptions:
```bash
sudo apt install chrony
sudo systemctl disable systemd-timesyncd
sudo systemctl enable --now chronyd
```

