#!/usr/bin/env bash
set -euo pipefail

# Secure way to clone with credentials. Preferred: Docker/K8s secret mounted at /run/secrets/git_token
#
# Supports:
# - GitHub: set GIT_REPO=owner/repo (default), or GIT_URL=https://github.com/owner/repo.git
# - Azure DevOps: either set
#     - GIT_URL=https://dev.azure.com/<org>/<project>/_git/<repo>
#   or
#     - GIT_PROVIDER=azure and GIT_REPO=<org>/<project>/<repo> (or <org>/<project>/_git/<repo>)
#
# Usage examples:
#   GIT_REPO=owner/repo GIT_BRANCH=main ./secure-clone.sh
#   GIT_PROVIDER=azure GIT_REPO=org/project/repo ./secure-clone.sh
#   GIT_URL=https://dev.azure.com/org/project/_git/repo ./secure-clone.sh
# Optional env:
#   GIT_TOKEN_FILE=/run/secrets/git_token (preferred) or GIT_TOKEN=<pat>
#   GIT_USERNAME=x-access-token (GitHub) | azdo (Azure DevOps)
#   GIT_HOST=github.com|dev.azure.com (overrides host detection when building from GIT_REPO)
#   PROJECT_DIR=/workspace  TARGET_DIR=/workspace/repo

if [[ -z "${GIT_URL:-}" && -z "${GIT_REPO:-}" ]]; then
  echo "Error: set either GIT_URL (full https URL) or GIT_REPO (slug)" >&2
  echo "  - GitHub slug: owner/repo" >&2
  echo "  - Azure DevOps slug with GIT_PROVIDER=azure: org/project/repo or org/project/_git/repo" >&2
  exit 1
fi

TOKEN=""
if [[ -n "${GIT_TOKEN_FILE:-}" && -f "${GIT_TOKEN_FILE}" ]]; then
  # Trim trailing newlines/CR from token files to avoid auth failures
  TOKEN=$(tr -d '\r\n' < "${GIT_TOKEN_FILE}")
elif [[ -n "${GIT_TOKEN:-}" ]]; then
  echo "Warning: Using token from environment variable" >&2
  TOKEN="${GIT_TOKEN}"
else
  echo "Error: No Git token provided (set GIT_TOKEN_FILE or GIT_TOKEN)" >&2
  exit 1
fi

BASE_DIR="${PROJECT_DIR:-/workspace}"
if [[ -n "${TARGET_DIR:-}" ]]; then
  if [[ "${TARGET_DIR}" = /* ]]; then
    WORKSPACE_DIR="${TARGET_DIR}"
  else
    WORKSPACE_DIR="${BASE_DIR%/}/${TARGET_DIR}"
  fi
else
  WORKSPACE_DIR="${BASE_DIR}"
fi
mkdir -p "${WORKSPACE_DIR}"
cd "${WORKSPACE_DIR}"

# Build repository URL if not provided
REPO_URL="${GIT_URL:-}"
if [[ -z "$REPO_URL" ]]; then
  PROVIDER="${GIT_PROVIDER:-}"
  # lowercase
  PROVIDER="${PROVIDER,,}"
  HOST_DEFAULT="github.com"
  if [[ -n "${GIT_HOST:-}" ]]; then
    HOST_DEFAULT="$GIT_HOST"
  elif [[ "$PROVIDER" == "azure" || "$PROVIDER" == "ado" || "$PROVIDER" == "azure-devops" ]]; then
    HOST_DEFAULT="dev.azure.com"
  fi

  if [[ "$HOST_DEFAULT" == "github.com" && -z "$PROVIDER" ]]; then
    REPO_URL="https://github.com/${GIT_REPO}.git"
  else
    REPO_SLUG="$GIT_REPO"
    if [[ "$REPO_SLUG" != *"/_git/"* ]]; then
      IFS='/' read -r _org _project _repo rest <<<"$REPO_SLUG"
      if [[ -n "$_org" && -n "$_project" && -n "$_repo" && -z "${rest:-}" ]]; then
        REPO_PATH="${_org}/${_project}/_git/${_repo}"
      else
        REPO_PATH="$REPO_SLUG"
      fi
    else
      REPO_PATH="$REPO_SLUG"
    fi
    REPO_URL="https://${HOST_DEFAULT}/${REPO_PATH}"
  fi
fi

# Avoid leaking token in process listings by using env var expansion inside URL
# Using git -c to avoid writing credentials to config
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_ASKPASS_SCRIPT=$(mktemp -p "${HOME:-/home/devuser}")
trap 'rm -f "$GIT_ASKPASS_SCRIPT"' EXIT

USERNAME_DEFAULT="x-access-token"  # GitHub accepts this with PATs; override via GIT_USERNAME
# If targeting Azure DevOps, set a non-empty default username
if [[ "$REPO_URL" == *"dev.azure.com"* || "$REPO_URL" == *"visualstudio.com"* ]]; then
  USERNAME_DEFAULT="azdo"
fi
GIT_USERNAME_VALUE="${GIT_USERNAME:-$USERNAME_DEFAULT}"

cat >"$GIT_ASKPASS_SCRIPT" <<'EOF'
#!/usr/bin/env bash
prompt="$1"
if [[ "$prompt" == *"Username"* ]]; then
  echo "$GIT_USERNAME_VALUE"
else
  echo "$GIT_TOKEN"
fi
EOF
chmod 700 "$GIT_ASKPASS_SCRIPT"

export GIT_ASKPASS="$GIT_ASKPASS_SCRIPT"
export GIT_TOKEN="$TOKEN"
export GIT_USERNAME_VALUE="$GIT_USERNAME_VALUE"

if [[ -d .git ]]; then
  echo "Workspace contains a git repo. Updating..." >&2
  ORIGIN_URL=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ -n "$ORIGIN_URL" && "$ORIGIN_URL" != *"${GIT_REPO}"* && "$ORIGIN_URL" != *"${REPO_URL}"* ]]; then
    if [[ "${GIT_FORCE_RECLONE:-}" == "1" ]]; then
      echo "Origin mismatch. Re-cloning into workspace due to GIT_FORCE_RECLONE=1" >&2
      # Clean workspace (including dotfiles), but keep current dir
      shopt -s dotglob nullglob
      rm -rf -- *
      shopt -u dotglob nullglob
      git -c credential.helper= -c core.askpass="$GIT_ASKPASS_SCRIPT" \
        clone --branch "$GIT_BRANCH" "$REPO_URL" .
    else
      echo "Existing repo origin ($ORIGIN_URL) does not match requested ($REPO_URL). Set GIT_FORCE_RECLONE=1 to replace." >&2
      exit 1
    fi
  else
    # Ensure correct remote URL (handles https/ssh variants)
    git remote set-url origin "$REPO_URL" || true
    git fetch --all --prune
    # Ensure branch exists locally or track it from origin
    if git show-ref --verify --quiet "refs/heads/$GIT_BRANCH"; then
      git checkout "$GIT_BRANCH"
    else
      git checkout -B "$GIT_BRANCH" "origin/$GIT_BRANCH" || git checkout -b "$GIT_BRANCH"
    fi
    git pull --ff-only origin "$GIT_BRANCH" || true
  fi
elif [[ -n "$(ls -A "$WORKSPACE_DIR" 2>/dev/null || true)" ]]; then
  if [[ "${GIT_FORCE_RECLONE:-}" == "1" ]]; then
    echo "Workspace not empty. Re-cloning into workspace due to GIT_FORCE_RECLONE=1" >&2
    shopt -s dotglob nullglob
    rm -rf -- *
    shopt -u dotglob nullglob
    git -c credential.helper= -c core.askpass="$GIT_ASKPASS_SCRIPT" \
      clone --branch "$GIT_BRANCH" "$REPO_URL" .
  else
    echo "Workspace '${WORKSPACE_DIR}' is not empty and not a git repo. Set GIT_FORCE_RECLONE=1 to replace its contents." >&2
    exit 1
  fi
else
  # Empty workspace: clone directly into this directory
  git -c credential.helper= -c core.askpass="$GIT_ASKPASS_SCRIPT" \
    clone --branch "$GIT_BRANCH" "$REPO_URL" .
fi

unset TOKEN GIT_TOKEN
