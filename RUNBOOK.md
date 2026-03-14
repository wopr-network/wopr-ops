# WOPR Production Runbook

> Updated by the DevOps agent after every operation. Never edit manually outside of agent sessions.

## Current State

**Status:** PRE-PRODUCTION — not yet deployed to VPS
**Last Updated:** 2026-03-05
**Last Operation:** Full DinD local dev stack online — VPS + GPU containers both healthy (2026-03-05). GPU: RTX 3070 8GB, CUDA 13.0. All 9 services healthy. GPU seeded — InferenceWatchdog confirmed llama, qwen, chatterbox, whisper all ok.

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
paperclip-platform (Hono API)         platform-ui-core (npm @wopr-network/platform-ui-core, v1.1.3, tag-triggered publish)
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
| platform-ui-core | `git tag v1.x.y && git push --tags` → CI publishes to npm | `cd ~/paperclip-platform-ui && pnpm update @wopr-network/platform-ui-core && cd ~/paperclip-platform && docker compose up --build dashboard` |
| paperclip (managed image) | `cd ~/paperclip && docker build -t tsavo/paperclip-managed:local -f Dockerfile.managed . && docker push tsavo/paperclip-managed:local` | `cd ~/paperclip-platform && docker compose down -v && docker compose up --build` (fleet pulls on create) |
| paperclip-platform | Rebuild Docker: `docker compose up --build platform` | N/A (leaf node) |
| paperclip-platform-ui | Rebuild Docker: `docker compose up --build dashboard` | N/A (leaf node) |

### Repositories

| Repo | Local Path | npm Package | Purpose |
|------|-----------|-------------|---------|
| wopr-network/platform-core | ~/platform-core | @wopr-network/platform-core (v1.14.4) | Shared backend: DB, auth, billing, fleet, gateway |
| wopr-network/platform-ui-core | ~/platform-ui-core | @wopr-network/platform-ui-core (v1.1.3) | Brand-agnostic Next.js UI (dashboard, auth pages) |
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
| seed | paperclip-managed:local | 3100 (internal) | N/A |

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

- **Integer math only** — credit values are nanodollars. Never floating point for money.
- **Balanced journal entries** — every mutation posts `sum(debits) === sum(credits)`.
- **API boundary** — backend sends `balance_credits` (in cents). UI divides by 100 for display.
- **Idempotent grants** — `grantSignupCredits` uses `referenceId` dedup.
- **Any violation is a bug** — fix immediately.

### Verified E2E Happy Path (2026-03-14)

Tested via curl through Caddy at `runpaperclip.com:8080`:

| Step | Endpoint | Result |
|------|----------|--------|
| Landing page | `GET app.runpaperclip.com:8080` | PASS — Paperclip branding |
| Signup | `POST api.runpaperclip.com:8080/api/auth/sign-up/email` | PASS — user created, `Domain=.runpaperclip.com` cookie |
| $5 credits | `GET .../trpc/billing.creditsBalance` | PASS — `balance_credits: 500` ($5.00) |
| Fleet list | `GET .../trpc/fleet.listInstances` | PASS — `{"bots":[]}` |
| Create instance | `POST .../trpc/fleet.createInstance?batch=1` | PASS — container running, healthy |
| Tenant subdomain | `GET my-org.runpaperclip.com:8080` | PASS — Caddy → platform proxy → container UI |

### Health checks

```bash
# Platform API
curl http://localhost:3200/health

# Dashboard (via Caddy)
curl -I http://app.localhost:8080

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

### Caddy routing (local)

The local Caddyfile (`caddy/Caddyfile.local`) uses plain HTTP, no TLS:

| URL Pattern | Destination | Purpose |
|-------------|-------------|---------|
| http://app.localhost:8080 | dashboard:3000 | Dashboard UI |
| http://localhost:8080 | redirect → app.localhost:8080 | Bare domain redirect |
| http://*.localhost:8080 | platform:3200 | Tenant subdomain proxy |

Chrome and Firefox resolve `*.localhost` to 127.0.0.1 automatically. No `/etc/hosts` entries needed.

### Stripe integration

- **Test keys:** `sk_test_*` from `~/wopr-platform/.env` — no real charges
- **SDK initialized** when `STRIPE_SECRET_KEY` is set in `.env.local`
- **Webhook routes:** not yet wired — credits can be manually granted via admin API for now
- **Checkout flow:** not yet implemented

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
- [ ] Stripe switched to live keys
- [ ] Stripe webhook endpoint registered + checkout flow wired
- [ ] BetterAuth URL set to https://api.runpaperclip.com (or appropriate)
- [ ] GHCR CI/CD pipeline for paperclip-platform + paperclip images
- [ ] Smoke test: sign-up → pay → instance provisioned → subdomain accessible
