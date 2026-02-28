#!/bin/bash
# GPU container entrypoint — installs Docker + NVIDIA Container Toolkit,
# then starts the GPU compose stack.
#
# Runs inside the wopr-gpu DinD container (nvidia/cuda:12.4.1-base-ubuntu22.04).
# On first boot this takes approximately 60-120s for apt installs.
# Subsequent boots reuse the gpu-docker-data volume and are faster (~15s).

set -e

echo "==> GPU container entrypoint starting..."

# ---------------------------------------------------------------------------
# Install Docker if not already present (first boot only)
# The gpu-docker-data volume persists the Docker installation.
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Docker not found. Installing..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg lsb-release
  curl -fsSL https://get.docker.com | sh
  echo "==> Docker installed."
else
  echo "==> Docker already installed, skipping."
fi

# ---------------------------------------------------------------------------
# Install NVIDIA Container Toolkit if not already present
# ---------------------------------------------------------------------------
if ! command -v nvidia-container-toolkit >/dev/null 2>&1; then
  echo "==> NVIDIA Container Toolkit not found. Installing..."
  export DEBIAN_FRONTEND=noninteractive
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq
  apt-get install -y -qq nvidia-container-toolkit
  echo "==> NVIDIA Container Toolkit installed."
else
  echo "==> NVIDIA Container Toolkit already installed, skipping."
fi

# ---------------------------------------------------------------------------
# Configure Docker daemon with nvidia as the default runtime
# ---------------------------------------------------------------------------
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'DAEMON_JSON'
{
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
DAEMON_JSON

nvidia-ctk runtime configure --runtime=docker --set-as-default 2>/dev/null || true

# ---------------------------------------------------------------------------
# Start the Docker daemon in the background
# ---------------------------------------------------------------------------
echo "==> Starting Docker daemon..."
dockerd &
DOCKERD_PID=$!

echo "==> Waiting for Docker daemon to be ready..."
timeout=60
while ! docker info >/dev/null 2>&1; do
  sleep 1
  timeout=$((timeout - 1))
  if [ $timeout -le 0 ]; then
    echo "ERROR: Docker daemon did not become ready in 60s"
    exit 1
  fi
done
echo "==> Docker daemon ready."

# ---------------------------------------------------------------------------
# Verify NVIDIA runtime is available
# ---------------------------------------------------------------------------
echo "==> Checking NVIDIA runtime..."
if docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
  echo "==> NVIDIA GPU accessible inside Docker."
else
  echo "WARNING: NVIDIA GPU not accessible inside Docker. GPU containers will start but may use CPU."
fi

# ---------------------------------------------------------------------------
# Authenticate with registries before pulling images
# Prevents Docker Hub rate limits and GHCR auth failures (WOP-1186)
# ---------------------------------------------------------------------------
echo "==> Authenticating with Docker registries..."
if [ -n "${REGISTRY_PASSWORD}" ] && [ -n "${REGISTRY_USERNAME}" ]; then
  echo "${REGISTRY_PASSWORD}" | docker login ghcr.io -u "${REGISTRY_USERNAME}" --password-stdin
  echo "${REGISTRY_PASSWORD}" | docker login -u "${REGISTRY_USERNAME}" --password-stdin
  echo "==> Registry auth done."
else
  echo "WARNING: REGISTRY_USERNAME/REGISTRY_PASSWORD not set — pulls may hit rate limits"
fi

# ---------------------------------------------------------------------------
# Start the GPU compose stack
# ---------------------------------------------------------------------------
echo "==> Starting GPU compose stack..."
cd /workspace/gpu

# Load env file if present
ENV_FILE=""
if [ -f .env ]; then
  ENV_FILE="--env-file .env"
fi

docker compose $ENV_FILE up -d

echo "==> GPU stack started."
echo "==> Services: llama-cpp:8080, chatterbox:8081, whisper:8082, qwen-embeddings:8083"
echo "==> Container will stay alive. Use 'docker compose logs -f' inside to follow logs."

# Keep the container alive (wait on dockerd)
wait $DOCKERD_PID
