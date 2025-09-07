#!/usr/bin/env bash
set -euo pipefail

# Entry point for safe Poetry environment setup
# - Creates/updates the venv inside the project (.venv) if pyproject.toml exists
# - Installs dependencies without using cache
# - Avoids storing secrets or tokens in image layers

export PATH="/home/devuser/.local/bin:$PATH"
PROJECT_DIR=${PROJECT_DIR:-/workspace}
cd "$PROJECT_DIR"

# Optional: secure git clone before setup
if [[ -n "${GIT_REPO:-}" ]]; then
  if command -v ./secure-clone.sh >/dev/null 2>&1; then
    ./secure-clone.sh
  else
    echo "secure-clone.sh not found; skipping repo clone" >&2
  fi
fi

if [[ -f "pyproject.toml" ]]; then
  echo "Poetry project detected. Ensuring virtualenv and dependencies..."
  # Ensure Poetry uses in-project venv
  poetry config virtualenvs.in-project true --local || true
  # Create the venv if missing
  poetry env use python || true
  # Install dependencies with no cache and no interaction. Respect optional groups via POETRY_GROUPS
  if [[ -n "${POETRY_GROUPS:-}" ]]; then
    poetry install --no-interaction --no-ansi --no-root --with "$POETRY_GROUPS"
  else
    poetry install --no-interaction --no-ansi --no-root
  fi
fi

exec "$@"
