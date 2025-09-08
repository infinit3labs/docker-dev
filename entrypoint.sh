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

# Unattended Oh My Zsh and plugin installation (idempotent)
OHMYZSH_REPO="${OHMYZSH_REPO:-https://github.com/ohmyzsh/ohmyzsh.git}"
OHMYZSH_REF="${OHMYZSH_REF:-master}"
P10K_REPO="${P10K_REPO:-https://github.com/romkatv/powerlevel10k.git}"
P10K_REF="${P10K_REF:-master}"
ZSHAUTO_REPO="${ZSHAUTO_REPO:-https://github.com/zsh-users/zsh-autosuggestions.git}"
ZSHAUTO_REF="${ZSHAUTO_REF:-master}"
ZSHHL_REPO="${ZSHHL_REPO:-https://github.com/zsh-users/zsh-syntax-highlighting.git}"
ZSHHL_REF="${ZSHHL_REF:-master}"

ZSH_DIR="/home/devuser/.oh-my-zsh"
ZSHRC="/home/devuser/.zshrc"

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

# Enable pyenv and pipx in .zshrc if not already present
if ! grep -q 'pyenv init' "$ZSHRC"; then
  echo '' >> "$ZSHRC"
  echo '# Pyenv initialization' >> "$ZSHRC"
  echo 'export PYENV_ROOT="$HOME/.pyenv"' >> "$ZSHRC"
  echo 'export PATH="$PYENV_ROOT/bin:$PATH"' >> "$ZSHRC"
  echo 'eval "$(pyenv init --path)"' >> "$ZSHRC"
  echo 'eval "$(pyenv init -)"' >> "$ZSHRC"
fi
if ! grep -q 'pipx' "$ZSHRC"; then
  echo '' >> "$ZSHRC"
  echo '# Pipx initialization' >> "$ZSHRC"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$ZSHRC"
fi

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
