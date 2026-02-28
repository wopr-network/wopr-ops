# WOPR Two-Machine Local Dev Topology

Replicates the production stack as two Docker-in-Docker (DinD) containers on one host:

| Container | Simulates | Services |
|-----------|-----------|---------|
| `wopr-vps` | DO VPS droplet | postgres, platform-api, platform-ui, caddy |
| `wopr-gpu` | DO GPU droplet | llama-cpp, chatterbox, whisper, qwen-embeddings |

Both containers share the `wopr-dev` bridge network. Platform-api reaches GPU services via the `wopr-gpu` hostname on ports 8080-8083, exactly as production platform-api reaches the GPU droplet by IP.

## Prerequisites

1. **NVIDIA Container Toolkit** on the host — `nvidia-smi` must work inside Docker:
   ```bash
   docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
   ```

2. **Model weights at `/opt/models/`** — required files:
   - `Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf` (~5 GB VRAM, Q4_K_M for RTX 3070)
   - `qwen2-0_5b-instruct-q8_0.gguf` (~1 GB VRAM)
   - Whisper and Chatterbox models auto-download on first start

3. **Env files** — copy the examples and fill in values:
   ```bash
   cp local/vps/.env.example local/vps/.env
   cp local/gpu/.env.example local/gpu/.env
   # Edit both files — generate secrets with: openssl rand -hex 32
   ```

4. **GHCR login** — required to pull private platform images:
   ```bash
   echo <token> | docker login ghcr.io -u <github-username> --password-stdin
   ```
   Or build images locally (see RUNBOOK.md — GHCR tags may be stale).

## Starting the stack

```bash
# From the wopr-ops directory
docker compose -f local/docker-compose.yml up -d
```

The GPU container installs Docker + NVIDIA Container Toolkit on first boot (~90s).
Subsequent boots are faster (~15s) because the `gpu-docker-data` volume persists.

Watch startup progress:
```bash
docker logs -f wopr-gpu    # GPU machine bootstrap
docker logs -f wopr-vps    # VPS machine
```

## Seeding the GPU node

After both containers are up and their inner stacks are healthy, seed the GPU node
registration row into postgres:

```bash
bash local/gpu-seeder.sh
```

This upserts a `gpu_nodes` row with the wopr-gpu container's IP address and
restarts platform-api so InferenceWatchdog picks it up on its next 30s poll.

## Accessing services

From the host (or WSL2):

```bash
curl http://localhost:3100/health    # platform-api → {"status":"ok"}
curl -I http://localhost             # platform-ui via Caddy → 200
curl http://localhost:8080/health    # llama-cpp
curl http://localhost:8081/health    # chatterbox
curl http://localhost:8082/health    # whisper
curl http://localhost:8083/health    # qwen-embeddings
```

For Caddy subdomains, add to `/etc/hosts`:
```
127.0.0.1 api.localhost app.localhost
```

## Useful commands

```bash
# Follow logs for the VPS inner stack
docker exec wopr-vps sh -c "cd /workspace/vps && docker compose logs -f platform-api"

# Follow logs for the GPU inner stack
docker exec wopr-gpu sh -c "cd /workspace/gpu && docker compose logs -f"

# Restart platform-api (e.g. after env change)
docker exec wopr-vps sh -c "cd /workspace/vps && docker compose restart platform-api"

# Check inner compose status
docker exec wopr-vps sh -c "cd /workspace/vps && docker compose ps"
docker exec wopr-gpu sh -c "cd /workspace/gpu && docker compose ps"

# Re-run gpu-seeder (idempotent — safe to run multiple times)
bash local/gpu-seeder.sh
```

## Teardown

```bash
# Stop and remove containers (preserves volumes — data survives)
docker compose -f local/docker-compose.yml down

# Full teardown including all data
docker compose -f local/docker-compose.yml down -v
docker network rm wopr-dev 2>/dev/null || true
```

## Topology diagram

```
Host machine
├── wopr-dev (bridge network)
│   ├── wopr-vps (docker:27-dind)  [ports 80, 3100]
│   │   └── Inner Docker daemon
│   │       ├── wopr-vps-postgres      :5432
│   │       ├── wopr-vps-platform-api  :3100  (extra_hosts: wopr-gpu → host-gateway)
│   │       ├── wopr-vps-platform-ui   :3000
│   │       └── wopr-vps-caddy         :80
│   │
│   └── wopr-gpu (nvidia/cuda + Docker)  [ports 8080-8083]
│       └── Inner Docker daemon (NVIDIA runtime)
│           ├── wopr-gpu-llama-cpp        :8080
│           ├── wopr-gpu-chatterbox       :8081
│           ├── wopr-gpu-whisper          :8082
│           └── wopr-gpu-qwen-embeddings  :8083
```

Platform-api reaches GPU services via: `wopr-gpu:8080-8083` (resolved through
the outer wopr-dev bridge via `extra_hosts: wopr-gpu:host-gateway` inside the
vps DinD container).

## Differences from the flat `docker-compose.local.yml` approach

| Aspect | Flat (old) | DinD two-machine (new) |
|--------|-----------|----------------------|
| Topology | Single Docker network, all services visible to each other | Two machines with a bridge — matches prod isolation |
| GPU host | `host.docker.internal` or service name | `wopr-gpu` hostname (container IP) |
| First boot time | Instant | ~90s (Docker + NVIDIA toolkit install in gpu container) |
| Complexity | Lower | Higher — two layers of Docker |
| Prod fidelity | Lower | Higher — network hops match prod |

Use the flat approach (`docker-compose.local.yml`) for rapid iteration.
Use this DinD approach when testing multi-machine behavior: GPU node registration,
InferenceWatchdog, network error handling between VPS and GPU.
