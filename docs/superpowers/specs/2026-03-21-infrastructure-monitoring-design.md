# Infrastructure Monitoring Design

**Date:** 2026-03-21
**Status:** Approved
**Author:** Claude + Tsavo

## Problem

4 production droplets with zero monitoring. Chain server running 5 containers at 5x load average with no visibility into sync progress, disk pressure, or container health. Currently using a cron that SSHes in every 30 minutes — inadequate for production infrastructure.

## Decision

Netdata — open source, self-hosted, zero-config Docker monitoring with free cloud dashboard.

## Architecture

```
chain-server (pay.wopr.bot)     → netdata:19999 (5 containers + chain metrics)
wopr-platform (138.68.30.247)   → netdata:19999 (4 containers)
holyship (138.68.46.192)        → netdata:19999 (4 containers)
nemoclaw (167.172.208.149)      → netdata:19999 (3 containers)
         │
         └──── all stream to ────→ Netdata Cloud (free, 5 nodes)
                                   Single dashboard at app.netdata.cloud
```

Port 19999 firewalled to admin IP only. Access via Netdata Cloud or SSH tunnel.

## Deployment

### Per-Droplet Container

Added to each product's `docker-compose.yml`:

```yaml
netdata:
  image: netdata/netdata:stable
  container_name: netdata
  hostname: <droplet-name>
  cap_add:
    - SYS_PTRACE
    - SYS_ADMIN
  security_opt:
    - apparmor:unconfined
  ports:
    - "19999:19999"
  volumes:
    - /proc:/host/proc:ro
    - /sys:/host/sys:ro
    - /var/run/docker.sock:/var/run/docker.sock:ro
    - /etc/os-release:/host/etc/os-release:ro
    - netdata_config:/etc/netdata
    - netdata_lib:/var/lib/netdata
    - netdata_cache:/var/cache/netdata
  environment:
    - NETDATA_CLAIM_TOKEN=<from-cloud>
    - NETDATA_CLAIM_URL=https://app.netdata.cloud
    - NETDATA_CLAIM_ROOMS=<room-id>
  restart: unless-stopped
```

### Chain Server Low Resource Mode

On the chain server (already pegged at 5x load), add environment:

```yaml
environment:
  - NETDATA_DISABLE_ML=1
  - NETDATA_DISABLE_CLOUD_DURING_AGENT_START=1
```

This reduces Netdata to <1% CPU and ~100MB RAM by disabling ML anomaly detection.

## Custom Chain Collectors

Shell script collector at `/opt/chain-server/netdata-collectors/chain-sync.sh`, runs every 30 seconds.

Queries each node's RPC and outputs Netdata-compatible metrics:

### Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `chain.btc.blocks` | gauge | Current block height |
| `chain.btc.progress` | gauge | Sync progress (0.0-1.0) |
| `chain.btc.peers` | gauge | Connected peer count |
| `chain.doge.blocks` | gauge | Current block height |
| `chain.doge.progress` | gauge | Sync progress (0.0-1.0) |
| `chain.doge.peers` | gauge | Connected peer count |
| `chain.ltc.blocks` | gauge | Current block height |
| `chain.ltc.progress` | gauge | Sync progress (0.0-1.0) |
| `chain.ltc.peers` | gauge | Connected peer count |

### Collector Script

Uses Netdata's `charts.d` plugin format. Calls each node's `getblockchaininfo` RPC and `getconnectioncount` every 30 seconds. Handles RPC failures gracefully (outputs 0 instead of crashing).

RPC credentials read from `/opt/chain-server/.env`.

## Alerts

### Custom Alerts (chain server)

| Alert | Condition | Severity | Action |
|-------|-----------|----------|--------|
| Chain peers zero | peers = 0 for > 5 min | warning | Discord |
| Chain progress stuck | progress unchanged for > 30 min (and < 1.0) | critical | Discord |
| Key server down | crypto health endpoint fails | critical | Discord |

### Default Netdata Alerts (all droplets)

| Alert | Condition | Severity |
|-------|-----------|----------|
| Disk space | > 85% used | warning |
| Disk space | > 95% used | critical |
| CPU | > 90% sustained 30 min | warning |
| RAM | > 90% used | warning |
| Swap | > 80% used | warning |
| Container restart | restart count > 0 | warning |
| Container OOM | OOM kill detected | critical |

## Notification Routing

Netdata Cloud free tier handles all notifications:

- **Discord webhook** → `#infra-alerts` channel
- **Email** → backup

Severity mapping:
- **Critical** → immediate Discord ping
- **Warning** → batched, no ping
- **Info** → dashboard only

## Security

- Port 19999 blocked by DO Cloud Firewall on all droplets
- Access via Netdata Cloud (authenticated) or SSH tunnel
- Docker socket mounted read-only
- No secrets in Netdata config — chain RPC creds read from existing .env files

## Cost

$0/mo. Netdata is open source. Cloud free tier supports up to 5 nodes (we have 4).

## Implementation Steps

1. Sign up for Netdata Cloud, create a "WOPR Infrastructure" space
2. Get claim token and room ID
3. Add netdata container to chain server docker-compose (low resource mode)
4. Write chain-sync.sh collector script
5. Add netdata container to wopr-platform, holyship, nemoclaw composes
6. Configure Discord webhook in Netdata Cloud
7. Configure custom chain alerts
8. Update DO Cloud Firewall to block 19999 from public
9. Delete the cron job
10. Update RUNBOOK.md with monitoring access instructions

## Success Criteria

- All 4 droplets visible in Netdata Cloud dashboard
- Chain sync progress charted in real-time
- Discord alert fires within 5 minutes of container crash
- Disk space alert fires at 85% threshold
- Zero additional cost
