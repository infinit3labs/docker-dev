#!/usr/bin/env bash
set -euo pipefail

# Build with BuildKit and scan image with Trivy
# Requirements: Docker, Trivy (docker image used below)

IMAGE_NAME=${IMAGE_NAME:-docker-dev-secure:latest}
DOCKERFILE=${DOCKERFILE:-Dockerfile}

# Basic leak check for obvious secrets
if grep -R -nE "(?i)(password|token|apikey|api_key|secret|client_secret)" \
  --include "*.py" --include "*.yml" --include "*.yaml" --include "*.json" --include "Dockerfile*" .; then
  echo "Potential secrets found. Review before building." >&2
  exit 1
fi

export DOCKER_BUILDKIT=1

echo "Building ${IMAGE_NAME} using ${DOCKERFILE}..."
docker build --pull --no-cache -t "${IMAGE_NAME}" -f "${DOCKERFILE}" .

echo "Scanning image with Trivy (HIGH,CRITICAL)..."
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image --severity HIGH,CRITICAL "${IMAGE_NAME}"

echo "Build and scan completed."
