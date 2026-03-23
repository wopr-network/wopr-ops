# OAuth Setup Guide: Zero to GitHub + Google in 15 Minutes

Set up GitHub and Google OAuth for any WOPR product using agent-browser + Chrome CDP.

## Prerequisites

- Chrome installed on Windows (WSL2 setup)
- GitHub account with 2FA
- Google Cloud account (free tier works)
- SSH access to the product's droplet
- `agent-browser` installed

## Step 1: Launch Chrome with CDP

```bash
# From WSL2 — launch Chrome on Windows with remote debugging
/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command \
  "Start-Process 'chrome.exe' -ArgumentList '--remote-debugging-port=9222','--user-data-dir=C:\temp\chrome-debug'"
```

All subsequent agent-browser commands use `--cdp 9222` to connect to this Chrome instance.

## Step 2: GitHub OAuth App

### Navigate and authenticate

```bash
agent-browser --cdp 9222 open https://github.com/settings/developers
agent-browser --cdp 9222 wait --load networkidle
```

If GitHub asks for 2FA, approve it in the browser window, then continue.

### Create the OAuth app

```bash
# Find and click "New OAuth app"
agent-browser --cdp 9222 snapshot -i  # Find the "New OAuth app" link ref
agent-browser --cdp 9222 click @eXX   # Click it
agent-browser --cdp 9222 wait --load networkidle

# Fill the form
agent-browser --cdp 9222 snapshot -i  # Get form field refs
agent-browser --cdp 9222 fill @eNAME "Your Product Name"
agent-browser --cdp 9222 fill @eURL "https://app.yourdomain.com"
agent-browser --cdp 9222 fill @eDESC "Your product description"
agent-browser --cdp 9222 fill @eCALLBACK "https://api.yourdomain.com/api/auth/callback/github"
agent-browser --cdp 9222 click @eREGISTER  # Register application
```

### Extract credentials

```bash
# Get Client ID
agent-browser --cdp 9222 eval --stdin <<'EVALEOF'
const text = document.body.innerText;
const match = text.match(/Client ID\s*\n\s*(\S+)/);
match ? match[1] : "not found"
EVALEOF

# Generate Client Secret — click "Generate a new client secret"
agent-browser --cdp 9222 snapshot -i  # Find the generate button
agent-browser --cdp 9222 click @eGENERATE
# May need 2FA approval — check browser, then continue
# The secret is shown once — copy it from the browser or ask the user
```

### Callback URL format

```
https://api.{domain}/api/auth/callback/github
```

BetterAuth registers this route automatically when `GITHUB_CLIENT_ID` + `GITHUB_CLIENT_SECRET` are set.

## Step 3: Google OAuth Client

### Navigate to GCP

```bash
agent-browser --cdp 9222 open "https://console.cloud.google.com/apis/credentials/oauthclient"
agent-browser --cdp 9222 wait 5000
```

This may redirect to the new Google Auth Platform at `console.cloud.google.com/auth/clients`.

### Create the OAuth client

```bash
# Select application type
agent-browser --cdp 9222 snapshot -i
agent-browser --cdp 9222 click @eTYPE_COMBO  # Click "Application type" combobox
agent-browser --cdp 9222 wait 1000
agent-browser --cdp 9222 find text "Web application" click

# Fill name and redirect URI
agent-browser --cdp 9222 wait 2000
agent-browser --cdp 9222 snapshot -i
agent-browser --cdp 9222 fill @eNAME "Your Product Name"

# Add redirect URI — click "Add URI" in the redirect section
agent-browser --cdp 9222 click @eADD_URI  # The second "Add URI" button (redirect, not JS origins)
agent-browser --cdp 9222 wait 1000
agent-browser --cdp 9222 snapshot -i
agent-browser --cdp 9222 fill @eURI "https://api.yourdomain.com/api/auth/callback/google"

# Create
agent-browser --cdp 9222 click @eCREATE
agent-browser --cdp 9222 wait 5000
```

### Extract credentials

```bash
agent-browser --cdp 9222 eval --stdin <<'EVALEOF'
const text = document.body.innerText;
const clientIdMatch = text.match(/Client ID\s*\n\s*(\S+)/);
const secretMatch = text.match(/Client secret\s*\n\s*(\S+)/);
JSON.stringify({
  clientId: clientIdMatch ? clientIdMatch[1] : "not found",
  clientSecret: secretMatch ? secretMatch[1] : "not found"
})
EVALEOF
```

### Publish the app (allow all users, not just test users)

```bash
agent-browser --cdp 9222 open "https://console.cloud.google.com/auth/audience"
agent-browser --cdp 9222 wait 5000
agent-browser --cdp 9222 snapshot -i  # Find "Publish app" button
agent-browser --cdp 9222 click @ePUBLISH
agent-browser --cdp 9222 wait 3000
agent-browser --cdp 9222 snapshot -i  # Find "Confirm" button
agent-browser --cdp 9222 click @eCONFIRM
```

### Callback URL format

```
https://api.{domain}/api/auth/callback/google
```

## Step 4: Set Environment Variables

### Add to the product's `.env` file on the droplet

```bash
ssh deploy@{DROPLET_IP} "cat >> /opt/{product}/.env << 'EOF'

# GitHub OAuth
GITHUB_CLIENT_ID={your_client_id}
GITHUB_CLIENT_SECRET={your_client_secret}

# Google OAuth
GOOGLE_CLIENT_ID={your_client_id}
GOOGLE_CLIENT_SECRET={your_client_secret}
EOF"
```

### Add to docker-compose.yml environment block

**CRITICAL**: Adding vars to `.env` alone is not enough. Docker Compose only passes env vars that are explicitly listed in the `environment:` block (using `${VAR}` interpolation).

```bash
# Add these lines to the platform-api service's environment block:
ssh deploy@{DROPLET_IP} "cd /opt/{product} && sed -i '/AWS_ACCESS_KEY_ID/a\
      - GITHUB_CLIENT_ID=\${GITHUB_CLIENT_ID}\n\
      - GITHUB_CLIENT_SECRET=\${GITHUB_CLIENT_SECRET}\n\
      - GOOGLE_CLIENT_ID=\${GOOGLE_CLIENT_ID}\n\
      - GOOGLE_CLIENT_SECRET=\${GOOGLE_CLIENT_SECRET}' docker-compose.yml"
```

### Recreate the container

```bash
# docker restart does NOT re-read env_file — must force-recreate
ssh deploy@{DROPLET_IP} "cd /opt/{product} && docker compose up -d --force-recreate platform-api"
```

### Verify

```bash
ssh deploy@{DROPLET_IP} "docker exec {product}-platform-api-1 env | grep -E 'GITHUB_CLIENT_ID|GOOGLE_CLIENT_ID'"
```

## How It Works (BetterAuth)

Platform-core's `better-auth.ts` has `resolveSocialProviders()` which checks env vars at startup:

- `GITHUB_CLIENT_ID` + `GITHUB_CLIENT_SECRET` → enables GitHub OAuth
- `GOOGLE_CLIENT_ID` + `GOOGLE_CLIENT_SECRET` → enables Google OAuth
- `DISCORD_CLIENT_ID` + `DISCORD_CLIENT_SECRET` → enables Discord OAuth

No code changes needed. The `OAuthButtons` component in `platform-ui-core` renders buttons for all configured providers automatically.

## Gotchas

| Issue | Fix |
|-------|-----|
| `docker restart` doesn't pick up new `.env` vars | Use `docker compose up -d --force-recreate` |
| `.env` vars not in container | Must also add `${VAR}` entries to compose `environment:` block |
| Google "Access blocked: testing" error | Publish the app in GCP Console → Auth Platform → Audience → Publish |
| GitHub 2FA blocks automation | Approve manually in the browser window, then continue with agent-browser |
| Chrome CDP connection refused | Kill all Chrome instances first, launch with `--remote-debugging-port=9222 --user-data-dir=C:\temp\chrome-debug` |
| `agent-browser` shows stale content | Use `--cdp 9222` flag (not headless) to connect to the real Chrome |

## Products Using This Setup

| Product | Droplet | GitHub OAuth | Google OAuth |
|---------|---------|-------------|-------------|
| Paperclip | 68.183.160.201 | `Ov23likozOBEs9lzUXIh` | `964670643245-...` |
| WOPR | 138.68.30.247 | — | Existing "Wopr" client |
| HolyShip | 138.68.46.192 | — | — |
| NemoClaw | 167.172.208.149 | — | — |
