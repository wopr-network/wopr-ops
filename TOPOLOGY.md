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

**Domain strategy:** holyship.wtf is the canonical domain. holyship.dev 301-redirects to holyship.wtf (Cloudflare redirect rule). API lives at api.holyship.wtf.

**Landing page:** CF Pages project `holyship` serves holyship.wtf + www.holyship.wtf via CNAME → holyship.pages.dev.

**GitHub App:** "Holy Ship" (App ID 3099979), installed on wopr-network org. Webhook URL: `https://api.holyship.wtf/api/github/webhook`. Installation tokens (1hr TTL) used for git ops in holyshipper containers.

**DO droplet:** `holyship`, s-1vcpu-1gb ($6/mo), sfo2, Ubuntu 24.04 LTS, 5GB swap. SSH key: id_ed25519.

```
Internet
  └─ Cloudflare
       ├─ holyship.wtf            → CF Pages (landing page) / VPS IP (dashboard)
       ├─ www.holyship.wtf        → CNAME holyship.wtf
       ├─ holyship.dev            → 301 redirect to holyship.wtf (CF redirect rule)
       └─ api.holyship.wtf        → VPS IP (platform API + webhook)

Production VPS (DO sfo2, s-1vcpu-1gb, 5GB swap)
  └─ docker-compose.yml
       ├─ caddy:2-alpine                        (80, 443 — auto-TLS)
       │    ├─ holyship.wtf              → holyship-ui:3000
       │    └─ api.holyship.wtf          → holyship-api:3001
       ├─ holyship-api                   (3001 — internal)
       │    ├─ Flow engine (state machine, gates, claim/report)
       │    ├─ GitHub App webhook at /api/github/webhook
       │    ├─ Ship It endpoint at /api/ship-it
       │    ├─ Baked-in engineering flow (auto-provisioned on boot)
       │    └─ platform-core: auth, billing, fleet, gateway
       ├─ holyship-platform-ui           (3000 — internal)
       └─ postgres:16-alpine             (5432 — internal)

Holyshipper Containers (ephemeral, per-issue, managed by holyship-api via fleet)
  └─ ghcr.io/wopr-network/holyshipper-coder:latest (or holyshipper-devops)
       ├─ one per issue, tears down when done
       ├─ LLM calls → metered gateway → credits
       ├─ Git push via GitHub App installation token (1hr TTL)
       └─ claims work from holyship-api, reports signals back
```

### Holy Ship Flow

```
Issue arrives (GitHub webhook or "Ship It" button)
  → holyship-api creates entity in "spec" state
  → fleet provisions holyshipper container
  → holyshipper claims work → runs Claude agent
  → agent reports signal → engine evaluates gate
     ├─ gate passes → transition → next state → holyshipper claims again
     ├─ gate fails → new invocation with failure context → holyshipper retries
     ├─ approval required → holyshipper tears down → entity waits in inbox
     │    └─ human approves → new invocation → new holyshipper provisions
     ├─ spending cap hit → entity moves to budget_exceeded
     └─ terminal state → holyshipper tears down, entity done
```

### Baked-In Engineering Flow (11 states, 3 gates, 13 transitions)

```
spec ──spec_ready──→ code ──pr_created──→ review ──clean──→ docs ──docs_ready──→ learning ──learned──→ merge ──merged──→ done
                                            │                 │                                         │
                                            ├─issues──→ fix ←─┤cant_document──→ stuck                   ├─blocked──→ fix
                                            ├─ci_failed──→ fix │                                        └─closed──→ stuck
                                            │            │
                                            │            └─fixes_pushed──→ review (loop)
                                            │            └─cant_resolve──→ stuck
```

**Gates (opinionated, baked-in):**
| Gate | Transition | Check |
|------|-----------|-------|
| spec-posted | spec→code | `issue_tracker.comment_exists` — spec posted as issue comment |
| ci-green | code→review | `vcs.ci_status` — all CI checks passed |
| pr-mergeable | merge→done | `vcs.pr_status` — PR is clean and mergeable |

Gates use GitHub App installation tokens via `primitive-ops.ts`. No shell scripts.

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
| `DATABASE_URL` | holyship-api | Shared Postgres |
| `HOLYSHIP_ADMIN_TOKEN` | holyship-api | Admin auth for MCP/admin routes |
| `HOLYSHIP_WORKER_TOKEN` | holyship-api | Worker auth for claim/report |
| `GITHUB_APP_ID` | holyship-api | GitHub App authentication |
| `GITHUB_APP_PRIVATE_KEY` | holyship-api | GitHub App JWT signing |
| `GITHUB_WEBHOOK_SECRET` | holyship-api | Webhook HMAC verification |
| `OPENROUTER_API_KEY` | holyship-api | Upstream LLM provider for gateway |
| `STRIPE_SECRET_KEY` | holyship-api | Payment processing |
| `UI_ORIGIN` | holyship-api | CORS origin (https://holyship.wtf) |

UI build-time vars (baked into Next.js at `docker compose build`):
| `NEXT_PUBLIC_API_URL` | holyship-platform-ui | API base URL (https://api.holyship.wtf) |
| `NEXT_PUBLIC_GITHUB_APP_URL` | holyship-platform-ui | GitHub App install URL |
| `NEXT_PUBLIC_BRAND_*` | holyship-platform-ui | Product name, domain, tagline, storage prefix, home path |

Holyshipper containers receive these at provision time (not configured manually):
| `ANTHROPIC_API_KEY` | holyshipper | Gateway service key (not a real API key) |
| `ANTHROPIC_BASE_URL` | holyshipper | Points to metered gateway |
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
| holyship-api | 3001 | Via Caddy at api.holyship.wtf |
| holyship-platform-ui | 3000 | Via Caddy at holyship.wtf |
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
