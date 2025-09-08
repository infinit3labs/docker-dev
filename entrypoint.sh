#!/usr/bin/env bash
set -euo pipefail

# Entry point for safe Poetry environment setup
# - Fixes /workspace permissions if starting as root, then re-execs as devuser
# - Creates/updates the venv inside the project (.venv) if pyproject.toml exists
# - Installs dependencies without using cache
# - Avoids storing secrets or tokens in image layers

export PATH="/home/devuser/.local/bin:$PATH"
# Default location for secret token file unless overridden via env
export GIT_TOKEN_FILE=${GIT_TOKEN_FILE:-/run/secrets/git_token}
PROJECT_DIR=${PROJECT_DIR:-/workspace}

# If running as root (e.g., via compose user: root), ensure /workspace is writable by devuser and drop to devuser
if [[ "$(id -u)" == "0" && "${ENTRYPOINT_AS_DEVUSER:-}" != "1" ]]; then
  mkdir -p "$PROJECT_DIR"
  chown -R devuser:devuser "$PROJECT_DIR" || true
  # Re-exec this entrypoint as devuser with the same args, preserving env
  printf -v _argv '%q ' "$@"
  exec su -p -l devuser -c "ENTRYPOINT_AS_DEVUSER=1 /usr/local/bin/entrypoint.sh ${_argv}"
fi

cd "$PROJECT_DIR"

# Optional: secure git clone before setup
if [[ -n "${GIT_REPO:-}" || -n "${GIT_URL:-}" || -n "${GIT_REPOS:-}" ]]; then
  if [[ -x "/usr/local/bin/secure-clone.sh" ]]; then
    /usr/local/bin/secure-clone.sh
  elif [[ -f "./secure-clone.sh" ]]; then
    # If the script isn't executable or the mount is noexec, run via bash
    if [[ -x "./secure-clone.sh" ]]; then
      ./secure-clone.sh
    else
      bash ./secure-clone.sh
    fi
  else
    echo "secure-clone.sh not found in image or project; skipping repo clone" >&2
  fi
fi

if [[ -f "pyproject.toml" ]]; then
  echo "Poetry project detected. Ensuring virtualenv and dependencies..."
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
