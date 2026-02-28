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
