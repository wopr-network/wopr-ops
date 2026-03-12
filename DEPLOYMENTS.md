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

*(no production entries yet — system not yet deployed to VPS)*

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
