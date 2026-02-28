# WOPR Production Runbook

> Updated by the DevOps agent after every operation. Never edit manually outside of agent sessions.

## Current State

**Status:** PRE-PRODUCTION — not yet deployed to VPS
**Last Updated:** 2026-02-28
**Last Operation:** Local dev stack validated — VPS node + voice profile healthy; GPU node seeding pending

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

Files: `docker-compose.local.yml`, `Caddyfile.local`, `.env.local.example` (all in wopr-ops root).

This stack simulates the full production topology on a single host with GPU pass-through. Two logical nodes run on one machine: a VPS node (postgres, platform-api, platform-ui, Caddy) and a GPU node (llama-cpp, qwen-embeddings, chatterbox, whisper). Both share the `wopr-local` Docker network so platform-api can reach GPU services by container name.

**Last validated:** 2026-02-28. Full VPS node stack confirmed healthy. Voice GPU profile confirmed running. GPU node seeding not yet done — next step.

### Current Running State (2026-02-28)

| Container | Status | Notes |
|-----------|--------|-------|
| wopr-ops-postgres-1 | healthy | |
| wopr-ops-platform-api-1 | healthy | port 3100 inside network |
| wopr-ops-platform-ui-1 | healthy | port 3000 inside network |
| wopr-ops-caddy-1 | running | port 80 → ui, api.localhost → api |
| wopr-local-chatterbox | running | port 8081, `--profile voice` |
| wopr-local-whisper | running | port 8082, `--profile voice` |

GPU profile (`--profile llm`: llama-cpp port 8080, qwen-embeddings port 8083) not yet started. Next action: seed GPU node registration.

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

### Starting the stack

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

Production GPU nodes self-register via cloud-init by POSTing to `/internal/gpu/register`. In local dev, run the seeder manually after the stack is healthy:

```bash
docker compose -f docker-compose.local.yml --env-file .env.local \
  run --rm gpu-seeder
```

This does two things:
1. Upserts a row in `gpu_nodes` with `host=llama-cpp` (the container name the InferenceWatchdog polls)
2. POSTs `POST /internal/gpu/register?stage=done` with the GPU_NODE_SECRET to mark the node active

The seeder is idempotent — safe to re-run. The `GPU_NODE_ID` in `.env.local` is the stable node identity.

**Status:** GPU node seeding not yet done as of 2026-02-28. This is the next step.

### Health checks

```bash
curl http://localhost:3100/health           # platform-api → {"status":"ok"}
curl -I http://localhost                    # Caddy → 200
curl http://localhost:8081/health           # chatterbox (voice profile)
curl http://localhost:8082/health           # whisper (voice profile)
curl http://localhost:8080/health           # llama-cpp (llm profile)
curl http://localhost:8083/health           # qwen-embeddings (llm profile)
```

### Known limitations vs production

| Area | Production | Local Dev |
|------|-----------|-----------|
| TLS | Caddy DNS-01 via Cloudflare, HTTPS everywhere | Plain HTTP, no TLS |
| Domain | `wopr.bot`, `api.wopr.bot` | `localhost`, `api.localhost` |
| GPU node | Separate DO droplet, cloud-init self-registration | Same host, manual seeder (not yet run) |
| GPU node reboot | InferenceWatchdog reboots DO droplet | Watchdog runs but reboot fails (no droplet) — harmless |
| BETTER_AUTH_URL | `https://api.wopr.bot` | `http://localhost:3100` |
| COOKIE_DOMAIN | `.wopr.bot` | `localhost` |
| Platform images | Built by CI, pushed to GHCR | Build from source — GHCR tags are stale |
| VRAM | A100 80 GB or similar | RTX 3070 8 GB — use Q4 quantization for llama |
| Stripe | Live keys, real payments | Test keys, no real charges |
| Email | Resend with verified domain | Disabled (placeholder API key) |

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
