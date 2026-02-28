# WOPR Production Topology

## Repositories

| Repo | Purpose | Registry Image |
|------|---------|----------------|
| wopr-network/wopr-platform | Hono API, Drizzle/Postgres, tRPC, fleet, billing, auth | ghcr.io/wopr-network/wopr-platform |
| wopr-network/wopr-platform-ui | Next.js dashboard | ghcr.io/wopr-network/wopr-platform-ui |
| wopr-network/wopr | WOPR bot core — one container per tenant | ghcr.io/wopr-network/wopr |
| wopr-network/wopr-ops | This logbook | N/A |

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
