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

## 2026-03-01 — Caddy LAN access: catch-all block required

Caddy named site blocks match the `Host` header exactly. `http://localhost` only serves requests where `Host: localhost`. LAN access from another machine sends `Host: 192.168.1.239` — Caddy finds no match and returns empty 200 (content-length 0), which looks like a blank page. Fix: add `http://` catch-all block after the named sites.

Also: `caddy reload` does not re-read bind-mounted files — it reloads from the running process state. After editing a bind-mounted Caddyfile, `docker restart` is required.

Diagnosis tip: `Content-Length: 0` + HTTP 200 = Caddy no-match. A real upstream failure returns 502/504.

## 2026-02-28 — GPU node separate from bot fleet

GPU nodes are shared infrastructure with no per-tenant capacity. They have different health semantics (inference endpoints vs WebSocket self-registration). Sharing the node state machine would conflate unrelated concerns (see GPU Inference Infrastructure design doc in Linear).

---

### 2026-03-18 — BTCPay bitcoind won't start on mainnet

**What we were trying to do:**
We added Bitcoin payments to Holy Ship (holyship.wtf) by copying the BTCPay stack from paperclip-platform. Paperclip runs on regtest (fake local chain for testing). Holy Ship needs mainnet (real Bitcoin). We changed `BITCOIN_NETWORK=regtest` to `mainnet` and the bitcoind container started crash-looping.

**What went wrong:**
The BTCPay project's Docker image (`btcpayserver/bitcoin:30.2`) has a bug in its entrypoint script. On first boot, it creates a wallet by running:

```
bitcoin-wallet -${BITCOIN_NETWORK} -datadir=... -wallet= create
```

For regtest this becomes `bitcoin-wallet -regtest` which is valid. For testnet, `-testnet` is valid. But for mainnet it becomes `bitcoin-wallet -mainnet` — and `-mainnet` is not a real flag. Bitcoin Core doesn't need a network flag for mainnet because mainnet is the default. The container dies with `Error parsing command line arguments: Invalid parameter -mainnet` before bitcoind ever starts.

We tried: removing the env var entirely (entrypoint defaults to `mainnet` internally), setting it empty (entrypoint still fills in `mainnet`), wiping the volume. Nothing helps because the bug is baked into the image's entrypoint at line 40 of `/entrypoint.sh`.

**What we did about it:**
We wrote a custom entrypoint (`/opt/holyship/bitcoind-entrypoint.sh`) that runs BEFORE the stock entrypoint. It starts a temporary bitcoind, creates the wallet using `bitcoin-cli createwallet` (which works fine on mainnet), shuts it down, then hands off to the stock entrypoint. The stock entrypoint sees the wallet already exists and skips the broken `bitcoin-wallet` call.

The custom entrypoint is bind-mounted into the container:
```yaml
entrypoint: ["/custom-entrypoint.sh", "bitcoind"]
volumes:
  - ./bitcoind-entrypoint.sh:/custom-entrypoint.sh:ro
```

**Current state:**
Bitcoind is syncing mainnet (pruned to 550MB). Headers downloading, peers connected, working correctly. BTCPay and nbxplorer are running and will be ready once sync completes.

**What should happen next:**
Report the bug upstream at https://github.com/btcpayserver/dockerfile-deps. The fix is trivial — skip the `-${BITCOIN_NETWORK}` flag when the value is `mainnet`. Once they fix it, we can drop our custom entrypoint.

**Who this affects:**
Anyone using `btcpayserver/bitcoin:30.2` with `BITCOIN_NETWORK=mainnet`. Paperclip is unaffected (regtest). The WOPR VPS doesn't run BTCPay.
