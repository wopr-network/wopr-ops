# Platform Monorepo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate 18 repos + ops into a single `wopr-network/platform` monorepo, eliminating all infrastructure and dependency drift.

**Architecture:** pnpm workspaces + Turborepo + Biome, organized by layer (core/, platforms/, sidecars/, shells/, services/, ops/). All cross-deps become `workspace:*`. Unified CI/CD replaces 84 workflow files.

**Tech Stack:** pnpm 10.x, Node 24, TypeScript 5.9.3, Turborepo 2.5.x, Biome 2.4.x, Changesets

**Spec:** `docs/superpowers/specs/2026-03-27-platform-monorepo-design.md`

---

### Task 1: Create repo and root scaffolding

**Files:**
- Create: `platform/package.json`
- Create: `platform/pnpm-workspace.yaml`
- Create: `platform/turbo.json`
- Create: `platform/biome.json`
- Create: `platform/tooling/tsconfig.base.json`
- Create: `platform/.changeset/config.json`
- Create: `platform/.gitignore`
- Create: `platform/.npmrc`

- [ ] **Step 1: Create the GitHub repo**

```bash
gh repo create wopr-network/platform --private --clone
cd platform
```

- [ ] **Step 2: Create root package.json**

```json
{
  "name": "platform",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "packageManager": "pnpm@10.31.0",
  "engines": {
    "node": ">=24.0.0"
  },
  "scripts": {
    "lint": "turbo run lint",
    "build": "turbo run build",
    "test": "turbo run test",
    "check": "turbo run lint build test",
    "format": "biome format --write .",
    "changeset": "changeset",
    "version-packages": "changeset version"
  },
  "devDependencies": {
    "@biomejs/biome": "2.4.4",
    "@changesets/cli": "^2.29.4",
    "turbo": "^2.5.4",
    "typescript": "~5.9.3",
    "vitest": "^4.0.18",
    "tsx": "^4.19.4"
  }
}
```

- [ ] **Step 3: Create pnpm-workspace.yaml**

```yaml
packages:
  - "core/*"
  - "platforms/*"
  - "sidecars/*"
  - "shells/*"
  - "services/*"
```

- [ ] **Step 4: Create turbo.json**

```json
{
  "$schema": "https://turbo.build/schema.json",
  "tasks": {
    "lint": {
      "inputs": ["src/**", "biome.json", "../../biome.json"],
      "cache": true
    },
    "build": {
      "dependsOn": ["^build"],
      "inputs": ["src/**", "tsconfig.json", "tsconfig*.json", "package.json"],
      "outputs": ["dist/**", ".next/**"],
      "cache": true
    },
    "test": {
      "dependsOn": ["build"],
      "inputs": ["src/**", "tests/**", "test/**", "*.test.ts", "*.test.tsx", "vitest.config.*"],
      "cache": true
    },
    "docker:build": {
      "dependsOn": ["build"],
      "cache": false
    },
    "db:generate": {
      "cache": false
    },
    "db:migrate": {
      "cache": false
    }
  }
}
```

- [ ] **Step 5: Create biome.json**

```json
{
  "$schema": "https://biomejs.dev/schemas/2.4.4/schema.json",
  "vcs": {
    "enabled": true,
    "clientKind": "git",
    "useIgnoreFile": true
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineWidth": 120,
    "attributePosition": "auto"
  },
  "javascript": {
    "formatter": {
      "quoteStyle": "double",
      "trailingCommas": "all",
      "semicolons": "always"
    }
  },
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true,
      "correctness": {
        "noUnusedImports": "error",
        "noUnusedVariables": "error",
        "useExhaustiveDependencies": "warn",
        "noUndeclaredVariables": "error"
      },
      "suspicious": {
        "noExplicitAny": "warn",
        "noConsole": "warn"
      },
      "style": {
        "useConst": "error",
        "noNonNullAssertion": "warn"
      },
      "nursery": {
        "noTsIgnoreComment": "error"
      }
    }
  },
  "css": {
    "linter": {
      "enabled": true
    },
    "formatter": {
      "enabled": true
    }
  },
  "overrides": [
    {
      "includes": ["**/*.test.ts", "**/*.test.tsx", "**/*.spec.ts"],
      "linter": {
        "rules": {
          "suspicious": {
            "noExplicitAny": "off"
          }
        }
      }
    },
    {
      "includes": ["**/e2e/**"],
      "linter": {
        "rules": {
          "suspicious": {
            "noConsole": "off"
          }
        }
      }
    }
  ]
}
```

- [ ] **Step 6: Create tooling/tsconfig.base.json**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2022"],
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "verbatimModuleSyntax": true,
    "isolatedModules": true
  },
  "exclude": ["node_modules", "dist"]
}
```

- [ ] **Step 7: Create .changeset/config.json**

```json
{
  "$schema": "https://unpkg.com/@changesets/config@3.1.1/schema.json",
  "changelog": "@changesets/cli/changelog",
  "commit": false,
  "fixed": [],
  "linked": [],
  "access": "restricted",
  "baseBranch": "main",
  "updateInternalDependencies": "patch",
  "ignore": []
}
```

Note: `access` is `restricted` (private repo, no npm publishing) unlike wopr-plugins which uses `public`.

- [ ] **Step 8: Create .gitignore**

```
node_modules/
dist/
.next/
*.tsbuildinfo
.turbo/
.env
.env.*
!.env.example
```

- [ ] **Step 9: Create .npmrc**

```
auto-install-peers=true
strict-peer-dependencies=false
```

- [ ] **Step 10: Install dependencies and verify**

```bash
pnpm install
pnpm turbo --version
```

Expected: clean install, turbo available.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat: scaffold platform monorepo with root configs"
```

---

### Task 2: Import core packages

**Files:**
- Create: `core/platform-core/` (from ~/platform-core)
- Create: `core/platform-ui-core/` (from ~/platform-ui-core)

- [ ] **Step 1: Copy platform-core source**

```bash
# From the platform monorepo root
mkdir -p core/platform-core
cp -r ~/platform-core/src core/platform-core/
cp -r ~/platform-core/drizzle core/platform-core/ 2>/dev/null || true
cp ~/platform-core/package.json core/platform-core/
cp ~/platform-core/tsconfig.json core/platform-core/
cp ~/platform-core/vitest.config.* core/platform-core/ 2>/dev/null || true
cp ~/platform-core/.env.example core/platform-core/ 2>/dev/null || true
cp -r ~/platform-core/tests core/platform-core/ 2>/dev/null || true
cp -r ~/platform-core/test core/platform-core/ 2>/dev/null || true
```

- [ ] **Step 2: Update platform-core tsconfig.json to extend base**

Replace the `extends` (or add it) in `core/platform-core/tsconfig.json`:

```json
{
  "extends": "../../tooling/tsconfig.base.json",
  "compilerOptions": {
    "outDir": "dist",
    "rootDir": "src"
  },
  "include": ["src"],
  "exclude": ["node_modules", "dist"]
}
```

Preserve any package-specific compiler options (paths, jsx, etc.) — merge them into the above.

- [ ] **Step 3: Remove npm-publish fields from platform-core package.json**

Remove `publishConfig`, `files`, `repository`, `homepage`, `bugs` fields. Remove `semantic-release` from devDependencies and scripts. Remove `@wopr-network/semantic-release-config` from devDependencies. Keep all other deps.

- [ ] **Step 4: Copy platform-ui-core source**

```bash
mkdir -p core/platform-ui-core
cp -r ~/platform-ui-core/src core/platform-ui-core/
cp -r ~/platform-ui-core/components core/platform-ui-core/ 2>/dev/null || true
cp ~/platform-ui-core/package.json core/platform-ui-core/
cp ~/platform-ui-core/tsconfig.json core/platform-ui-core/
cp ~/platform-ui-core/next.config.* core/platform-ui-core/ 2>/dev/null || true
cp ~/platform-ui-core/tailwind.config.* core/platform-ui-core/ 2>/dev/null || true
cp ~/platform-ui-core/postcss.config.* core/platform-ui-core/ 2>/dev/null || true
cp ~/platform-ui-core/vitest.config.* core/platform-ui-core/ 2>/dev/null || true
cp -r ~/platform-ui-core/public core/platform-ui-core/ 2>/dev/null || true
cp -r ~/platform-ui-core/tests core/platform-ui-core/ 2>/dev/null || true
```

- [ ] **Step 5: Update platform-ui-core tsconfig and remove publish fields**

Same pattern as Step 2-3: extend base tsconfig, remove publishConfig/semantic-release/files fields. Preserve Next.js-specific tsconfig options (jsx, paths, etc.).

- [ ] **Step 6: Verify both packages have lint scripts**

Ensure both package.json files have at minimum:

```json
{
  "scripts": {
    "lint": "biome check src/",
    "build": "<existing build command>",
    "test": "<existing test command>"
  }
}
```

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: import platform-core and platform-ui-core into core/"
```

---

### Task 3: Import services

**Files:**
- Create: `services/platform-crypto-server/` (from ~/platform-crypto-server)
- Create: `services/provision-client/` (from ~/provision-client)
- Create: `services/provision-server/` (from ~/provision-server)

- [ ] **Step 1: Copy all three services**

```bash
for svc in platform-crypto-server provision-client provision-server; do
  mkdir -p "services/$svc"
  cp -r ~/"$svc"/src "services/$svc/" 2>/dev/null || true
  cp ~/"$svc"/package.json "services/$svc/"
  cp ~/"$svc"/tsconfig.json "services/$svc/" 2>/dev/null || true
  cp ~/"$svc"/vitest.config.* "services/$svc/" 2>/dev/null || true
  cp ~/"$svc"/Dockerfile "services/$svc/" 2>/dev/null || true
  cp ~/"$svc"/.env.example "services/$svc/" 2>/dev/null || true
  cp -r ~/"$svc"/tests "services/$svc/" 2>/dev/null || true
  cp -r ~/"$svc"/test "services/$svc/" 2>/dev/null || true
  cp -r ~/"$svc"/drizzle "services/$svc/" 2>/dev/null || true
done
```

- [ ] **Step 2: Update tsconfig.json for each to extend base**

For each service with a tsconfig.json:

```json
{
  "extends": "../../tooling/tsconfig.base.json",
  "compilerOptions": {
    "outDir": "dist",
    "rootDir": "src"
  },
  "include": ["src"],
  "exclude": ["node_modules", "dist"]
}
```

Preserve any package-specific options.

- [ ] **Step 3: Remove publish fields from each package.json**

Remove `publishConfig`, `files`, `repository`, `homepage`, `bugs`, semantic-release config from all three.

- [ ] **Step 4: Ensure lint/build/test scripts exist in each**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: import platform-crypto-server, provision-client, provision-server into services/"
```

---

### Task 4: Import platform backends

**Files:**
- Create: `platforms/wopr-platform/` (from ~/wopr-platform)
- Create: `platforms/paperclip-platform/` (from ~/paperclip-platform)
- Create: `platforms/nemoclaw-platform/` (from ~/nemoclaw-platform)
- Create: `platforms/holyship/` (from ~/holyship)

- [ ] **Step 1: Copy all four platform backends**

```bash
for pair in "wopr-platform:wopr-platform" "paperclip-platform:paperclip-platform" "nemoclaw-platform:nemoclaw-platform" "holyship:holyship"; do
  src="${pair%%:*}"
  dst="${pair##*:}"
  mkdir -p "platforms/$dst"
  cp -r ~/"$src"/src "platforms/$dst/"
  cp ~/"$src"/package.json "platforms/$dst/"
  cp ~/"$src"/tsconfig.json "platforms/$dst/" 2>/dev/null || true
  cp ~/"$src"/vitest.config.* "platforms/$dst/" 2>/dev/null || true
  cp ~/"$src"/Dockerfile "platforms/$dst/" 2>/dev/null || true
  cp ~/"$src"/docker-compose*.yml "platforms/$dst/" 2>/dev/null || true
  cp ~/"$src"/.env.example "platforms/$dst/" 2>/dev/null || true
  cp -r ~/"$src"/tests "platforms/$dst/" 2>/dev/null || true
  cp -r ~/"$src"/test "platforms/$dst/" 2>/dev/null || true
  cp -r ~/"$src"/drizzle "platforms/$dst/" 2>/dev/null || true
  cp -r ~/"$src"/e2e "platforms/$dst/" 2>/dev/null || true
  cp -r ~/"$src"/migrations "platforms/$dst/" 2>/dev/null || true
done
```

- [ ] **Step 2: Update tsconfig.json for each to extend base**

```json
{
  "extends": "../../tooling/tsconfig.base.json",
  "compilerOptions": {
    "outDir": "dist",
    "rootDir": "src"
  },
  "include": ["src"],
  "exclude": ["node_modules", "dist"]
}
```

Preserve package-specific options (paths aliases, etc.).

- [ ] **Step 3: Remove publish/semantic-release fields from each package.json**

- [ ] **Step 4: Ensure lint/build/test scripts exist in each**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: import wopr-platform, paperclip-platform, nemoclaw-platform, holyship into platforms/"
```

---

### Task 5: Import sidecars

**Files:**
- Create: `sidecars/wopr/` (from ~/wopr)
- Create: `sidecars/paperclip/` (from ~/paperclip)
- Create: `sidecars/holyshipper/` (from ~/holyshipper)
- Create: `sidecars/nemoclaw/` (from ~/nemoclaw)

- [ ] **Step 1: Copy wopr sidecar**

```bash
mkdir -p sidecars/wopr
# wopr has a complex structure — copy everything except node_modules/.git
rsync -a --exclude='node_modules' --exclude='.git' --exclude='dist' --exclude='.turbo' ~/wopr/ sidecars/wopr/
```

- [ ] **Step 2: Copy paperclip sidecar**

Paperclip is already a monorepo with sub-packages. Preserve its internal structure:

```bash
mkdir -p sidecars/paperclip
rsync -a --exclude='node_modules' --exclude='.git' --exclude='dist' --exclude='.turbo' --exclude='.next' ~/paperclip/ sidecars/paperclip/
```

Note: paperclip has internal pnpm-workspace.yaml and sub-packages (@paperclipai/server, @paperclipai/ui). These become nested workspace packages. Update `pnpm-workspace.yaml` at root to include:

```yaml
packages:
  - "core/*"
  - "platforms/*"
  - "sidecars/*"
  - "sidecars/paperclip/*"
  - "sidecars/paperclip/server"
  - "sidecars/paperclip/ui"
  - "shells/*"
  - "services/*"
```

Remove paperclip's own `pnpm-workspace.yaml` after updating root.

- [ ] **Step 3: Copy holyshipper sidecar**

```bash
mkdir -p sidecars/holyshipper
rsync -a --exclude='node_modules' --exclude='.git' --exclude='dist' ~/holyshipper/ sidecars/holyshipper/
```

- [ ] **Step 4: Copy nemoclaw sidecar**

```bash
mkdir -p sidecars/nemoclaw
rsync -a --exclude='node_modules' --exclude='.git' --exclude='dist' ~/nemoclaw/ sidecars/nemoclaw/
```

- [ ] **Step 5: Update tsconfig.json for each (where present) to extend base**

Sidecars may not all have tsconfig — only update those that do. Use `../../tooling/tsconfig.base.json` as extends.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: import wopr, paperclip, holyshipper, nemoclaw into sidecars/"
```

---

### Task 6: Import UI shells

**Files:**
- Create: `shells/wopr-platform-ui/` (from ~/wopr-platform-ui)
- Create: `shells/paperclip-platform-ui/` (from ~/paperclip-platform-ui)
- Create: `shells/nemoclaw-platform-ui/` (from ~/nemoclaw-platform-ui)
- Create: `shells/holyship-platform-ui/` (from ~/holyship-platform-ui)

- [ ] **Step 1: Copy all four UI shells**

```bash
for shell in wopr-platform-ui paperclip-platform-ui nemoclaw-platform-ui holyship-platform-ui; do
  mkdir -p "shells/$shell"
  rsync -a --exclude='node_modules' --exclude='.git' --exclude='.next' --exclude='dist' ~/"$shell"/ "shells/$shell/"
done
```

- [ ] **Step 2: Update tsconfig.json for each to extend base**

Next.js apps need additional options:

```json
{
  "extends": "../../tooling/tsconfig.base.json",
  "compilerOptions": {
    "jsx": "preserve",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "plugins": [{ "name": "next" }],
    "paths": {
      "@/*": ["./src/*"]
    }
  },
  "include": ["next-env.d.ts", "src", "**/*.ts", "**/*.tsx"],
  "exclude": ["node_modules", ".next", "dist"]
}
```

Preserve any brand-specific paths or options.

- [ ] **Step 3: Remove publish/semantic-release fields from each package.json**

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: import 4 UI shells into shells/"
```

---

### Task 7: Import ops

**Files:**
- Create: `ops/` (from ~/wopr-ops)

- [ ] **Step 1: Copy ops content (not .git, not .jj)**

```bash
mkdir -p ops
rsync -a --exclude='node_modules' --exclude='.git' --exclude='.jj' --exclude='docs/superpowers' ~/wopr-ops/ ops/
```

Note: exclude docs/superpowers since the specs/plans live here in the monorepo already.

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "feat: import wopr-ops into ops/"
```

---

### Task 8: Rewire all dependencies to workspace:*

**Files:**
- Modify: `platforms/wopr-platform/package.json`
- Modify: `platforms/paperclip-platform/package.json`
- Modify: `platforms/nemoclaw-platform/package.json`
- Modify: `platforms/holyship/package.json`
- Modify: `shells/wopr-platform-ui/package.json`
- Modify: `shells/paperclip-platform-ui/package.json`
- Modify: `shells/nemoclaw-platform-ui/package.json`
- Modify: `shells/holyship-platform-ui/package.json`
- Modify: `services/platform-crypto-server/package.json`
- Modify: `sidecars/paperclip/server/package.json` (provision-server dep)

- [ ] **Step 1: Rewire platform backends**

In each `platforms/*/package.json`, replace versioned `@wopr-network/*` deps with `workspace:*`:

| Package | Find | Replace |
|---------|------|---------|
| `wopr-platform` | `"@wopr-network/platform-core": "1.72.0"` | `"@wopr-network/platform-core": "workspace:*"` |
| `wopr-platform` | `"@wopr-network/wopr": "2.0.0"` | `"@wopr-network/wopr": "workspace:*"` |
| `paperclip-platform` | `"@wopr-network/platform-core": "^1.71.0"` | `"@wopr-network/platform-core": "workspace:*"` |
| `paperclip-platform` | `"@wopr-network/provision-client": "^1.0.0"` | `"@wopr-network/provision-client": "workspace:*"` |
| `nemoclaw-platform` | `"@wopr-network/platform-core": "^1.71.0"` | `"@wopr-network/platform-core": "workspace:*"` |
| `nemoclaw-platform` | `"@wopr-network/provision-client": "^1.0.0"` | `"@wopr-network/provision-client": "workspace:*"` |
| `holyship` | `"@wopr-network/platform-core": "^1.71.0"` | `"@wopr-network/platform-core": "workspace:*"` |

- [ ] **Step 2: Rewire UI shells**

In each `shells/*/package.json`:

| Package | Find | Replace |
|---------|------|---------|
| `wopr-platform-ui` | `"@wopr-network/platform-ui-core": "^1.27.2"` | `"@wopr-network/platform-ui-core": "workspace:*"` |
| `paperclip-platform-ui` | `"@wopr-network/platform-ui-core": "^1.27.5"` | `"@wopr-network/platform-ui-core": "workspace:*"` |
| `nemoclaw-platform-ui` | `"@wopr-network/platform-ui-core": "^1.26.0"` | `"@wopr-network/platform-ui-core": "workspace:*"` |
| `holyship-platform-ui` | `"@wopr-network/platform-ui-core": "^1.26.0"` | `"@wopr-network/platform-ui-core": "workspace:*"` |

- [ ] **Step 3: Rewire services**

In `services/platform-crypto-server/package.json`:

| Find | Replace |
|------|---------|
| `"@wopr-network/crypto-plugins": "^1.1.0"` | Check if crypto-plugins is in the monorepo. If not, leave as npm dep. |

In `sidecars/paperclip/server/package.json`:

| Find | Replace |
|------|---------|
| `"@wopr-network/provision-server": "^1.0.5"` | `"@wopr-network/provision-server": "workspace:*"` |

- [ ] **Step 4: Run pnpm install to resolve workspace links**

```bash
pnpm install
```

Expected: all workspace:* deps resolve to local packages. No errors.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: rewire all cross-deps to workspace:*"
```

---

### Task 9: Unified CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Create unified CI workflow**

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]
  merge_group:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}

jobs:
  ci:
    runs-on: self-hosted
    timeout-minutes: 30
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: 24

      - name: Setup pnpm
        uses: pnpm/action-setup@v4

      - name: Install dependencies
        run: pnpm install --frozen-lockfile

      - name: Lint (affected)
        run: pnpm turbo run lint --filter='...[origin/main]'

      - name: Build (affected)
        run: pnpm turbo run build --filter='...[origin/main]'

      - name: Test (affected)
        run: pnpm turbo run test --filter='...[origin/main]'
```

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "feat: unified CI workflow with Turborepo affected-only builds"
```

---

### Task 10: Unified Docker build workflow

**Files:**
- Create: `.github/workflows/docker.yml`

- [ ] **Step 1: Create Docker build matrix workflow**

```yaml
name: Docker Build & Push

on:
  push:
    branches: [main]

env:
  REGISTRY: ghcr.io/wopr-network

jobs:
  detect-changes:
    runs-on: self-hosted
    outputs:
      matrix: ${{ steps.detect.outputs.matrix }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Detect changed products
        id: detect
        run: |
          CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD)
          PRODUCTS='[]'

          # Core changes affect ALL products
          if echo "$CHANGED_FILES" | grep -q "^core/"; then
            PRODUCTS='["wopr-platform","paperclip-platform","nemoclaw-platform","holyship","wopr-platform-ui","paperclip-platform-ui","nemoclaw-platform-ui","holyship-platform-ui"]'
          else
            ITEMS=()
            # Check each product layer
            echo "$CHANGED_FILES" | grep -q "^platforms/wopr-platform/" && ITEMS+=("wopr-platform")
            echo "$CHANGED_FILES" | grep -q "^platforms/paperclip-platform/" && ITEMS+=("paperclip-platform")
            echo "$CHANGED_FILES" | grep -q "^platforms/nemoclaw-platform/" && ITEMS+=("nemoclaw-platform")
            echo "$CHANGED_FILES" | grep -q "^platforms/holyship/" && ITEMS+=("holyship")
            echo "$CHANGED_FILES" | grep -q "^shells/wopr-platform-ui/" && ITEMS+=("wopr-platform-ui")
            echo "$CHANGED_FILES" | grep -q "^shells/paperclip-platform-ui/" && ITEMS+=("paperclip-platform-ui")
            echo "$CHANGED_FILES" | grep -q "^shells/nemoclaw-platform-ui/" && ITEMS+=("nemoclaw-platform-ui")
            echo "$CHANGED_FILES" | grep -q "^shells/holyship-platform-ui/" && ITEMS+=("holyship-platform-ui")
            echo "$CHANGED_FILES" | grep -q "^services/platform-crypto-server/" && ITEMS+=("platform-crypto-server")
            # Services changes affect platforms that depend on them
            echo "$CHANGED_FILES" | grep -q "^services/provision-client/" && ITEMS+=("wopr-platform" "paperclip-platform" "nemoclaw-platform")
            echo "$CHANGED_FILES" | grep -q "^services/provision-server/" && ITEMS+=("paperclip") # sidecar dep

            # Deduplicate and format
            UNIQUE=($(printf '%s\n' "${ITEMS[@]}" | sort -u))
            PRODUCTS=$(printf '%s\n' "${UNIQUE[@]}" | jq -R . | jq -s .)
          fi

          echo "matrix={\"product\":$PRODUCTS}" >> "$GITHUB_OUTPUT"

  build-push:
    needs: detect-changes
    if: ${{ fromJson(needs.detect-changes.outputs.matrix).product[0] != null }}
    runs-on: self-hosted
    permissions:
      packages: write
    strategy:
      matrix: ${{ fromJson(needs.detect-changes.outputs.matrix) }}
    steps:
      - uses: actions/checkout@v4

      - name: Resolve paths
        id: paths
        run: |
          case "${{ matrix.product }}" in
            wopr-platform)       echo "context=platforms/wopr-platform" >> "$GITHUB_OUTPUT" ;;
            paperclip-platform)  echo "context=platforms/paperclip-platform" >> "$GITHUB_OUTPUT" ;;
            nemoclaw-platform)   echo "context=platforms/nemoclaw-platform" >> "$GITHUB_OUTPUT" ;;
            holyship)            echo "context=platforms/holyship" >> "$GITHUB_OUTPUT" ;;
            wopr-platform-ui)    echo "context=shells/wopr-platform-ui" >> "$GITHUB_OUTPUT" ;;
            paperclip-platform-ui) echo "context=shells/paperclip-platform-ui" >> "$GITHUB_OUTPUT" ;;
            nemoclaw-platform-ui)  echo "context=shells/nemoclaw-platform-ui" >> "$GITHUB_OUTPUT" ;;
            holyship-platform-ui)  echo "context=shells/holyship-platform-ui" >> "$GITHUB_OUTPUT" ;;
            platform-crypto-server) echo "context=services/platform-crypto-server" >> "$GITHUB_OUTPUT" ;;
          esac

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: ${{ steps.paths.outputs.context }}
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ matrix.product }}:staging
            ${{ env.REGISTRY }}/${{ matrix.product }}:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "feat: unified Docker build workflow with change detection matrix"
```

---

### Task 11: Unified promote workflow

**Files:**
- Create: `.github/workflows/promote.yml`

- [ ] **Step 1: Move promote.yml from ops/ to .github/workflows/**

```bash
cp ops/.github/workflows/promote.yml .github/workflows/promote.yml
```

The existing promote.yml from wopr-ops already handles all 4 products with a manual dispatch. It works as-is — same image names, same VPS hosts, same health checks.

- [ ] **Step 2: Add health checks to all products (not just UIs)**

The current promote.yml already has health checks for all products. Verify the health check step covers all 4 products and their API containers. If any product is missing health checks, add it to the loop.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: unified promote workflow from wopr-ops"
```

---

### Task 12: Dependabot and auto-fix workflows

**Files:**
- Create: `.github/dependabot.yml`
- Create: `.github/workflows/dependabot-auto-merge.yml`
- Create: `.github/workflows/auto-fix.yml`

- [ ] **Step 1: Create dependabot.yml**

```yaml
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    groups:
      minor-and-patch:
        update-types:
          - "minor"
          - "patch"
    open-pull-requests-limit: 10
```

- [ ] **Step 2: Create dependabot-auto-merge.yml**

```yaml
name: Dependabot Auto-Merge

on:
  pull_request:
    types: [opened, synchronize]

permissions:
  contents: write
  pull-requests: write

jobs:
  auto-merge:
    runs-on: self-hosted
    if: github.actor == 'dependabot[bot]'
    steps:
      - name: Auto-merge minor/patch
        run: gh pr merge "$PR_URL" --squash --auto
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

One file. Replaces 13 copies.

- [ ] **Step 3: Create auto-fix.yml**

```yaml
name: Auto-Fix

on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches-ignore: [main]

jobs:
  auto-fix:
    runs-on: self-hosted
    if: github.event.workflow_run.conclusion == 'failure'
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.workflow_run.head_branch }}

      - uses: anthropics/claude-code-action@v1
        with:
          model: claude-sonnet-4-6
          prompt: |
            The CI workflow failed on this branch. Look at the failing checks,
            identify the issue, fix it, and commit the fix.
          allowed_tools: "Bash,Read,Write,Edit,Glob,Grep"
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

One file. Replaces 4 copies.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: unified dependabot, auto-merge, and auto-fix workflows"
```

---

### Task 13: Full verification

- [ ] **Step 1: Install all dependencies**

```bash
pnpm install
```

Expected: clean install, all workspace:* links resolved.

- [ ] **Step 2: Run full lint**

```bash
pnpm turbo run lint
```

Fix any lint errors. Biome config may need package-level overrides for existing code that doesn't conform. Add overrides to `biome.json` or per-package `biome.json` files as needed.

- [ ] **Step 3: Run full build**

```bash
pnpm turbo run build
```

Fix any TypeScript errors from tsconfig changes. Common issues:
- Missing path aliases (add to per-package tsconfig)
- Import resolution changes from verbatimModuleSyntax
- Declaration emit issues

- [ ] **Step 4: Run full test**

```bash
pnpm turbo run test
```

Fix any test failures. Common issues:
- Path changes in test fixtures
- Environment variable expectations

- [ ] **Step 5: Verify workspace graph**

```bash
pnpm turbo run build --graph
```

Verify the dependency graph matches expectations: core → platforms/shells, services → platforms/sidecars.

- [ ] **Step 6: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve lint/build/test issues after monorepo consolidation"
```

- [ ] **Step 7: Push and verify CI**

```bash
git push origin main
```

Watch the CI workflow run. All steps should pass: lint, build, test (affected = everything on first run).

---

### Task 14: Archive source repos

- [ ] **Step 1: Archive all 18 source repos on GitHub**

```bash
for repo in platform-core platform-ui-core wopr-platform paperclip-platform nemoclaw-platform holyship wopr paperclip holyshipper nemoclaw wopr-platform-ui paperclip-platform-ui nemoclaw-platform-ui holyship-platform-ui platform-crypto-server provision-client provision-server wopr-ops; do
  gh repo archive "wopr-network/$repo" --yes
done
```

- [ ] **Step 2: Update CLAUDE.md in the monorepo**

Create a CLAUDE.md at the monorepo root with updated repo locations, CI gate, and standing orders. Reference `docs/superpowers/specs/2026-03-27-platform-monorepo-design.md` for architecture.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: add monorepo CLAUDE.md"
```
