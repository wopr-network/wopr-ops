# Production Topology

Four products on shared infrastructure. Same GPUs, same platform-core, same credit system.

## Products

| Product | Domain | Audience | What it does |
|---------|--------|----------|-------------|
| **WOPR** | wopr.bot | Bot deployers | AI bot platform — always-on bots across messaging channels |
| **Paperclip** | runpaperclip.com | Non-technical users | Managed bot hosting — one-click bot deployment |
| **Holy Ship** | holyship.wtf (canonical), holyship.dev (redirect) | Engineering teams | Guaranteed code shipping — issues in, merged PRs out |
| **NemoClaw** | nemopod.com | ML/AI teams | One-click NVIDIA NemoClaw deployment with metered inference billing |

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
| **NemoClaw** | | |
| wopr-network/nemoclaw-platform | NemoClaw Hono API — fleet, billing, auth, gateway | ghcr.io/wopr-network/nemoclaw-platform |
| wopr-network/nemoclaw-platform-ui | NemoClaw dashboard (thin shell on platform-ui-core) | ghcr.io/wopr-network/nemoclaw-platform-ui |
| wopr-network/nemoclaw | Fork of NVIDIA NemoClaw with WOPR sidecar | ghcr.io/wopr-network/nemoclaw |

## Shared Infrastructure

```
platform-core (npm package — v1.50+)
    ├── BetterAuth (sessions, signup, login, GitHub OAuth)
    ├── Double-entry credit ledger (journal_entries + journal_lines + account_balances)
    │    ├── Credits are nanodollars, integer math only
    │    ├── $5 signup grant via grantSignupCredits()
    │    ├── debitCapped() for budget-limited operations
    │    └── Stripe + crypto checkout (CryptoServiceClient → key server at pay.wopr.bot:3100)
    │         ├── BTC, DOGE, LTC (UTXO), ETH + 9 ERC20 tokens on Base
    │         ├── CompositeOracle: Chainlink (BTC/ETH) → CoinGecko fallback (DOGE/LTC)
    │         ├── Microdollar precision (10⁻⁶ USD), DB-driven EVM watchers
    │         ├── address_type routing: bech32/p2pkh/evm, shared-xpub collision retry
    │         └── Partial payments + webhook outbox with durable retry
    ├── Tenant types: personal, org, platform_service
    │    └── platform_service bypasses credit gate (company pays, ledger still tracks)
    ├── FleetManager (Docker container lifecycle)
    │    └── Instance API (restart/stop/start on Instance, not FleetManager)
    ├── Metered inference gateway (OpenRouter proxy at /v1)
    │    ├── Per-tenant service keys (SHA-256 hashed, DB-backed)
    │    ├── Budget check → upstream proxy → metering → credit debit
    │    ├── X-Attribute-To header for cross-tenant attribution
    │    └── Usage sanitized to standard OpenAI format (strips OpenRouter extras)
    ├── Org/tenant isolation (DrizzleOrgMemberRepository)
    ├── Notification pipeline (SES primary, Resend fallback; 29 templates, 30s poll)
    ├── tRPC router factories (billing, org, settings, profile)
    └── Drizzle ORM (shared Postgres schema + migrations)

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
       ├─ wopr.bot        → 206.189.173.166
       ├─ app.wopr.bot    → 206.189.173.166
       └─ api.wopr.bot    → 206.189.173.166

VPS (DigitalOcean — wopr-platform, s-1vcpu-1gb, sfo2, 206.189.173.166)
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

**DO droplet:** `paperclip-platform`, s-1vcpu-1gb ($6/mo), sfo2, Ubuntu 24.04 LTS, 5GB swap. IP: 68.183.160.201.

```
Internet
  └─ Cloudflare DNS (proxy OFF — Caddy DNS-01 requires it)
       │  Zone: c2ac899c5e55d3ac150197a18effadf2
       ├─ runpaperclip.com       → A 68.183.160.201
       ├─ app.runpaperclip.com   → A 68.183.160.201 (dashboard)
       └─ *.runpaperclip.com     → A 68.183.160.201 (wildcard — tenant subdomains + api)

Production VPS (DO sfo2, s-1vcpu-1gb, 5GB swap, IP 68.183.160.201)
  └─ docker-compose.yml (/opt/paperclip-platform/)
       ├─ caddy (pre-built: ghcr.io/wopr-network/paperclip-caddy:latest)  (80, 443 — DNS-01 TLS via CF)
       │    ├─ runpaperclip.com      → platform-ui:3000
       │    ├─ app.runpaperclip.com  → platform-ui:3000
       │    ├─ api.runpaperclip.com  → platform-api:3200
       │    └─ *.runpaperclip.com    → platform-api:3200 (tenant proxy)
       ├─ paperclip-platform (platform-api)  (3200 — internal)
       │    ├─ Docker socket → spawns tenant containers
       │    ├─ COOKIE_DOMAIN=.runpaperclip.com (shared auth with instances)
       │    ├─ hosted_proxy deployment mode (instances trust X-Paperclip-User-Id)
       │    ├─ Inference gateway at /v1 (metered OpenRouter proxy)
       │    ├─ BetterAuth at /api/auth/*
       │    ├─ tRPC at /trpc/*
       │    └─ platform-core: auth, billing, credits, gateway, fleet
       ├─ paperclip-platform-ui     (3000 — internal)
       ├─ postgres:16-alpine        (5432 — internal)
       └─ netdata                   (19999 — host network, Netdata Cloud)
       NOTE: All services on named network "paperclip-platform" (compose default)

Tenant Containers (dynamic, managed by paperclip-platform via Dockerode)
  └─ ghcr.io/wopr-network/paperclip:managed
       ├─ one per tenant, named volume /data for persistence
       ├─ BETTER_AUTH_SECRET shared with platform (subdomain cookie auth)
       ├─ /internal/provision endpoint for manual provisioning
       └─ Health check: 30 retries × 2s = 60s (first boot runs 29 migrations)
```

### Paperclip Key Env Vars

| Var | Where | Purpose |
|-----|-------|---------|
| `DATABASE_URL` | platform-api | Shared Postgres |
| `BETTER_AUTH_SECRET` | platform-api + instances | Shared secret for subdomain cookie auth |
| `COOKIE_DOMAIN` | platform-api | `.runpaperclip.com` — session cookies work across subdomains |
| `PAPERCLIP_IMAGE` | platform-api | `ghcr.io/wopr-network/paperclip:managed` |
| `FLEET_DOCKER_NETWORK` | platform-api | Docker network instances join (must match compose network) |
| `PROVISION_SECRET` | platform-api | Bearer token for `/internal/provision` on instances |
| `GATEWAY_URL` | platform-api | Inference gateway URL for tenant containers |
| `OPENROUTER_API_KEY` | platform-api | Upstream LLM provider for gateway |
| `STRIPE_SECRET_KEY` | platform-api | Payment processing |
| `CLOUDFLARE_API_TOKEN` | caddy | DNS-01 TLS challenge |
| `TRUSTED_PROXY_IPS` | platform-api | CIDR for hosted_proxy trust (`172.16.0.0/12`) |

UI build-time vars (baked into Next.js at image build):
| `NEXT_PUBLIC_API_URL` | platform-ui | API base URL (`https://api.runpaperclip.com`) |
| `NEXT_PUBLIC_APP_DOMAIN` | platform-ui | Dashboard domain (`app.runpaperclip.com`) |

### Paperclip Deployment Mode: hosted_proxy

Instances run in `hosted_proxy` mode. The platform's tenant proxy adds `X-Paperclip-User-Id` header and instances trust it (no per-instance auth). Session cookies use `COOKIE_DOMAIN=.runpaperclip.com` so both `session_token` and `session_data` cookies are readable by both the platform and instance subdomains.

## Holy Ship Architecture (holyship.wtf)

Guaranteed code shipping. One shared engine instance, ephemeral holyshipper containers per-issue. GitHub App only.

**Domain strategy:** holyship.wtf is the canonical domain. holyship.dev 301-redirects to holyship.wtf (Cloudflare redirect rule). API lives at api.holyship.wtf.

**Landing page:** Served by holyship-platform-ui on the VPS (was CF Pages, migrated 2026-03-17).

**GitHub App:** "Holy Ship" (App ID 3099979), installed on wopr-network org. Webhook URL: `https://api.holyship.wtf/api/github/webhook`. Installation tokens (1hr TTL) used for git ops in holyshipper containers.

**DO droplet:** `holyship`, s-1vcpu-1gb ($6/mo), sfo2, Ubuntu 24.04 LTS, 5GB swap. SSH key: id_ed25519.

```
Internet
  └─ Cloudflare (proxy OFF — Caddy handles TLS via DNS-01)
       ├─ holyship.wtf            → A 138.68.46.192 (VPS)
       ├─ www.holyship.wtf        → A 138.68.46.192 (VPS)
       ├─ api.holyship.wtf        → A 138.68.46.192 (VPS)
       └─ holyship.dev            → 301 redirect to holyship.wtf (CF redirect rule)

Production VPS (DO sfo2, s-1vcpu-1gb, 5GB swap, IP 138.68.46.192)
  └─ docker-compose.yml (/opt/holyship/)
       ├─ caddy (custom build: caddy-cloudflare, xcaddy + caddy-dns/cloudflare)  (80, 443 — DNS-01 TLS via CF)
       │    ├─ holyship.wtf, www.holyship.wtf → holyship-ui:3000
       │    └─ api.holyship.wtf               → holyship-api:3001
       │    NOTE: Caddy + api + ui MUST all be on the same named Docker network
       ├─ holyship-api (platform-core v1.42.1)        (3001 — internal)
       │    ├─ Flow engine (state machine, gates, claim/report)
       │    ├─ GitHub App webhook at /api/github/webhook
       │    ├─ Ship It endpoint at /api/ship-it
       │    ├─ Baked-in engineering flow (auto-provisioned on boot)
       │    ├─ Inference gateway at /v1 (metered OpenRouter proxy)
       │    ├─ Interrogation routes at /api/repos/:owner/:repo/interrogate, /config, /gaps
       │    ├─ Flow editor routes at /api/repos/:owner/:repo/flow, /flow/edit, /flow/apply, /design-flow
       │    ├─ Gap → GitHub issue creation at /api/repos/:owner/:repo/gaps/:id/create-issue
       │    ├─ BetterAuth at /api/auth/* (sessions, GitHub OAuth)
       │    ├─ tRPC at /trpc/* (billing, org, settings)
       │    ├─ Double-entry credit ledger (nanodollars, journal_entries + journal_lines)
       │    └─ platform-core: auth, billing, credits, gateway, orgs, notifications
       ├─ holyship-platform-ui (platform-ui-core v1.14.1) (3000 — internal)
       │    ├─ Landing page, dashboard, repo analyze/pipeline/stories pages
       │    ├─ Visual flow editor (conversational — talk to your pipeline)
       │    ├─ /api/github/repos (Next.js API route for dashboard repo listing)
       │    └─ Config grid, gap checklist, flow diagram with diff highlighting
       └─ postgres:16-alpine             (5432 — internal)
       NOTE: No bitcoind/nbxplorer/BTCPay on this VPS. BTC payments handled by the dedicated chain server.

  Auto-deploy: auto-pull.sh cron (every 60s) detects new GHCR digests, restarts services

Holyshipper Containers (ephemeral, per-issue, managed by holyship-api via fleet)
  └─ ghcr.io/wopr-network/holyshipper-coder:latest (or holyshipper-devops)
       ├─ one per issue, tears down when done
       ├─ OpenCode SDK → OpenCode server (Go, port 4096) → gateway at /v1
       ├─ per-entity service key (HOLYSHIP_GATEWAY_KEY) for metered billing
       ├─ opencode.json declares "holyship" provider → @ai-sdk/openai-compatible
       ├─ Git push via GitHub App installation token (1hr TTL)
       ├─ worker-runtime: HTTP server (claim, dispatch, checkout, gate, credentials)
       └─ SSE event streaming: tool_use, text, step-start/finish, session.error
```

### Holy Ship Flow

```
Issue arrives (GitHub webhook or "Ship It" button)
  → holyship-api creates entity in "spec" state
  → fleet provisions holyshipper container
  → holyshipper claims work → runs OpenCode agent (via gateway)
  → agent reports signal → engine evaluates gate
     ├─ gate passes → transition → next state → holyshipper claims again
     ├─ gate fails → new invocation with failure context → holyshipper retries
     ├─ approval required → holyshipper tears down → entity waits in inbox
     │    └─ human approves → new invocation → new holyshipper provisions
     ├─ spending cap hit → entity moves to budget_exceeded
     └─ terminal state → holyshipper tears down, entity done
```

### Baked-In Engineering Flow (10 states, 3 gates, 12 transitions)

```
spec ──spec_ready──→ code ──pr_created──→ review ──clean──→ docs ──docs_ready──→ merge ──merged──→ done
                                            │                 │                    │
                                            ├─issues──→ fix ←─┤cant_document──→ stuck ├─blocked──→ fix
                                            ├─ci_failed──→ fix │                    └─closed──→ stuck
                                            │            │
                                            │            └─fixes_pushed──→ review (loop)
                                            │            └─cant_resolve──→ stuck
```

Learning is implicit — every agent gets a "what did you learn?" prompt after signaling done, before container teardown. Same session, full context. Updates .holyship/knowledge.md + ship.log as last commit in the PR.

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
| **.holyship/flow.yaml** | Customer's pipeline definition — lives in their repo, no lock-in |
| **.holyship/knowledge.md** | Repo intelligence — conventions, CI gate, gotchas. Updated by agents after every flow run |
| **.holyship/ship.log** | Append-only agent history — what was tried, what worked, what failed |
| **Interrogation** | AI scans repo to discover capabilities, conventions, gaps. Produces RepoConfig + gaps + bootstrapped knowledge.md |
| **Gap** | Missing capability found during interrogation (e.g., no tests, no CI). Each gap becomes a GitHub issue |
| **Flow editor** | Conversational UI — user talks to their pipeline, AI modifies flow.yaml, apply creates a PR |
| **Platform service account** | Tenant type `platform_service` — company-funded, bypasses credit gate, tracks spend via attribution |
| **Model tiers** | opus (reasoning), sonnet (coding), haiku (merge/docs), test (Qwen3-Coder, free) |

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

## NemoClaw Architecture (nemopod.com)

One-click NVIDIA NemoClaw deployment. Each tenant gets their own NemoClaw container with inference routed through the platform gateway for metered per-tenant billing.

```
Internet
  └─ Cloudflare DNS
       ├─ nemopod.com          → 167.172.208.149
       ├─ api.nemopod.com      → 167.172.208.149
       ├─ app.nemopod.com      → 167.172.208.149
       └─ *.nemopod.com        → 167.172.208.149 (tenant subdomains)

Production VPS (DigitalOcean — 167.172.208.149)
  └─ docker-compose.yml
       ├─ caddy:2-alpine                (80, 443 — auto-TLS)
       │    ├─ nemopod.com        → marketing / UI
       │    ├─ app.nemopod.com    → platform-ui:3000
       │    ├─ api.nemopod.com    → platform-api:3100
       │    └─ *.nemopod.com      → platform-api:3100 (tenant proxy)
       ├─ nemoclaw-platform      (3100 — internal)
       │    ├─ Docker socket → spawns tenant NemoClaw containers
       │    ├─ Inference gateway at /v1 (metered OpenRouter proxy)
       │    ├─ BetterAuth at /api/auth/*
       │    ├─ tRPC at /trpc/*
       │    ├─ Stripe webhook at /api/stripe/webhook
       │    └─ platform-core: auth, billing, credits, gateway, fleet
       ├─ nemoclaw-platform-ui   (3000 — internal)
       └─ postgres:16-alpine     (5432 — internal)

Tenant Containers (dynamic, managed by nemoclaw-platform via Dockerode)
  └─ ghcr.io/wopr-network/nemoclaw:latest
       ├─ Fork of NVIDIA NemoClaw with WOPR sidecar at /opt/wopr/sidecar.js
       ├─ Sidecar: GET /internal/health, POST /internal/provision
       ├─ Provision rewrites openclaw.json to use GATEWAY_URL as provider
       └─ Per-tenant gateway service key → metered billing through platform
```

### NemoClaw Key Env Vars

| Var | Purpose |
|-----|---------|
| `PLATFORM_DOMAIN` | Tenant subdomain root — `nemopod.com` |
| `GATEWAY_URL` | `https://api.nemopod.com/v1` — inference gateway for tenant billing |
| `OPENROUTER_API_KEY` | Upstream LLM provider |
| `NEMOCLAW_IMAGE` | Default: `ghcr.io/wopr-network/nemoclaw:latest` |
| `STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` | Stripe test-mode (sandbox) |
| `PLATFORM_UI_URL` | `https://app.nemopod.com` — post-checkout redirect |

### NemoClaw Billing Flow

```
User buys credits (Stripe checkout)
  → checkout.session.completed webhook → /api/stripe/webhook
  → credits added to tenant's journal_entries (nanodollars)
  → tenant provisions a NemoClaw container
  → fleet router creates per-tenant gateway service key
  → NemoClaw sidecar wires openclaw.json → gateway_url + service_key
  → every LLM call → gateway → meters tokens → debits credits
```

## Chain Server (pay.wopr.bot)

Centralized crypto payment service shared by all 4 products. Replaces per-product BTCPay stacks entirely.

```
Chain Server (DO sfo2, s-2vcpu-4gb, 80GB disk, $24/mo)
  IP: 167.71.118.221
  Private IP: 10.120.0.5
  Hostname: pay.wopr.bot
  Attached volume: ltc-sync (100GB, /mnt/ltc_sync) — temporary for LTC sync, $10/mo
  └─ docker-compose.yml (/opt/chain-server/)
       ├─ crypto-key-server          (port 3100 — ghcr.io/wopr-network/crypto-key-server:latest)
       │    ├─ Hono HTTP — 7 API endpoints
       │    │    ├─ GET  /chains          — list enabled payment methods
       │    │    ├─ POST /address         — derive next HD address (BIP-44)
       │    │    ├─ POST /charges         — create charge (oracle locks exchange rate)
       │    │    ├─ GET  /charges/:id     — check charge status
       │    │    ├─ GET  /admin/next-path — available derivation path
       │    │    ├─ PUT  /admin/chains    — register/update payment method
       │    │    └─ DELETE /admin/chains/:id — disable payment method
       │    ├─ Auth: Bearer service key (products) / admin token (path registration)
       │    ├─ Chainlink on-chain oracle (Base mainnet) for BTC/ETH/DOGE/LTC prices
       │    ├─ Native amount tracking — expectedAmount locked in sats/token units at charge creation
       │    ├─ Partial payment accumulation — BigInt math, webhook on every payment
       │    ├─ Webhook outbox — durable delivery with exponential backoff (10 max retries)
       │    ├─ SSRF protection — callbackUrl validated, internal IPs blocked
       │    └─ Watcher service — boots UTXO watchers (BTC/DOGE/LTC) + EVM watchers from DB
       │
       ├─ bitcoind                   (port 8332 — btcpayserver/bitcoin:30.2)
       │    ├─ Mainnet, pruned 5GB, ~26GB on disk
       │    ├─ Custom wrapper entrypoint (bypasses BTCPay entrypoint bugs)
       │    └─ Volume: chain-server_bitcoin_data (Docker managed)
       │
       ├─ dogecoind                  (port 22555 — blocknetdx/dogecoin:latest)
       │    ├─ Mainnet, pruned 2200MB, ~4GB on disk (rebuilding chainstate)
       │    ├─ Custom wrapper entrypoint (writes config, execs dogecoind directly)
       │    ├─ Seed nodes by IP (hostnames don't resolve inside container)
       │    ├─ Blocks pre-loaded from ghcr.io/wopr-network/doge-chaindata:latest
       │    └─ Volume: doge_data (external, Docker managed)
       │
       ├─ litecoind                  (port 9332 — uphold/litecoin-core:latest)
       │    ├─ Mainnet, pruned 2200MB, syncing from peers (~90GB download → ~3GB pruned)
       │    ├─ Custom wrapper entrypoint (same pattern as BTC/DOGE)
       │    ├─ Data on attached volume: /mnt/ltc_sync (100GB DO block storage)
       │    ├─ After sync: move pruned data to main disk, detach volume
       │    └─ DNS seeds work natively (uphold image has proper DNS)
       │
       ├─ postgres:16-alpine        (5432 — internal, DB: crypto_key_server)
       │    └─ Tables: payment_methods, crypto_charges, path_allocations,
       │              derived_addresses, webhook_deliveries
       │
       └─ DO Cloud Firewall (chain-server-fw):
            ├─ SSH: admin IP only
            ├─ TCP 3100: VPC + product VPS IPs
            └─ TCP 8332/22555/9332: product VPS IPs only

Products call: POST https://pay.wopr.bot:3100/charges → receive webhook callbacks
  Env vars per product:
    CRYPTO_SERVICE_URL=http://pay.wopr.bot:3100
    CRYPTO_WEBHOOK_URL=https://api.{product}/billing/crypto/webhook

All nodes use wrapper entrypoint pattern:
  entrypoint: ["/opt/wrapper.sh"]  +  volumes: ./XXX-wrapper.sh:/opt/wrapper.sh:ro
  Wrapper writes config, execs daemon. No reliance on image defaults.
```

4 xpubs registered: BTC (m/44'/0'/0'), EVM (m/44'/60'/0'), DOGE (m/44'/3'/0'), LTC (m/44'/2'/0').
12 payment methods seeded: BTC, DOGE, LTC, 9 EVM tokens on Base (USDC, USDT, DAI, etc.).

BTCPay, nbxplorer: removed entirely from platform-core v1.44.0. CryptoServiceClient replaces BTCPayClient.

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
| paperclip-platform | 3200 | Via Caddy at api.runpaperclip.com |
| paperclip-platform-ui | 3000 | Via Caddy at runpaperclip.com / app.runpaperclip.com |
| **Holy Ship** | | |
| holyship-api | 3001 | Via Caddy at api.holyship.wtf |
| holyship-platform-ui | 3000 | Via Caddy at holyship.wtf |
| **NemoClaw** | | |
| nemoclaw-platform | 3100 | Via Caddy at api.nemopod.com |
| nemoclaw-platform-ui | 3000 | Via Caddy at app.nemopod.com |
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

## Crypto Payment Wallet Hierarchy

All platforms share one BIP39 master seed (`paperclip-wallet.enc` on G drive, encrypted with `openssl enc -aes-256-cbc -pbkdf2 -iter 100000`). Each deployment gets its own BIP44 account-level xpub — completely isolated address spaces, no cross-platform address collisions possible.

| Deployment | Account Path | xpub | Status |
|-----------|-------------|------|--------|
| nemoclaw | `m/44'/60'/0'` | `xpub6DSVkV7mgEZrnBEmZEq412Cx9sYYZtFvGSb6W9bRDDSikYdpmUiJoNeuechuir63ZjdHQuWBLwchQQnh2GD6DJP6bPKUa1bey1X6XvH9jvM` | deployed |
| holyship | `m/44'/60'/1'` | `xpub6DSVkV7mgEZrq3tu6TD8NJBvQPceKzuZdtkSS7gfUJBRb37HzHKKxtVPVkY8FquGXnKbCNH27KTGagMRYu4Tg5y5UXLYVfXGuD3kFHBbyMp` | deployed |
| paperclip | `m/44'/60'/2'` | `xpub6DSVkV7mgEZrs93tLMxNf5Yq8mbtqNcMjQ8zeHXcNxcERZDb17U4Ky5WUme1GFGLuRHWYe6NNBHVjLdYC5HjVzZMjuF7K7RCz4voAKf8QhY` | reserved |
| wopr | `m/44'/60'/3'` | (derive when needed) | not configured |

**To derive a new xpub:**
```bash
openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -pass pass:<passphrase> \
  -in "/mnt/g/My Drive/paperclip-wallet.enc" | npx tsx --eval "
import { HDKey } from '@scure/bip32';
import { mnemonicToSeedSync } from '@scure/bip39';
const mnemonic = require('fs').readFileSync('/dev/stdin','utf8').trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(mnemonic));
console.log(root.derive(\"m/44'/60'/N'\").publicExtendedKey);
"
```

**Why account-level xpubs:** Each deployment holds only its branch. A server compromise exposes only that platform's address space. Addresses are mathematically disjoint — no code or config error can produce collisions.

## AWS SES Email Infrastructure

Transactional email for all products. AWS account `264991295931`, IAM user `ses-admin` (AmazonSESFullAccess policy). Region: `us-east-1`.

```
platform-core SesTransport (v1.51.0+)
    ├── Auto-selects SES when AWS_SES_REGION is set
    ├── Falls back to Resend when SES env vars absent
    └── Legacy RESEND_FROM / RESEND_REPLY_TO still work as fallback

AWS SES (us-east-1)
    ├── runpaperclip.com  — verified (DKIM + SPF + verification TXT)
    ├── wopr.bot          — verified (DKIM + SPF + verification TXT)
    ├── holyship.wtf      — verified (DKIM + SPF + verification TXT)
    └── nemopod.com       — not yet verified

DNS (Cloudflare)
    Per domain:
    ├── _amazonses.<domain> TXT  (SES domain verification token)
    ├── 3x CNAME              (DKIM: <selector>._domainkey.<domain> → <selector>.dkim.amazonses.com)
    └── TXT "v=spf1 include:amazonses.com ~all"  (SPF)
```

### SES Env Vars (per product)

| Variable | Example | Notes |
|----------|---------|-------|
| `AWS_SES_REGION` | `us-east-1` | Presence triggers SES transport |
| `AWS_ACCESS_KEY_ID` | `AKIA...` | IAM user `ses-admin` |
| `AWS_SECRET_ACCESS_KEY` | (secret) | IAM user `ses-admin` |
| `EMAIL_FROM` | `noreply@runpaperclip.com` | Sender address (new unified var) |
| `EMAIL_REPLY_TO` | `support@runpaperclip.com` | Reply-to (optional) |
| `RESEND_API_KEY` | `re_...` | Fallback — used only when SES vars absent |

### SES Production Access

SES starts in **sandbox mode** — can only send to verified recipient addresses. Production access requested (pending AWS approval). Once approved, all verified domains can send to any recipient.

### Verification Script

`scripts/ses-verify-domain.sh <domain> <cloudflare-zone-id>` — verifies domain in SES, retrieves DKIM tokens, adds all DNS records to Cloudflare via API. Requires `aws` CLI + `CF_API_TOKEN` env var.
