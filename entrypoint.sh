#!/usr/bin/env bash
set -euo pipefail

# Entry point for safe Poetry environment setup
# - Runs entirely as root
# - Creates/updates the venv inside the project (.venv) if pyproject.toml exists
# - Installs dependencies without using cache
# - Avoids storing secrets or tokens in image layers

export PATH="/root/.local/bin:$PATH"
# Default location for secret token file unless overridden via env
export GIT_TOKEN_FILE=${GIT_TOKEN_FILE:-/run/secrets/git_token}
PROJECT_DIR=${PROJECT_DIR:-/workspace}
LOGFILE="${PROJECT_DIR}/entrypoint.log"

# Simple logger: timestamp to both stderr and log file (if writable)
log() {
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s %s\n' "$ts" "$*" >&2
  if [[ -d "${PROJECT_DIR}" ]]; then
    printf '%s %s\n' "$ts" "$*" >>"${LOGFILE}" 2>/dev/null || true
  fi
}

trap 'log "entrypoint exit code:$?"' EXIT

mkdir -p "$PROJECT_DIR"

cd "$PROJECT_DIR"

# Configure global Git options (idempotent)
if command -v git >/dev/null 2>&1; then
  log "configuring global git settings"
  git_conf_set() {
    local key="$1" val="$2"
    # Set only if non-empty value provided and key not already set
    if [[ -n "$val" ]]; then
      if git config --global --get "$key" >/dev/null 2>&1; then
        :
      else
        git config --global "$key" "$val" || log "failed to set git $key"
      fi
    fi
  }

  # Required/requested settings with env overrides
  git_conf_set user.name  "${GIT_USER_NAME:-}"
  git_conf_set user.email "${GIT_USER_EMAIL:-}"
  git_conf_set credential.useHttpPath "${GIT_CREDENTIAL_USE_HTTP_PATH:-true}"

  # Sensible defaults (overridable via env)
  git_conf_set fetch.prune         "${GIT_FETCH_PRUNE:-true}"
  git_conf_set pull.rebase         "${GIT_PULL_REBASE:-false}"
  git_conf_set rebase.autoStash    "${GIT_REBASE_AUTOSTASH:-true}"
  git_conf_set init.defaultBranch  "${GIT_DEFAULT_BRANCH:-main}"
  git_conf_set push.default        "${GIT_PUSH_DEFAULT:-simple}"
  git_conf_set color.ui            "${GIT_COLOR_UI:-auto}"
  git_conf_set core.autocrlf       "${GIT_CORE_AUTOCRLF:-false}"
  git_conf_set core.filemode       "${GIT_CORE_FILEMODE:-false}"
  git_conf_set log.date            "${GIT_LOG_DATE:-iso}"

  # Mark the workspace as safe to avoid dubious ownership warnings in bind mounts
  # Space-separated list; supports globs like $PROJECT_DIR/repos/*
  IFS=' ' read -r -a _safe_dirs <<< "${GIT_SAFE_DIRECTORIES:-$PROJECT_DIR $PROJECT_DIR/repos/*}"
  # Capture once to avoid pipefail; compare via here-string
  _existing_safe_dirs=$(git config --global --get-all safe.directory 2>/dev/null || true)
  for d in "${_safe_dirs[@]}"; do
    if ! grep -Fxq "$d" <<< "$_existing_safe_dirs"; then
      git config --global --add safe.directory "$d" || true
    fi
  done
fi

# Unattended Oh My Zsh and plugin installation (idempotent)
OHMYZSH_REPO="${OHMYZSH_REPO:-https://github.com/ohmyzsh/ohmyzsh.git}"
OHMYZSH_REF="${OHMYZSH_REF:-master}"
P10K_REPO="${P10K_REPO:-https://github.com/romkatv/powerlevel10k.git}"
P10K_REF="${P10K_REF:-master}"
ZSHAUTO_REPO="${ZSHAUTO_REPO:-https://github.com/zsh-users/zsh-autosuggestions.git}"
ZSHAUTO_REF="${ZSHAUTO_REF:-master}"
ZSHHL_REPO="${ZSHHL_REPO:-https://github.com/zsh-users/zsh-syntax-highlighting.git}"
ZSHHL_REF="${ZSHHL_REF:-master}"

ZSH_DIR="/root/.oh-my-zsh"
ZSHRC="/root/.zshrc"

# Only install if not already present
if [[ ! -d "$ZSH_DIR" ]]; then
  git clone --depth 1 --branch "$OHMYZSH_REF" "$OHMYZSH_REPO" "$ZSH_DIR"
fi
if [[ ! -f "$ZSHRC" ]]; then
  cp "$ZSH_DIR/templates/zshrc.zsh-template" "$ZSHRC"
fi
mkdir -p "$ZSH_DIR/custom/themes" "$ZSH_DIR/custom/plugins"

# Powerlevel10k theme (defer config wizard)
if [[ ! -d "$ZSH_DIR/custom/themes/powerlevel10k" ]]; then
  git clone --depth 1 --branch "$P10K_REF" "$P10K_REPO" "$ZSH_DIR/custom/themes/powerlevel10k"
fi
# zsh-autosuggestions
if [[ ! -d "$ZSH_DIR/custom/plugins/zsh-autosuggestions" ]]; then
  git clone --depth 1 --branch "$ZSHAUTO_REF" "$ZSHAUTO_REPO" "$ZSH_DIR/custom/plugins/zsh-autosuggestions"
fi
# zsh-syntax-highlighting
if [[ ! -d "$ZSH_DIR/custom/plugins/zsh-syntax-highlighting" ]]; then
  git clone --depth 1 --branch "$ZSHHL_REF" "$ZSHHL_REPO" "$ZSH_DIR/custom/plugins/zsh-syntax-highlighting"
fi

# Set theme to powerlevel10k but do NOT run p10k configure (defer to user login)
if grep -q '^ZSH_THEME=' "$ZSHRC"; then
  sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|g' "$ZSHRC"
else
  echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> "$ZSHRC"
fi
# Set plugins (idempotent)
if grep -q '^plugins=' "$ZSHRC"; then
  sed -i 's|^plugins=.*|plugins=(git zsh-autosuggestions zsh-syntax-highlighting)|g' "$ZSHRC"
else
  echo 'plugins=(git zsh-autosuggestions zsh-syntax-highlighting)' >> "$ZSHRC"
fi

# Ensure Powerlevel10k config is sourced to avoid interactive wizard
if ! grep -q 'source ~/.p10k.zsh' "$ZSHRC"; then
  echo '[[ -r ~/.p10k.zsh ]] && source ~/.p10k.zsh' >> "$ZSHRC"
fi

# Enable pyenv and pipx in .zshrc if not already present (idempotent)
if ! grep -q 'PYENV_ROOT' "$ZSHRC"; then
  cat >> "$ZSHRC" <<'ZSH_CFG'

# Pyenv initialization
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv >/dev/null 2>&1; then
  eval "$(pyenv init --path)"
  eval "$(pyenv init -)"
fi
ZSH_CFG
fi

if ! grep -q 'pipx' "$ZSHRC"; then
  cat >> "$ZSHRC" <<'ZSH_PIPX'

# Pipx initialization
export PATH="$HOME/.local/bin:$PATH"
ZSH_PIPX
fi

# Create a minimal Powerlevel10k config to prevent the interactive wizard from running
P10K_CONF_DIR="/root/.p10k.zsh"
if [[ ! -f "/root/.p10k.zsh" ]]; then
  cat > "/root/.p10k.zsh" <<'P10K_MIN'
# Minimal Powerlevel10k config to avoid interactive setup in containers
typeset -g POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=1
POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(user dir vcs)
POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=()
P10K_MIN
  # Running as root; no chown needed
fi

# Optional: secure git clone before setup
if [[ -n "${GIT_REPO:-}" || -n "${GIT_URL:-}" || -n "${GIT_REPOS:-}" ]]; then
  if [[ -x "/usr/local/bin/secure-clone.sh" ]]; then
    log "running secure-clone.sh"
    /usr/local/bin/secure-clone.sh || log "secure-clone.sh exited with $?"
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

# If no pyproject in current PROJECT_DIR, but exactly one repo under $PROJECT_DIR/repos
# has a pyproject.toml, switch PROJECT_DIR into that repo to enable Poetry setup.
if [[ ! -f "pyproject.toml" ]]; then
  if [[ -d "$PROJECT_DIR/repos" ]]; then
    # Find up to two candidates to detect uniqueness
    mapfile -t _pyprojects < <(find "$PROJECT_DIR/repos" -mindepth 2 -maxdepth 2 -type f -name pyproject.toml 2>/dev/null | head -n 2)
    if [[ ${#_pyprojects[@]} -eq 1 ]]; then
      _newdir="$(dirname "${_pyprojects[0]}")"
      log "switching PROJECT_DIR to $_newdir"
      PROJECT_DIR="$_newdir"; export PROJECT_DIR
      cd "$PROJECT_DIR" || log "failed to cd into $_newdir"
    elif [[ ${#_pyprojects[@]} -gt 1 ]]; then
      log "multiple pyproject.toml found under $PROJECT_DIR/repos; staying in $PROJECT_DIR"
    fi
  fi
fi

if [[ -f "pyproject.toml" ]]; then
  log "Poetry project detected. Ensuring virtualenv and dependencies..."
  # Temporarily relax 'set -e' so failures here don't kill the entrypoint
  set +e
  # Create the venv if missing
  poetry env use python || true
  # Install dependencies with no cache and no interaction. Respect optional groups via POETRY_GROUPS
  POETRY_AUTO_RELOCK=${POETRY_AUTO_RELOCK:-1}
  install_args=(--no-interaction --no-ansi --no-root)
  if [[ -n "${POETRY_GROUPS:-}" ]]; then
    install_args+=(--with "$POETRY_GROUPS")
  fi
  if poetry install "${install_args[@]}"; then
    :
  else
    rc=$?
    log "poetry install failed with code $rc; attempting lock regeneration (POETRY_AUTO_RELOCK=$POETRY_AUTO_RELOCK)"
    if [[ "$POETRY_AUTO_RELOCK" == "1" ]]; then
      poetry lock --no-interaction --no-ansi --no-update || poetry lock --no-interaction --no-ansi || true
      if poetry install "${install_args[@]}"; then
        :
      else
        rc2=$?
        log "poetry install still failing after relock (code $rc2); continuing without blocking shell"
      fi
    else
      log "skipping auto relock per POETRY_AUTO_RELOCK=0"
    fi
  fi
  # Reinstate 'set -e'
  set -e
fi

# Optionally supervise the final command to auto-restart on transient errors.
# Set ENABLE_SUPERVISOR=1 to enable, SUPERVISOR_MAX_RETRIES and SUPERVISOR_BASE_BACKOFF
# control behavior (defaults below).
ENABLE_SUPERVISOR=${ENABLE_SUPERVISOR:-0}
SUPERVISOR_MAX_RETRIES=${SUPERVISOR_MAX_RETRIES:-5}
SUPERVISOR_BASE_BACKOFF=${SUPERVISOR_BASE_BACKOFF:-1}

# If the target command is an interactive shell, disable supervisor to avoid
# immediate exit/restarts when the shell exits cleanly.
if [[ "$ENABLE_SUPERVISOR" == "1" ]]; then
  case "${1:-}" in
    */zsh|zsh|*/bash|bash)
      log "interactive shell detected ($1); disabling supervisor"
      ENABLE_SUPERVISOR=0
      ;;
  esac
fi

if [[ "$ENABLE_SUPERVISOR" == "1" ]]; then
  attempt=0
  while true; do
    attempt=$((attempt+1))
    log "supervisor: starting attempt $attempt: $*"
    "$@"
    rc=$?
    log "supervisor: command exited with code $rc"
    if [[ $rc -eq 0 ]]; then
      log "supervisor: command exited cleanly; exiting supervisor"
      exit 0
    fi
    if [[ $attempt -ge $SUPERVISOR_MAX_RETRIES ]]; then
      log "supervisor: reached max retries ($SUPERVISOR_MAX_RETRIES); aborting"
      exit $rc
    fi
    # Exponential backoff
    backoff=$((SUPERVISOR_BASE_BACKOFF * (2 ** (attempt-1))))
    log "supervisor: sleeping ${backoff}s before retry"
    sleep $backoff
  done
else
  exec "$@"
fi
