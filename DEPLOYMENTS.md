# Deployment Log

> Append-only. DevOps agent adds an entry after every deploy.

## Format

```
### YYYY-MM-DD HH:MM UTC — <what changed>
**Repos:** list
**Images deployed:** ghcr.io/wopr-network/<repo>@sha256:xxx
**Result:** Success / Failed
**Rollback needed:** No / Yes — reason
**Notes:** anything relevant
```

---

### 2026-03-17 23:30 UTC — Holy Ship production launch (DigitalOcean SFO2)

**Repos:** wopr-network/holyship, wopr-network/holyship-platform-ui, wopr-network/platform-core, wopr-network/holyshipper, wopr-network/wopr-ops
**VPS:** DigitalOcean s-1vcpu-1gb ($6/mo), IP 138.68.46.192, sfo2
**Images deployed:**
- `ghcr.io/wopr-network/holyship:latest` (platform-core v1.42.1)
- `ghcr.io/wopr-network/holyship-platform-ui:latest` (platform-ui-core v1.14.1)
- `postgres:16-alpine`
- `caddy:2-alpine` (custom build with caddy-dns/cloudflare for DNS-01 TLS)

**DNS:** holyship.wtf, api.holyship.wtf, www.holyship.wtf → 138.68.46.192 (Cloudflare proxy OFF, Caddy handles TLS)
**TLS:** Let's Encrypt via Caddy DNS-01 challenge (Cloudflare API token), valid until 2026-06-15

**Result:** Success — all 4 containers healthy, full stack verified

**Verified endpoints:**
- `https://holyship.wtf` → 200 (landing page, "Holy Ship — Guaranteed Code Shipping")
- `https://holyship.wtf/dashboard` → 200 (auth redirect works)
- `https://api.holyship.wtf/health` → `{"status":"ok"}`
- Gateway LLM call → 200 (Claude Haiku via OpenRouter, credits debited correctly)
- Billing ledger → double-entry balanced (adapter_usage debits verified)

**What shipped this session (17 issues, 15+ PRs):**
- .holyship/ directory convention (flow.yaml, knowledge.md, ship.log)
- Implicit learning (agents learn after every flow run)
- Repo interrogation (prompt + parser + service)
- Visual flow editor (conversational — frontend + backend)
- Flow API (GET/POST /flow, /flow/edit, /flow/apply, /design-flow)
- Platform billing (platform_service tenant, X-Attribute-To attribution, credit bypass)
- Direct gateway LLM calls (no runner overhead for flow editing)
- Gap → GitHub issue creation wiring
- Dashboard repo listing (/api/github/repos)
- VPS provisioning scripts (vps/holyship/)
- Qwen3-Coder as test tier model in holyshipper

**Issues found and fixed during deploy:**
1. GHCR token expired — used `gh auth token` instead
2. Caddy TLS challenge failed — DNS was pointing to Cloudflare Pages, not VPS. Fixed A records, proxy OFF.
3. `/tmp/fleet` owned by root → meter WAL EACCES → silent billing failure. Fixed in Dockerfile (PR #242).
4. Tenant ID mismatch — engine uses `"default"`, manual seed used `"tenant-default"`. Fixed in DB.
5. No credits seeded — used `grantSignupCredits()` inside container to properly create ledger accounts.

**Rollback needed:** No

**Notes:**
- Auto-pull cron (`auto-pull.sh`) runs every minute on the VPS, detects new GHCR images, restarts services.
- Gateway service key: `sk-hs-97eeb...` (in /opt/holyship/.env on VPS, NOT in git).
- Engineering flow auto-provisions on boot (flow_definitions table, initial_state: spec).
- First repo onboarded: wopr-network/holyship (meta — Holy Ship shipped itself).

---

## Local Dev Sessions

### 2026-03-05 01:20 UTC — DinD local dev environment started (WSL2, Docker Desktop)

**Repos:** wopr-network/wopr-platform-ui (built locally from main + fix/wop-1187-local-image next.config.ts)
**Images deployed (inner VPS stack):**
- `ghcr.io/wopr-network/wopr-platform:latest` (pulled from GHCR)
- `ghcr.io/wopr-network/wopr-platform-ui:local` (built locally sha256:8fdcc03a553d8b3ae7e400eee30bb2690c254c10eb20098c8fa983396b507f56, pushed to GHCR)
- `postgres:16-alpine`, `caddy:2-alpine`, `containrrr/watchtower:latest` (pulled from Docker Hub)

**Result:** Success — all 5 inner VPS services healthy
- `wopr-vps-postgres`: healthy
- `wopr-vps-platform-api`: healthy — `curl http://localhost:3100/health` → `{"status":"ok","service":"wopr-platform","backups":{"staleCount":0,"totalTracked":0}}`
- `wopr-vps-platform-ui`: healthy
- `wopr-vps-caddy`: running — `curl -sI http://localhost` → HTTP/1.1 200 OK
- `wopr-vps-watchtower`: healthy

**Rollback needed:** No

**Issues resolved this session:**
1. `docker-credential-desktop.exe` not in DinD PATH — worked around with `/tmp/dockercfg` plain-auth config
2. `platform-ui:local` didn't exist on GHCR — built locally, pushed with `docker push`
3. `platform-ui` Next.js SSR validation rejects `localhost` in production mode even with `NODE_ENV=development` (Turbopack inlines NODE_ENV at build time) — bypassed with `PLAYWRIGHT_TESTING=true` in compose env
4. `platform-ui` Dockerfile requires `output: "standalone"` in `next.config.ts` which is only on `fix/wop-1187-local-image` branch — cherry-picked `next.config.ts` for build, restored after
5. `docker save | docker exec -i` piping fails in Docker Desktop WSL — worked around by pushing to GHCR and pulling from inside container

**Notes:** GPU container not started — nvidia-smi was not in PATH; GPU confirmed absent at time of initial stack start. GPU started in subsequent operation (see entry below).

---

### 2026-03-05 01:55 UTC — GPU container started (RTX 3070, CUDA 13.0)

**Repos:** wopr-network/wopr-ops (gpu-seeder.sh)
**Images deployed (inner GPU stack):**
- `ghcr.io/ggml-org/llama.cpp:server-cuda` — llama-cpp port 8080
- `travisvn/chatterbox-tts-api:gpu` — chatterbox port 8081
- `fedirz/faster-whisper-server:0.6.0-rc.3-cuda` — whisper port 8082
- `ghcr.io/ggml-org/llama.cpp:server-cuda` — qwen-embeddings port 8083

**GPU:** NVIDIA RTX 3070 8GB, driver 581.08 (Windows), CUDA 13.0, WSL2

**Result:** Success
- `wopr-gpu-llama-cpp`: healthy — `curl http://localhost:8080/health` → `{"status":"ok"}`
- `wopr-gpu-chatterbox`: healthy — `curl http://localhost:8081/health` → `OK`
- `wopr-gpu-whisper`: health: starting (within start_period) — endpoint responding
- `wopr-gpu-qwen-embeddings`: healthy — `curl http://localhost:8083/health` → `{"status":"ok"}`
- GPU node seeded: `local-gpu-node-001` at `172.22.0.3`
- InferenceWatchdog DB: `service_health = {"llama":"ok","qwen":"ok","chatterbox":"ok","whisper":"ok"}`

**Rollback needed:** No

**Notes:** First boot installed Docker + NVIDIA Container Toolkit inside the DinD container (~90s). Large CUDA image layers (1–1.4 GB each) produced containerd layer-lock error spam in logs — normal, resolved on completion. nvidia-smi is at `/usr/lib/wsl/lib/nvidia-smi`, not in PATH. GPU container was already running from prior outer compose up attempt; just needed time to complete pulls.

---

## Paperclip Platform

### 2026-03-12 — Paperclip Platform local testing stack committed (not yet tested)

**Repos:** wopr-network/paperclip-platform (commit c0d1a6f on main)
**Images:** `paperclip-managed:local` (built from ~/paperclip/Dockerfile.managed), `postgres:16-alpine`, `caddy:2-alpine`
**Result:** Committed + pushed — not yet run end-to-end

**What was added:**
- `docker-compose.local.yml` — full local stack: Postgres + platform API (port 3200) + dashboard from platform-ui-core (port 3000) + Caddy (port 8080) + seed Paperclip container
- `caddy/Caddyfile.local` — no-TLS local routing: `app.localhost:8080` → dashboard, `*.localhost:8080` → tenant proxy
- `.env.local.example` — complete env template (Stripe test keys from ~/wopr-platform/.env, BetterAuth, branding)
- `src/db/index.ts` + `src/db/migrate.ts` — Postgres pool + platform-core Drizzle migrations
- `src/index.ts` — rewritten to wire BetterAuth, DrizzleCreditLedger, DrizzleUserRoleRepository, optional Stripe
- `scripts/local-test.sh` — preflight checks, image build, compose up, health wait, access URLs

**Stripe:** test-mode keys (`sk_test_*`) from `~/wopr-platform/.env`. Stripe SDK initialized when `STRIPE_SECRET_KEY` is set; webhook routes TBD.

**Next steps:**
1. Copy `.env.local.example` → `.env.local`, fill in Stripe test keys
2. Build `paperclip-managed:local` image
3. Run `bash scripts/local-test.sh` end-to-end
4. Wire Stripe webhook + checkout flow routes

---

### 2026-03-19 21:30 UTC — Shared chain server deployed (DigitalOcean SFO2)

**Repos:** wopr-network/wopr-ops
**VPS:** DigitalOcean s-2vcpu-4gb ($24/mo), IP 167.71.118.221, Private IP 10.120.0.5, sfo2
**Images deployed:**
- `btcpayserver/bitcoin:30.2` (mainnet, pruned 550MB, custom wrapper entrypoint)
- `nicolasdorier/nbxplorer:2.6.1`
- `btcpayserver/btcpayserver:2.3.5`
- `postgres:16-alpine` (databases: chain, nbxplorer, btcpayserver)

**DNS:** pay.wopr.bot → 167.71.118.221 (Cloudflare, proxy OFF)

**Result:** Success — UTXO snapshot (block 910,000, 9GB torrent) loaded via assumeutxo. Tip chain at 92%+, syncing to current. Background IBD validating old history.

**Architecture:** Shared chain node serving all 4 products via DO private networking (10.120.0.5:23002). Products point BTCPAY_BASE_URL at private IP.

**Issues encountered:**
1. BTCPay UTXO snapshot server (utxo-sets.btcpayserver.org) unreachable — used community torrent instead
2. BITCOIN_EXTRA_ARGS `\n` not expanding in compose env — BTCPay entrypoint writes literal `\n` to bitcoin.conf. Fixed with custom wrapper entrypoint that writes proper config and execs bitcoind directly.
3. BTCPay `bitcoin-wallet -mainnet` bug (same as holyship VPS) — wrapper bypasses entrypoint entirely.

**Next steps:**
1. Wait for tip chain to fully sync (~31K blocks remaining)
2. BTCPay admin setup at http://167.71.118.221:23002
3. Create stores for holyship, wopr, paperclip, nemoclaw
4. Update each product .env: BTCPAY_BASE_URL=http://10.120.0.5:23002
5. Resize droplet to s-1vcpu-2gb ($12/mo) after full sync

**Rollback needed:** No
