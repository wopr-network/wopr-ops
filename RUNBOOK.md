# WOPR Production Runbook

> Updated by the DevOps agent after every operation. Never edit manually outside of agent sessions.

## Current State

**Status:** PRE-PRODUCTION — not yet deployed to VPS
**Last Updated:** 2026-02-28
**Last Operation:** DinD local dev environment stabilized and fully verified (2026-02-28)

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

# 2. Create local/vps/.env from ~/wopr-platform/.env on the host
#    (gitignored — must recreate after fresh clone)
grep -v '^#' ~/wopr-platform/.env | grep -v '^$' | \
  grep -v 'DOMAIN=' | grep -v '_DB_PATH=' | grep -v 'METER_' | \
  grep -v 'SNAPSHOT_' | grep -v 'TENANT_KEYS_' > ~/wopr-ops/local/vps/.env
echo "POSTGRES_PASSWORD=wopr_local_dev" >> ~/wopr-ops/local/vps/.env
echo "GPU_NODE_SECRET=wopr_local_gpu_secret" >> ~/wopr-ops/local/vps/.env
echo "COOKIE_DOMAIN=localhost" >> ~/wopr-ops/local/vps/.env

# 3. Start the stack
docker compose -f ~/wopr-ops/local/docker-compose.yml up -d

# 4. VPS boots, logs in to GHCR, pulls images, starts inner stack (~2 min first boot)
docker logs -f wopr-vps   # watch for "==> VPS stack started."

# 5. Seed GPU node registration (run after both containers are healthy)
bash ~/wopr-ops/local/gpu-seeder.sh
```

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
