# Platform Monorepo Design

**Date:** 2026-03-27
**Status:** Draft
**Repo:** wopr-network/platform

## Problem

18 repos (17 packages + ops) drift from each other. Same CI patterns copied 84 times across 19 repos. Node versions diverge (20/22/24). Docker build strategies differ. Deploy workflows have health checks in some products but not others. SSH secret names vary. Dependabot auto-merge duplicated 13 times. Every shared change (platform-core bump, Dockerfile fix, CI improvement) requires coordinating across multiple repos.

## Decision

Consolidate all 18 repos into a single monorepo called `platform`, using the same tooling pattern proven by `wopr-plugins`: pnpm workspaces + Turborepo + Biome + Changesets.

## Packages (18)

### core/ — Shared foundations

| Package | Current repo | Description |
|---------|-------------|-------------|
| `platform-core` | wopr-network/platform-core | Shared backend: DI, auth, billing, DB |
| `platform-ui-core` | wopr-network/platform-ui-core | Shared UI: Next.js components, layouts |

### platforms/ — Product backends (depend on core + provision-client)

| Package | Current repo | Description |
|---------|-------------|-------------|
| `wopr-platform` | wopr-network/wopr-platform | WOPR backend |
| `paperclip-platform` | wopr-network/paperclip-platform | Paperclip backend |
| `nemoclaw-platform` | wopr-network/nemoclaw-platform | NemoClaw backend |
| `holyship` | wopr-network/holyship | Holy Ship backend/engine |

### sidecars/ — Product code (forks, depend on provision-server)

| Package | Current repo | Upstream |
|---------|-------------|----------|
| `wopr` | wopr-network/wopr | fork |
| `paperclip` | wopr-network/paperclip | paperclipai/paperclip |
| `holyshipper` | wopr-network/holyshipper | fork |
| `nemoclaw` | wopr-network/nemoclaw | fork |

### shells/ — Product UIs (depend on platform-ui-core)

| Package | Current repo | Description |
|---------|-------------|-------------|
| `wopr-platform-ui` | wopr-network/wopr-platform-ui | WOPR brand shell |
| `paperclip-platform-ui` | wopr-network/paperclip-platform-ui | Paperclip brand shell |
| `nemoclaw-platform-ui` | wopr-network/nemoclaw-platform-ui | NemoClaw brand shell |
| `holyship-platform-ui` | wopr-network/holyship-platform-ui | Holy Ship brand shell |

### services/ — Shared infrastructure

| Package | Current repo | Description |
|---------|-------------|-------------|
| `platform-crypto-server` | wopr-network/platform-crypto-server | Chain nodes + payment detection |
| `provision-client` | wopr-network/provision-client | Platform-side HTTP client for provisioned containers |
| `provision-server` | wopr-network/provision-server | Embeddable router making sidecars provisionable |

### ops/ — Infrastructure (from wopr-ops)

Deploy scripts, compose templates, VPS configs, promote workflow, backup scripts, Caddyfile patterns.

## Directory Structure

```
platform/
  pnpm-workspace.yaml
  turbo.json
  biome.json
  tooling/
    tsconfig.base.json
  core/
    platform-core/
    platform-ui-core/
  platforms/
    wopr-platform/
    paperclip-platform/
    nemoclaw-platform/
    holyship/
  sidecars/
    wopr/
    paperclip/
    holyshipper/
    nemoclaw/
  shells/
    wopr-platform-ui/
    paperclip-platform-ui/
    nemoclaw-platform-ui/
    holyship-platform-ui/
  services/
    platform-crypto-server/
    provision-client/
    provision-server/
  ops/
    scripts/
    vps/
    compose/
  .github/
    workflows/
```

## Dependency Graph

```
        platform-core          platform-ui-core
         ↑       ↑                    ↑
   platforms  services           4 shells
         ↑
  provision-client
         ↕ (wire protocol)
  provision-server
         ↑
    4 sidecars
```

All cross-references become `workspace:*`. No npm publishing — nothing outside this monorepo consumes these packages.

## Workspace Configuration

**pnpm-workspace.yaml:**
```yaml
packages:
  - "core/*"
  - "platforms/*"
  - "sidecars/*"
  - "shells/*"
  - "services/*"
```

**turbo.json:** Same pattern as wopr-plugins — lint, build, test pipelines with `^build` dependency chains. Affected-only CI via `--filter='...[origin/main]'`.

**biome.json:** Shared root config. Same rules as wopr-plugins (strict, 2-space, double quotes, trailing commas). Overrides per package where needed.

**tooling/tsconfig.base.json:** Shared TypeScript config (ES2022, NodeNext, strict). Each package extends it.

## Unified CI/CD

### What replaces 84 workflows

**One CI workflow** (`ci.yml`):
- Triggers: push to main, pull_request, merge_group
- Runner: self-hosted
- Steps: install → Turborepo lint/build/test (affected only)
- Concurrency group cancels in-progress builds

**One Docker build matrix** (`docker.yml`):
- Triggers: push to main (when package files change)
- Detects which products changed via Turborepo
- Builds affected Docker images only
- Pushes `:staging` + `:<sha>` tags to GHCR
- Shared Dockerfile templates, shared caching strategy (type=gha)

**One promote workflow** (`promote.yml`):
- Manual workflow_dispatch, pick product or "all"
- Retags `:staging` → `:latest` with `:latest-previous` rollback
- SSH deploy + health checks for ALL products (not just UIs)
- DB backup before promote, auto-rollback on failure
- Carries over from current wopr-ops promote.yml

**One dependabot config** — replaces 13 copies.

**One auto-fix workflow** — Claude Code agent on CI failures, replaces 4 copies.

### Standardization

- **Node:** Pin to 24 (current latest in some repos, standardize everywhere)
- **pnpm:** Pin to 10.x (already used by most repos)
- **Runners:** All self-hosted
- **Registry:** GHCR only (drop DockerHub from platform-ui-core)
- **SSH secrets:** Unified naming (`PROD_SSH_KEY` everywhere)
- **Health checks:** All products get health checks on deploy, not just UIs

## Forked Sidecars

The 4 sidecars are forks of external projects. They live in `sidecars/` as regular packages. Upstream sync:

- Upstream changes are pulled into the sidecar's directory via cherry-pick or manual merge
- Existing upstream-sync workflows (paperclip, nemoclaw have Claude-driven sync) consolidate into one reusable workflow

## Migration Strategy

1. Create empty `wopr-network/platform` repo
2. Set up root configs (pnpm-workspace, turbo, biome, tsconfig.base)
3. Import each repo as a package in its layer directory (preserve git history with `git subtree add` or fresh copy)
4. Convert all cross-deps to `workspace:*`
5. Build unified CI/CD workflows
6. Verify all packages build and test
7. Archive source repos

## What This Eliminates

- 84 workflow files → ~6
- 13 dependabot-auto-merge copies → 1
- 4 auto-fix copies → 1
- Node version drift (20/22/24) → pinned to 24
- npm version drift on cross-deps → `workspace:*`
- Missing health checks on 3 products → all products covered
- Inconsistent Docker caching → unified strategy
- Per-repo CI/CD maintenance → one pipeline

## Open Questions

None — all design decisions resolved during brainstorming.
