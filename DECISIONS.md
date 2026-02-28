# Operational Decisions

> Why we made the infrastructure calls we did. Written by the DevOps agent when a significant choice is made.

## 2026-02-28 — Bare VPS over managed platforms

Tenant bots are persistent always-on containers with named volumes. Managed platforms (Fly.io, Railway, Render) don't support this cleanly. docker-compose gives full control over Docker socket, named volumes, and container lifecycle. Fly.io was specifically rejected after sprint agents deployed it without authorization (WOP-370).

## 2026-02-28 — No Kubernetes

Multi-node scaling is SSH + SQLite routing table. Kubernetes complexity is not justified. Adding a node means SSH to a new VPS and run docker-compose — same pattern, no orchestrator.

## 2026-02-28 — Caddy for TLS, Cloudflare proxy OFF

Caddy handles TLS via DNS-01 challenge using Cloudflare API token. Cloudflare proxy (orange cloud) must be OFF — proxying intercepts TLS and breaks Caddy's certificate management.

## 2026-02-28 — GHCR as container registry

Free for public repos, integrated with GitHub Actions, supports private images for tenant bot pulls from inside platform-api.

## 2026-02-28 — Watchtower for local CD, separate :local image for dev

Watchtower polls GHCR every 60s and auto-restarts containers when a new image digest appears. `NEXT_PUBLIC_API_URL` is baked into the Next.js bundle at build time — runtime env vars have no effect on `NEXT_PUBLIC_*`. So a single image can't serve both staging (staging URL) and local dev (localhost:3100). Solution: `build-local.yml` builds a second image tagged `:local` with `localhost:3100` baked in. Watchtower tracks `:local` in the local dev stack and `:latest` for platform-api.

## 2026-02-28 — DinD env var propagation lessons

Running docker-compose inside a DinD container (docker:27-dind) has several traps:

1. **YAML `>` collapses newlines** — shell `if/fi`, `while/done` blocks break because `>` folds newlines into spaces. Always use `|` (literal block scalar) or list form for multi-line shell scripts in `command:`/`entrypoint:`.

2. **`command:` with `dockerd-entrypoint.sh` as first arg sets `DOCKER_HOST=tcp://docker:2375`** — the entrypoint configures `DOCKER_HOST` internally before running the command arg, so any `docker` calls in the command hit a nonexistent remote host and hang. Use `entrypoint:` list form instead, background `dockerd-entrypoint.sh`, and poll the local socket directly.

3. **Compose v2 doesn't auto-load `.env` from read-only bind mounts** — when `./vps` is mounted `:ro`, compose reads the `.env` file but variable substitution falls back to the shell environment, not the file, for vars not set in the shell. Fix: `set -a && . ./.env && set +a` before `docker compose up -d` to export all vars into the shell environment first.

4. **bind-mounting host paths into inner containers is silently dropped** — the inner Docker daemon can only bind-mount paths within its own filesystem namespace. Mounting `/root/.docker` from the VPS container into a Watchtower container inside DinD doesn't work. Use `REPO_USER`/`REPO_PASS` env vars instead.

5. **`/tmp` is wiped on WSL restart** — never clone repos into `/tmp`. All wopr repos live under `~` on the host.

6. **`local/vps/.env` is gitignored and must be recreated after fresh clone** — source values from `~/wopr-platform/.env` on the host. The `.env.example` documents every required variable.

## 2026-02-28 — GPU node separate from bot fleet

GPU nodes are shared infrastructure with no per-tenant capacity. They have different health semantics (inference endpoints vs WebSocket self-registration). Sharing the node state machine would conflate unrelated concerns (see GPU Inference Infrastructure design doc in Linear).
