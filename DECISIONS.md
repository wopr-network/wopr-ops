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

## 2026-03-23 — One chain at a time: contention kills throughput

**Context:** Chain server (s-2vcpu-4gb) was pegged at load 5.5+ with BTC and LTC both syncing. 0% idle CPU, 2.4GB swap in use. LTC syncing at ~8 blocks/sec.

**Decision:** Never sync multiple chains concurrently on a small VPS. Stop already-synced chains during active sync. Resize CPU-only (reversible) if needed.

**Why:** Concurrent chain sync causes cascading contention at every layer:
- **I/O thrashing** — competing page cache evictions, every disk read is a miss
- **Scheduler thrashing** — CPU-bound processes context-switching constantly on 2 cores
- **L2/L3 cache thrashing** — each context switch invalidates the other process's hot cache lines

**Result:** Resized to s-4vcpu-8gb ($48/mo, CPU-only = reversible), stopped BTC. LTC went from 8 blocks/sec → 40+ blocks/sec — a 5x improvement. 2x from more cores, 2x from eliminating contention. LTC finished syncing in ~20 hours.

**Rule:** Sync one chain at a time. Stop the others. Resize temporarily if needed (CPU-only resize is free to reverse).

---

## 2026-03-23 — Bitcoin assumeutxo requires both chainstates

**Context:** BTC uses assumeutxo with two chainstates: `chainstate_snapshot` (at tip, functional) and `chainstate` (background validation from genesis). Background validation was burning CPU. Attempted to delete `chainstate` to skip it.

**Decision:** Do NOT delete the background validation chainstate. Bitcoin Core requires both directories. Deleting `chainstate` causes crash loops ("Failed for FlatFilePos(nFile=-1, nPos=0)"). Creating an empty replacement also fails — pruned block references can't resolve.

**What we tried:**
1. Delete `chainstate` entirely → crash loop, 12 restarts
2. Create empty `chainstate` directory → boots further but still crash loops on block file lookups

**What saved us:** Full backup on external volume (`/mnt/ltc_sync/btc-backup/`). Restored `chainstate` from backup, BTC came up clean.

**Lesson:** Always back up before modifying chainstate. Background validation is the price of assumeutxo — you can't skip it without a full resync.

---

## 2026-03-23 — Chain data migration pattern: external volume → main disk

**Context:** LTC synced on 100GB external DO volume ($10/mo). Needed to move to main disk and eventually delete the volume.

**Decision:** 9-step migration pattern with no data deletion until fully verified:
1. Stop the chain daemon (clean shutdown)
2. Backup to GHCR as OCI artifact (insurance)
3. Copy to Docker named volume on main disk
4. Verify copy (byte count + file count comparison)
5. Update docker-compose.yml (bind mount → named volume with `external: true`)
6. Start daemon on new volume
7. Verify sync resumes (check UpdateTip in logs)
8. Watch for 10+ minutes (no restarts, no errors)
9. Only then: delete external volume

**Key details:**
- Docker Compose prefixes volume names with project name — use `external: true` to reference a manually-created volume by exact name
- Source data stays untouched until step 9
- GHCR backup exists independently from step 2
- Two independent copies before anything gets deleted

**Result:** LTC migrated successfully. DOGE moved to the (now empty) external volume to sync. Same pattern will be applied when DOGE finishes.

---

## 2026-03-23 — DO CPU-only resize for temporary compute needs

**Context:** Chain sync is CPU-bound but temporary. Need more compute during sync, less after.

**Decision:** Use DigitalOcean CPU-only resize (omit `--resize-disk` flag). This changes CPU/RAM but keeps disk size fixed, making the resize fully reversible. Can downsize back to original plan when sync completes.

**Commands:**
```bash
# Upsize (auto powers off)
doctl compute droplet-action resize <id> --size s-4vcpu-8gb --wait
doctl compute droplet-action power-on <id> --wait

# Downsize when done
doctl compute droplet-action resize <id> --size s-2vcpu-4gb --wait
doctl compute droplet-action power-on <id> --wait
```

**Gotcha:** Resize auto-powers-off but does NOT auto-power-on. Must explicitly `power-on` after.

**Cost:** $48/mo during sync, $24/mo after. Temporary spend for 5x throughput.

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

## 2026-03-24 — Postmark replaces AWS SES for transactional email

**Context:** Switched from SES to Postmark. SES sandbox mode was blocking sends to unverified recipients and production access approval was pending indefinitely. Postmark has no sandbox — verified domains can send immediately.

**Decision:** Postmark as the sole email transport. One Postmark account, one server ("Paperclip"), one server token shared across all products. Replaces both SES and Resend.

**Why Postmark over SES:**
- **No sandbox** — verified domains send immediately, no AWS production access approval wait.
- **Simpler credentials** — one `POSTMARK_API_KEY` env var vs three AWS vars (`AWS_SES_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).
- **Better deliverability defaults** — dedicated IP pool, automatic DKIM rotation, built-in suppression management.
- **Cost:** $15/mo for 10,000 emails. At our volume this is negligible.

**Migration (2026-03-24):**
- Removed AWS SES env vars from all products
- Added `POSTMARK_API_KEY` to Paperclip `.env.production`
- 5 domains verified in Postmark (SPF + DKIM + Return-Path): `nefariousplan.com`, `runpaperclip.com`, `wopr.bot`, `holyship.wtf`, `nemopod.com`
- DNS records (DKIM TXT + Return-Path CNAME) added to Cloudflare for all domains
- **All products can now send email from any verified domain** — no phased rollout needed

---

## 2026-03-24 — Staging on same VPS with Watchtower auto-deploy

**Context:** No staging environment existed. Every change went straight to prod. Need a way to test before promoting, without extra droplets.

**Decision:** Run staging alongside prod on the same VPS using compose overlays. Watchtower auto-pulls new images. Promote via GitHub Actions `workflow_dispatch` that retags `:staging` → `:latest`.

**Architecture:**
- Each VPS has `docker-compose.yml` (prod) + `docker-compose.staging.yml` (staging overlay)
- Staging services: `staging-postgres`, `staging-api`, `staging-ui` — separate DB, separate auth secret
- Caddy routes `staging.<domain>` to staging containers
- Watchtower polls GHCR every 60s, auto-restarts on new images
- CI pushes `:staging` tag → Watchtower pulls → staging updates
- Promote workflow retags `:staging` → `:latest` → Watchtower pulls → prod updates

**Staging env differences:**
- `EMAIL_DISABLED=true` — no emails sent
- `SKIP_EMAIL_VERIFICATION=true` — signup skips verification
- Separate `STAGING_BETTER_AUTH_SECRET` — sessions isolated from prod
- `NODE_ENV=staging`
- DB seeded from prod snapshot at deploy time

**DNS:** `staging.*`, `staging.api.*`, `staging.app.*` A records for all 4 domains → same droplet IPs.

**Promote:** `gh workflow run promote --field product=<name>` from wopr-ops repo.

---

## 2026-03-24 — Watchtower for auto-deploy

**Context:** Manual SSH + `docker compose pull` + `docker compose up -d` for every deploy. Tedious and error-prone.

**Decision:** Watchtower on all 4 VPSes. Polls GHCR every 60s, auto-pulls new images, recreates containers. GHCR auth via `/root/.docker/config.json`.

**Tradeoff:** 60s max delay between image push and deploy. Acceptable for our scale. If we need instant deploys, switch to webhook-triggered.

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

---

## 2026-03-22 — Holy Ship: DOCKER_NETWORK must match compose network name

**Context:** Worker containers spawned by the fleet manager joined `holyship_default` but the API container was on `holyship`. Workers couldn't reach the API.

**Decision:** `DOCKER_NETWORK=holyship` in the compose file, matching the actual network name from `docker network ls`. The compose-generated default network (`holyship_default`) is not the one used when a named network is defined in `networks:`.

**Result:** Worker containers spawn on the correct network and can reach `api:3001`.

---

## 2026-03-22 — Holy Ship: Fleet manager needs Docker group + registry creds

**Context:** Engine container couldn't create worker containers — Docker socket was `rw` for group `docker` (GID 988) but the container didn't have that group. Also, anonymous GHCR pulls were rate-limited.

**Decision:** Add `group_add: ["988"]` to the API service in compose. Pass `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`, `REGISTRY_SERVER` env vars so fleet manager authenticates pulls.

**Result:** Fleet manager creates containers in ~2s. Authenticated pulls avoid rate limits.

---

## 2026-03-22 — Holy Ship: InterrogationService was using noopFleet

**Context:** Clicking "Analyze Repo" in the UI caused the engine to log "[interrogation] provisioning runner" then hang silently. The InterrogationService was initialized with a `noopFleet` that always rejected — the real `HolyshipperFleetManager` was scoped inside the worker pool `if` block.

**Decision:** Hoist `holyshipperFleetManager` as a module-level `let` variable, assign inside the worker pool block, reference via nullish coalesce in the interrogation service init. PR #250 on wopr-network/holyship.

**Result:** Analyze provisions worker in ~2s, runs LLM calls through gateway (billed), completes in ~90s with config + gaps + flow editor.

---

## 2026-03-23 — Paperclip Electric Indigo rebrand

**Context:** Paperclip UI was generic monochrome (black/white/gray). No brand identity. Looked like every other SaaS.

**Decision:** "Electric Indigo" design system — pure black (#09090b) + electric indigo (#818cf8) accent. 3-tier typography: Space Grotesk (display), DM Sans (body), JetBrains Mono (code). Glassmorphic cards, atmospheric radial gradients, subtle grid pattern. Design mockups via ui-ux-pro-max skill + visual companion server.

**Result:** Full rebrand across all pages — landing (gradient hero), unified auth (split-panel with pitch + tab toggle), dashboard, admin, instance detail, privacy, terms, pricing. Zero amber references remaining. OAuth buttons (GitHub + Google) live.

---

## 2026-03-23 — Unified auth page replaces separate login/signup

**Context:** Two separate pages (/login and /signup) felt redundant. The split-panel signup design was too good to only show for signups.

**Decision:** Single page at `/login` with tab toggle (Sign in / Create account). Split-panel layout: left = brand pitch (value props, $5 credit card), right = tabbed form. `?tab=signup` deep-links to create account. Removed `/signup` route entirely.

**Result:** Cleaner funnel, one gorgeous screen. OAuth buttons shared below both forms.

---

## 2026-03-23 — GitHub + Google OAuth for Paperclip

**Context:** Paperclip only had email/password auth. OAuth increases conversion and reduces friction.

**Decision:** Create OAuth apps via agent-browser CDP (connecting to real Chrome on Windows). GitHub OAuth App + Google Cloud OAuth Client. Env vars in `.env` AND docker-compose.yml `environment:` block (both required — compose only passes vars explicitly listed).

**Gotcha:** `docker restart` does NOT re-read env_file. Must use `docker compose up -d --force-recreate`.

**Result:** Both providers live. Buttons render via `authSocialRouter` (platform-core 1.57.0) + tRPC batch fix (platform-ui-core 1.22.4).

---

## 2026-03-23 — tRPC batch 401 poisoning fix

**Context:** OAuth buttons weren't rendering on login page despite API returning correct data. Root cause: `trpcFetchWithAuth` throws `UnauthorizedError` on ANY 401. On login page, auth queries naturally 401 (no session). The throw kills the entire batch response, preventing public queries like `enabledSocialProviders` from resolving.

**Decision:** Skip the throw when `window.location.pathname.startsWith("/login")`. Let the 401 response pass through so the batch continues. Public queries resolve, auth queries fail gracefully.

**Result:** OAuth buttons render on login page. 401 redirect still works on all other pages. Fix in platform-ui-core 1.22.4 (PR #56).

---

## 2026-03-23 — $5 signup credit math validation

**Context:** Question: should we give $5 free on signup, or require a $10 purchase first then give $5?

**Analysis:** At 7x markup on DeepSeek V3.2 (sell $0.001/1K input vs cost $0.00014/1K), a $5 free credit only costs ~$0.70 in real inference. Even if a user burns $5 and leaves, loss is 70 cents.

**Decision:** Keep $5 on signup. Better conversion funnel. The math works regardless because of the markup.

## 2026-03-24 — Crypto payment methods from chain server, not DB

**Context:** The billing UI showed crypto payment methods from the local `payment_methods` DB table. Adding a new token required a DB insert + watcher config. The chain server already had a `/chains` API with all available tokens.

**Decision:** `supportedPaymentMethods` tRPC route calls `cryptoClient.listChains()` directly. If the chain server has it, the UI shows it. No local DB config needed. Removed evmXpub/priceOracle/paymentMethodStore guards from checkout mutation — `createUnifiedCheckout` only needs `cryptoClient`.

**Impact:** 14 tokens immediately available in billing UI. Adding new tokens is a chain server config change, zero platform code.

## 2026-03-24 — Webhook auth: chain server uses SERVICE_KEY as Bearer

**Context:** Chain server detected payments and confirmed charges, but webhook delivery to Paperclip returned 401. The delivery had no auth header. Paperclip's webhook endpoint required a Bearer token.

**Decision:** Added `serviceKey` to `WatcherServiceOpts` in platform-core. Webhook outbox delivery sends `Authorization: Bearer <serviceKey>`. Paperclip webhook endpoint accepts both `PROVISION_SECRET` and `CRYPTO_SERVICE_KEY`.

**Chain server keys:** `SERVICE_KEY=sk-chain-2026` (service ops, webhook auth), `ADMIN_TOKEN=ks-admin-2026` (admin ops, listing chains).

## 2026-03-24 — Local charge storage for webhook crediting

**Context:** Checkout created charges on the chain server only. When the webhook arrived, `handleCryptoWebhook` looked for the charge in the local DB — empty. Credits never added.

**Decision:** After `createUnifiedCheckout`, store the charge locally via `cryptoChargeRepo.create(referenceId, tenantId, amountUsdCents)`. Webhook handler finds it → credits tenant ledger.

## 2026-03-24 — CRITICAL: Compressed public key bug in EVM address derivation

**Context:** EVM deposit addresses were derived by passing SEC1 compressed public keys (33 bytes, 02/03 prefix) to `viem.publicKeyToAddress()`. This function does `keccak256(pubkey.slice(2))` — strips the prefix byte and hashes. For compressed keys, it hashes 32 bytes (just X coordinate) instead of 64 bytes (X+Y). The resulting address is not a standard Ethereum address. No private key can sign for it because Ethereum's ECDSA recovery always uses uncompressed public keys.

**Root cause:** `HDKey.publicKey` from `@scure/bip32` is always compressed. The `encodeEvm()` function in `address-gen.ts` passed it directly to `publicKeyToAddress` without decompressing.

**Fix:** Decompress via `secp256k1.Point.fromHex(compressed).toBytes(false)` before hashing. Added `@noble/curves` as direct dependency. platform-core PR #144.

**Impact:** All EVM deposit addresses created before this fix generated invalid addresses. Funds sent to them are permanently unrecoverable. All new addresses after the fix are standard and sweepable. Testnet LINK on Sepolia was lost (no real value).

## 2026-03-24 — Product config DB seed required for platform-core 1.59.0

**Context:** Platform-core 1.59.0 added `platformBoot()` which reads product config from a `products` DB table. Without the seed row, startup fails with "Product not found" and the platform runs in degraded mode — no auth, no billing, no crypto.

**Decision:** Manually seeded via SQL INSERT. Needs a migration or seed script for production.

```sql
INSERT INTO products (slug, brand_name, product_name, tagline, domain, app_domain, cookie_domain, 
  company_legal, price_label, default_image, email_support, email_privacy, email_legal, 
  from_email, home_path, storage_prefix) 
VALUES ('paperclip', 'Paperclip', 'Paperclip', 'AI agents that run your business.', 
  'runpaperclip.com', 'app.runpaperclip.com', '.runpaperclip.com', 'Paperclip AI Inc.', 
  '$5/month', 'ghcr.io/wopr-network/paperclip:latest', 'support@runpaperclip.com', 
  'privacy@runpaperclip.com', 'legal@runpaperclip.com', 'noreply@runpaperclip.com', 
  '/instances', 'paperclip') ON CONFLICT (slug) DO NOTHING;
```

## 2026-03-24 — Sweep script fetches tokens from chain server

**Context:** Sweep script had hardcoded Base mainnet token addresses. Couldn't sweep other chains (Sepolia, future chains).

**Decision:** Script now fetches `/chains` from chain server, filters by `EVM_CHAIN` env var. Adding a new token to the chain server = automatically swept. No code changes.
