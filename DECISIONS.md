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

**Simpler fix found (nemoclaw-platform, 2026-03-18):**
The custom entrypoint works but there's a one-liner: set `CREATE_WALLET=false` in the bitcoind service environment. The entrypoint checks this flag before running `bitcoin-wallet` and skips wallet creation entirely. BTCPay doesn't need a wallet for payment processing — it only needs the RPC interface. No custom entrypoint, no bind-mount, no pre-boot dance.

```yaml
bitcoind:
  environment:
    CREATE_WALLET: "false"
```

Bitcoind starts clean, syncs mainnet, nbxplorer connects, BTCPay works. If you want to simplify the holyship stack you can drop the custom entrypoint and use this instead.

**Further update (2026-03-20):** We abandoned BTCPay entirely. See the dedicated chain server decision below.

---

## 2026-03-20 — Dedicated chain server replaces per-product BTCPay

**Context:** We initially deployed bitcoind + nbxplorer + BTCPay on each product's VPS ($6 droplets). Problems: 1GB RAM couldn't sync mainnet (8% after days), each product would need its own chain sync, wasted disk/RAM across 4 droplets.

**Decision:** One dedicated chain server (s-2vcpu-4gb, $24/mo) at pay.wopr.bot running just bitcoind. All 4 products connect via DO private networking or DNS. BTCPay removed entirely — platform-core's native BTC watcher talks to bitcoind RPC directly. NBXplorer removed — not needed without BTCPay.

**Result:** Chain server syncing at ~23 blocks/min with assumeutxo snapshot (block 910,000 via torrent). Single bitcoind serves holyship, wopr, paperclip, nemoclaw. Will resize to $12/mo after sync.

---

## 2026-03-20 — Caddy needs custom build + explicit network

**Context:** After scp'ing an updated docker-compose.yml to the holyship VPS, Caddy started crash-looping with "module not registered: dns.providers.cloudflare". The local compose used stock `caddy:2-alpine` but the Caddyfile requires the cloudflare DNS plugin for DNS-01 TLS challenges.

**Decision:** Caddy must always use a custom-built image (`caddy-cloudflare`) with the cloudflare DNS plugin. Build from `caddy/Dockerfile` (xcaddy + github.com/caddy-dns/cloudflare). Also: Caddy MUST be on the same Docker network as API and UI services — compose `networks:` section is required.

**Gotcha:** When the compose defines a named network (e.g., `holyship`), Docker creates it as `<project>_holyship`. If any service doesn't explicitly join that network, it lands on `<project>_default` and can't resolve other service names. This caused 502 errors — Caddy couldn't reach `api:3001` or `ui:3000`.

---

## 2026-03-20 — BITCOIN_EXTRA_ARGS newline expansion broken in Docker Compose

**Context:** The `btcpayserver/bitcoin` image accepts `BITCOIN_EXTRA_ARGS` as a newline-separated list of bitcoin.conf directives. When set via Docker Compose environment variables, `\n` escape sequences are written literally to the config file rather than expanding into real newlines.

**Decision:** Use a wrapper entrypoint script that writes a proper `bitcoin.conf` file directly and execs `bitcoind` bypassing the stock entrypoint entirely. This avoids all the BTCPay entrypoint quirks and gives full control over config generation.

---

## 2026-03-20 — Crypto key server replaces BTCPay across all products

**Context:** BTCPay was a per-product nightmare: 4 separate stacks, 4 sets of xpubs, 4 watchers, 4 webhook configs. Each $6 droplet couldn't sync mainnet. Even the shared chain server only ran bitcoind — products still needed their own watchers and webhook plumbing.

**Decision:** Centralized crypto key server (`pay.wopr.bot:3100`) built into platform-core. Products call `POST /charges` and receive webhooks — no local watchers, no xpubs, no BTCPay. Key server handles: HD address derivation (BIP-44), Chainlink on-chain oracle for exchange rates, native amount tracking (sats/token units, locked at charge creation), partial payment accumulation, durable webhook delivery (outbox pattern with exponential backoff).

**Stack:** Hono HTTP + Drizzle/Postgres + bitcoind, all Docker on one droplet. Auth: service key for products, admin token for path registration.

**Result:** BTCPay completely removed from platform-core (v1.44.0). `CryptoServiceClient` replaces `BTCPayClient`. All 4 products bumped. Old BTCPay env vars (`BTCPAY_*`) replaced with `CRYPTO_SERVICE_URL` + `CRYPTO_WEBHOOK_SECRET`.

---

## 2026-03-21 — DOGE/LTC node deployment

**Context:** Chain server needs DOGE and LTC nodes alongside bitcoind for native payment processing.

**DOGE — synced via temp droplet + GHCR snapshot:**
Temp droplet downloaded blockchain snapshot from `Blockchains-Download/Dogecoin` GitHub releases (Dec 2025, 10GB compressed → 17GB extracted), synced to tip, pushed pruned blocks to `ghcr.io/wopr-network/doge-chaindata:latest`, destroyed droplet. Loaded blocks on chain server, dogecoind rebuilding chainstate from local blocks.

**LTC — syncing from peers directly on chain server:**
Attached 100GB DO block storage volume (`ltc-sync`, $10/mo) to chain server at `/mnt/ltc_sync`. Running `uphold/litecoin-core` with `prune=2200`. Syncing ~90GB full chain from peers, will prune to ~2-3GB. After sync: move pruned data to main disk, detach and delete volume.

**Lessons learned:**
- `bootstrap.sochain.com` is dead — use GitHub snapshots (Blockchains-Download org).
- DOGE minimum prune is **2200 MB** (not 2048 like BTC).
- **Never use `-reindex` with prune** — destroys existing block files.
- **LevelDB chainstate has per-instance obfuscation keys** — chainstate does NOT survive across container instances. Only back up blocks/, not chainstate/. The node rebuilds chainstate from blocks automatically (~hours, not days).
- **`blocknetdx/dogecoin` image injects `-txindex=1` by default** — conflicts with prune. Use a wrapper entrypoint to write your own config and `exec dogecoind` directly.
- **`uphold/litecoin-core` is the clean LTC image** — no default flags, passes args straight to litecoind. DNS seeds work out of the box.
- **DOGE DNS seeds fail inside Docker** — hostnames don't resolve in containers. Use IP addresses for `addnode` lines.
- **`FROM scratch` Docker images need a dummy command** for `docker create` — `docker create --name x image ""` works, plain `docker create --name x image` fails with "no command specified".
- Fresh DO droplets have broken `systemd-resolved` — fix immediately: `echo "nameserver 1.1.1.1" > /etc/resolv.conf`
- **DO can't resize disk independently** — disk is tied to plan. Use block storage volumes ($0.10/GB/mo) for temporary extra space.
- **DO block storage 200GB fails** — account limit. 100GB works.

**Cost:** DOGE temp droplet ~$3 total. LTC volume $10/mo temporary.

---

## 2026-03-21 — Wrapper entrypoint pattern for chain nodes

**Context:** Both `btcpayserver/bitcoin` and `blocknetdx/dogecoin` Docker images inject default flags that conflict with our config (mainnet wallet creation bug, txindex=1 with prune). Fighting image defaults via command-line overrides is fragile.

**Decision:** All chain nodes use the same wrapper pattern: bind-mount a shell script as `/opt/wrapper.sh`, write the config file directly, `exec` the daemon. No reliance on image entrypoints or default configs. Used for bitcoind, dogecoind. LTC uses `uphold/litecoin-core` which is clean but still gets the wrapper for consistency.

```yaml
entrypoint: ["/opt/wrapper.sh"]
volumes:
  - ./dogecoind-wrapper.sh:/opt/wrapper.sh:ro
```

---

## 2026-03-21 — Sync LTC on the chain server, not a separate droplet

**Context:** For DOGE, we used a temp droplet to sync, exported to GHCR, then loaded on the chain server. This took all night, cost ~$3, and ultimately failed to preserve the chainstate across containers (LevelDB obfuscation key is per-instance). The only value was the block files — and dogecoind rebuilds chainstate from blocks anyway, taking hours regardless.

**Decision:** Skip the temp droplet for LTC. Attach a temporary 100GB DO block storage volume ($10/mo) to the chain server, sync LTC directly from peers. After sync + prune (~3GB), move pruned data to main disk, detach and delete the volume. Zero GHCR complexity, zero temp droplets, zero chainstate transfer issues.

**Why this is better:**
- Chainstate doesn't transfer across containers, so the GHCR snapshot only saves block download time
- LTC peers are fast enough (~90GB download in 12-24hrs)
- Block storage is $10/mo and can be deleted after sync — cheaper than a temp droplet running for hours
- No risk of extraction failures, Docker image layer gymnastics, or disk space juggling
- The chain server has the CPU/RAM to sync while running other services

**Tradeoff:** No GHCR backup for LTC blocks. If the chain server dies, LTC re-syncs from peers (~24hrs). Acceptable for a pruned node.

---

## 2026-03-21 — Netdata for infrastructure monitoring

**Context:** 4 production droplets with zero monitoring. Chain server running 3 chains at 5x load average with no visibility. Using a Claude Code cron that SSHes in every 30 minutes — inadequate.

**Decision:** Netdata — open source, self-hosted, zero-config Docker monitoring. One container per droplet, all streaming to Netdata Cloud (free tier, 5 nodes). Custom chain sync metrics via host-side systemd service pushing to statsd.

**Why Netdata over Grafana/Prometheus:**
- Zero config — auto-discovers all Docker containers, host metrics, disk, network
- Single container deploy — `netdata/netdata:stable` with `network_mode: host`
- Free cloud dashboard — single pane of glass for all 4 nodes, no self-hosted Grafana
- <5% CPU, ~100MB RAM — lightweight enough for $6 droplets

**Chain metrics architecture:**
- `chain-monitor.service` runs on chain server host (not inside Netdata container — no Docker CLI in Netdata image)
- Parses `docker logs --tail 200 | grep UpdateTip` — no RPC calls (too slow under CPU load, timeouts cause false zeros)
- Must `grep -v "background validation"` for BTC (assumeutxo logs both tip and background chainstate)
- Pushes to Netdata statsd on localhost:8125 (UDP)
- Statsd app config (`chain.conf`) groups raw gauges into multi-dimension charts (blocks vs headers on same chart)
- ETA uses exponential moving average (alpha=0.1) with spike filter (>5x EMA discarded, downward corrections always accepted)
- State persisted to `/opt/chain-server/.chain-monitor-state` — survives restarts without 0-blip

**Lessons learned:**
- `netdata/netdata` container has no `docker` CLI — can't `docker exec` from inside. Run collectors on the host.
- Statsd gauges that receive 0 on timeout show 0 in charts — must use last-known-value pattern
- Wiping `/var/cache/netdata/dbengine/` resets ALL history — charts disappear until data refills
- BTC background validation moves so slowly (~0.05 basis points/sec at 50% CPU cap) that ETA is unreliable — keep it on the chart but don't trust the number

---

## 2026-03-21 — Nemoclaw reprovisioned at s-1vcpu-1gb ($6/mo)

**Context:** Nemoclaw was running on s-2vcpu-4gb ($24/mo) with bitcoind + BTCPay + nbxplorer — all dead weight since the chain server handles crypto. Couldn't resize in place because DO won't shrink disks.

**Decision:** Nuke and reprovision. New droplet at s-1vcpu-1gb ($6/mo), scp .env from old, write clean compose (no BTCPay), update DNS, destroy old droplet.

**Result:** $18/mo saved. 4 containers instead of 7. Same for holyship — removed BTCPay stack (was using 406MB RAM on a 1GB box).

---

## 2026-03-21 — Sequential chain syncing, not parallel

**Context:** Running BTC (background validation) + DOGE + LTC simultaneously on 2 cores pegged the machine at 5x load average. DOGE stalled completely — lost peers, RPC unresponsive, no new blocks for 15+ minutes.

**Decision:** Sync one chain at a time. Stopped DOGE, capped BTC at 50% CPU (`docker update --cpus=0.5`), let LTC have the remaining resources. After LTC syncs, start DOGE. After DOGE syncs, uncap BTC.

**Why:** 2 cores can't serve 3 CPU-intensive chain syncs. Nodes that lose peers and stall waste more time than sequential syncing.

---

## 2026-03-22 — Standardized UTXO RPC credentials

**Context:** BTC used `btcpay:btcpay-chain-2026`, DOGE used `doge:doge-chain-2026`, LTC used `ltc:ltc-chain-2026`. The crypto key server's watcher passes one global `bitcoindUser`/`bitcoindPassword` to all UTXO watchers — can't use different creds per chain.

**Decision:** Standardized all 3 nodes to `rpcuser=btcpay` with the same password. Updated wrapper scripts and `.env`.

**Follow-up:** Proper fix is per-chain RPC credentials stored in `payment_methods` table. Deferred — single cred works for now.

---

## 2026-03-22 — DB-driven EVM watcher config

**Context:** `EvmWatcher` and `EthWatcher` called `getChainConfig()` which only knew `base`, `ethereum`, `arbitrum`, `polygon`. Adding Sepolia for testnet e2e required code changes. The `payment_methods` table already has `rpc_url`, `confirmations`, `decimals`, `contract_address`.

**Decision:** Watchers now take config from opts (sourced from DB), not hardcoded chain registry. `EvmChain` type accepts any string via `(string & {})`. Any chain registered in the DB works without code changes.

**Result:** Registered `LINK:sepolia` and `ETH:base-sepolia` via SQL insert — watchers picked them up on restart with zero code changes. First e2e crypto payment processed (LINK on Sepolia → settled → webhook delivered).

---

## 2026-03-22 — Microdollar oracle pricing (10⁻⁶ USD)

**Context:** DOGE at $0.094 rounded to 9 cents (6% error). Cents don't have enough precision for sub-dollar coins.

**Decision:** Entire oracle pipeline migrated from cents to microdollars (10⁻⁶ USD). DOGE $0.094 = 94,147 microdollars. `priceCents` → `priceMicros` across all interfaces. Bridge constant `MICROS_PER_CENT = 10,000` for conversion.

**Result:** Sub-cent pricing accurate to 6 decimal places. CoinGecko fallback for DOGE/LTC (no Chainlink feeds on Base). CompositeOracle: Chainlink primary → CoinGecko fallback. `AssetNotSupportedError` distinguishes unknown assets (stablecoin 1:1) from transient failures (503 reject).

---

## 2026-03-22 — Shared BETTER_AUTH_SECRET for subdomain cookie auth (Paperclip)

**Context:** Paperclip instances run as separate containers on tenant subdomains (`my-bot.runpaperclip.com`). Users log in once at `app.runpaperclip.com` and expect seamless access to their instance subdomain without re-authenticating.

**Decision:** Share the same `BETTER_AUTH_SECRET` between the platform and all tenant instances. Set `COOKIE_DOMAIN=.runpaperclip.com` so both `session_token` and `session_data` cookies are readable across all subdomains. The leading dot is required for subdomain sharing.

**Result:** Single sign-on across platform and all tenant instances. No per-instance auth flow needed. The tradeoff is that a compromised instance secret would allow forging sessions for any subdomain — acceptable because we control all instance containers.

---

## 2026-03-22 — hosted_proxy deployment mode (Paperclip)

**Context:** Paperclip instances need to know which user is making requests. Options: (1) each instance does its own auth, (2) platform proxy injects user identity and instances trust it.

**Decision:** Instances run in `hosted_proxy` deployment mode. The platform's tenant proxy adds `X-Paperclip-User-Id` header. Instances trust this header without verifying it themselves. `TRUSTED_PROXY_IPS=172.16.0.0/12` restricts trust to Docker internal networks.

**Result:** Simpler instance code — no auth middleware needed in tenant containers. Platform handles all authentication centrally. The CIDR restriction prevents spoofing from outside the Docker network.

---

## 2026-03-22 — Pre-built Caddy image for 1GB droplets

**Context:** Caddy needs the `caddy-dns/cloudflare` plugin for DNS-01 TLS challenges. The standard approach is building with `xcaddy` in a Dockerfile. On 1GB droplets, Go compilation OOMs during `xcaddy build` — Go's compiler and linker need ~1.5GB+ RAM.

**Decision:** Build the custom Caddy image locally (or on a larger machine), push to `ghcr.io/wopr-network/paperclip-caddy:latest`, and pull the pre-built image on the droplet. No build step on the VPS.

**Result:** Caddy starts instantly on 1GB droplets. The image is ~40MB. Rebuild and push when upgrading Caddy or the cloudflare plugin. Same approach should be used for any future product on 1GB droplets (holyship already uses this pattern).

---

## 2026-03-22 — Docker socket permissions via systemd oneshot

**Context:** `platform-api` needs Docker socket access to spawn tenant containers via Dockerode. The default socket permissions are `660 root:docker`. The container process runs as a non-root user and gets EACCES. Adding the container user to the docker group doesn't work across the mount boundary.

**Decision:** A systemd oneshot service (`docker-socket-perms.service`) runs `chmod 666 /var/run/docker.sock` after `docker.service` starts. This persists across reboots without manual intervention.

**Why not `group_add: docker`?** Compose `group_add` maps by GID, and the host's docker GID may not match inside the container. `chmod 666` is simpler and works universally.

**Result:** Platform-api can always access the Docker socket. The security tradeoff (world-readable socket) is acceptable on a single-purpose VPS where the only users are root and deploy.

---

## 2026-03-22 — AWS SES replaces Resend for transactional email

**Context:** All 4 products used Resend for transactional email (verification, notifications, password reset). Resend charges per email after the free tier, requires a per-domain API key, and has no automation API for domain verification. With 4 products and growing, this doesn't scale.

**Decision:** AWS SES as the primary email transport. One AWS account (264991295931), one IAM user (`ses-admin`), one region (`us-east-1`). `platform-core` v1.51.0 adds `SesTransport` that auto-selects SES when `AWS_SES_REGION` is set, falls back to Resend when absent.

**Why SES over Resend:**
- **Cost:** SES is $0.10/1,000 emails with no monthly minimum. Resend free tier caps at 100 emails/day, then $20/mo for 50k. At our volume (low hundreds/day across 4 products), SES is effectively free.
- **Automation:** `ses-verify-domain.sh` script verifies a domain and adds all DNS records (verification TXT, 3 DKIM CNAMEs, SPF) to Cloudflare in one command. Resend requires manual dashboard clicks per domain.
- **Single credential set:** One IAM user serves all 4 products. Resend needs a separate API key per sending domain.
- **Deliverability:** SES has dedicated IP pools, suppression list management, and bounce/complaint dashboards. Resend abstracts these away with less control.

**Tradeoff:** SES starts in sandbox mode — can only send to verified recipients until AWS approves production access. Resend works immediately. During the transition, keep `RESEND_API_KEY` as fallback.

**Rollout plan:**

| Phase | Products | Prereq | Action |
|-------|----------|--------|--------|
| 1 | Paperclip | SES env vars already in .env | Bump platform-core to 1.51.0, rebuild image, restart |
| 2 | WOPR + HolyShip | SES production access approved | Add SES env vars, bump platform-core, deploy |
| 3 | Nemoclaw + cleanup | Phase 2 stable | Verify nemoclaw domain (`ses-verify-domain.sh`), deploy, remove Resend deps, cancel Resend subscription |

**Current state (2026-03-22):**
- 3 domains verified in SES: `runpaperclip.com`, `wopr.bot`, `holyship.wtf`
- DNS records (DKIM + SPF + verification) added to Cloudflare for all 3
- Test email confirmed: `noreply@runpaperclip.com` → `tsavo@wopr.bot`
- SES production access: requested, pending approval
- Paperclip droplet: SES env vars set, awaiting platform-core 1.51.0 image rebuild

---

## 2026-03-22 — Health check window: 30 retries x 2s for first-boot migrations

**Context:** Paperclip tenant instances run 29 Drizzle schema migrations on first boot. The default Docker health check (3 retries x 30s interval) declares the container unhealthy before migrations finish.

**Decision:** Health check configured as `interval: 2s, retries: 30` giving a 60-second window. This covers the migration time on a 1GB droplet while still detecting actual failures reasonably quickly.

**Result:** First boot succeeds within the health window. If it still times out (very slow disk), manual provisioning via `POST /internal/provision` with Bearer token bypasses the health check.

---

## 2026-03-22 — Provision routes at /internal must be explicitly wired

**Context:** Paperclip tenant instances expose `POST /internal/provision` for manual provisioning. This route was expected to be auto-discovered by the Hono router but was returning 404.

**Decision:** The `/internal/*` routes must be explicitly mounted in `app.ts`. They are not auto-discovered because they live outside the standard route directory structure. This is by design — internal routes should be deliberately opt-in.

**Result:** Route wired manually in app.ts. Documented as a gotcha for future internal endpoints.

---

## 2026-03-22 — Holy Ship: COOKIE_DOMAIN for cross-subdomain OAuth

**Context:** GitHub OAuth callback lands on `api.holyship.wtf` which sets the session cookie. The UI at `holyship.wtf` couldn't read it because cookies default to the exact domain that set them.

**Decision:** Set `COOKIE_DOMAIN=.holyship.wtf` on the API container. The leading dot makes cookies readable by all subdomains. Same pattern as Paperclip's `COOKIE_DOMAIN=.runpaperclip.com`.

**Result:** Single OAuth flow: UI → GitHub → API callback → cookie set → UI reads session. No double-login needed.

---

## 2026-03-22 — Holy Ship: Auth client must override baseURL, not inherit from core

**Context:** `platform-ui-core` exports an auth client that reads `NEXT_PUBLIC_API_URL` at build time. But Next.js standalone builds don't trace `NEXT_PUBLIC_*` vars through `node_modules` — the var was undefined in the client bundle, causing auth calls to hit the UI origin instead of the API.

**Decision:** `holyship-ui` overrides the auth client (`src/lib/auth-client.ts`) with an explicit `baseURL` hardcoded to the env var. This is a thin override — 10 lines, re-exports everything from the local client.

**Result:** Auth calls correctly target `api.holyship.wtf` regardless of how Next.js traces env vars through the dependency graph. This applies to any brand shell built on platform-ui-core.

---

## 2026-03-22 — Holy Ship: Worker token not admin token for UI → engine API

**Context:** The UI needs to call engine REST endpoints (`/api/status`, `/api/flows`, `/api/entities`). Engine routes authenticate with `HOLYSHIP_WORKER_TOKEN` (Bearer auth). Initial setup used the admin token, which is for admin-only routes (flow management).

**Decision:** UI container gets `HOLYSHIP_API_TOKEN=${HOLYSHIP_WORKER_TOKEN}` — same token the workers use. The engine's auth middleware checks a single token for all REST routes. Admin routes are separate (tRPC, different auth).

**Result:** UI can read engine data. Worker token is lower privilege than admin token. If we later need separate scopes, the engine auth middleware can be extended.

---

## 2026-03-22 — Holy Ship: Pipeline state ordering via transition graph topology

**Context:** The engine returns flow states in alphabetical order (DB default). The pipeline board displayed: budget_exceeded, cancelled, code, docs... instead of the actual pipeline order.

**Decision:** Client-side topological sort using the transition graph from `/api/flows`. Walk the happy path (first edge at each state from `initialState`), then BFS for side states (fix, stuck), then append orphans (budget_exceeded, cancelled). No server-side change needed — the transition data is already there.

**Result:** Pipeline board shows: spec → code → review → docs → learning → merge → done → fix → stuck → budget_exceeded → cancelled. Matches the actual flow definition.
