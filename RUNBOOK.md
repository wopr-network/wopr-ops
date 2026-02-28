# WOPR Production Runbook

> Updated by the DevOps agent after every operation. Never edit manually outside of agent sessions.

## Current State

**Status:** PRE-PRODUCTION — not yet deployed to VPS
**Last Updated:** 2026-02-28
**Last Operation:** Status check — all code blockers confirmed Done in Linear

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

### Prerequisites

1. **NVIDIA Container Toolkit** — install from https://github.com/NVIDIA/nvidia-container-toolkit. Verify with `nvidia-smi` and `docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi`.

2. **Model weights at `/opt/models/`** on the host — the compose file bind-mounts this path read-only into the GPU containers. Required files:
   - `Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf` (~5 GB VRAM, recommended for RTX 3070)
   - `qwen2-0_5b-instruct-q8_0.gguf` (~1 GB VRAM)
   - Whisper model is auto-downloaded from HuggingFace on first start
   - Chatterbox is a placeholder (see note below)

   Download with huggingface-cli or llama.cpp's `tools/download.py`.

3. **GHCR access** — `docker login ghcr.io` if pulling private images.

4. **`.env.local`** — copy from `.env.local.example` and fill in secrets:
   ```bash
   cp .env.local.example .env.local
   # Edit .env.local — generate secrets with: openssl rand -hex 32
   ```

### Starting the stack

```bash
# From wopr-ops directory
docker compose -f docker-compose.local.yml --env-file .env.local up -d
```

Watch logs until healthy:

```bash
docker compose -f docker-compose.local.yml logs -f platform-api
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

### Accessing services

| Service | URL |
|---------|-----|
| Platform UI | http://localhost (via Caddy) or http://localhost:3000 (direct) |
| Platform API | http://localhost:3100 (direct) |
| API via Caddy | http://api.localhost (add to /etc/hosts) |
| App via Caddy | http://app.localhost (add to /etc/hosts) |
| llama-cpp | http://localhost:8080 |
| chatterbox (placeholder) | http://localhost:8081 |
| whisper | http://localhost:8082 |
| qwen-embeddings | http://localhost:8083 |

To use Caddy subdomains, add to `/etc/hosts`:
```
127.0.0.1 api.localhost app.localhost
```

### Health checks

```bash
curl http://localhost:3100/health           # platform-api → {"status":"ok"}
curl -I http://localhost                    # Caddy → 200
curl http://localhost:8080/health           # llama-cpp
curl http://localhost:8082/health           # whisper
curl http://localhost:8083/health           # qwen-embeddings
```

### Known limitations vs production

| Area | Production | Local Dev |
|------|-----------|-----------|
| TLS | Caddy DNS-01 via Cloudflare, HTTPS everywhere | Plain HTTP, no TLS |
| Domain | `wopr.bot`, `api.wopr.bot`, `app.wopr.bot` | `localhost`, `api.localhost`, `app.localhost` |
| GPU node | Separate DO droplet, cloud-init self-registration | Same host, manual seeder |
| GPU node reboot | InferenceWatchdog reboots DO droplet | Watchdog runs but reboot fails (no droplet) — harmless |
| BETTER_AUTH_URL | `https://api.wopr.bot` | `http://localhost:3100` |
| COOKIE_DOMAIN | `.wopr.bot` | `localhost` |
| Chatterbox | `travisvn/chatterbox-tts-api:v1.0.1` (real TTS) | `fedirz/faster-whisper-server` placeholder on port 8081 — health checks pass but TTS does not work |
| VRAM | A100 80 GB or similar | RTX 3070 8 GB — must use Q4 quantization for llama |
| Stripe | Live keys, real payments | Test keys, no real charges |
| Email | Resend with verified domain | Disabled (placeholder API key) |

### Chatterbox placeholder

The production chatterbox image (`travisvn/chatterbox-tts-api:v1.0.1`) requires validation on RTX 3070 (8 GB VRAM). Until that validation is done, the local stack uses `fedirz/faster-whisper-server` on port 8081 as a port/healthcheck-compatible placeholder. The InferenceWatchdog and platform-api will see port 8081 as healthy. TTS calls will fail with unexpected responses.

To swap in the real chatterbox image once validated, edit `docker-compose.local.yml` — the service has a `# PLACEHOLDER` comment marking the image line and the required substitution.

### Teardown

```bash
docker compose -f docker-compose.local.yml --env-file .env.local down -v
```

The `-v` flag removes volumes including the postgres database. Omit it to preserve data across restarts.
