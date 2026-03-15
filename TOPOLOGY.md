# Production Topology

Three products on shared infrastructure. Same GPUs, same platform-core, same credit system.

## Products

| Product | Domain | Audience | What it does |
|---------|--------|----------|-------------|
| **WOPR** | wopr.bot | Bot deployers | AI bot platform — always-on bots across messaging channels |
| **Paperclip** | runpaperclip.com | Non-technical users | Managed bot hosting — one-click bot deployment |
| **Holy Ship** | holyship.wtf (canonical), holyship.dev (redirect) | Engineering teams | Guaranteed code shipping — issues in, merged PRs out |

## Repositories

| Repo | Purpose | Registry Image |
|------|---------|----------------|
| **Shared** | | |
| wopr-network/platform-core | DB schema, auth, billing, fleet, gateway, credits | npm: @wopr-network/platform-core |
| wopr-network/platform-ui-core | Brand-agnostic Next.js UI components | npm: @wopr-network/platform-ui-core |
| wopr-network/wopr-ops | This logbook | N/A |
| **WOPR** | | |
| wopr-network/wopr-platform | WOPR Hono API — fleet, billing, auth | ghcr.io/wopr-network/wopr-platform |
| wopr-network/wopr-platform-ui | WOPR dashboard (thin shell on platform-ui-core) | ghcr.io/wopr-network/wopr-platform-ui |
| wopr-network/wopr | WOPR bot core — one container per tenant | ghcr.io/wopr-network/wopr |
| **Paperclip** | | |
| wopr-network/paperclip-platform | Paperclip Hono API — fleet, billing, auth | ghcr.io/wopr-network/paperclip-platform |
| wopr-network/paperclip-platform-ui | Paperclip dashboard (thin shell on platform-ui-core) | ghcr.io/wopr-network/paperclip-platform-ui |
| wopr-network/paperclip | Paperclip managed bot — one container per tenant | ghcr.io/wopr-network/paperclip |
| **Holy Ship** | | |
| wopr-network/holyship | Flow engine + platform server (holyship-platform) | ghcr.io/wopr-network/holyship |
| wopr-network/holyship-platform-ui | Holy Ship dashboard (thin shell on platform-ui-core) | ghcr.io/wopr-network/holyship-platform-ui |
| wopr-network/holyshipper | Ephemeral agent containers — per-discipline worker images | ghcr.io/wopr-network/holyshipper-coder, holyshipper-devops |

## Shared Infrastructure

```
platform-core (npm package)
    ├── BetterAuth (sessions, signup, login)
    ├── Stripe + double-entry credit ledger
    ├── FleetManager (Docker container lifecycle)
    ├── Metered inference gateway (OpenRouter proxy)
    ├── tRPC router factories
    └── Drizzle ORM (shared Postgres schema)

platform-ui-core (npm package)
    ├── Brand-agnostic Next.js components
    ├── setBrandConfig() — one call configures everything
    ├── Auth, billing, settings pages
    └── Each brand is a thin shell (~30 files)
```

## CI/CD Pipeline

```
push to main (any repo)
  → GitHub Actions: lint + test + build (runs-on: self-hosted)
  → docker build → push ghcr.io/wopr-network/<repo>:latest
  → SSH to VPS
  → docker compose pull && docker compose up -d
```

## WOPR Architecture (wopr.bot)

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

GPU Node (DigitalOcean — separate droplet)
  └─ docker-compose.gpu.yml
       ├─ llama.cpp    :8080
       ├─ chatterbox   :8081
       ├─ whisper      :8082
       └─ qwen         :8083
```

## Paperclip Architecture (runpaperclip.com)

White-label deployment using platform-core. Same pattern as WOPR but for managed bot hosting.

```
Internet
  └─ Cloudflare DNS
       ├─ runpaperclip.com       → VPS IP
       ├─ app.runpaperclip.com   → VPS IP (dashboard)
       └─ *.runpaperclip.com     → VPS IP (tenant subdomains)

Production VPS
  └─ docker-compose.yml
       ├─ caddy:2-alpine                (80, 443)
       │    ├─ app.runpaperclip.com  → dashboard:3000
       │    ├─ runpaperclip.com/api  → platform:3200
       │    └─ *.runpaperclip.com    → platform:3200 (tenant proxy)
       ├─ paperclip-platform         (3200 — internal)
       │    └─ Docker socket → spawns tenant containers
       ├─ paperclip-platform-ui      (3000 — internal)
       └─ postgres:16-alpine         (5432 — internal)

Tenant Containers (dynamic, managed by paperclip-platform via Dockerode)
  └─ paperclip-managed:latest
       └─ one per tenant, named volume /data for persistence
```

## Holy Ship Architecture (holyship.wtf)

Guaranteed code shipping. One shared engine instance, ephemeral holyshipper containers per-issue. GitHub App only.

**Domain strategy:** holyship.wtf is the canonical site. holyship.dev 301-redirects to holyship.wtf. API/gateway subdomains stay on holyship.dev (no .wtf subdomains for infrastructure).

```
Internet
  └─ Cloudflare DNS
       ├─ holyship.wtf            → VPS IP (landing + dashboard — canonical)
       ├─ holyship.dev            → 301 redirect to holyship.wtf (Cloudflare Page Rule)
       ├─ api.holyship.dev        → VPS IP (platform API)
       └─ gateway.holyship.dev    → VPS IP (metered inference gateway)

Production VPS
  └─ docker-compose.yml
       ├─ caddy:2-alpine                        (80, 443)
       │    ├─ holyship.wtf              → holyship-ui:3000
       │    ├─ api.holyship.dev/api      → holyship-platform:4000
       │    ├─ api.holyship.dev/trpc     → holyship-platform:4000
       │    └─ gateway.holyship.dev/v1   → holyship-platform:4000 (metered gateway)
       ├─ holyship-platform              (4000 — internal)
       │    ├─ Flow engine (state machine, gates, claim/report)
       │    ├─ GitHub App webhook receiver
       │    ├─ Docker socket → spawns holyshipper containers
       │    └─ platform-core: auth, billing, fleet, gateway
       ├─ holyship-platform-ui           (3000 — internal)
       └─ postgres:16-alpine             (5432 — shared with platform-core)

Holyshipper Containers (ephemeral, per-issue, managed by holyship-platform via fleet)
  └─ ghcr.io/wopr-network/holyshipper-coder:latest (or holyshipper-devops)
       ├─ one per issue, tears down when done
       ├─ LLM calls → gateway.holyship.dev → metered → credits
       ├─ Git push via GitHub App installation token (1hr TTL)
       └─ claims work from holyship-platform, reports signals back
```

### Holy Ship Flow

```
Issue arrives (GitHub webhook or "Ship It" button)
  → holyship-platform creates entity in flow
  → fleet provisions holyshipper container
  → holyshipper claims work → runs Claude agent
  → agent reports signal → engine evaluates gate
     ├─ gate passes → transition → next stage → holyshipper claims again
     ├─ gate fails → new invocation with failure context → holyshipper retries
     ├─ approval required → holyshipper tears down → entity waits in inbox
     │    └─ human approves → new invocation → new holyshipper provisions
     ├─ spending cap hit → entity moves to budget_exceeded
     └─ terminal state → holyshipper tears down, entity done
```

### Holy Ship Key Concepts

| Concept | Description |
|---------|-------------|
| **Entity** | An issue being worked. Moves through flow states. |
| **Flow** | State machine definition (spec → code → review → merge) |
| **Gate** | Deterministic check at state boundaries (CI, review bots, human approval) |
| **Holyshipper** | Ephemeral Docker container that runs a Claude agent for one issue |
| **Installation token** | 1-hour GitHub App token, generated per-holyshipper at provision time |
| **Service key** | Gateway API key tied to tenant, metered for billing |

### Holy Ship Env Vars

| Var | Where | Purpose |
|-----|-------|---------|
| `DATABASE_URL` | holyship-platform | Shared Postgres (platform-core + holyship tables) |
| `OPENROUTER_API_KEY` | holyship-platform | Upstream LLM provider for gateway |
| `GITHUB_APP_ID` | holyship-platform | GitHub App authentication |
| `GITHUB_APP_PRIVATE_KEY` | holyship-platform | GitHub App JWT signing |
| `GITHUB_WEBHOOK_SECRET` | holyship-platform | Webhook signature verification |
| `STRIPE_SECRET_KEY` | holyship-platform | Payment processing |
| `FLEET_DATA_DIR` | holyship-platform | Meter WAL/DLQ path |

Holyshipper containers receive these at provision time (not configured manually):
| `ANTHROPIC_API_KEY` | holyshipper | Gateway service key (not a real API key) |
| `ANTHROPIC_BASE_URL` | holyshipper | Points to gateway.holyship.dev |
| `GITHUB_TOKEN` | holyshipper | Installation access token (1hr TTL) |
| `HOLYSHIP_URL` | holyshipper | Claim/report endpoint |
| `HOLYSHIP_WORKER_TOKEN` | holyshipper | Per-container auth token |

## Shared Dependencies

| Package | Used By | Purpose |
|---------|---------|---------|
| @wopr-network/platform-core | wopr-platform, paperclip-platform, holyship | DB schema, Drizzle migrations, BetterAuth, CreditLedger, FleetManager, Gateway |
| @wopr-network/platform-ui-core | wopr-platform-ui, paperclip-platform-ui, holyship-platform-ui | Brand-agnostic Next.js UI, configured via setBrandConfig() |

## Revenue Model

All three products use inference arbitrage:

```
User action → LLM call → gateway proxy → upstream provider
                              ↓
                     serviceKeyAuth() → resolve tenant
                     meter tokens → debit credits
                     margin = credit price - wholesale cost
```

| Product | Token pattern | Billing model |
|---------|--------------|---------------|
| WOPR | Per-conversation | Always-on bot, continuous |
| Paperclip | Per-conversation | Always-on bot, continuous |
| Holy Ship | Per-issue | Ephemeral, massive burst per issue (250K-1M+ tokens) |

## Hard Constraints

- NO Kubernetes — ever
- NO Fly.io — ever (removed WOP-370)
- NO secrets in any file committed to git
- NO unversioned images — always pull :latest after CI builds
- Cloudflare proxy must be OFF on A records (Caddy DNS-01 requires it)
- ALL CI workflows use `runs-on: self-hosted` — never GitHub-hosted runners

## MCP Tools Available

| Tool | Provider | Capability |
|------|----------|-----------|
| DO MCP | DigitalOcean | Provision/destroy/reboot droplets, manage SSH keys |
| Cloudflare MCP | Cloudflare | Create/update/delete DNS records |

## Port Reference

| Service | Internal Port | External Access |
|---------|--------------|-----------------|
| **WOPR** | | |
| platform-api | 3100 | Via Caddy at api.wopr.bot |
| platform-ui | 3000 | Via Caddy at wopr.bot |
| **Paperclip** | | |
| paperclip-platform | 3200 | Via Caddy at runpaperclip.com/api |
| paperclip-platform-ui | 3000 | Via Caddy at app.runpaperclip.com |
| **Holy Ship** | | |
| holyship-platform | 4000 | Via Caddy at api.holyship.dev |
| holyship-platform-ui | 3000 | Via Caddy at holyship.dev |
| **Infrastructure** | | |
| caddy | 80, 443 | Direct |
| postgres | 5432 | Internal only |
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

All infrastructure uses a shared NTP source to ensure consistent timestamps across logs, event ordering, timeouts, and replay protection.

| Layer | Mechanism |
|-------|-----------|
| Production VPS (DO) | `systemd-timesyncd` → Cloudflare NTS (`time.cloudflare.com`) |
| Runner stack | `cturra/ntp` chrony container → runners sync on startup via `SYS_TIME` cap |
| Local dev stack | `cturra/ntp` chrony container on `wopr-local` network |

**Why this matters:** holyship stores all timestamps as Unix ms integers. If the host clock drifts (especially in WSL2 after sleep/wake), gate timeouts, event ordering, and replay-protection nonce windows all silently break.

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
