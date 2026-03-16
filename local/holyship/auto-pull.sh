#!/bin/bash
# Auto-pull and restart holyship containers when new GHCR images are available.
# Cron: * * * * * /home/tsavo/wopr-ops/local/holyship/auto-pull.sh >> /tmp/holyship-auto-pull.log 2>&1

cd "$(dirname "$0")"

for svc in api ui; do
  # Get current running image digest
  container="holyship-${svc}"
  old=$(docker inspect "$container" --format '{{.Image}}' 2>/dev/null)

  # Pull latest
  docker compose pull "$svc" -q 2>/dev/null

  # Get the new image ID
  image=$(docker compose config --images 2>/dev/null | grep "$svc" | head -1)
  new=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null)

  if [ -n "$old" ] && [ -n "$new" ] && [ "$old" != "$new" ]; then
    echo "$(date -Iseconds) $svc: new image detected, restarting"
    docker compose up -d --no-deps "$svc" 2>/dev/null
  fi
done
