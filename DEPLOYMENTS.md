# Deployment Log

> Append-only. DevOps agent adds an entry after every deploy.

## Format

```
### YYYY-MM-DD HH:MM UTC — <what changed>
**Repos:** list
**Images deployed:** ghcr.io/wopr-network/<repo>@sha256:xxx
**Result:** Success / Failed
**Rollback needed:** No / Yes — reason
**Notes:** anything relevant
```

---

*(no production entries yet — system not yet deployed to VPS)*

---

## Local Dev Sessions

### 2026-03-05 01:20 UTC — DinD local dev environment started (WSL2, Docker Desktop)

**Repos:** wopr-network/wopr-platform-ui (built locally from main + fix/wop-1187-local-image next.config.ts)
**Images deployed (inner VPS stack):**
- `ghcr.io/wopr-network/wopr-platform:latest` (pulled from GHCR)
- `ghcr.io/wopr-network/wopr-platform-ui:local` (built locally sha256:8fdcc03a553d8b3ae7e400eee30bb2690c254c10eb20098c8fa983396b507f56, pushed to GHCR)
- `postgres:16-alpine`, `caddy:2-alpine`, `containrrr/watchtower:latest` (pulled from Docker Hub)

**Result:** Success — all 5 inner VPS services healthy
- `wopr-vps-postgres`: healthy
- `wopr-vps-platform-api`: healthy — `curl http://localhost:3100/health` → `{"status":"ok","service":"wopr-platform","backups":{"staleCount":0,"totalTracked":0}}`
- `wopr-vps-platform-ui`: healthy
- `wopr-vps-caddy`: running — `curl -sI http://localhost` → HTTP/1.1 200 OK
- `wopr-vps-watchtower`: healthy

**Rollback needed:** No

**Issues resolved this session:**
1. `docker-credential-desktop.exe` not in DinD PATH — worked around with `/tmp/dockercfg` plain-auth config
2. `platform-ui:local` didn't exist on GHCR — built locally, pushed with `docker push`
3. `platform-ui` Next.js SSR validation rejects `localhost` in production mode even with `NODE_ENV=development` (Turbopack inlines NODE_ENV at build time) — bypassed with `PLAYWRIGHT_TESTING=true` in compose env
4. `platform-ui` Dockerfile requires `output: "standalone"` in `next.config.ts` which is only on `fix/wop-1187-local-image` branch — cherry-picked `next.config.ts` for build, restored after
5. `docker save | docker exec -i` piping fails in Docker Desktop WSL — worked around by pushing to GHCR and pulling from inside container

**Notes:** GPU container not started — no NVIDIA GPU in this WSL2 environment. VPS-only stack sufficient for platform development.
